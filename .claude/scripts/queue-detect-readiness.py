#!/usr/bin/env python3
"""queue-detect-readiness.py — build-readiness classifier for the autonomous work queue (ADR-124, Wave 2).

Given the path to an in-queue artifact (a folder that `/queue add` moved into `docs/step-4-queue/<stage>/<entry>/`,
or a single file), decide whether it is a **PLANNED** roadmapped spec (ready for a straight `/orchestrated`
build — preamble skipped, slice-once) or a **NOT-PLANNED** raw plan/idea (no decomposed ticket graph).

The classification MIRRORS `core/scripts/workflows/orchestrated.js::parsesToTickets` (the single shape
classifier the build engine itself uses): a markdown is "planned" iff it has a `## Tickets` heading followed
by at least one `### KEY: title` block whose KEY matches `^[A-Z][A-Z0-9]*-[A-Z0-9]+` (the wave-schema ticket
key shape, PEC-T3 / SSM-T1). Keeping ONE detector shape means the queue's pre-launch readiness gate and the
engine's own `detectPlanned()` agree on what "planned" means.

Coarse-gate semantics (the queue only needs "roadmapped vs raw", not the engine's per-wave `every()`):
  PLANNED      → at least one `*.md` under the target parses to tickets (a roadmapped spec folder/file).
  NOT_PLANNED  → no ticket-bearing wave spec found (a raw plan, a shaped idea, an un-decomposed thesis).
Fail-closed: an unreadable/empty/missing target is NOT_PLANNED (the safe direction — a raw build, not a
silently-skipped preamble).

Usage:
  queue-detect-readiness.py <path>     # prints PLANNED or NOT_PLANNED; exit 0 always (the verdict is stdout)
"""
import os
import re
import sys

# `## Tickets` heading, then `### KEY: title` (KEY shape mirrors orchestrated.js parsesToTickets, PEC-T3).
_TICKETS_H = re.compile(r"^##[ \t]+Tickets[ \t]*$", re.M)
_TICKET_KEY = re.compile(r"^###[ \t]+[A-Z][A-Z0-9]*-[A-Z0-9]+:", re.M)


def _parses_to_tickets(md):
    """True iff md has a `## Tickets` heading followed by >=1 `### KEY:` block (mirrors parsesToTickets)."""
    if not isinstance(md, str) or not md:
        return False
    h = _TICKETS_H.search(md)
    if not h:
        return False
    return bool(_TICKET_KEY.search(md[h.end():]))


def _iter_markdown(path):
    """Yield the text of every *.md under path (or path itself if it is a single .md). Fail-closed on errors."""
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


def classify(path):
    """PLANNED iff any markdown under path parses to tickets; NOT_PLANNED otherwise (fail-closed)."""
    for md in _iter_markdown(path):
        if _parses_to_tickets(md):
            return "PLANNED"
    return "NOT_PLANNED"


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: queue-detect-readiness.py <path>\n")
        sys.exit(2)
    print(classify(sys.argv[1]))


if __name__ == "__main__":
    main()
