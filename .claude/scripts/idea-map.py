#!/usr/bin/env python3
"""idea-map.py — regenerate the clustered backlog map (R1, jam-capture-review-surface).

The keystone of the "review surface" — turns the flat `docs/step-1-ideas/` inbox into a grouped,
human-scannable view WITHOUT introducing a state machine. The source of truth stays the individual
backlog files + their `- **cluster:**` field; this script renders a **generated, disposable**
`INDEX.md` from them (git is the history). On-demand only — no hook, no daemon, no JSON ledger.

How clustering works (option B, per RAW-…-ideas-clustering-and-map-view):
  - Each idea file MAY carry an optional `- **cluster:** <slug>[, <slug2>]` line (comma = multi-membership).
  - Cluster assignment is a human triage action ("avoid silent auto-clustering"); this script never guesses
    a cluster — it only renders what the files declare. Ideas with no `cluster:` land in "Unclustered".
  - **Location is status (ADR-087):** the `RAW-`/`SHAPING-`/`PROMOTED-`/`DROPPED-` prefix-as-status mechanic
    is RETIRED. A backlog file lives here because it is unprocessed; advancing it is a `git mv` to the next
    step folder. The only surviving prefixes are `DEFER-` (a deferral, carries a source pointer) and
    `FOLLOWUP-` (a delta stub) — kind tags, not status. The one-liner is the `why / value` field.

Subcommands / flags:
  (default)            write docs/step-1-ideas/INDEX.md
  --print              print to stdout, do NOT write
  --root DIR           backlog dir (default: docs/step-1-ideas)
  --check              exit 1 if INDEX.md is stale vs a fresh render (for /doctor); writes nothing

No external deps. Safe to run anytime; idempotent for unchanged inputs.
"""
import argparse
import datetime
import os
import re
import sys

# ADR-087: status-prefixes (RAW/SHAPING/PROMOTED/DROPPED) are retired — location is status.
# The only surviving prefixes are kind tags that carry a pointer, not a status. Backlog files are
# `<date>-<slug>.md`; `DEFER-<date>-<slug>.md` carries a source-run pointer; `FOLLOWUP-<spec-slug>.md`
# is a dateless delta stub (ADR-087 D6). KIND_RE accepts the dateless FOLLOWUP- form too.
KIND_RE = re.compile(r"^(DEFER|FOLLOWUP)-(?:(\d{4}-\d{2}-\d{2})-)?(.+)\.md$")
DATED_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})-(.+)\.md$")
TITLE_RE = re.compile(r"^#\s+(.*\S)\s*$")
FIELD_RE = re.compile(r"^\s*-\s+\*\*([^:*]+):\*\*\s*(.*\S)\s*$")
SKIP = {"INDEX.md", "README.md"}
UNCLUSTERED = "(unclustered)"
MAXLEN = 150

# Inbox disposition buckets (ADR-111 / W2IO-T16 taxonomy), SPLIT BY CONVEYOR MEMBERSHIP.
# ADR-111 conveyor-orthogonality (binding): the idea-cluster map represents the on-conveyor
# shaping flow, so it walks ONLY the on-conveyor buckets + flat top-level files. The
# off-conveyor lanes/shelves (chores/parked/backlog) are EXCLUDED — they are not on the
# shaping conveyor this map clusters (CR-001 / ADR-111). Absent buckets contribute nothing.
# Mirrors docs-index.py::_list_md_inbox (on-conveyor only).
ONCONVEYOR_BUCKETS = (
    "needs-shaping", "ready-to-build", "blocked-on-dependency", "already-done",
)
OFFCONVEYOR_BUCKETS = ("chores", "parked", "backlog")  # excluded from the cluster map


def _one_liner(text):
    text = re.sub(r"\s+", " ", text).strip()
    # drop leading bold lead-ins like "**foo:**" so the gist shows
    if len(text) <= MAXLEN:
        return text
    cut = text[:MAXLEN].rsplit(" ", 1)[0]
    return cut + "…"


def parse_idea(path, fname):
    # Kind tag (DEFER-/FOLLOWUP-) if present; else a bare dated idea; else fall back to the stem.
    km = KIND_RE.match(fname)
    if km:
        kind, short = km.group(1), km.group(3)
    else:
        dm = DATED_RE.match(fname)
        kind = "IDEA"
        short = dm.group(2) if dm else fname[:-3]
    title, clusters, value, size = None, [], None, None
    with open(path, encoding="utf-8") as f:
        for line in f:
            if title is None:
                tm = TITLE_RE.match(line)
                if tm:
                    title = tm.group(1)
                    continue
            fm = FIELD_RE.match(line)
            if not fm:
                continue
            key, val = fm.group(1).strip().lower(), fm.group(2).strip()
            if key == "cluster":
                clusters = [c.strip() for c in val.split(",") if c.strip()]
            elif key in ("why / value", "value"):
                if value is None:
                    value = val
            elif key in ("rough size", "size"):
                size = val
    return {
        "short": short,
        "kind": kind,
        "clusters": clusters or [UNCLUSTERED],
        "line": _one_liner(value or title or short),
        "size": size,
    }


