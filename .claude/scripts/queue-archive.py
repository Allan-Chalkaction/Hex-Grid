#!/usr/bin/env python3
"""queue-archive.py — the DETERMINISTIC settled-set predicate for queue-`done/` archival (ADR-128, QDM-T1).

F9 BINDING OPERATOR DIRECTIVE — ZERO LLM involvement in the archival decision (ADR-126). This script
computes which `docs/step-4-queue/done/` entries are **archivable** (safe to physically move to the
canonical date-partitioned `docs/step-6-done/queue/<date>/` archive — ADR-128 Amendment 1) purely from the
live folder state. It is **deterministic**: the same folder state always yields the same settled set. There
is no model in the loop — `grep -nE 'agent\\('` over this file is clean by construction (no dispatch, no
advisory hint that overrides the predicate).

NOTE — this predicate computes only the settled SET, it does NOT write the archive path. The physical move
(and the date-partitioned `<date>` sub-dir derivation, ADR-128 Amendment 1) lives in `qc_archive_settled`
(queue-chew-lib.sh); the read-side dual-read (dated ∪ legacy-flat) lives in `qc_completed_labels`.

THE SETTLED PREDICATE (ADR-128 D-2, PLAN §4.1 — the complete safety condition).
A `done/` entry is **archivable iff no live `pending/*/sidecar.json` names it in `after:`**. That is the
WHOLE safety condition, and it follows from the investigation grounding (PLAN §2): `done/` is read for
*dependency gating* only — `qc_pick_entry` gates a `pending` entry with `after: X` as ready iff `X` is
completed. Once no live `pending` entry still names an entry in `after:`, that entry's `done/` *location*
is inert for gating, so a post-settlement archival hop preserves the four ADR-123 D-3 invariants — PROVIDED
the dependency read also covers the archive location (the `qc_completed_labels()` union chokepoint, D-3).
That union is what makes a *late* `after:<archived>` still resolve; this predicate only decides *which*
already-settled entries may move now.

FOLDER-AS-TRUTH + NO-GUESS (ADR-126, mirroring queue-order.py).
  - Candidates  = the `done/` entry-folder basenames (the entry-as-folder shape, ADR-124).
  - Live demands = the union of every `after` token declared by a live `pending/*/sidecar.json`.
  - Archivable   = candidates whose basename appears in NO live `after` demand.
  - ABSTAIN on a malformed sidecar rather than guess (no-guess): an UNREADABLE/non-object `pending` sidecar
    is treated as if it COULD name anything, so we conservatively WITHHOLD archival of every candidate while
    it is present (fail-closed — never archive an entry a malformed sidecar might still depend on). A
    malformed `done` sidecar simply drops that candidate from consideration (we never archive what we cannot
    read). Abstention is recorded in `reason`; it is never silently archived-anyway.

`.gitkeep` and any non-directory in `done/` are ignored (never candidates — PLAN §4.5 / AC-7).

OUTPUT — the `queue-order.py` `{decision, reason, confidence}` mold (one JSON object):
  {
    "decision":   "archive" | "withhold",      # archive = the settled set is non-empty + safe to move
    "archivable": ["<label>", ...],             # the settled entry-folder basenames (sorted, deterministic)
    "withheld":   ["<label>", ...],             # done/ candidates still named by a live after: (or fail-closed)
    "reason":     "<human-legible deterministic explanation>",
    "confidence": "high" | "abstain"            # abstain iff any pending sidecar was malformed (fail-closed)
  }

Exit status: 0 always on a successful read (the decision is in the JSON; an empty settled set is a normal
`decision:"withhold"`, not an error). 2 only on a usage error (bad --queue-dir).

Subcommand:
  settled  --queue-dir DIR     # print the settled set + decision for DIR (default docs/step-4-queue)

Cites: ADR-128 (archival design), ADR-126 (the F9 zero-LLM floor), ADR-124 (entry-as-folder), ADR-123 D-3
(the four invariants this predicate's post-settlement discipline preserves).
"""
import json
import os
import sys
import argparse
import glob


