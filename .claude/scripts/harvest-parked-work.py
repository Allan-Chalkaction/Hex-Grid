#!/usr/bin/env python3
"""harvest-parked-work.py — surface parked work stranded in run-folder PROSE (R2, intra-repo).

The capture lanes (docs/step-1-ideas/, docs/step-5-pipeline/PENDING/ — ADR-087: the backlog is the one
inbox; the legacy docs/deferrals/ is kept as a dedup lane until migration) are durable, but landing work in
them is behavioral-only. When the discipline lapses, parked work gets stranded as *prose* inside run
artifacts ("deferred to a focused pass", "TODO", "out of scope", "not built") and is invisible until someone
greps for it. This sweep finds those candidate lines and REPORTS them — it never writes (report-only; the
operator triages each with /defer). Distinct from T17's harvest-infra-deferrals.sh, which is a cross-repo
PULL of already-formed DEFER-/OPEN- files; this one *forms candidates from prose that never became a file*.

READ-ONLY. No new primitive — the output is a candidate list, not a state file. Honors the drop-folder ethos
(no hook, no auto-sweep daemon, no auto-write): it surfaces the leak; the human decides.

Usage:
  python3 core/scripts/harvest-parked-work.py [--days N] [--all] [--root docs/step-5-pipeline]
    --days N   only scan run-folder files modified within N days (default 14)
    --all      ignore the date filter (scan every dated run folder)

Light dedup: a candidate is suppressed if a normalized snippet of it already appears verbatim in an existing
capture (docs/step-1-ideas/, docs/deferrals/ [legacy], docs/step-5-pipeline/PENDING/). Fuzzy semantic dedup is
deliberately NOT attempted — over-suppression hides real leaks; the operator cross-checks before filing.

Last stdout line is machine-parseable:
  HARVEST-PARKED: C candidate(s) across F file(s) (scanned S file(s)).
"""
import argparse
import os
import re
import sys
import time

# Strong deferral-language markers (case-insensitive). Each requires trailing CONTENT (not a bare header
# word) so structural "## Out of scope" headings and passing mentions don't match — that was the v1 noise.
MARKERS = re.compile(
    r"("
    r"deferred?\s+(?:to|in|the|this|until|—|-|:)|"        # "deferred to a focused pass", "deferred the X"
    r"\bdefer\s+(?:the|this|t-|t\d|[a-z]+ing|building)|"  # "defer the X", "defer building Y"
    r"punt(?:ed|ing)?\b|\bparked\b|park(?:ed|ing)?\s+(?:it|this|for)|"
    r"not\s+(?:yet\s+)?built\b|didn'?t\s+build\b|never\s+built\b|"
    r"left\s+(?:this\s+|it\s+)?for\s+(?:a\s+)?(?:later|focused|follow|future)|"
    r"out[-\s]of[-\s]scope\s*[:—-]\s*\S|"                  # "out of scope: <content>", not a bare header
    r"\bTODO:|\bFIXME:|\bXXX:"
    r")",
    re.IGNORECASE,
)

# Only sweep the high-signal filenames where parked work actually hides (per the R2 idea): findings,
# followups, residuals, gaps, handoffs, open-decisions. NOT every .md — that floods the report.
SCAN_NAME = re.compile(
    r"(^findings-|/findings/|followup|residual|^gaps|-gaps|handoff|open-decisions|retirement)", re.IGNORECASE
)
DATED_DIR = re.compile(r"\d{4}-\d{2}-\d{2}")
SKIP_NAMES = {"INDEX.md", "README.md", "deferrals-log.md"}
# planning run folders are meta-discussion of deferrals, not build residue — exclude by default
SKIP_DIR_MARKERS = ("/PENDING", "-PLANNER-", "-ROADMAP-")
HEADER_RE = re.compile(r"^\s{0,3}#{1,6}\s")
# ADR-087: the deferrals silo merged into the backlog and ideas lost the RAW- prefix — the single
# inbox is docs/step-1-ideas/. PENDING stays a capture lane (handoffs). The legacy docs/deferrals/
# is kept for dedup tolerance until the migration executes (then it simply yields nothing). The
# script-name/concept "parked" predates the new docs/parked/ shelf — distinct meanings (this sweeps
# prose leaks; the shelf is an operator move-target), so docs/parked/ is intentionally NOT a capture lane.
CAPTURE_DIRS = ["docs/step-1-ideas", "docs/deferrals", "docs/step-5-pipeline/PENDING"]
MAXLEN = 160


