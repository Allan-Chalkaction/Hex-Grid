#!/usr/bin/env python3
"""adr-index.py — regenerate the generated ADR index (one-file lookup over docs/decisions/).

A near-mechanical port of `core/scripts/idea-map.py` (the established generated-disposable
pattern): one row per `ADR-NNN-*.md` file under `docs/decisions/`, capturing number, title,
one-line scope, status, and the load-bearing supersede/amend edges parsed from each ADR's
header (`Supersedes:`, `Amends:`, `Superseded-by:`, `Amended-by:`, `Extends:`, `Builds on:`).

Purpose: let an agent (or a human) load ONE file instead of 60+ ADRs to learn the current
shape of the decision record AND avoid landing on a retired/superseded decision. The per-ADR
files remain the source of truth; this index is **generated, disposable, idempotent**.

Subcommands / flags (mirror idea-map.py):
  (default)            write docs/decisions/INDEX.md
  --print              print to stdout, do NOT write
  --root DIR           ADR dir (default: docs/decisions)
  --check              exit 1 if INDEX.md is stale vs a fresh render (for /doctor); writes nothing

No external deps. Safe to run anytime; idempotent for unchanged inputs.

Date-line normalization in --check: a fresh render's "Generated <today>" line is normalized
so a date-only diff does NOT register as stale (matches idea-map.py's contract).
"""
import argparse
import datetime
import os
import re
import sys

# Filename pattern: ADR-NNN[-slug].md  (NNN is 2-4 digits; slug optional)
ADR_FILE_RE = re.compile(r"^ADR-(\d{2,4})(?:-(.+))?\.md$")

# Title line: `# ADR-NNN — Title`  or  `# ADR-NNN -- Title` or `# ADR-NNN: Title`
# Also accepts `# ADR-NNN Amendment — Title` (ADR-012-amendment shape) by allowing extra words
# between the ADR number and the canonical separator.
TITLE_RE = re.compile(r"^#\s+ADR-\d{2,4}(?:\s+[^—–\-:]+)?\s*[—–\-:]\s*(.+?)\s*$")

# Edge / status fields. Match both `Field:` and `**Field:**` shapes.
# Captures the entire VALUE (we later mine ADR refs from it).
FIELD_RE = re.compile(
    r"^\s*[>\-\*]?\s*\*{0,2}([A-Za-z][A-Za-z \-/]+?)\*{0,2}\s*:\s*(.+?)\s*$"
)

# Inline `ADR-NNN` references inside a value (used to extract edge targets).
ADR_REF_RE = re.compile(r"ADR-(\d{2,4})")

# Status-keyword normalization. The captured value is the ADR's status field;
# we drop everything after the first separator (parens/dot/dash/period) for a short
# one-liner, and lowercase-rank it for the "is this retired?" decision.
STATUS_KEYWORDS = {
    "accepted": "accepted",
    "proposed": "proposed",
    "superseded": "superseded",
    "supersedes": "accepted",  # an ADR that supersedes something is itself live
    "deprecated": "deprecated",
    "retired": "retired",
    "rejected": "rejected",
    "draft": "draft",
    "implemented": "accepted",
}

# Edge-field names we care about. We bucket them as: outgoing (this -> other),
# incoming (other -> this), and the loose "builds-on/extends" tag.
OUTGOING_EDGES = {"supersedes", "amends"}
INCOMING_EDGES = {"superseded-by", "superseded by", "amended-by", "amended by"}
RELATION_EDGES = {"extends", "builds on", "builds-on"}

SKIP = {"INDEX.md", "README.md"}
MAXLEN_SCOPE = 140


def _norm_field_name(s):
    """Lowercase + strip emphasis. `Supersedes`, `**Supersedes**`, ` Supersedes ` -> `supersedes`."""
    return s.strip().strip("*").strip().lower()


def _strip_emphasis(s):
    """Strip leading/trailing markdown emphasis and stray punctuation that's not part of a real value.

    A `**Status:** Accepted (T5b) · ...` line, when piece-split on ` · `, yields a first piece
    `**Status:** Accepted (T5b)`. FIELD_RE matches `Status` as the name and `Accepted (T5b)` as the
    value — but the closing `**` is greedy with the `(.+?)` non-greedy quantifier, so without explicit
    cleanup we'd see `**Accepted (T5b)` in the value. Strip those bookends here.
    """
    s = s.strip()
    # Trim leading "**" / "*" / "_" emphasis markers that leaked through.
    while s and s[0] in "*_":
        s = s[1:]
    while s and s[-1] in "*_":
        s = s[:-1]
    return s.strip()


