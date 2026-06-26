#!/usr/bin/env python3
"""graduate-jam.py — script the jam→spec graduation move (ADR-061).

Operationalizes the jam→spec boundary of the move-on-advance lifecycle (ADR-051 §7.2) that was previously a
hand-driven `git mv` snippet in core/skills/bulk-decompose-jams/SKILL.md. Three operations, in order:

  1. MOVE     docs/step-2-planning/jam-<slug>/ → docs/step-3-specs/<slug>/  (git mv preferred, plain mv fallback,
              mirroring core/skills/orchestrated/SKILL.md:84,118).
  2. RESHAPE  (--target orchestrated only) the jam's `# Wave: <name>` headers into per-wave folders
              docs/step-3-specs/<slug>/waves/<wave-slug>/{<wave-slug>.md, <wave-slug>-prompts.md}.
  3. INTENT   the converged brief (README.md, fallback index.md) rides along to the spec via the move,
              completing the forward direction of ADR-051 §8's intent handoff.

--target bypass is move-only — no waves/ reshape; the paste-ready decomposition/prompts.md rides along to
docs/step-3-specs/<slug>/decomposition/prompts.md.

Decomposition discovery order: decomposition/tickets.md first; if absent (or header-free), any other
decomposition/*.md is scanned for `# Wave:` headers.

Reshape split heuristic: each `# Wave: <name>` section's body (from its header to the next header or EOF)
is written verbatim to <wave-slug>.md. The paired <wave-slug>-prompts.md is sourced from a `## Prompts` /
`## Build prompts` subsection inside that wave's body when one exists; otherwise a minimal pointer stub is
written so BOTH per-wave files always exist (the `# Wave:` schema carries the build content; per-ticket
prompts may be authored into the stub later).

Idempotency-via-refusal: refuses when docs/step-3-specs/<slug>/ already exists and is non-empty (an empty target
dir is treated as absent). Path-safety inherited from ADR-049: the slug is validated first and interpolated
into paths only after acceptance; both endpoints are realpath-bounded under repo_root before any mutation;
subprocess is always called with an argument list (NEVER shell=True); no operator-controlled inputs beyond
the three flags (no input(), no os.environ/getenv).

Usage:
  python3 core/scripts/graduate-jam.py --slug <slug> --target {orchestrated,bypass} [--repo-root <path>]

Last stdout line is machine-parseable:
  GRADUATE-JAM: moved jam-<slug> → docs/step-3-specs/<slug>/ (W waves reshaped, I intent artifact, R retained files).
"""
import argparse
import os
import re
import shutil  # noqa: F401  (stdlib import declared by the ADR-061 contract; mv fallback uses subprocess)
import subprocess
import sys

SLUG_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')   # matches core/scripts/workflows/roadmap.js:55
BRIEF_FILES = ('README.md', 'index.md')          # matches core/scripts/bulk-decompose-plan.py:43, ADR-051 §8
WAVE_HEADER_RE = re.compile(r'^# Wave:[ \t]+(.+?)[ \t]*$', re.MULTILINE)
PROMPTS_SUBSECTION_RE = re.compile(r'^##[ \t]+(?:Build [Pp]rompts|Prompts)\b.*$', re.MULTILINE)
DECOMP_DIR = 'decomposition'


