#!/usr/bin/env python3
"""bulk-decompose-plan.py — the readiness plan for bulk-decomposing jams into buildable tickets.

DESIGN (rev 2): readiness is DECLARED, not inferred. An earlier rev guessed readiness from prose labels
in the jam brief ("converged brief" / "shaping brief" / ...). That was a mistake: the labels are
inconsistent, the guess misfires, and — more fundamentally — "is this ready to decompose?" is an OPERATOR
judgment ("only when I say yes"), not a property to be parsed out of text. Every wrong guess erodes
confidence that work will progress.

So this script reads exactly two unambiguous things per jam:

    1. Did the operator say yes?   -> an explicit `- **decompose:** ready|skip|hold` field in the brief.
    2. Is it already decomposed?   -> a `decomposition/` folder exists (objective idempotency guard).

Everything else is "not promoted yet" (UNMARKED) — invisible to the decompose pass until the operator
stamps `decompose: ready`. The descriptive H1 labels stay as human prose; the machine no longer parses them.

    stable key = jam slug = jam folder name (docs/step-2-planning/jam-<slug>/)

States:
    READY     decompose:ready, no decomposition/ yet        -> decompose this pass
    STALE     decompose:ready, decomposed but brief changed  -> re-decompose this pass
    DONE      decomposition/ exists and is current           -> already decomposed, skip
    SKIP      decompose:skip (operator: nothing to build)    -> intentionally out
    HOLD      decompose:hold (operator: not ready / converge first)
    UNMARKED  no decompose flag, not decomposed              -> awaiting the operator's yes

Only READY + STALE are decomposed. STALE detection is by mtime (brief newer than decomposition/) — no
ledger, no state machine, mirroring bulk-jam-plan.py's no-extra-state ethos.

Usage:
  python3 core/scripts/bulk-decompose-plan.py [--jams docs/step-2-planning] [--only slug,slug]

Last stdout line is machine-parseable:
  BULK-DECOMPOSE-PLAN: R ready, T stale, D done, K skip, H hold, U unmarked across N jam(s).
"""
import argparse
import os
import re
import sys

FIELD_RE = re.compile(r"^\s*-\s+\*\*([^:*]+):\*\*\s*(.*\S)\s*$")
BRIEF_FILES = ("README.md", "index.md")
DECOMP_DIR = "decomposition"
VALID_FIELD = {"ready", "skip", "hold"}


def read_brief(jam_dir):
    """Return text of the first present brief file (README/index), or None."""
    for fn in BRIEF_FILES:
        p = os.path.join(jam_dir, fn)
        if os.path.isfile(p):
            try:
                with open(p, encoding="utf-8") as f:
                    return f.read(), p
            except OSError:
                pass
    return None, None


def explicit_field(text):
    """The operator's `- **decompose:** ready|skip|hold` flag, or None."""
    if not text:
        return None
    for line in text.splitlines():
        m = FIELD_RE.match(line)
        if m and m.group(1).strip().lower() == "decompose":
            val = m.group(2).strip().lower()
            return val if val in VALID_FIELD else None
    return None


def is_kickoff_only(jam_dir):
    """A jam scaffolded but not yet converged: a kickoff-prompt.md and no README/index brief."""
    return (
        os.path.isfile(os.path.join(jam_dir, "kickoff-prompt.md"))
        and not any(os.path.isfile(os.path.join(jam_dir, b)) for b in BRIEF_FILES)
    )


def newest_mtime(path):
    """Newest mtime under a dir (or of a file). 0 if missing."""
    if os.path.isfile(path):
        return os.path.getmtime(path)
    newest = 0.0
    for dirpath, _, files in os.walk(path):
        for fn in files:
            try:
                newest = max(newest, os.path.getmtime(os.path.join(dirpath, fn)))
            except OSError:
                pass
    return newest


def classify(jam_dir):
    """Return (code, detail). Reads only the explicit flag + decomposition/ presence — no inference."""
    text, brief_path = read_brief(jam_dir)
    field = explicit_field(text)

    decomp_path = os.path.join(jam_dir, DECOMP_DIR)
    has_decomp = os.path.isdir(decomp_path)

    if field == "skip":
        return "SKIP", "decompose:skip (operator — nothing to build)"
    if field == "hold":
        return "HOLD", "decompose:hold (operator — not ready / converge first)"
    if field == "ready":
        if not has_decomp:
            return "READY", "decompose:ready — promoted, not yet decomposed"
        if brief_path and newest_mtime(brief_path) > newest_mtime(decomp_path):
            return "STALE", "decompose:ready — brief changed after last decompose; re-decompose"
        return "DONE", "decompose:ready — decomposition/ present and current"

    # No flag.
    if has_decomp:
        return "DONE", "decomposed (no flag) — decomposition/ present"
    # Neutral descriptor only — NOT a readiness guess.
    if is_kickoff_only(jam_dir):
        return "UNMARKED", "no decompose flag — kickoff only (not converged)"
    if text is None:
        return "UNMARKED", "no decompose flag — no brief file"
    return "UNMARKED", "no decompose flag — awaiting your `decompose: ready`"


def main():
    ap = argparse.ArgumentParser(description="Compute the bulk-decompose readiness plan (read-only).")
    ap.add_argument("--jams", default="docs/step-2-planning")
    ap.add_argument("--only", default="", help="comma-separated jam slugs to restrict to")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    jams = args.jams if os.path.isabs(args.jams) else os.path.join(repo_root, args.jams)
    if not os.path.isdir(jams):
        print(f"bulk-decompose-plan: no such dir: {jams}", file=sys.stderr)
        sys.exit(2)

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    jam_dirs = sorted(
        d for d in os.listdir(jams)
        if d.startswith("jam-") and os.path.isdir(os.path.join(jams, d))
    )

    print("BULK-DECOMPOSE READINESS PLAN (read-only) — readiness is DECLARED (decompose: ready), not guessed\n")

    counts = {"READY": 0, "STALE": 0, "DONE": 0, "SKIP": 0, "HOLD": 0, "UNMARKED": 0}
    label = {
        "READY": "READY   ", "STALE": "STALE   ", "DONE": "DONE    ",
        "SKIP": "SKIP    ", "HOLD": "HOLD    ", "UNMARKED": "UNMARKED",
    }
    total = 0
    for d in jam_dirs:
        slug = d[len("jam-"):]
        if only and slug not in only:
            continue
        total += 1
        code, detail = classify(os.path.join(jams, d))
        counts[code] += 1
        print(f"{label[code]}  jam-{slug}  — {detail}")

    if total == 0:
        print("No jam-* folders found (or none matched --only).")
    print()
    print(f"BULK-DECOMPOSE-PLAN: {counts['READY']} ready, {counts['STALE']} stale, {counts['DONE']} done, "
          f"{counts['SKIP']} skip, {counts['HOLD']} hold, {counts['UNMARKED']} unmarked across {total} jam(s).")


if __name__ == "__main__":
    main()