def _one_liner(text, maxlen=MAXLEN_SCOPE):
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= maxlen:
        return text
    cut = text[:maxlen].rsplit(" ", 1)[0]
    return cut + "…"


def _normalize_status(raw):
    """Pull a short status label and a 'retired?' boolean from the free-form Status: value."""
    if not raw:
        return ("?", False)
    # Strip emphasis markers anywhere in the captured value.
    cleaned = raw.replace("**", "").replace("*", "")
    # Take the head before the first separator. The hyphen split is risky around `ADR-NNN`
    # references; protect those by temporarily masking them before splitting.
    masked = re.sub(r"ADR-(\d+)", r"ADR\1", cleaned)
    short = re.split(r"[(.·]|\s+-\s+|\s+—\s+", masked, maxsplit=1)[0].strip()
    short = re.sub(r"ADR(\d+)", r"ADR-\1", short)
    # Heuristic rank by first keyword that appears.
    low = cleaned.lower()
    retired = False
    label = short or "?"
    for kw in ("superseded", "deprecated", "retired", "rejected"):
        if kw in low:
            retired = True
            # Prefer the canonical short label when we have one.
            label = short or kw.title()
            break
    return (_one_liner(label, 60), retired)


def _first_nonempty_line_after_title(lines):
    """First non-blank prose line after the title — used as 'scope' for the row.

    Skips: title, blank lines, all heading lines (`#`/`##`), all metadata-shaped lines
    (whether bracketed by `*` emphasis or hung off a `>` blockquote), and the common
    'Status: …', 'Date: …', 'Supersedes: …' / similar field lines even when parens or
    other punctuation in the value defeat FIELD_RE. The first prose paragraph is the
    Context-section opening line, which is what we want.
    """
    saw_title = False
    seen_context_heading = False
    # Look for these prefixes (case-insensitive) inside leading `**…**:` or `>` markup.
    META_PREFIXES = (
        "status:", "date:", "supersedes", "superseded", "amends", "amended",
        "extends", "builds on", "builds-on", "related", "depends on", "deciders",
        "repo:", "branch:", "touches", "test:", "door:", "jam:", "research:",
        "pairs with", "numbering",
    )
    for ln in lines:
        stripped = ln.strip()
        if not saw_title:
            if stripped.startswith("# "):
                saw_title = True
            continue
        if not stripped:
            continue
        # Skip every heading; track when we cross into a Context section (preferred
        # source of the one-line scope).
        if stripped.startswith("#"):
            if "context" in stripped.lower():
                seen_context_heading = True
            continue
        # Strip leading list / blockquote / emphasis markers for the meta-prefix check.
        probe = re.sub(r"^[>\s\-\*]+", "", stripped).lower()
        if any(probe.startswith(p) for p in META_PREFIXES):
            continue
        # Skip lines that are just a single bold/italic phrase ending in a colon
        # (these are inline field labels like "**Supersedes (for v2):**").
        if re.match(r"^\*{1,2}[A-Z][^*]{0,60}:\*{1,2}", stripped):
            continue
        # Skip lines that match FIELD_RE (regular metadata).
        if FIELD_RE.match(ln):
            continue
        # Render-ready prose: strip leading markup + inline emphasis.
        body = re.sub(r"^[>\s\-\*]+", "", stripped)
        body = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", body)
        if body:
            return body
    return ""