def _md_in(d):
    """The .md files directly in d (no recursion), skipping INDEX/README. [] if absent."""
    if not os.path.isdir(d):
        return []
    return sorted(
        os.path.join(d, f)
        for f in os.listdir(d)
        if f.endswith(".md") and f not in SKIP and os.path.isfile(os.path.join(d, f))
    )


def collect(root):
    """Subfolder-aware: collect flat top-level idea files AND nested ON-CONVEYOR
    disposition-bucket files (mixed flat+nested inbox state — W2IO-T15). Off-conveyor
    folders (chores/parked/backlog) are excluded (ADR-111 conveyor-orthogonality, CR-001).
    No-regression: flat top-level files are still collected. Absent buckets contribute nothing."""
    ideas = []
    paths = list(_md_in(root))  # flat top-level (mixed-migration state)
    for sub in ONCONVEYOR_BUCKETS:
        paths.extend(_md_in(os.path.join(root, sub)))  # absent dir -> []
    for path in sorted(paths):
        ideas.append(parse_idea(path, os.path.basename(path)))
    return ideas


def render(ideas, today):
    # group: cluster -> [idea]; an idea appears under each cluster it declares
    groups = {}
    for it in ideas:
        for c in it["clusters"]:
            groups.setdefault(c, []).append(it)
    # order: by descending member count, then name; (unclustered) always last
    names = [c for c in groups if c != UNCLUSTERED]
    names.sort(key=lambda c: (-len(groups[c]), c))
    if UNCLUSTERED in groups:
        names.append(UNCLUSTERED)

    out = []
    out.append("# Backlog — clustered map (generated view)\n")
    out.append(
        "> **Generated by `core/scripts/idea-map.py`** from the `- **cluster:**` field in each "
        "`docs/step-1-ideas/*.md` file.\n"
        "> Disposable — regenerate anytime (`/idea-map`). The per-file backlog items are the source of "
        "truth; git is the history.\n"
        "> No state machine, no hook, no auto-sweep — clustering is a human triage action recorded in the "
        "file, rendered here.\n"
    )
    for c in names:
        members = sorted(groups[c], key=lambda it: (_kind_rank(it["kind"]), it["short"]))
        heading = "Unclustered" if c == UNCLUSTERED else f"Cluster: `{c}`"
        out.append(f"\n## {heading}  ({len(members)})\n")
        for it in members:
            also = [x for x in it["clusters"] if x != c and x != UNCLUSTERED]
            tags = []
            if it["size"]:
                tags.append(it["size"])
            if it["kind"] != "IDEA":
                tags.append(it["kind"])
            if also:
                tags.append("also: " + ", ".join(f"`{a}`" for a in also))
            suffix = (" · " + " · ".join(tags)) if tags else ""
            out.append(f"- `{it['short']}` — {it['line']}{suffix}\n")

    n_clusters = len([c for c in names if c != UNCLUSTERED])
    out.append(
        f"\n---\n*Counts: {len(ideas)} idea files across {n_clusters} clusters"
        + (f" + {len(groups[UNCLUSTERED])} unclustered" if UNCLUSTERED in groups else "")
        + f". Generated {today} by idea-map.py.*\n"
    )
    return "".join(out)


def _kind_rank(k):
    # Ideas first, then deferrals, then follow-up stubs (a stable, legible order).
    return {"IDEA": 0, "DEFER": 1, "FOLLOWUP": 2}.get(k, 0)


def main():
    ap = argparse.ArgumentParser(description="Regenerate the clustered ideas map.")
    ap.add_argument("--root", default="docs/step-1-ideas")
    ap.add_argument("--print", dest="to_stdout", action="store_true", help="print, don't write")
    ap.add_argument("--check", action="store_true", help="exit 1 if INDEX.md is stale; write nothing")
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        sys.stderr.write(f"idea-map: no such dir: {args.root}\n")
        sys.exit(2)

    today = datetime.date.today().isoformat()
    ideas = collect(args.root)
    rendered = render(ideas, today)
    index_path = os.path.join(args.root, "INDEX.md")

    if args.check:
        existing = ""
        if os.path.exists(index_path):
            with open(index_path, encoding="utf-8") as f:
                existing = f.read()
        # ignore the "Generated <date>" line so a date-only diff isn't "stale"
        norm = lambda s: re.sub(r"Generated \d{4}-\d{2}-\d{2}", "Generated <date>", s)
        if norm(existing) != norm(rendered):
            sys.stderr.write("idea-map: INDEX.md is stale — run `/idea-map` to regenerate.\n")
            sys.exit(1)
        print("idea-map: INDEX.md is current.")
        return

    if args.to_stdout:
        sys.stdout.write(rendered)
        return

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(rendered)
    print(f"idea-map: wrote {index_path} ({len(ideas)} ideas).")


if __name__ == "__main__":
    main()