def _norm(s):
    return re.sub(r"\s+", " ", s).strip().lower()


def build_corpus(repo_root):
    chunks = []
    for d in CAPTURE_DIRS:
        full = os.path.join(repo_root, d)
        for dirpath, _, files in os.walk(full):
            for fn in files:
                if fn.endswith(".md"):
                    try:
                        with open(os.path.join(dirpath, fn), encoding="utf-8") as f:
                            chunks.append(_norm(f.read()))
                    except OSError:
                        pass
    return "\n".join(chunks)


def already_captured(line, corpus):
    """Suppress only on a strong verbatim-snippet match (>=8 words of the candidate seen in a capture)."""
    words = _norm(re.sub(MARKERS, " ", line)).split()
    if len(words) < 8:
        return False
    snippet = " ".join(words[:8])
    return snippet in corpus


def find_run_files(root, cutoff):
    out = []
    for dirpath, _, files in os.walk(root):
        if not DATED_DIR.search(dirpath) or any(m in dirpath for m in SKIP_DIR_MARKERS):
            continue
        for fn in files:
            if not fn.endswith(".md") or fn in SKIP_NAMES:
                continue
            if not SCAN_NAME.search(fn) and not SCAN_NAME.search(os.path.join(dirpath, fn)):
                continue
            p = os.path.join(dirpath, fn)
            if cutoff is not None:
                try:
                    if os.path.getmtime(p) < cutoff:
                        continue
                except OSError:
                    continue
            out.append(p)
    return out


def main():
    ap = argparse.ArgumentParser(description="Surface parked work stranded in run-folder prose (read-only).")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--root", default="docs/step-5-pipeline")
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    root = args.root if os.path.isabs(args.root) else os.path.join(repo_root, args.root)
    if not os.path.isdir(root):
        print(f"harvest-parked-work: no such dir: {root}", file=sys.stderr)
        print("HARVEST-PARKED: 0 candidate(s) across 0 file(s) (scanned 0 file(s)).")
        return

    cutoff = None if args.all else time.time() - args.days * 86400
    files = find_run_files(root, cutoff)
    corpus = build_corpus(repo_root)

    print("PARKED-WORK HARVEST (intra-repo, read-only) — candidates from run-folder prose")
    window = "all dated run folders" if args.all else f"modified within {args.days} days"
    print(f"Scanned: {len(files)} file(s) in {args.root} ({window})\n")

    total, hit_files = 0, 0
    for p in sorted(files):
        hits = []
        try:
            with open(p, encoding="utf-8") as f:
                for n, line in enumerate(f, 1):
                    if HEADER_RE.match(line):
                        continue
                    if MARKERS.search(line) and not already_captured(line, corpus):
                        txt = _norm(line)
                        if len(txt) > MAXLEN:
                            txt = txt[:MAXLEN].rsplit(" ", 1)[0] + "…"
                        hits.append((n, txt))
        except OSError:
            continue
        if hits:
            hit_files += 1
            total += len(hits)
            rel = os.path.relpath(p, repo_root)
            print(rel)
            for n, txt in hits:
                print(f"  L{n}: {txt}")
            print()

    if total == 0:
        print("No un-captured parked-work candidates found in the scanned window.\n")
    else:
        print("Cross-check docs/step-1-ideas + docs/step-5-pipeline/PENDING before filing; "
              "file the real ones with /defer.\n")
    print(f"HARVEST-PARKED: {total} candidate(s) across {hit_files} file(s) (scanned {len(files)} file(s)).")


if __name__ == "__main__":
    main()
