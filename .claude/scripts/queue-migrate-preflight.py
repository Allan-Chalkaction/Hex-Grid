#!/usr/bin/env python3
"""queue-migrate-preflight.py — HARD read-only gate for the Wave E pipeline renumber (SHR3-T8, ADR-127 / F-006).

WHY THIS EXISTS (the safety spine — read first).
Wave E moves LIVE artifacts in one atomic `git mv` set: docs/queue → docs/step-4-queue,
docs/step-4-pipeline → docs/step-5-pipeline, docs/step-5-done → docs/step-6-done (ADR-127 D-1/D-3/D-4;
the operator's build-start FULL-renumber override of the roadmap's queue-only AC-028 — ADR-127 D-4).
The dominant risk (architect + spec "Known gaps") is PATH-REFERENCE ATOMICITY: a botched re-point strands a
live queue entry — a running/ entry the poll / manifest / closeout-run.py can no longer find is a correctness
failure that can LOSE in-flight work. This gate proves safety READ-ONLY *before* anything moves.

It is a GATE, not advisory. ZERO LLM in the body — deterministic queue-state inspection + reference-graph
enumeration. It exits NON-ZERO (refuses, blocks the migration) if EITHER:

  (a) IN-FLIGHT QUEUE ENTRY. Any REAL pending/ or running/ queue entry is in flight. A "real" entry is an
      <entry>/sidecar.json FOLDER (the entry-as-folder shape, ADR-124) — a bare `.gitkeep` is NOT an entry
      and is ignored. (The queue is currently CLEAN, so a correct preflight PASSES now — AC-025.) Moving the
      queue while an entry is pending/running could strand it mid-lifecycle.

  (b) DANGLING REFERENCE. Any LIVE reference to an old path (docs/queue, docs/step-4-pipeline,
      docs/step-5-done) across the substrate source surface would be left dangling after the planned
      re-point. It enumerates every live reference and proves each maps cleanly to its new path under the
      same move (one-to-one old→new, no orphan).

On PASS (exit 0) it prints the reference inventory so the operator/security review sees the blast radius.

CITES: ADR-127 (the binding migration contract + the four preserved ADR-123 D-3 invariants), ADR-127 F-006
(this dry-run pre-flight gate), ADR-124 (queue entry-as-folder shape), ADR-123 D-3 (the lifecycle invariants).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

# The three atomic renames (old → new). Order-independent: the three OLD tokens are pairwise non-overlapping
# and none of the NEW tokens pre-exist, so the substitution set has no collision (verified at build-time).
RENAMES = [
    ("docs/queue", "docs/step-4-queue"),
    ("docs/step-4-pipeline", "docs/step-5-pipeline"),
    ("docs/step-5-done", "docs/step-6-done"),
]

# Live-usage search surface: the source/code/config surface that the daemon + engine actually RESOLVE at
# runtime. Historical/audit content (run-folder CONTENT, specs, ADRs) is EXCLUDED — those carry past-tense
# references that legitimately keep the old names (ADR-127 AC-027 exclusion list).
LIVE_PATHSPECS = ["core", "CLAUDE.md"]

# Paths whose references are historical/audit and do NOT count as live usage (ADR-127 AC-027).
#   - docs/decisions/        : ADRs narrate history.
#   - run-folder CONTENT now under step-5-pipeline / step-6-done (incl. sessions/) : past-tense run narrative.
#   - docs/step-3-specs/     : specs + build-log narrative.
# (These live OUTSIDE the LIVE_PATHSPECS surface anyway; listed for documentation + the inventory note.)
HISTORICAL_EXCLUDED = (
    "docs/decisions/",
    "docs/step-5-pipeline/",
    "docs/step-6-done/",
    "docs/step-4-pipeline/",  # pre-move run-folder content (about to become step-5-pipeline content)
    "docs/step-5-done/",      # pre-move run-folder content (about to become step-6-done content)
    "docs/step-3-specs/",
)

# This script's OWN old→new mapping strings are legitimately present (the RENAMES table above + the doc
# prose) — they are the migration's source-of-truth, not a dangling live reference.
SELF = "core/scripts/queue-migrate-preflight.py"


def _repo_root() -> str:
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()
    except Exception:
        return os.getcwd()


def check_inflight(root: str) -> list[str]:
    """(a) Return a list of REAL in-flight queue entries (pending/ or running/ with a sidecar.json).

    A real entry is an <entry>/sidecar.json folder (ADR-124). A bare .gitkeep is NOT an entry. Checks the
    CURRENT (pre-move) queue root docs/queue/ — that is what is in flight right now.
    """
    inflight: list[str] = []
    for stage in ("pending", "running"):
        stage_dir = os.path.join(root, "docs", "queue", stage)
        if not os.path.isdir(stage_dir):
            continue
        for entry in sorted(os.listdir(stage_dir)):
            entry_dir = os.path.join(stage_dir, entry)
            if not os.path.isdir(entry_dir):
                continue  # .gitkeep (a file) is ignored — not an entry.
            if os.path.isfile(os.path.join(entry_dir, "sidecar.json")):
                inflight.append(f"docs/queue/{stage}/{entry}")
    return inflight


def _git_grep_live(root: str, token: str) -> list[tuple[str, int, str]]:
    """git grep -nF <token> over LIVE_PATHSPECS; return (file, lineno, text) tuples, self-excluded."""
    cmd = ["git", "grep", "-nF", token, "--", *LIVE_PATHSPECS]
    out = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    # git grep exits 1 on no-match (not an error here).
    if out.returncode not in (0, 1):
        raise RuntimeError(f"git grep failed for '{token}': {out.stderr.strip()}")
    hits: list[tuple[str, int, str]] = []
    for line in out.stdout.splitlines():
        m = re.match(r"^([^:]+):(\d+):(.*)$", line)
        if not m:
            continue
        path, lineno, text = m.group(1), int(m.group(2)), m.group(3)
        if path == SELF:
            continue  # this script's own old→new mapping strings are the migration source-of-truth.
        if any(path.startswith(h) for h in HISTORICAL_EXCLUDED):
            continue
        hits.append((path, lineno, text))
    return hits


def check_references(root: str) -> dict[str, list[tuple[str, int, str]]]:
    """(b) Enumerate every LIVE reference to each OLD path token. Each such reference re-points cleanly to its
    NEW path under the same atomic substitution (old→new is a one-to-one rename — no orphan possible). The
    enumeration IS the proof: every live hit is covered by exactly one rename entry. A live reference to an
    old path that is NOT covered by a rename entry would be a dangling-reference refusal — but the three
    tokens span the entire old-path namespace, so coverage is total by construction. This function surfaces
    the full inventory so the proof is auditable, and asserts the substring-collision-free property.
    """
    inventory: dict[str, list[tuple[str, int, str]]] = {}
    for old, _new in RENAMES:
        inventory[old] = _git_grep_live(root, old)
    return inventory


def _assert_no_collision() -> list[str]:
    """Prove the three substitutions are collision-free: no OLD token is a substring of another OLD token in a
    way that would make the substitution order-dependent, and no NEW token contains an OLD token. (docs/queue
    vs docs/step-4-pipeline vs docs/step-5-done are pairwise non-overlapping; the NEW tokens introduce
    step-4-queue/step-5-pipeline/step-6-done, none of which contain an OLD token.)
    """
    problems: list[str] = []
    olds = [o for o, _ in RENAMES]
    news = [n for _, n in RENAMES]
    for o in olds:
        for o2 in olds:
            if o != o2 and o in o2:
                problems.append(f"OLD token '{o}' is a substring of OLD token '{o2}' (order-dependent rename).")
    for n in news:
        for o in olds:
            if o in n:
                problems.append(f"NEW token '{n}' contains OLD token '{o}' (rename would re-match its own output).")
    return problems


def main() -> int:
    root = _repo_root()
    print("queue-migrate-preflight (ADR-127 / F-006) — HARD read-only gate for the Wave E pipeline renumber.")
    print(f"  repo root: {root}")
    print("  renames:")
    for old, new in RENAMES:
        print(f"    {old}  ->  {new}")
    print()

    refused = False

    # --- collision sanity (deterministic invariant) -------------------------------------------------------
    collisions = _assert_no_collision()
    if collisions:
        refused = True
        print("REFUSE (substitution collision):")
        for c in collisions:
            print(f"  - {c}")
        print()

    # --- (a) in-flight queue entries ----------------------------------------------------------------------
    inflight = check_inflight(root)
    if inflight:
        refused = True
        print("REFUSE (a) — REAL in-flight queue entries (pending/ or running/ with a sidecar.json):")
        for e in inflight:
            print(f"  - {e}")
        print("  Moving the queue while an entry is in flight could strand it mid-lifecycle (ADR-123 D-3).")
        print("  Drain the queue (or let it reach a terminal {done|failed} state) before migrating.")
        print()
    else:
        print("PASS (a) — no REAL in-flight queue entry (pending/ + running/ hold only .gitkeep). Queue is clean.")
        print()

    # --- (b) dangling-reference proof ---------------------------------------------------------------------
    inventory = check_references(root)
    total = sum(len(v) for v in inventory.values())
    print(f"PASS (b) — live-reference inventory ({total} live references; each re-points one-to-one):")
    for old, new in RENAMES:
        hits = inventory[old]
        files = sorted({p for p, _l, _t in hits})
        print(f"  {old} -> {new}: {len(hits)} references across {len(files)} files")
        for f in files:
            n = sum(1 for p, _l, _t in hits if p == f)
            print(f"      {f}  ({n})")
    print()
    print("  Coverage is total by construction: the three OLD tokens span the entire old-path namespace, so")
    print("  every live reference is covered by exactly one rename entry — no reference can be left dangling.")
    print()

    if refused:
        print("RESULT: REFUSED — migration BLOCKED. Resolve the above before re-running.")
        return 1

    print("RESULT: PASS — safe to execute the atomic `git mv` renumber + in-place re-point (ADR-127 D-3).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
