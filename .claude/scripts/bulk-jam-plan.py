#!/usr/bin/env python3
"""bulk-jam-plan.py — the UPSERT plan for bulk-jamming the ideas backlog (P2, idea-pipeline jam).

Bulk jam = open/advance a jam for every ripe cluster at once. The hazard: if you keep adding ideas and
re-run before the jams reach development, a naive runner forks duplicate folders (jam-X and jam-X-2). The
fix is an UPSERT keyed on a stable identity:

    stable key = cluster slug = jam folder name (docs/step-2-planning/jam-<slug>/)

This script computes — deterministically, read-only — the upsert plan: for each cluster, whether to CREATE a
new jam or REOPEN an existing one, and (for reopens) exactly which members are NEW this pass. New-member
detection rides jam-folder membership (ADR-087: location is status; the backlog folder is the inbox, the
jam folder is the next stage — a `git mv` advances), so re-runs naturally pick up only fresh sparks — NO
separate ledger, NO state machine. The /bulk-jam skill consumes this plan to scaffold / append; deep
convergence stays with `/planner jam <slug>`.

A member is NEW to an existing jam if its short-slug does not appear verbatim in any file under the jam dir.

Verify-shipped gate (ADR-060): before classifying CREATE/REOPEN/SKIP, every cluster is run through a
deterministic, read-only verify-shipped classifier (SHIPPED / PARTLY / UNBUILT). A SHIPPED cluster — one whose
deliverable already exists on disk — is suppressed from the CREATE/REOPEN/SKIP listing and surfaced in a
top-of-output `VERIFY-SHIPPED GATE` banner instead, so already-built work is never re-opened as a jam. The
`--verify=explore` Explore-agent upgrade for ambiguous (PARTLY) clusters lives in /bulk-idea-jam, not here;
this script is grep-only and always-on, and it never adjudicates.

Usage:
  python3 core/scripts/bulk-jam-plan.py [--root docs/step-1-ideas] [--jams docs/step-2-planning] [--min N]
    --min N   only plan clusters with >= N members (default 2; clusters emerge at 2)

Excludes the synthetic "standalone" / "(unclustered)" buckets — those aren't convergence clusters.
Last stdout line is machine-parseable:
  BULK-JAM-PLAN: C create, R reopen(+new), S skip(no-new), H shipped across T cluster(s).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

# ADR-087: status-prefixes (RAW/SHAPING/PROMOTED/DROPPED) retired — location is status, the backlog
# folder IS the "RAW" stage and jam-folder membership is the new-member signal. Backlog files are
# `<date>-<slug>.md`; `DEFER-`/`FOLLOWUP-` carry a kind tag (still cluster-eligible).
# FOLLOWUP- stubs are dateless (`FOLLOWUP-<spec-slug>.md`, ADR-087 D6); DEFER- carries a date.
KIND_RE = re.compile(r"^(DEFER|FOLLOWUP)-(?:(\d{4}-\d{2}-\d{2})-)?(.+)\.md$")
DATED_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+)\.md$")
FIELD_RE = re.compile(r"^\s*-\s+\*\*([^:*]+):\*\*\s*(.*\S)\s*$")
SKIP_FILES = {"INDEX.md", "README.md"}
NON_CLUSTERS = {"standalone", "(unclustered)", "unclustered"}

# Verify-shipped gate (ADR-060): the search roots the classifier reads, relative to repo_root, and the
# fixture directory excluded from body-match (so the checked-in synthetic corpus never pollutes a real run).
SEARCH_ROOTS = ("core/skills", "core/scripts", "docs/decisions")
_FIXTURE_DIRNAME = "test-fixtures"


def parse_idea(path, fname):
    # Accept a dated backlog file (`<date>-<slug>.md`) or a kind-tagged one (`DEFER-`/`FOLLOWUP-`).
    km = KIND_RE.match(fname)
    if km:
        kind, short = km.group(1), km.group(3)
    else:
        dm = DATED_RE.match(fname)
        if not dm:
            return None
        kind, short = "IDEA", dm.group(2)
    clusters = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            fm = FIELD_RE.match(line)
            if fm and fm.group(1).strip().lower() == "cluster":
                clusters = [c.strip() for c in fm.group(2).split(",") if c.strip()]
                break
    return {"short": short, "kind": kind, "clusters": clusters}


def collect_clusters(root, min_members):
    by_cluster = {}
    for fname in sorted(os.listdir(root)):
        if fname in SKIP_FILES or not fname.endswith(".md"):
            continue
        idea = parse_idea(os.path.join(root, fname), fname)
        if not idea:
            continue
        for c in idea["clusters"]:
            if c.lower() in NON_CLUSTERS:
                continue
            by_cluster.setdefault(c, []).append(idea)
    return {c: m for c, m in by_cluster.items() if len(m) >= min_members}


def jam_text(jam_dir):
    """Concatenated text of every file under an existing jam dir (for new-member detection)."""
    chunks = []
    for dirpath, _, files in os.walk(jam_dir):
        for fn in files:
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8") as f:
                    chunks.append(f.read())
            except OSError:
                pass
    return "\n".join(chunks)


def _search_dir(dirpath, needle):
    """Return the set of absolute file paths under dirpath whose body contains `needle` as a literal
    substring. Read-only. Prefers ripgrep (a single subprocess, never shell=True); transparently falls back
    to a pure-Python walk in the jam_text() style when rg is absent or fails to spawn. Both paths produce
    identical results across the fixture corpus. The test-fixtures/ tree is excluded so the checked-in
    synthetic corpus never pollutes a real classification."""
    if not os.path.isdir(dirpath):
        return set()
    if shutil.which("rg"):
        try:
            proc = subprocess.run(
                ["rg", "-l", "--fixed-strings",
                 "-g", "!**/{}/**".format(_FIXTURE_DIRNAME),
                 "--", needle, dirpath],
                capture_output=True, text=True, check=False,
            )
            return {ln for ln in proc.stdout.splitlines() if ln}
        except (FileNotFoundError, OSError, subprocess.SubprocessError):
            pass  # rg failed to spawn — fall through to the pure-Python walk.
    found = set()
    for root, dirs, files in os.walk(dirpath):
        dirs[:] = [d for d in dirs if d != _FIXTURE_DIRNAME and not d.startswith(".")]
        for fn in files:
            if fn.startswith("."):
                continue
            p = os.path.join(root, fn)
            try:
                with open(p, encoding="utf-8", errors="ignore") as f:
                    if needle in f.read():
                        found.add(p)
            except OSError:
                pass
    return found


def classify_shipped(slug, repo_root):
    """Deterministic, read-only verify-shipped classifier (ADR-060).

    Returns {'classification': 'SHIPPED'|'PARTLY'|'UNBUILT', 'evidence': [<repo-relative path>, ...]}.
    The cluster slug IS the canonical deliverable identifier — used verbatim as the grep needle, no
    re-slugification. Compute order (first match wins): path-existence (SHIPPED) -> body-match (PARTLY)
    -> neither (UNBUILT)."""
    # 1. SHIPPED — any path-existence signal fires (short-circuits the body search).
    evidence = []
    for rel in (
        os.path.join("core", "skills", slug, "SKILL.md"),
        os.path.join("core", "scripts", slug + ".py"),
        os.path.join("core", "scripts", slug + ".sh"),
    ):
        if os.path.exists(os.path.join(repo_root, rel)):
            evidence.append(rel)
    adr_glob = os.path.join(repo_root, "docs", "decisions", "ADR-*-" + slug + ".md")
    for hit in sorted(glob.glob(adr_glob)):
        evidence.append(os.path.relpath(hit, repo_root))
    if evidence:
        return {"classification": "SHIPPED", "evidence": evidence}

    # 2. PARTLY — slug appears as a literal string in file bodies under the search roots.
    body_hits = set()
    for rel_root in SEARCH_ROOTS:
        body_hits |= _search_dir(os.path.join(repo_root, rel_root), slug)
    if body_hits:
        ev = sorted(os.path.relpath(p, repo_root) for p in body_hits)
        return {"classification": "PARTLY", "evidence": ev}

    # 3. UNBUILT — neither path-existence nor body match.
    return {"classification": "UNBUILT", "evidence": []}


def main():
    ap = argparse.ArgumentParser(description="Compute the bulk-jam upsert plan (read-only).")
    ap.add_argument("--root", default="docs/step-1-ideas")
    ap.add_argument("--jams", default="docs/step-2-planning")
    ap.add_argument("--min", type=int, default=2)
    args = ap.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    root = args.root if os.path.isabs(args.root) else os.path.join(repo_root, args.root)
    jams = args.jams if os.path.isabs(args.jams) else os.path.join(repo_root, args.jams)
    if not os.path.isdir(root):
        print(f"bulk-jam-plan: no such dir: {root}", file=sys.stderr)
        sys.exit(2)

    clusters = collect_clusters(root, args.min)

    # Verify-shipped gate (ADR-060): classify every cluster; SHIPPED clusters are suppressed from the
    # CREATE/REOPEN/SKIP listing and surfaced in a top-of-output banner instead. PARTLY/UNBUILT clusters
    # proceed to the normal listing unchanged (the PARTLY annotation is an orchestrator-side concern under
    # --verify=explore in /bulk-idea-jam; the script never adjudicates).
    shipped = []   # [(slug, [evidence, ...]), ...]
    pending = []   # slugs that proceed to CREATE/REOPEN/SKIP
    for slug in sorted(clusters):
        res = classify_shipped(slug, repo_root)
        if res["classification"] == "SHIPPED":
            shipped.append((slug, res["evidence"]))
        else:
            pending.append(slug)

    print("BULK-JAM UPSERT PLAN (read-only) — stable key: cluster slug = jam folder name\n")

    if shipped:
        print(f"VERIFY-SHIPPED GATE — {len(shipped)} SHIPPED cluster(s) suppressed from CREATE:")
        for slug, ev in shipped:
            print(f"  SHIPPED  jam-{slug}  evidence: {ev[0] if ev else '<none>'}")
        print()

    n_create = n_reopen = n_skip = 0
    for slug in pending:
        members = clusters[slug]
        jam_dir = os.path.join(jams, f"jam-{slug}")
        shorts = [it["short"] for it in members]
        if not os.path.isdir(jam_dir):
            n_create += 1
            print(f"CREATE  jam-{slug}  ({len(members)} member(s))")
            for s in shorts:
                print(f"          + {s}")
        else:
            text = jam_text(jam_dir)
            new = [s for s in shorts if s not in text]
            if new:
                n_reopen += 1
                print(f"REOPEN  jam-{slug}  ({len(new)} NEW of {len(members)} member(s)) — append + re-converge")
                for s in new:
                    print(f"          + {s}   (new this pass)")
            else:
                n_skip += 1
                print(f"SKIP    jam-{slug}  ({len(members)} member(s), 0 new) — up to date")
        print()

    total = len(clusters)
    n_shipped = len(shipped)
    if total == 0:
        print(f"No clusters with >= {args.min} members. Cluster ideas (add the `cluster:` field) and re-run.\n")
    print(f"BULK-JAM-PLAN: {n_create} create, {n_reopen} reopen(+new), {n_skip} skip(no-new), "
          f"{n_shipped} shipped across {total} cluster(s).")


if __name__ == "__main__":
    main()
