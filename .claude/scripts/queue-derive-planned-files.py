#!/usr/bin/env python3
"""queue-derive-planned-files.py — DETERMINISTIC add-time planned_files derivation (ADR-124, Wave 3).

The autonomous work queue's overlap detection (`queue-order.py::_overlap_conflict` + `dependents`) is
DORMANT when entries carry no `planned_files`: with nothing to compare, two structurally-dependent builds
look independent and the orderer can only fall back to the operator's explicit `after X`. v1 never derived
`planned_files`, so the overlap edges never fired (the dogfood "dependency detection is name-only" finding).

This script DERIVES an entry's `planned_files` from the queued artifact ITSELF — deterministically, with
ZERO LLM (F9): it parses the wave-spec ticket blocks for the `- planned_files: [a, b, c]` field (the wave
schema `wave-manifest.py` already consumes) and returns the de-duplicated UNION across every ticket in every
`*.md` under the target. A roadmapped spec thus arrives in the queue with its real file set, so the orderer's
overlap edges become live. A raw plan (no ticket blocks, no `planned_files` field) yields the empty set —
overlap detection simply stays inactive for it, which is correct: it isn't roadmapped, so its file set is
unknown, and the orderer falls back to explicit `after X` (never a guess).

This is the DETERMINISTIC half of the dogfood's "derivation or explore pass" idea. An LLM explore-pass that
PREDICTS files for a raw plan would be advisory-only and is deliberately NOT done here (it would violate F9's
zero-LLM-placement contract). Derivation reads DECLARED structure; it never predicts.

Output: a comma-separated list of unique paths (sorted for determinism) on stdout — the exact shape
`/queue add` passes to `queue-order.py compute --planned-files` and writes into the sidecar. Empty output =
nothing derived (a raw plan / no declarations). Exit 0 always; fail-open (unreadable → empty).

Usage:
  queue-derive-planned-files.py <path>     # path = the in-queue artifact (folder or single .md)
"""
import os
import re
import sys

# `- planned_files: [a, b, c]` — the wave-schema ticket field (mirrors wave-manifest.py's parser). Tolerant of
# leading whitespace and `*`/`-` bullet markers; captures the bracketed, comma-separated list body.
_PF = re.compile(r"^[ \t]*[-*][ \t]+planned_files:[ \t]*\[([^\]]*)\]", re.M)
# `## Tickets` heading — derivation scans planned_files ONLY within the Tickets section (mirrors
# wave-manifest.py: planned_files outside a ticket block is not parsed). This drops false positives from a
# `planned_files:` line that appears in prose / a code fence BEFORE the ticket list.
_TICKETS_H = re.compile(r"^##[ \t]+Tickets[ \t]*$", re.M)


def _iter_markdown(path):
    if os.path.isfile(path):
        if path.endswith(".md"):
            try:
                with open(path, encoding="utf-8") as fh:
                    yield fh.read()
            except OSError:
                return
        return
    if os.path.isdir(path):
        for root, _dirs, files in os.walk(path):
            for name in sorted(files):
                if name.endswith(".md"):
                    try:
                        with open(os.path.join(root, name), encoding="utf-8") as fh:
                            yield fh.read()
                    except OSError:
                        continue


def derive(path):
    """Return the sorted, de-duplicated union of declared planned_files across all wave specs under path.

    Scans planned_files ONLY within each file's `## Tickets` section (mirrors wave-manifest.py — a
    planned_files line outside the ticket list is not a ticket declaration). A file with no `## Tickets`
    heading contributes nothing (a raw plan → empty), the safe direction.
    """
    files = set()
    for md in _iter_markdown(path):
        h = _TICKETS_H.search(md)
        if not h:
            continue                       # no ticket section → not a roadmapped spec → nothing to derive
        for m in _PF.finditer(md[h.end():]):
            for raw in m.group(1).split(","):
                p = raw.strip().strip("'\"").strip()
                if p:
                    files.add(p)
    return sorted(files)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: queue-derive-planned-files.py <path>\n")
        sys.exit(2)
    print(",".join(derive(sys.argv[1])))


if __name__ == "__main__":
    main()
