#!/usr/bin/env python3
"""activation-check.py — the BUILT_NOT_ACTIVATED surfacing check (ADR-103 W4).

The dig's DOMINANT in-window loss mode was not silent orphaning — it was
`BUILT_NOT_ACTIVATED`: infra/seam shipped, committed, "done", but never wired to a
live path so it never actually runs. (The canonical example: the W2 source-coverage
checker would have been exactly this had its lock-step wiring not landed — a script
with a test but no caller.)

This check surfaces that pattern at close-out, deterministically and NON-BLOCKING:
for each newly-built *wireable* file a run produced (a `core/scripts/**` or
`core/hooks/**` script/hook — the "needs a caller to run" class), it asks whether any
LIVE (non-test) file under `core/` references it. A file referenced only by tests — or
by nothing — is built but not wired: flagged `BUILT_NOT_ACTIVATED` in the wrap report.

Phased (ADR-103): SURFACE-FIRST. This never blocks a wrap — "live path" is
per-capability-class and brittle to mechanize universally, so a flag is an advisory the
operator reads ("did you wire this?"), not a gate. Escalation to a hard `activation-AC`
for operator-activation-tagged capabilities is a later, separate step.

Signal (deterministic, no LLM):
  - decided atoms = the run's manifest tickets[].planned_files
  - wireable      = ^core/(scripts|hooks)/.*\\.(py|sh|js)$  (excludes the file itself if it is a test)
  - activated     = at least one LIVE (non-test) file under core/ references the basename
  - flagged       = wireable file that exists, with zero live references (note: test-only vs none)

Usage:
    activation-check.py check <run_folder>

Exit codes:
    0  ran (whether or not anything was flagged — this is non-blocking by design)
    2  usage error
"""
import json
import os
import re
import subprocess
import sys

_WIREABLE_RE = re.compile(r"^core/(scripts|hooks)/.+\.(py|sh|js)$")


def _is_test_path(path):
    """A test file is not 'live-path activation' evidence (a script only a test calls is
    built+tested but not wired — exactly the BUILT_NOT_ACTIVATED pattern)."""
    base = os.path.basename(path)
    return (
        base.startswith("test-") or base.startswith("test_")
        or base.endswith("_test.py") or base.endswith(".test.js")
        or "/tests/" in path or "/__tests__/" in path
        or "/fixtures/" in path
    )


def _find_manifest(run_folder):
    for name in ("manifest.json", "run-manifest.json"):
        p = os.path.join(run_folder, name)
        if os.path.isfile(p):
            return p
    return None


def _planned_files(manifest_path):
    """Every planned_file across the manifest's tickets[] (the decided build surface)."""
    try:
        with open(manifest_path, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError):
        return None
    tickets = m.get("tickets")
    if not isinstance(tickets, list):
        return None
    out = []
    for t in tickets:
        if not isinstance(t, dict):
            continue
        for p in (t.get("planned_files") or []):
            if isinstance(p, str):
                out.append(p)
    return out


def _search_terms(base):
    """The fixed-strings to search for a basename. For JS-family modules, ALSO match the
    extensionless stem — Node resolves `require("./_lib/click")` / `import … from "./click"`
    without the extension, so the literal `click.js` never appears in a wired caller (CR-001).
    Matching the stem trades a little over-suppression (a false-negative is the quiet, acceptable
    failure for a surface-first advisory) to avoid the false-POSITIVE noise that trains the
    signal into being ignored — the AC-COVERAGE lesson this epic exists to honor."""
    terms = [base]
    stem, ext = os.path.splitext(base)
    if ext in (".js", ".mjs", ".cjs", ".ts") and stem:
        terms.append(stem)
    return terms


def _live_refs(root, rel_path):
    """Files under core/ that reference rel_path (by basename, + extensionless stem for JS),
    split (live, test).

    Uses `git grep -l --fixed-strings -e <term> … -- core/` (tracked blobs only — avoids the
    .claude/ symlink-target false positives). The file itself is excluded."""
    cmd = ["git", "grep", "-l", "--fixed-strings"]
    for t in _search_terms(os.path.basename(rel_path)):
        cmd += ["-e", t]
    cmd += ["--", "core/"]
    try:
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    except Exception:
        return None, None  # git unavailable — caller treats as "cannot determine"
    hits = [h for h in r.stdout.splitlines() if h and h != rel_path]
    live = [h for h in hits if not _is_test_path(h)]
    test = [h for h in hits if _is_test_path(h)]
    return live, test


def check(root, run_folder):
    man = _find_manifest(run_folder)
    if not man:
        print("activation-check: no thin manifest in run folder (nimble/no-ticket run) — not applicable (OK).")
        return 0
    planned = _planned_files(man)
    if planned is None:
        print("activation-check: manifest has no tickets[] (or is unreadable) — not applicable (OK).")
        return 0
    # de-dup, keep order; the wireable, non-test, existing subset is what we interrogate.
    seen, wireable = set(), []
    for p in planned:
        if p in seen:
            continue
        seen.add(p)
        if _WIREABLE_RE.match(p) and not _is_test_path(p) and os.path.isfile(os.path.join(root, p)):
            wireable.append(p)
    if not wireable:
        print("activation-check: no wireable core/scripts|hooks files in this run — not applicable (OK).")
        return 0

    flagged = []   # (path, has_test_refs)
    for p in wireable:
        live, test = _live_refs(root, p)
        if live is None:
            print(f"activation-check: WARN could not determine refs for {p} (git unavailable) — skipping it.")
            continue
        if not live:
            flagged.append((p, bool(test)))

    n = len(wireable)
    if not flagged:
        print(f"ACTIVATION OK: all {n} wireable file(s) this run built are referenced on a live path.")
        return 0
    print(f"ACTIVATION SURFACE: {len(flagged)}/{n} wireable file(s) appear BUILT_NOT_ACTIVATED "
          f"(no live-path caller under core/):")
    for p, has_test in flagged:
        why = "only test references — built + tested but not wired" if has_test else "no references at all"
        print(f"  - {p}  ({why})")
    print("This is ADVISORY (non-blocking, ADR-103 W4): a built capability that nothing on a live path calls "
          "never actually runs. If intentional (e.g. an operator-run utility), ignore. Otherwise: wire it "
          "(a skill/hook/script caller, or a settings.json hook registration) before it is lost as silent scope.")
    return 0


def main(argv):
    if len(argv) == 2 and argv[0] == "check":
        # repo root via git, fall back to two-up from this script.
        try:
            r = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                               capture_output=True, text=True, check=False)
            root = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() \
                else os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        except Exception:
            root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        return check(root, os.path.abspath(argv[1]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