def parse_adr(path, fname):
    """Return a dict for one ADR file."""
    m = ADR_FILE_RE.match(fname)
    if not m:
        return None
    num = int(m.group(1))
    slug = (m.group(2) or "").strip()

    title = None
    status_raw = ""
    fields = {}  # normalized-name -> last value seen (string)
    outgoing = {"Supersedes": set(), "Amends": set()}
    incoming = {"Superseded-by": set(), "Amended-by": set()}
    relations = {"Extends": set(), "Builds on": set()}
    body_lines = []

    try:
        with open(path, encoding="utf-8") as f:
            body_lines = f.readlines()
    except OSError:
        return None

    for line in body_lines:
        if title is None:
            tm = TITLE_RE.match(line)
            if tm:
                title = tm.group(1).strip()
                continue
        # Field lines. NOTE: a ' > ' (blockquote) prefix is allowed; FIELD_RE
        # already strips leading `[>\-\*]?` once.
        # Also handle multi-field-on-one-line lines like:
        #   **Status:** X · **Date:** Y · **Repo:** Z
        # by splitting on `·` first, parsing each piece.
        raw = line.rstrip("\n")
        # blockquote-only marker for metadata at start of line
        raw_clean = re.sub(r"^\s*>\s*", "", raw)
        pieces = re.split(r"\s+·\s+", raw_clean)
        for piece in pieces:
            fm = FIELD_RE.match(piece)
            if not fm:
                continue
            key = _norm_field_name(fm.group(1))
            val = _strip_emphasis(fm.group(2))
            # Don't double-record a non-metadata sentence that starts with capital-Word + colon.
            # Heuristic: the key must be short (<=24 chars) and look like a metadata field name.
            if len(key) > 24:
                continue
            fields[key] = val
            if key == "status" and not status_raw:
                status_raw = val
            if key in OUTGOING_EDGES:
                refs = {int(r) for r in ADR_REF_RE.findall(val)}
                bucket = "Supersedes" if key == "supersedes" else "Amends"
                outgoing[bucket].update(refs)
            elif key in INCOMING_EDGES:
                refs = {int(r) for r in ADR_REF_RE.findall(val)}
                bucket = "Superseded-by" if "superseded" in key else "Amended-by"
                incoming[bucket].update(refs)
            elif key in RELATION_EDGES:
                refs = {int(r) for r in ADR_REF_RE.findall(val)}
                bucket = "Extends" if key == "extends" else "Builds on"
                relations[bucket].update(refs)

    status_short, is_retired = _normalize_status(status_raw)
    scope = _one_liner(_first_nonempty_line_after_title(body_lines))

    return {
        "num": num,
        "slug": slug,
        "title": title or f"ADR-{num:03d}",
        "status": status_short,
        "status_raw": status_raw,
        "retired": is_retired,
        "scope": scope,
        "outgoing": {k: sorted(v) for k, v in outgoing.items()},
        "incoming": {k: sorted(v) for k, v in incoming.items()},
        "relations": {k: sorted(v) for k, v in relations.items()},
        "fname": fname,
    }


def collect(root):
    adrs = []
    if not os.path.isdir(root):
        return adrs
    for fname in sorted(os.listdir(root)):
        if fname in SKIP or not fname.endswith(".md"):
            continue
        path = os.path.join(root, fname)
        if not os.path.isfile(path):
            continue
        parsed = parse_adr(path, fname)
        if parsed is None:
            continue
        adrs.append(parsed)
    # Stable order: by ADR number ascending, then filename (handles duplicate numbers
    # like ADR-012-amendment and ADR-012-surface — both present in the repo today).
    adrs.sort(key=lambda a: (a["num"], a["fname"]))
    return adrs


def _adr_ref(n):
    """Canonical 3-digit ADR reference (so `ADR-028` not `ADR-28`).

    Three digits is the on-disk filename convention and the form AC-011/AC-012 grep over.
    ADRs above 999 (unlikely; we'd see substrate-wide drift first) fall back to as-is.
    """
    return f"ADR-{n:03d}" if n < 1000 else f"ADR-{n}"


def _edge_tags(adr):
    """Render the edges to a compact tag list for the row."""
    tags = []
    for label, refs in adr["outgoing"].items():
        if refs:
            tags.append(f"{label}: " + ", ".join(_adr_ref(n) for n in refs))
    for label, refs in adr["incoming"].items():
        if refs:
            tags.append(f"{label}: " + ", ".join(_adr_ref(n) for n in refs))
    for label, refs in adr["relations"].items():
        if refs:
            tags.append(f"{label}: " + ", ".join(_adr_ref(n) for n in refs))
    return tags


