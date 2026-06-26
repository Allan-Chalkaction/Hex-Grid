#!/usr/bin/env python3
"""closeout-jam.py — the terminal jam-husk MOVE (ADR-106/107, W1 doc-lifecycle conveyor, W1DLP-T8).

Moves a now-graduated jam's material to its terminal home `docs/step-6-done/jams/<slug>/` — MOVE never
DELETE (the husk holds the only tree copy of `git-mv`'d-in source ideas; deleting it would lose them). It
mirrors `closeout-run.py::_git_mv` (L81-102): stage-only `git mv` with a plain-`mv` fallback, idempotent,
missing-source-tolerant.

THE GRADUATE-JAM COLLISION, RESOLVED (AC-016):
  `graduate-jam.py` (ADR-061) ALREADY `git mv`s a jam OUT of `docs/step-2-planning/jam-<slug>/` →
  `docs/step-3-specs/<slug>/` at graduation (graduate-jam.py L175-176, L205). closeout-jam.py operates on
  that POST-GRADUATION home (`docs/step-3-specs/<slug>/`) — NOT `docs/step-2-planning/`. It is a LATER
  transition (post-graduation home → `docs/step-6-done/jams/<slug>/`) that runs ONLY after the spec the
  jam produced has itself advanced. It does NOT race graduate-jam's move (graduate-jam runs at graduation;
  closeout-jam runs at spec-advancement, strictly later).

THE GATED NO-OP (AC-018):
  closeout-jam.py NO-OPS when the produced spec has NOT yet advanced (built-pending-merge or merged, per
  the ADR-107 stage model). The husk only moves once it is no longer the live working copy. "Advanced" is
  signalled, in priority order, by ANY of:
    1. the spec folder carries a `BUILT-PENDING-MERGE.md` or `MERGED.md` marker (location-is-status), OR
    2. a `built-pending-merge/<slug>/` location exists (the sanctioned built-but-unmerged home, ADR-107), OR
    3. the spec folder is already gone from `docs/step-3-specs/` AND present under `docs/step-6-done/`
       (the spec itself was moved on merge — its jam husk should follow).
  Absent all signals → gated no-op (the spec has not advanced; the husk stays live).

ABANDONMENT-RECOVERY (AC-018): graduation → a failed build leaves jam material recoverable from
`docs/step-6-done/jams/<slug>/` once advanced (MOVE-not-DELETE), and the W2-harvested residuals already
landed on `main` independent of jam location (ADR-108). Nothing is lost on an abandoned build.

Usage:
  python3 core/scripts/closeout-jam.py <slug> [--repo-root <path>] [--dry-run] [--force]
  python3 core/scripts/closeout-jam.py --help

  <slug>        the graduated jam's slug (its post-graduation home is docs/step-3-specs/<slug>/).
  --force       move even if the spec-advancement gate is not satisfied (the escape hatch).
  --dry-run     print the plan, mutate nothing.

Contract (ADR-106 wave-wide invariants):
  - STAGES only — `git mv` + `git add`, NEVER commits, NEVER pushes, NEVER force-pushes (AC-020).
  - Idempotent: an already-moved husk (source absent, destination present) is a no-op NOTE.
  - Missing-source tolerant: an absent post-graduation home is a WARN + clean continue.
  - Slug-safe: <slug> validated via validate_slug (rejects .., /, leading -, non-kebab); both endpoints
    realpath-bound under repo root before any mutation. NEVER shell=True; subprocess arg lists only.
"""
import argparse
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
    the slug on success; exits non-zero with a single 'closeout-jam: invalid slug:' stderr line on rejection."""
    if (slug is None or slug == '' or slug != slug.strip() or slug.startswith('-')
            or '..' in slug or '/' in slug or not SLUG_RE.match(slug)):
        _die(f"closeout-jam: invalid slug: {slug!r}")
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
        if os.path.exists(dst):
            print(f"NOTE: already moved: {_rel(root, dst)} (src absent)")
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
            print(f"WARN: git mv failed ({r.stderr.strip()}), using plain mv")
            os.rename(src, dst)
            subprocess.run(["git", "add", dst], cwd=root, capture_output=True, text=True)
    return "moved"


def spec_advanced(root, slug):
    """The gate (AC-018): has the produced spec advanced (built-pending-merge or merged)? Returns
    (advanced: bool, reason: str). See the module docstring for the three signals."""
    spec_home = os.path.join(root, "docs", "step-3-specs", slug)
    # 1. an advancement marker in the spec folder (location-is-status).
    for marker in ("BUILT-PENDING-MERGE.md", "MERGED.md"):
        if os.path.isfile(os.path.join(spec_home, marker)):
            return True, f"spec carries {marker}"
    # 2. the sanctioned built-pending-merge/<slug>/ location exists (ADR-107).
    bpm = os.path.join(root, "docs", "step-3-specs", "built-pending-merge", slug)
    if os.path.isdir(bpm):
        return True, "built-pending-merge/<slug>/ present"
    bpm_top = os.path.join(root, "docs", "built-pending-merge", slug)
    if os.path.isdir(bpm_top):
        return True, "docs/built-pending-merge/<slug>/ present"
    # 3. the spec itself was moved on merge: gone from step-3-specs AND present under step-6-done.
    if not os.path.isdir(spec_home):
        done = os.path.join(root, "docs", "step-6-done")
        if os.path.isdir(done):
            for dirpath, dirnames, _ in os.walk(done):
                # the spec's merged home would be a dir named <slug> under step-6-done
                if os.path.basename(dirpath) == slug and dirpath != os.path.join(done, "jams", slug):
                    return True, f"spec merged (found under {_rel(root, dirpath)})"
    return False, "spec has not advanced (no built-pending-merge/merged signal)"


def closeout_jam(root, slug, dry, force=False):
    """Move the graduated jam husk from its post-graduation home to docs/step-6-done/jams/<slug>/ — gated
    on spec advancement (unless --force). Stage-only, idempotent, missing-source-tolerant."""
    repo_root_real = os.path.realpath(root)
    source = os.path.realpath(os.path.join(root, "docs", "step-3-specs", slug))
    dest = os.path.realpath(os.path.join(root, "docs", "step-6-done", "jams", slug))
    # Realpath-bind both endpoints under repo root before any mutation (REUSE graduate-jam.py L174-179).
    for p in (source, dest):
        if not (p == repo_root_real or p.startswith(repo_root_real + os.sep)):
            _die(f"closeout-jam: path escapes repo root: {p}")

    # Idempotency: already moved (source absent, dest present).
    if not os.path.isdir(source):
        if os.path.isdir(dest):
            print(f"NOTE: jam husk already at terminal home: {_rel(root, dest)} (source absent) — no-op.")
            return "skipped-exists"
        print(f"WARN: post-graduation home not found (closeout-jam tolerant, continuing): "
              f"{_rel(root, source)}")
        return "missing"

    # The gated no-op (AC-018): only move once the produced spec has advanced.
    advanced, reason = spec_advanced(root, slug)
    if not advanced and not force:
        print(f"GATED NO-OP: {slug} — {reason}. The husk stays live at {_rel(root, source)} until its "
              f"spec advances (built-pending-merge or merged). Re-run after advancement, or --force.")
        return "gated-noop"
    if not advanced and force:
        print(f"FORCED: --force — moving despite the gate ({reason}).")
    else:
        print(f"GATE OK: {slug} advanced — {reason}.")

    return _git_mv(root, source, dest, dry)


def main():
    ap = argparse.ArgumentParser(
        prog="closeout-jam.py",
        description="Terminal jam-husk MOVE: git mv a graduated jam's post-graduation home to "
                    "docs/step-6-done/jams/<slug>/ once its spec advances (ADR-106/107). STAGES only.",
    )
    ap.add_argument("slug", help="the graduated jam's slug (post-graduation home: docs/step-3-specs/<slug>/)")
    ap.add_argument("--force", action="store_true",
                    help="move even if the spec-advancement gate is not satisfied (escape hatch)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, mutate nothing")
    ap.add_argument("--repo-root", default=None,
                    help="repo root (default: git toplevel, else core/scripts/../.. — resolved by _repo_root())")
    args = ap.parse_args()

    slug = validate_slug(args.slug)
    root = os.path.abspath(args.repo_root or _repo_root())
    mode = "DRY-RUN" if args.dry_run else "EXECUTE"
    print(f"=== closeout-jam.py (ADR-106/107) — MODE: {mode} — root: {root} ===")
    result = closeout_jam(root, slug, args.dry_run, force=args.force)
    print(f"CLOSEOUT-JAM: {slug} → docs/step-6-done/jams/{slug}/ (result={result}).")


if __name__ == "__main__":
    main()