def _die(msg, code=2):
    sys.stderr.write(f"queue-archive: {msg}\n")
    sys.exit(code)


def _done_candidates(queue_dir):
    """The done/ entry-folder basenames (candidates for archival). Non-dirs (.gitkeep) ignored — AC-7."""
    done_dir = os.path.join(queue_dir, "done")
    if not os.path.isdir(done_dir):
        return []
    cands = []
    for name in sorted(os.listdir(done_dir)):
        if not os.path.isdir(os.path.join(done_dir, name)):
            continue  # .gitkeep / stray files are never candidates.
        cands.append(name)
    return cands


def _live_after_demands(queue_dir):
    """Return (demands, malformed): the set of `after` tokens named by live pending/ sidecars, and whether
    any pending sidecar was unreadable/malformed (drives the fail-closed abstain — no-guess)."""
    pending_glob = os.path.join(queue_dir, "pending", "*", "sidecar.json")
    demands = set()
    malformed = False
    for side_path in sorted(glob.glob(pending_glob)):
        try:
            with open(side_path, encoding="utf-8") as fh:
                side = json.load(fh)
        except (json.JSONDecodeError, OSError):
            malformed = True  # fail-closed: a malformed pending sidecar could name anything.
            continue
        if not isinstance(side, dict):
            malformed = True
            continue
        after = side.get("after")
        if after is None:
            after = []
        elif isinstance(after, str):
            after = [after]
        elif not isinstance(after, list):
            # An `after` of an unexpected type is malformed — fail-closed.
            malformed = True
            continue
        for dep in after:
            if isinstance(dep, str):
                demands.add(dep)
    return demands, malformed


def cmd_settled(a):
    queue_dir = a.queue_dir
    if not os.path.isdir(queue_dir):
        _die(f"queue dir not found: {queue_dir}")

    candidates = _done_candidates(queue_dir)
    demands, malformed = _live_after_demands(queue_dir)

    # The settled predicate: a candidate is archivable iff NO live pending after: names it. When any pending
    # sidecar was malformed we ABSTAIN (fail-closed) — withhold EVERY candidate, never guess (no-guess).
    if malformed:
        archivable = []
        withheld = list(candidates)
        confidence = "abstain"
        reason = (
            "ABSTAIN (no-guess, fail-closed): one or more live pending/ sidecars are malformed/unreadable; "
            "a malformed sidecar could still name a done/ entry in after:, so all candidates are withheld "
            "until the queue is legible again (ADR-126 no-guess, ADR-128 D-2)."
        )
    else:
        archivable = [c for c in candidates if c not in demands]
        withheld = [c for c in candidates if c in demands]
        confidence = "high"
        if archivable:
            reason = (
                f"settled: {len(archivable)} done/ entr(y/ies) named by NO live pending after: are "
                f"archivable to step-6-done/queue/; {len(withheld)} still named by a live after: are "
                f"withheld (ADR-128 D-2 settled predicate)."
            )
        else:
            reason = (
                "no settled entries: every done/ candidate is either absent or still named by a live "
                "pending after: (or the queue is empty) — nothing to archive (ADR-128 D-2)."
            )

    out = {
        "decision": "archive" if archivable else "withhold",
        "archivable": sorted(archivable),
        "withheld": sorted(withheld),
        "reason": reason,
        "confidence": confidence,
    }
    print(json.dumps(out))


def main():
    p = argparse.ArgumentParser(prog="queue-archive")
    sub = p.add_subparsers(required=True)

    ps = sub.add_parser("settled", help="print the settled (archivable) done/ set for a queue dir")
    ps.add_argument("--queue-dir", default="docs/step-4-queue",
                    help="path to the queue root (default docs/step-4-queue)")
    ps.set_defaults(fn=cmd_settled)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