def render(adrs, today):
    out = []
    out.append("# ADRs — index (generated view)\n")
    out.append(
        "> **Generated by `core/scripts/adr-index.py`** from the `Status:` / `Supersedes:` / `Amends:` / "
        "`Superseded-by:` / `Amended-by:` / `Extends:` / `Builds on:` header fields in each "
        "`docs/decisions/ADR-*.md` file.\n"
        "> Disposable — regenerate anytime (`python3 core/scripts/adr-index.py`). The per-ADR files are the "
        "source of truth; git is the history. `/doctor` runs `--check` to flag staleness.\n"
        "> A lookup should land on a LIVE decision: an ADR row marked `superseded` / `retired` / `deprecated` "
        "points at its replacement via the `Superseded-by:` tag — follow it.\n"
    )
    # --- Section 1: live ADRs ---
    live = [a for a in adrs if not a["retired"]]
    retired = [a for a in adrs if a["retired"]]

    out.append(f"\n## Live decisions ({len(live)})\n\n")
    out.append("| ADR | Status | Title | Scope | Edges |\n")
    out.append("|---:|---|---|---|---|\n")
    for a in live:
        tags = _edge_tags(a)
        tags_cell = "<br>".join(tags) if tags else ""
        scope_cell = a["scope"].replace("|", "\\|")
        title_cell = a["title"].replace("|", "\\|")
        out.append(
            f"| {_adr_ref(a['num'])} | {a['status']} | {title_cell} | {scope_cell} | {tags_cell} |\n"
        )

    # --- Section 2: retired / superseded ADRs ---
    out.append(f"\n## Retired / superseded ({len(retired)})\n\n")
    out.append("> These remain on disk as historical context. Do not cite them as live decisions; follow the `Superseded-by` edge.\n\n")
    if retired:
        out.append("| ADR | Status | Title | Superseded-by / Replaced-by |\n")
        out.append("|---:|---|---|---|\n")
        for a in retired:
            replacers = a["incoming"].get("Superseded-by", []) + a["incoming"].get("Amended-by", [])
            # Some ADRs declare retirement via prose in Status: itself (e.g. ADR-028 mentions "SUPERSEDED by ADR-040" in body).
            # When no formal Superseded-by: field exists, mine the body once: look for "Superseded by ADR-NNN" / "SUPERSEDED by ADR-NNN" in status_raw.
            if not replacers and a.get("status_raw"):
                replacers = sorted({int(r) for r in ADR_REF_RE.findall(a["status_raw"])} - {a["num"]})
            cell = ", ".join(_adr_ref(n) for n in replacers) if replacers else "—"
            title_cell = a["title"].replace("|", "\\|")
            out.append(f"| {_adr_ref(a['num'])} | {a['status']} | {title_cell} | {cell} |\n")
    else:
        out.append("_None._\n")

    # --- Section 3: cross-cutting edge digest ---
    # Surfaces the load-bearing edges in a flat list so `--print | grep` lands on them
    # cheaply. This is what AC-011 keys on (≥5 supersede/amend edges visible).
    out.append("\n## Edge digest (load-bearing supersede/amend ties)\n\n")
    digest = []
    for a in adrs:
        for label, refs in a["outgoing"].items():
            for n in refs:
                digest.append((a["num"], label, n))
        for label, refs in a["incoming"].items():
            for n in refs:
                digest.append((a["num"], label, n))
    digest.sort()
    if digest:
        for src, label, tgt in digest:
            out.append(f"- ADR-{src:03d} **{label}** ADR-{tgt:03d}\n")
    else:
        out.append("_No supersede/amend edges declared in ADR headers._\n")

    # --- Footer ---
    out.append(
        f"\n---\n*Counts: {len(adrs)} ADR(s) total — {len(live)} live, {len(retired)} retired. "
        f"Generated {today} by adr-index.py.*\n"
    )
    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description="Regenerate the generated ADR index.")
    ap.add_argument("--root", default="docs/decisions")
    ap.add_argument("--print", dest="to_stdout", action="store_true", help="print, don't write")
    ap.add_argument("--check", action="store_true", help="exit 1 if INDEX.md is stale; write nothing")
    args = ap.parse_args()

    if not os.path.isdir(args.root):
        sys.stderr.write(f"adr-index: no such dir: {args.root}\n")
        sys.exit(2)

    today = datetime.date.today().isoformat()
    adrs = collect(args.root)
    rendered = render(adrs, today)
    index_path = os.path.join(args.root, "INDEX.md")

    if args.check:
        existing = ""
        if os.path.exists(index_path):
            with open(index_path, encoding="utf-8") as f:
                existing = f.read()
        # Ignore the "Generated <date>" line so a date-only diff isn't "stale".
        norm = lambda s: re.sub(r"Generated \d{4}-\d{2}-\d{2}", "Generated <date>", s)
        if norm(existing) != norm(rendered):
            sys.stderr.write("adr-index: INDEX.md is stale — run `python3 core/scripts/adr-index.py` to regenerate.\n")
            sys.exit(1)
        print("adr-index: INDEX.md is current.")
        return

    if args.to_stdout:
        sys.stdout.write(rendered)
        return

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(rendered)
    print(f"adr-index: wrote {index_path} ({len(adrs)} ADRs).")


if __name__ == "__main__":
    main()