def _die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _repo_root():
    """Resolve the repo root robustly: git rev-parse first, else the path-relative fallback.

    NOTE (bugfix): the prior default `dirname(dirname(abspath(__file__)))` resolved to
    `<repo>/core` (only two levels up from THIS file, which lives at `core/scripts/`), so a
    caller that did NOT pass `--repo-root` built `core/docs/...` paths and failed 'source
    missing'. This bit the W1B auto-graduate wiring (roadmap/SKILL.md calls graduate-jam.py
    without --repo-root). Mirror closeout-run.py::_repo_root — git toplevel, else
    `dirname(__file__)/../..` which IS the repo root from `core/scripts/`."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def validate_slug(slug):
    """Reject path-traversal and non-kebab slugs (ADR-049 discipline). Returns the slug on success; exits
    non-zero with a single 'graduate-jam: invalid slug:' stderr line on rejection."""
    if (slug is None or slug == '' or slug != slug.strip() or slug.startswith('-')
            or '..' in slug or '/' in slug or not SLUG_RE.match(slug)):
        _die(f"graduate-jam: invalid slug: {slug!r}")
    return slug


def wave_slug_from_header(name):
    """Normalize a `# Wave: <name>` header to a kebab slug. Exits non-zero with a single
    'graduate-jam: invalid wave header:' stderr line if normalization yields a non-SLUG_RE result."""
    slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
    if not slug or not SLUG_RE.match(slug):
        _die(f"graduate-jam: invalid wave header: {name!r}")
    return slug


def discover_intent_artifact(jam_dir):
    """Return the first existing of (jam_dir/README.md, jam_dir/index.md), or None if neither exists."""
    for fn in BRIEF_FILES:
        p = os.path.join(jam_dir, fn)
        if os.path.isfile(p):
            return p
    return None


def _find_decomp_text(jam_dir):
    """Return (path, text) of the decomposition file carrying `# Wave:` headers, or (path-or-None, text)
    for the best candidate. Discovery order: decomposition/tickets.md first, then any other
    decomposition/*.md (sorted)."""
    decomp = os.path.join(jam_dir, DECOMP_DIR)
    candidates = []
    primary = os.path.join(decomp, 'tickets.md')
    if os.path.isfile(primary):
        candidates.append(primary)
    if os.path.isdir(decomp):
        for fn in sorted(os.listdir(decomp)):
            p = os.path.join(decomp, fn)
            if p != primary and fn.endswith('.md') and os.path.isfile(p):
                candidates.append(p)
    for p in candidates:
        try:
            with open(p, encoding='utf-8') as f:
                text = f.read()
        except OSError:
            continue
        if WAVE_HEADER_RE.search(text):
            return p, text
    if candidates:
        try:
            with open(candidates[0], encoding='utf-8') as f:
                return candidates[0], f.read()
        except OSError:
            pass
    return None, ''


def _parse_waves(text):
    """Return [(wave_name, section_body), ...] — one entry per `# Wave:` header; body runs from the header
    to the next header (or EOF)."""
    matches = list(WAVE_HEADER_RE.finditer(text))
    waves = []
    for i, m in enumerate(matches):
        name = m.group(1).strip()
        start = m.start()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        waves.append((name, text[start:end].rstrip() + '\n'))
    return waves


def _prompts_for(wave_slug, body):
    """Extract a `## Prompts` / `## Build prompts` subsection from the wave body if present; otherwise a
    minimal pointer stub so the per-wave prompts file always exists."""
    m = PROMPTS_SUBSECTION_RE.search(body)
    if m:
        return body[m.start():].rstrip() + '\n'
    return (f"# {wave_slug} — build prompts\n\n"
            f"Per-ticket prompts for wave `{wave_slug}`, graduated from the jam's `# Wave:` schema. "
            f"See `{wave_slug}.md` for the ticket list; author paste-ready prompts here before dispatch.\n")


def _git_or_plain_mv(src, dst, cwd):
    """Move src→dst — `git mv` preferred (history-preserving), plain `mv` fallback when git is unavailable
    or the tree is untracked. The git invocation runs with cwd set to the repo root so it operates on the
    intended repo, not the caller's cwd. NEVER shell=True (path-safety, ADR-049: arg-list only)."""
    r = subprocess.run(['git', 'mv', src, dst], cwd=cwd,
                       capture_output=True, text=True, check=False)
    if r.returncode != 0:
        subprocess.run(['mv', src, dst], check=True)


def _merge_dir(source, target, cwd):
    """File-granularity merge of a colliding directory pair (CR-001 fix). Move every entry of source INTO
    the existing target dir; on a colliding entry, recurse if BOTH sides are directories, otherwise skip the
    individually-colliding leaf (never overwrite — a colliding leaf is the idempotent / already-present
    case). Non-colliding files/subdirs move wholesale. After the merge, rmdir source if it emptied.

    Bounded + path-safe: source and target are already realpath-bounded under repo_root by main(); the
    recursion only ever walks within the validated source tree into the validated target tree, and every
    subprocess is an arg-list (NEVER shell=True). Returns nothing — counts are tracked by the top-level
    caller."""
    for entry in sorted(os.listdir(source)):
        src = os.path.join(source, entry)
        dst = os.path.join(target, entry)
        if os.path.exists(dst):
            if os.path.isdir(src) and os.path.isdir(dst):
                # Both directories collide -> recurse and merge at file granularity.
                _merge_dir(src, dst, cwd)
            else:
                # Colliding leaf file (or type mismatch): never overwrite; leave it in source.
                print(f"graduate-jam: skip (target entry exists): "
                      f"{os.path.relpath(dst, target)}", file=sys.stderr)
            continue
        # No collision -> move the whole entry (file or subdir) wholesale.
        _git_or_plain_mv(src, dst, cwd)
    # rmdir only a genuinely-emptied source dir (collision-skipped leaves safely remain — no data loss).
    try:
        os.rmdir(source)
    except OSError:
        pass


def _move_tree(source, target, cwd, skip_existing=False):
    """Move every top-level entry of source into target — `git mv` preferred (history-preserving), plain
    `mv` fallback when git is unavailable or the tree is untracked. The git invocation runs with cwd set to
    the repo root so it operates on the intended repo, not the caller's cwd. rmdir the emptied source after.
    Returns the count of top-level entries moved. NEVER shell=True.

    skip_existing (merge-into-existing mode, ADR-114 D2): when True, a top-level entry that already exists
    in target is handled WITHOUT overwriting. CR-001 fix: a colliding top-level entry where BOTH sides are
    directories is MERGED at file granularity (recurse via _merge_dir) — non-colliding files/subdirs move
    INTO the existing target dir, only the individually-colliding leaf files are skipped. This is what lets
    the W1C delta-as-new-wave path route a later delta through --into-existing: by then `source/` already
    exists in the target, and a coarse top-level skip would silently DROP a new `source/*.md` delta atom.
    A colliding top-level entry that is a FILE (or whose types differ) keeps the skip-and-leave behavior
    (never overwrite). Collision-skipped entries stay in source; a source dir is rmdir'd only if fully
    emptied (collision-skipped residual files safely remain — no data loss)."""
    os.makedirs(target, exist_ok=True)
    moved = 0
    for entry in sorted(os.listdir(source)):
        src = os.path.join(source, entry)
        dst = os.path.join(target, entry)
        if skip_existing and os.path.exists(dst):
            if os.path.isdir(src) and os.path.isdir(dst):
                # Top-level directory collision -> file-granularity merge (CR-001).
                _merge_dir(src, dst, cwd)
            else:
                # Colliding top-level file (or type mismatch): never overwrite.
                print(f"graduate-jam: skip (target entry exists): {entry}", file=sys.stderr)
            continue
        _git_or_plain_mv(src, dst, cwd)
        moved += 1
    try:
        os.rmdir(source)
    except OSError:
        pass
    return moved


def main():
    ap = argparse.ArgumentParser(
        prog='graduate-jam.py',
        description='Graduate a decomposed jam from docs/step-2-planning/ into the docs/step-3-specs/ build queue (ADR-061).')
    ap.add_argument('--slug', required=True, help='jam slug (without the jam- prefix)')
    ap.add_argument('--target', required=True, choices=('orchestrated', 'bypass'),
                    help='orchestrated: reshape # Wave: headers into per-wave folders; bypass: move-only')
    ap.add_argument('--repo-root', default=None,
                    help='repo root (default: git toplevel, else core/scripts/../.. — resolved by _repo_root())')
    ap.add_argument('--into-existing', action='store_true',
                    help='merge-into-existing mode (ADR-114 D2): when the step-3 target already exists '
                         '(persist wrote roadmap.md + waves/ during the /roadmap run), skip the non-empty '
                         'refusal, move only the jam residual top-level entries that do NOT collide with an '
                         'existing target entry (source/, README/index brief, decomposition/), skip the '
                         '# Wave: reshape when waves/ already exists, then rmdir the emptied jam dir. '
                         'Default off — standalone callers keep the non-empty refusal unchanged.')
    args = ap.parse_args()

    slug = validate_slug(args.slug)

    repo_root = args.repo_root or _repo_root()
    repo_root_real = os.path.realpath(repo_root)
    source = os.path.realpath(os.path.join(repo_root, 'docs', 'step-2-planning', f'jam-{slug}'))
    target = os.path.realpath(os.path.join(repo_root, 'docs', 'step-3-specs', slug))
    for p in (source, target):
        if not (p == repo_root_real or p.startswith(repo_root_real + os.sep)):
            _die(f"graduate-jam: path escapes repo root: {p}")

    target_populated = os.path.isdir(target) and bool(os.listdir(target))

    if not os.path.isdir(source):
        if args.into_existing and target_populated:
            # Idempotency (ADR-114 D2): the jam was already merged in a prior lock — source gone,
            # target populated. Treat as already-graduated; skip-and-continue, never error.
            print(f"GRADUATE-JAM: jam-{slug} already graduated → docs/step-3-specs/{slug}/ "
                  f"(0 waves reshaped, 0 intent artifact, 0 retained files).")
            return
        _die(f"graduate-jam: source missing: docs/step-2-planning/jam-{slug}/")

    if target_populated and not args.into_existing:
        _die(f"graduate-jam: target docs/step-3-specs/{slug}/ already exists (non-empty). Already graduated; "
             f"re-run blocked. To re-graduate: git rm -rf docs/step-3-specs/{slug} && re-run. "
             f"(Or pass --into-existing to MERGE the jam residual into the existing target — ADR-114 D2.)")

    intent = discover_intent_artifact(source)
    n_intent = 1 if intent else 0

    # Merge-into-existing skips the reshape when persist already wrote waves/ (ADR-114 D2): the
    # roadmap engine's fan-out already reshaped # Wave: into per-wave folders; re-reshaping would
    # be redundant/conflicting. Reshape only when there is no waves/ already.
    waves_already = os.path.isdir(os.path.join(target, 'waves')) and bool(
        os.listdir(os.path.join(target, 'waves')))
    do_reshape = (args.target == 'orchestrated') and not (args.into_existing and waves_already)

    # Resolve the reshape plan BEFORE any move so the no-waves / bad-header guards refuse without a partial
    # move (--target orchestrated only).
    wave_plan = []  # [(wave_slug, body), ...]
    if do_reshape:
        _, decomp_text = _find_decomp_text(source)
        waves = _parse_waves(decomp_text)
        if not waves:
            _die("graduate-jam: --target orchestrated requires ≥1 # Wave: header; found 0. "
                 "Re-run bulk-decompose-jams with --target orchestrated, or pass --target bypass.")
        for name, body in waves:
            wave_plan.append((wave_slug_from_header(name), body))

    n_retained = len(os.listdir(source))

    _move_tree(source, target, repo_root_real, skip_existing=args.into_existing)

    n_waves = 0
    for wave_slug, body in wave_plan:
        wave_dir = os.path.join(target, 'waves', wave_slug)
        os.makedirs(wave_dir, exist_ok=True)
        with open(os.path.join(wave_dir, f'{wave_slug}.md'), 'w', encoding='utf-8') as f:
            f.write(body)
        with open(os.path.join(wave_dir, f'{wave_slug}-prompts.md'), 'w', encoding='utf-8') as f:
            f.write(_prompts_for(wave_slug, body))
        n_waves += 1

    print(f"GRADUATE-JAM: moved jam-{slug} → docs/step-3-specs/{slug}/ "
          f"({n_waves} waves reshaped, {n_intent} intent artifact, {n_retained} retained files).")


if __name__ == '__main__':
    main()
