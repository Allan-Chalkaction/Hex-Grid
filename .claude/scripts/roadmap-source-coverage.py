#!/usr/bin/env python3
"""roadmap-source-coverage.py — the deterministic IN-bookend gate (ADR-103 W2).

The Workflow engine (roadmap.js) has NO filesystem access (ADR-039), so the
"every decided jam source is accounted for in the roadmap" check cannot live in
the engine. It lives HERE, run by the /roadmap lock step (the orchestrator has
FS). This script owns the COMPLETENESS guarantee deterministically — the LLM
author only proposes the mapping (which wave/defer absorbs each source) as a
'## Source disposition' section; this script globs the real sources and proves
the set is complete. The author cannot make an incomplete roadmap pass.

A jam's source/*.md files ARE the decided-idea atoms (one idea per file). A
roadmap that locks without accounting for every one of them has silently dropped
scope — the exact failure ADR-103 fixes. This is the single HARD gate (ADR-103
one-hard-gate principle): a non-empty unaccounted set halts the lock.

Disposition section contract (authored into roadmap.md by roadmap.js):

    ## Source disposition

    - <source-slug>: wave:<wave-slug>
    - <source-slug>: non-goal
    - <source-slug>: defer:<target>

where <source-slug> is the source filename without '.md'. A source is ACCOUNTED
when it appears as a key with a recognized disposition (wave:/non-goal/defer:).

Usage:
    roadmap-source-coverage.py check <jam-dir> <roadmap-md>

Exit codes:
    0  complete (every source accounted) OR no gate applies (no jam / no sources)
    2  GAP — one or more sources unaccounted (the unaccounted slugs are printed)
    3  usage / IO error
"""
import os
import re
import sys
import glob

# A disposition is recognized iff its value begins with one of these keywords.
_DISPOSITION_RE = re.compile(r"^(wave:\S+|non-goal|defer:\S+)\s*$")
# A disposition line: '- <slug>: <disposition>'. Tolerant of surrounding backticks/space.
_LINE_RE = re.compile(r"^\s*-\s+`?([A-Za-z0-9._-]+?)`?\s*:\s*(.+?)\s*$")
_SECTION_RE = re.compile(r"^##+\s+Source disposition\s*$", re.IGNORECASE)
_NEXT_SECTION_RE = re.compile(r"^##+\s+\S")


def source_slugs(jam_dir):
    """The decided-idea atoms: every source/*.md filename (without .md)."""
    src = os.path.join(jam_dir, "source")
    if not os.path.isdir(src):
        return []
    return sorted(
        os.path.basename(p)[:-3]
        for p in glob.glob(os.path.join(src, "*.md"))
        if os.path.isfile(p)
    )


def dispositioned_slugs(roadmap_md):
    """Parse the '## Source disposition' section → {slug: disposition} for valid entries.

    Returns (accounted: set[str], malformed: list[(slug, value)]). A slug listed with an
    UNRECOGNIZED disposition value is 'malformed' — it is NOT counted as accounted (an
    author cannot pass the gate by writing '- foo: handled').
    """
    with open(roadmap_md, "r") as f:
        lines = f.read().split("\n")
    in_section = False
    accounted, malformed = set(), []
    for line in lines:
        if _SECTION_RE.match(line):
            in_section = True
            continue
        if in_section and _NEXT_SECTION_RE.match(line) and not _SECTION_RE.match(line):
            break  # next section ends the disposition block
        if not in_section:
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        slug, value = m.group(1), m.group(2).strip().strip("`").strip()
        if _DISPOSITION_RE.match(value):
            accounted.add(slug)
        else:
            malformed.append((slug, value))
    return accounted, malformed


def check(jam_dir, roadmap_md):
    if not os.path.isfile(roadmap_md):
        print(f"roadmap-source-coverage: roadmap file not found: {roadmap_md}", file=sys.stderr)
        return 3
    sources = source_slugs(jam_dir)
    if not sources:
        # No jam / no decided-idea atoms → no gate applies (a paste-intent epic, etc.).
        print(f"roadmap-source-coverage: no source atoms under {jam_dir}/source/ — gate not applicable (OK)")
        return 0
    try:
        accounted, malformed = dispositioned_slugs(roadmap_md)
    except OSError as e:
        # SA-001 (ADR-103 W2 security review): any IO failure reading the roadmap (permission, not-a-file,
        # I/O error) collapses to the usage/IO code — NEVER a fail-open. A completeness gate must not let a
        # roadmap with dropped scope pass because it couldn't be read. Keeps the exit surface exactly {0,2,3}.
        print(f"roadmap-source-coverage: cannot read roadmap {roadmap_md}: {e}", file=sys.stderr)
        return 3
    unaccounted = [s for s in sources if s not in accounted]
    for slug, value in malformed:
        print(f"roadmap-source-coverage: WARN malformed disposition for {slug!r}: {value!r} "
              f"(must be wave:<slug> | non-goal | defer:<target>)", file=sys.stderr)
    if unaccounted:
        print(f"roadmap-source-coverage: GAP — {len(unaccounted)}/{len(sources)} decided jam "
              f"source(s) UNACCOUNTED in the roadmap '## Source disposition' section:", file=sys.stderr)
        for s in unaccounted:
            print(f"  - {s}", file=sys.stderr)
        print("Each must map to a wave (wave:<slug>), a non-goal, or a defer:<target>. "
              "This is the ADR-103 W2 hard gate — the lock cannot proceed with dropped scope.", file=sys.stderr)
        return 2
    print(f"roadmap-source-coverage: OK — all {len(sources)} decided jam source(s) accounted for.")
    return 0


def main(argv):
    if len(argv) >= 1 and argv[0] == "check":
        if len(argv) != 3:
            print("usage: roadmap-source-coverage.py check <jam-dir> <roadmap-md>", file=sys.stderr)
            return 3
        return check(argv[1], argv[2])
    print(__doc__)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
