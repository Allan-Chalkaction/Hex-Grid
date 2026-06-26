#!/usr/bin/env python3
"""retire-spec.py — the superseded-spec move VERB (ADR-106 / ADR-107, W1 doc-lifecycle conveyor).

Retires a superseded spec by `git mv`-ing its folder out of the build queue to a terminal/superseded
home, recording the named successor. This is the shaping→locked→…→retired lifecycle's terminal move for a
spec that has been superseded by another (ADR-107 stage model; ADR-087 location-is-status).

W1 base form (this file, W1DLP-T2): the move verb + slug safety + the stage-only / idempotent /
missing-source-tolerant contract.

W2 weave (W1DLP-T4, SAME file — ADR-108): before the move, classify each residual in the spec
folder as DEAD / ABSORBED / ORPHANED and harvest ONLY the ORPHANED residuals to docs/step-1-ideas/ on the
current branch — one file per concept — BEFORE the `git mv`. The no-strand invariant: "no lifecycle move
may strand live content on a branch that might not land: harvest FIRST, move SECOND."

Residual classification (deterministic, marker-driven; fail-closed to ORPHANED so nothing strands):
  - DEAD     — the file carries a `<!-- retire: dead -->` marker (or a `# RETIRED`/`# DEAD` H1). It is
               obsolete; no harvest (the move terminally archives it).
  - ABSORBED — the file carries `<!-- retire: absorbed-by: <successor> -->` (its content already lives in
               the successor spec). No harvest; the successor is named.
  - ORPHANED — anything else (the fail-closed default): live content with no recorded fate. Harvested to
               docs/step-1-ideas/ BEFORE the move so it is not stranded on a doomed branch.
Structural files (RETIRED.md, README.md, the retirement marker, dotfiles) are skipped (never residuals).

Usage:
  python3 core/scripts/retire-spec.py --slug <slug> --superseded-by <successor-slug> [--repo-root <path>]
                                       [--no-harvest] [--dry-run]
  python3 core/scripts/retire-spec.py --help

  --slug SLUG            the spec to retire (docs/step-3-specs/<slug>/).
  --superseded-by SLUG   the named successor spec slug (recorded in the retirement marker).
  --no-harvest           skip the W2 harvest classification (move only). Default: harvest runs.
  --dry-run              print the plan, mutate nothing.

Contract (ADR-106 wave-wide invariants):
  - STAGES only — `git mv` + `git add`, NEVER commits, NEVER pushes, NEVER force-pushes (AC-020).
  - Idempotent: an already-retired spec (source absent, destination present) is a no-op NOTE.
  - Missing-source tolerant: an absent source spec folder is a WARN + clean continue.
  - Slug-safe: --slug and --superseded-by validated via validate_slug (rejects .., /, leading -,
    non-kebab); both endpoints realpath-bound under repo root before any mutation. NEVER shell=True;
    subprocess arg lists only.
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

SLUG_RE = re.compile(r'^[a-z0-9][a-z0-9-]*$')   # matches graduate-jam.py:45 / claim-id.py


def _die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _repo_root():
    """Resolve the repo root robustly: git toplevel first (correct for a consumer repo running
    this via a symlinked .claude/scripts/), else core/scripts/../.. (the repo root from THIS file).

    Bugfix (mirrors graduate-jam.py / closeout-run.py): the prior default
    `dirname(dirname(abspath(__file__)))` resolved to `<repo>/core` (one level short), so a caller
    that did not pass --repo-root built `core/docs/...` paths and failed."""
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
    """Reject path-traversal and non-kebab slugs (REUSE graduate-jam.py::validate_slug L57-63). Returns
    the slug on success; exits non-zero with a single 'retire-spec: invalid slug:' stderr line on rejection."""
    if (slug is None or slug == '' or slug != slug.strip() or slug.startswith('-')
            or '..' in slug or '/' in slug or not SLUG_RE.match(slug)):
        _die(f"retire-spec: invalid slug: {slug!r}")
    return slug


def _rel(root, p):
    try:
        return os.path.relpath(p, root)
    except ValueError:
        return p


def _git_mv(root, src, dst, dry):
    """Stage a move src -> dst (REUSE closeout-run.py::_git_mv L81-102 contract verbatim: stage-only
    `git mv` with plain-`mv` fallback, idempotency, missing-source tolerance). Returns one of
    moved/skipped-exists/missing. NEVER shell=True."""
    if not os.path.exists(src):
        # Idempotency: destination already there means the move already happened.
        if os.path.exists(dst):
            print(f"NOTE: already retired: {_rel(root, dst)} (src absent)")
            return "skipped-exists"
        print(f"WARN: missing source (mv): {_rel(root, src)}")
        return "missing"
    if os.path.exists(dst):
        print(f"WARN: destination exists, not overwriting: {_rel(root, dst)} (src left in place)")
        return "skipped-exists"
    print(f"MOVE: {_rel(root, src)} -> {_rel(root, dst)}")
    if not dry:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        r = subprocess.run(["git", "mv", src, dst], cwd=root, capture_output=True, text=True)
        if r.returncode != 0:
            # untracked? fall back to a plain mv + git add.
            print(f"WARN: git mv failed ({r.stderr.strip()}), using plain mv")
            os.rename(src, dst)
            subprocess.run(["git", "add", dst], cwd=root, capture_output=True, text=True)
    return "moved"


def _write_successor_marker(root, dst, slug, superseded_by, dry):
    """Record the named successor inside the retired spec's terminal home (RETIRED.md marker).
    Stage-only (git add). Idempotent (never overwrites an existing marker)."""
    marker = os.path.join(dst, "RETIRED.md")
    if os.path.exists(marker):
        print(f"NOTE: retirement marker already present (not overwriting): {_rel(root, marker)}")
        return
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = (
        f"# {slug} — RETIRED (superseded)\n\n"
        f"- **Retired:** {ts} by `retire-spec.py` (ADR-106/107 W1 doc-lifecycle conveyor)\n"
        f"- **Superseded by:** `{superseded_by}`\n"
        f"- **Former home:** `docs/step-3-specs/{slug}/`\n\n"
        "This spec was superseded and moved to its terminal/superseded home (MOVE-not-DELETE, ADR-087). "
        "Any live residual content was harvested to the ideas inbox before the move (harvest-FIRST, "
        "move-SECOND — see the W2 harvest-before-retire ADR).\n"
    )
    print(f"MARKER: {_rel(root, marker)} (superseded-by={superseded_by})")
    if dry:
        return
    try:
        os.makedirs(dst, exist_ok=True)
        with open(marker, "w", encoding="utf-8") as f:
            f.write(body)
        subprocess.run(["git", "add", marker], cwd=root, capture_output=True, text=True)
    except OSError as e:
        print(f"WARN: could not write retirement marker: {e}")


def retire(root, slug, superseded_by, dry, harvest=True):
    """Retire a superseded spec: (W2) harvest ORPHANED residuals first, then `git mv` the spec folder to
    its terminal/superseded home and record the named successor. Stage-only, idempotent, tolerant."""
    repo_root_real = os.path.realpath(root)
    source = os.path.realpath(os.path.join(root, "docs", "step-3-specs", slug))
    dest = os.path.realpath(os.path.join(root, "docs", "step-6-done", "superseded", slug))
    # Realpath-bind both endpoints under repo root before any mutation (REUSE graduate-jam.py L174-179).
    for p in (source, dest):
        if not (p == repo_root_real or p.startswith(repo_root_real + os.sep)):
            _die(f"retire-spec: path escapes repo root: {p}")

    # Idempotency / missing-source: handled by _git_mv's contract. But surface the no-op early when the
    # source is absent and the destination already exists (already retired).
    if not os.path.isdir(source):
        if os.path.isdir(dest):
            print(f"NOTE: already retired: {_rel(root, dest)} (source absent) — no-op.")
            return "skipped-exists"
        print(f"WARN: source spec not found (retire tolerant, continuing): {_rel(root, source)}")
        return "missing"

    # --- W2 harvest-before-retire: harvest FIRST, move SECOND (no-strand invariant) -------------------
    if harvest:
        _harvest_orphaned_residuals(root, slug, source, dry)

    # --- The move: git mv the spec folder to its terminal/superseded home -----------------------------
    result = _git_mv(root, source, dest, dry)
    if result == "moved":
        _write_successor_marker(root, dest, slug, superseded_by, dry)
    return result


# ---------------------------------------------------------------------------
# W2 harvest-before-retire (ADR-108) — WOVEN into this file by W1DLP-T4.
#
# The no-strand invariant: "no lifecycle move may strand live content on a branch that might not land:
# harvest FIRST, move SECOND." Classify each residual as DEAD / ABSORBED(names successor) / ORPHANED;
# harvest ONLY the ORPHANED residuals — one file per concept — to docs/step-1-ideas/ on the current
# branch, BEFORE the git mv. The harvest write REUSES the closeout-run.py::_reflux_stub PATTERN
# (L195-247: stage-only `git add`, never overwrites an existing file, missing-source-tolerant) — NOT
# ADR-103's verify_scope MECHANISM (which set-diffs a thin manifest's tickets[]; harvest classifies free
# residual content — a distinct input shape). Fail-closed: an unmarked residual is ORPHANED, so nothing
# live is ever silently stranded.
# ---------------------------------------------------------------------------
_STRUCTURAL = {"RETIRED.md", "README.md", "INDEX.md"}
_DEAD_RE = re.compile(r"<!--\s*retire:\s*dead\s*-->", re.IGNORECASE)
_ABSORBED_RE = re.compile(r"<!--\s*retire:\s*absorbed-by:\s*([a-z0-9][a-z0-9-]*)\s*-->", re.IGNORECASE)
_DEAD_H1_RE = re.compile(r"^#\s+(?:RETIRED|DEAD)\b", re.IGNORECASE | re.MULTILINE)


def _classify_residual(path):
    """Return (klass, successor) — klass in {'DEAD','ABSORBED','ORPHANED'}; successor named for ABSORBED.
    Fail-closed: an unreadable or unmarked residual is ORPHANED (never silently stranded)."""
    try:
        with open(path, encoding="utf-8") as f:
            head = f.read(8000)
    except OSError:
        return "ORPHANED", None
    m = _ABSORBED_RE.search(head)
    if m:
        return "ABSORBED", m.group(1)
    if _DEAD_RE.search(head) or _DEAD_H1_RE.search(head):
        return "DEAD", None
    return "ORPHANED", None


def _iter_residuals(source):
    """Yield (relpath, abspath) for each work-shaped residual file in the spec folder (recursive),
    skipping structural files and dotfiles. Only .md files are residuals (the content the spec carries)."""
    for dirpath, dirnames, filenames in os.walk(source):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in sorted(filenames):
            if fn.startswith(".") or fn in _STRUCTURAL or not fn.endswith(".md"):
                continue
            ab = os.path.join(dirpath, fn)
            yield os.path.relpath(ab, source), ab


def _harvest_stub(root, slug, rel, src_path, dry):
    """Write a harvest stub for one ORPHANED residual to docs/step-1-ideas/ — one file per concept, its
    own atomic mergeable unit. REUSE the closeout-run.py::_reflux_stub PATTERN (stage-only git add,
    never-overwrites, missing-source-tolerant). Returns the rel path written/already-present, or None."""
    from_dir = os.path.join(root, "docs/step-1-ideas", f"from-retired-{slug}")
    safe_key = re.sub(r"[^A-Za-z0-9._-]", "-", rel)
    dst = os.path.join(from_dir, f"{safe_key}")
    if not dst.endswith(".md"):
        dst += ".md"
    if os.path.exists(dst):
        print(f"NOTE: harvest stub already present (not overwriting): {_rel(root, dst)}")
        return _rel(root, dst)
    try:
        with open(src_path, encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        print(f"WARN: could not read residual for harvest ({rel}): {e}")
        return None
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = (
        f"# {rel} — orphaned residual harvested from retired spec `{slug}`\n\n"
        f"- **Harvested:** {ts} by `retire-spec.py` (ADR-108 W2 harvest-before-retire)\n"
        f"- **Source spec (retired):** `docs/step-3-specs/{slug}/{rel}`\n"
        "- **Why this is here:** this residual carried live content with no recorded fate (not DEAD, not "
        "ABSORBED) when its spec was retired. Harvest-FIRST-move-SECOND wrote it into the ideas inbox on "
        "`main` so it is **triageable, not stranded** on a doomed branch (the no-strand invariant).\n\n"
        "## Triage (operator)\n\n"
        "- **Build it** — re-open as an idea/ticket.\n"
        "- **Defer it** — rename to `DEFER-…` with a target home.\n"
        "- **Drop it** — delete this file if the content is obsolete (a deliberate, recorded decision).\n\n"
        "---\n\n"
        "## Original residual content (carried forward verbatim)\n\n"
        f"{content}\n"
    )
    print(f"HARVEST: {_rel(root, dst)}  (orphaned residual '{rel}')")
    if dry:
        return _rel(root, dst)
    try:
        os.makedirs(from_dir, exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(body)
        subprocess.run(["git", "add", dst], cwd=root, capture_output=True, text=True)
    except OSError as e:
        print(f"WARN: could not write harvest stub for {rel}: {e}")
        return None
    return _rel(root, dst)


def _harvest_orphaned_residuals(root, slug, source, dry):
    """Classify every residual; harvest ONLY the ORPHANED ones BEFORE the move. Returns the list of
    harvested rel paths. DEAD and ABSORBED residuals produce no harvest file."""
    harvested = []
    counts = {"DEAD": 0, "ABSORBED": 0, "ORPHANED": 0}
    for rel, ab in _iter_residuals(source):
        klass, successor = _classify_residual(ab)
        counts[klass] += 1
        if klass == "DEAD":
            print(f"CLASSIFY: DEAD     {rel} (obsolete — not harvested)")
        elif klass == "ABSORBED":
            print(f"CLASSIFY: ABSORBED {rel} (by `{successor}` — not harvested)")
        else:  # ORPHANED
            print(f"CLASSIFY: ORPHANED {rel} (live, no recorded fate — harvesting)")
            p = _harvest_stub(root, slug, rel, ab, dry)
            if p:
                harvested.append(p)
    print(f"HARVEST: classified residuals — DEAD={counts['DEAD']} ABSORBED={counts['ABSORBED']} "
          f"ORPHANED={counts['ORPHANED']}; harvested {len(harvested)} (ORPHANED only).")
    return harvested


def main():
    ap = argparse.ArgumentParser(
        prog="retire-spec.py",
        description="Retire a superseded spec: git mv its folder to a terminal/superseded home and record "
                    "the named successor (ADR-106/107 W1 doc-lifecycle conveyor). STAGES only.",
    )
    ap.add_argument("--slug", required=True, help="the spec to retire (docs/step-3-specs/<slug>/)")
    ap.add_argument("--superseded-by", required=True, dest="superseded_by",
                    help="the named successor spec slug (recorded in the retirement marker)")
    ap.add_argument("--no-harvest", dest="harvest", action="store_false",
                    help="skip the W2 harvest classification (move only); default: harvest runs")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, mutate nothing")
    ap.add_argument("--repo-root", default=None,
                    help="repo root (default: git toplevel, else core/scripts/../.. — resolved by _repo_root())")
    args = ap.parse_args()

    slug = validate_slug(args.slug)
    superseded_by = validate_slug(args.superseded_by)

    root = os.path.abspath(args.repo_root or _repo_root())
    mode = "DRY-RUN" if args.dry_run else "EXECUTE"
    print(f"=== retire-spec.py (ADR-106/107) — MODE: {mode} — root: {root} ===")
    result = retire(root, slug, superseded_by, args.dry_run, harvest=args.harvest)
    print(f"RETIRE-SPEC: {slug} superseded-by {superseded_by} → "
          f"docs/step-6-done/superseded/{slug}/ (result={result}).")


if __name__ == "__main__":
    main()
