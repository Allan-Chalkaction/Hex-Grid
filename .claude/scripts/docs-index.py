#!/usr/bin/env python3
"""docs-index.py — regenerate the operator dashboard (`docs/INDEX.md`).

The legibility payoff of ADR-087 (D5): one generated file that answers the 30-second
Monday scan — per-stage counts, the parked shelf with reasons, what's waiting on the
operator, and what shipped this week. The `adr-index.py` pattern: generated, disposable,
idempotent; the on-disk folders are the source of truth.

This render IS the ingestion schema for the future Jira-lite app — the app reads what
this renders.

Pre-migration tolerant (load-bearing): the doc-lifecycle migration
(`core/scripts/migrate-doc-lifecycle.sh`) has NOT necessarily run when this executes, so
every stage PREFERS the canonical path and FALLS BACK to the legacy one:
  step-1-ideas/     <- the inbox (ADR-089 renamed it from step-1-backlog; deferrals folded in).
                       Fallbacks: step-1-backlog/ (the short-lived ADR-087 name), then deferrals/.
  backlog/          <- the "we're doing this, just not now" shelf (ADR-089) — may be absent.
  parked/           <- the "shelved, maybe never" shelf — may be absent (empty shelf).
  step-6-done/sessions/, /deferrals/, /handoffs/  <- may be absent
Plan vitality (ADR-089 D5): each step-2 jam README may carry a machine-readable line
`<!-- vitality: absorbed=N passes=N last=YYYY-MM-DD pending=N -->`; rendered per jam, "—" if absent.
Missing dirs never crash — they render as zero / "none".

Subcommands / flags (mirror adr-index.py):
  (default)            write docs/INDEX.md
  --print              print to stdout, do NOT write
  --root DIR           repo root (default: auto-detect via git / script location)
  --check              exit 1 if INDEX.md is stale vs a fresh render (for /doctor); writes nothing

No external deps. Runs at /sweep + close-out time — NOT in CI (it reads a live, moving tree).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Path helpers — every stage prefers the NEW (ADR-087) path, falls back to legacy.
# ---------------------------------------------------------------------------


def _repo_root(arg_root):
    if arg_root:
        return os.path.abspath(arg_root)
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    # script lives in core/scripts/ -> repo root is two up.
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _first_existing(root, *rels):
    """Return the first <root>/<rel> that exists; else the first rel (for messaging)."""
    for rel in rels:
        p = os.path.join(root, rel)
        if os.path.isdir(p):
            return p
    return os.path.join(root, rels[0])


def _list_md(d):
    if not os.path.isdir(d):
        return []
    return sorted(
        os.path.join(d, f)
        for f in os.listdir(d)
        if f.endswith(".md") and f not in ("README.md", "INDEX.md")
        and os.path.isfile(os.path.join(d, f))
    )


# Inbox disposition buckets (ADR-111 / W2IO-T16 taxonomy), SPLIT BY CONVEYOR MEMBERSHIP.
# ADR-111 conveyor-orthogonality (binding): the on-conveyor buckets are the shaping flow;
# the off-conveyor lanes/shelves (chores/parked/backlog) share the parent dir but are NOT
# part of the inbox roll-up — they are rendered SOLELY by their dedicated shelf collectors
# (collect_chores / collect_parked / collect_backlog_shelf). The roll-up walk below must
# include ONLY the on-conveyor buckets + flat top-level files; folding the off-conveyor
# folders in here double-counts them and breaches ADR-111 (CR-001).
# Buckets may be absent; _list_md returns [] for a missing dir (absent-bucket tolerant).
_ONCONVEYOR_BUCKETS = (
    "needs-shaping", "ready-to-build", "blocked-on-dependency", "already-done",
)
_OFFCONVEYOR_BUCKETS = ("chores", "parked", "backlog")  # dedicated shelf collectors only — never the roll-up


def _list_md_inbox(inbox):
    """Subfolder-aware ON-CONVEYOR inbox walk: flat top-level .md files + each ON-conveyor
    disposition bucket's .md files. REUSES the collect_build_status per-bucket
    `_list_md(os.path.join(inbox, '<bucket>'))` idiom — no parallel walking tree, no os.walk.
    No-regression: flat top-level idea files are still collected alongside nested on-conveyor
    bucket files. The off-conveyor folders (chores/parked/backlog) are EXCLUDED here — they
    are rendered by their dedicated shelf collectors (ADR-111 conveyor-orthogonality, CR-001)."""
    files = list(_list_md(inbox))  # flat top-level (mixed-migration state)
    for sub in _ONCONVEYOR_BUCKETS:
        files.extend(_list_md(os.path.join(inbox, sub)))  # absent dir -> []
    return sorted(files)


def _age_days(path, root):
    """Age in whole days: prefer git first-commit (added) date, fall back to mtime."""
    try:
        out = subprocess.run(
            ["git", "log", "--diff-filter=A", "--follow", "--format=%at", "-1", "--", path],
            capture_output=True, text=True, cwd=root, check=False,
        )
        ts = out.stdout.strip().splitlines()
        if ts and ts[-1].isdigit():
            added = int(ts[-1])
            return max(0, int((datetime.datetime.now().timestamp() - added) // 86400))
    except Exception:
        pass
    try:
        mt = os.path.getmtime(path)
        return max(0, int((datetime.datetime.now().timestamp() - mt) // 86400))
    except OSError:
        return 0


def _first_line_gist(path, maxlen=80):
    """First markdown heading or first non-blank line, trimmed."""
    try:
        with open(path, encoding="utf-8") as f:
            for ln in f:
                s = ln.strip()
                if not s:
                    continue
                s = re.sub(r"^#+\s*", "", s)
                s = re.sub(r"^[>*\-]\s*", "", s).strip()
                s = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", s)
                if s:
                    s = re.sub(r"\s+", " ", s)
                    return s if len(s) <= maxlen else s[:maxlen].rsplit(" ", 1)[0] + "..."
    except OSError:
        pass
    return ""


# ---------------------------------------------------------------------------
# Stage collectors
# ---------------------------------------------------------------------------


def collect_backlog(root):
    """Split the inbox into ideas / DEFER / FOLLOWUP, with oldest-age."""
    # ADR-089: step-1-ideas is canonical; step-1-backlog is the short-lived ADR-087 fallback.
    backlog = _first_existing(root, "docs/step-1-ideas", "docs/step-1-backlog")
    # Subfolder-aware: collect flat top-level idea files AND nested disposition-bucket
    # files (mixed flat+nested inbox state — W2IO-T15). _list_md_inbox tolerates absent
    # buckets and does NOT alter the Wave-1 collect_build_status arm (which keeps its own
    # per-bucket _list_md calls).
    files = _list_md_inbox(backlog)
    # legacy: deferrals silo not yet folded in by migration — count it too.
    deferrals_legacy = os.path.join(root, "docs/deferrals")
    legacy_open = []
    if os.path.isdir(deferrals_legacy) and os.path.basename(backlog) != "step-1-ideas":
        legacy_open = [
            os.path.join(deferrals_legacy, f)
            for f in sorted(os.listdir(deferrals_legacy))
            if f.startswith("OPEN-") and f.endswith(".md")
        ]
    ideas, defers, followups = [], [], []
    for f in files:
        b = os.path.basename(f)
        if b.startswith("FOLLOWUP-"):
            followups.append(f)
        elif b.startswith("DEFER-") or b.startswith("OPEN-"):
            defers.append(f)
        elif b.startswith(("RAW-", "PROMOTED-", "SHAPING-")):
            ideas.append(f)  # legacy-prefixed ideas still count as ideas
        else:
            ideas.append(f)
    defers += legacy_open
    all_items = ideas + defers + followups
    oldest = max((_age_days(f, root) for f in all_items), default=0)
    older_30 = sum(1 for f in all_items if _age_days(f, root) > 30)
    return {
        "dir": backlog, "ideas": ideas, "defers": defers, "followups": followups,
        "oldest": oldest, "older_30": older_30,
        "legacy_deferrals_pending": len(legacy_open),
    }


def _collect_shelf(root, rel):
    shelf = os.path.join(root, rel)
    out = []
    for f in _list_md(shelf):
        out.append({"name": os.path.basename(f), "reason": _first_line_gist(f), "age": _age_days(f, root)})
    return {"dir": shelf, "items": out, "present": os.path.isdir(shelf)}


def collect_parked(root):
    # Repointed from the DEAD top-level docs/parked/ to its real home under the inbox
    # (docs/step-1-ideas/parked/). parked/ lives UNDER the inbox path but is OFF-conveyor
    # (ADR-089 D2 / ADR-110 conveyor-orthogonality: parent folder != conveyor membership).
    return _collect_shelf(root, "docs/step-1-ideas/parked")


def collect_backlog_shelf(root):
    """The ADR-089 D2 'we're doing this, just not now' shelf. Repointed (W2IO-T17) from the
    top-level docs/backlog/ to its folded home under the inbox (docs/step-1-ideas/backlog/).
    backlog/ lives UNDER the inbox path but is OFF-conveyor (ADR-111 conveyor-orthogonality)."""
    return _collect_shelf(root, "docs/step-1-ideas/backlog")


def collect_chores(root):
    """The ADR-090 chore lane — execution-ripe, no-planning queue. Repointed from the
    DEAD top-level docs/chores/ to its real home under the inbox (docs/step-1-ideas/chores/).
    chores/ lives UNDER the inbox path but is OFF-conveyor (ADR-090 / ADR-110
    conveyor-orthogonality: parent folder != conveyor membership)."""
    return _collect_shelf(root, "docs/step-1-ideas/chores")


def collect_specs(root):
    """Per-spec delta counts from step-3-specs/<slug>/deltas/."""
    specs_dir = os.path.join(root, "docs/step-3-specs")
    rows = []
    if os.path.isdir(specs_dir):
        for name in sorted(os.listdir(specs_dir)):
            sd = os.path.join(specs_dir, name)
            if not os.path.isdir(sd) or name.startswith("_"):
                continue
            deltas_dir = os.path.join(sd, "deltas")
            ndeltas = len(_list_md(deltas_dir)) if os.path.isdir(deltas_dir) else 0
            rows.append({"slug": name, "deltas": ndeltas})
    return rows


# ---------------------------------------------------------------------------
# Build-status collector (ADR-109 W3) — cross-BRANCH merged-vs-unmerged visibility.
# A main-resident roster answering "what is built-but-unmerged vs still-to-build" from
# the launch-manifest features[] (status+branch) + git branch state + the inbox readiness
# buckets. Reuses the collector idioms here (no parallel bucket-walking tree).
# ---------------------------------------------------------------------------


def _git_branches(root):
    """Return (all_local, merged_into_main) sets of local branch short-names. Empty/tolerant on a repo
    without git or without a main branch."""
    all_local, merged = set(), set()
    try:
        out = subprocess.run(
            ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"],
            capture_output=True, text=True, cwd=root, check=False,
        )
        all_local = {b.strip() for b in out.stdout.splitlines() if b.strip()}
    except Exception:
        pass
    base = "main" if "main" in all_local else ("master" if "master" in all_local else None)
    if base:
        try:
            out = subprocess.run(
                ["git", "branch", "--merged", base, "--format=%(refname:short)"],
                capture_output=True, text=True, cwd=root, check=False,
            )
            merged = {b.strip() for b in out.stdout.splitlines() if b.strip() and b.strip() != base}
        except Exception:
            pass
    return all_local, merged


def _find_fleet_manifests(root):
    """Best-effort: every launch-manifest.json under docs/ (a /launch fleet index). Tolerant of none."""
    out = []
    docs = os.path.join(root, "docs")
    if not os.path.isdir(docs):
        return out
    for dirpath, dirnames, filenames in os.walk(docs):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for fn in filenames:
            if fn == "launch-manifest.json":
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def collect_build_status(root):
    """Cross-branch merged-vs-unmerged roster data: per-feature {label, status, branch, merged} from any
    launch-manifest features[] reconciled against live git branch state, plus inbox readiness counts.

    Reads launch-manifest features[] (status+branch — fleet-manifest/2, L9-13; a /1 file defaults kind in
    memory). Derives built-but-unmerged vs still-to-build from feature status + whether its branch is
    merged into main. Tolerant: no manifest / no git / missing buckets render as empty."""
    all_local, merged = _git_branches(root)
    features = []
    for man in _find_fleet_manifests(root):
        try:
            with open(man, encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        slug = m.get("slug", os.path.basename(os.path.dirname(man)))
        for feat in m.get("features", []):
            if not isinstance(feat, dict):
                continue
            branch = feat.get("branch") or ""
            short = branch.split("/", 1)[-1] if branch else ""
            is_merged = branch in merged or short in merged or (
                branch.replace("refs/heads/", "") in merged)
            features.append({
                "fleet": slug,
                "label": feat.get("label", "?"),
                "status": feat.get("status", "?"),
                "branch": branch or "—",
                "merged": bool(is_merged),
            })
    # Inbox readiness buckets (EXTEND the roster — reuse _list_md, no parallel walking tree).
    inbox = _first_existing(root, "docs/step-1-ideas", "docs/step-1-backlog")
    readiness = {
        "ready-to-build": len(_list_md(os.path.join(inbox, "ready-to-build"))),
        "needs-shaping": len(_list_md(os.path.join(inbox, "needs-shaping"))),
        "blocked-on-dependency": len(_list_md(os.path.join(inbox, "blocked-on-dependency"))),
    }
    return {"features": features, "readiness": readiness,
            "n_branches": len(all_local), "n_merged": len(merged)}


_VITALITY_RE = re.compile(
    r"<!--\s*vitality:\s*"
    r"absorbed=(?P<absorbed>\d+)\s+"
    r"passes=(?P<passes>\d+)\s+"
    r"last=(?P<last>\d{4}-\d{2}-\d{2})\s+"
    r"pending=(?P<pending>\d+)\s*-->",
    re.IGNORECASE,
)


def _parse_vitality(jam_dir):
    """Parse the ADR-089 D5 vitality header from a jam's README.md (fallback index.md).

    Returns a dict {absorbed, passes, last, pending} or None when absent/malformed
    (tolerant — a legacy jam with no header renders as "—")."""
    for fname in ("README.md", "index.md"):
        p = os.path.join(jam_dir, fname)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                head = f.read(4000)
        except OSError:
            continue
        m = _VITALITY_RE.search(head)
        if m:
            return {
                "absorbed": int(m.group("absorbed")),
                "passes": int(m.group("passes")),
                "last": m.group("last"),
                "pending": int(m.group("pending")),
            }
    return None


def collect_jams(root):
    """Return per-jam dicts {slug, name, vitality} for each step-2 jam folder."""
    planning = os.path.join(root, "docs/step-2-planning")
    if not os.path.isdir(planning):
        return []
    out = []
    for d in sorted(os.listdir(planning)):
        jam_dir = os.path.join(planning, d)
        if not (d.startswith("jam-") and os.path.isdir(jam_dir)):
            continue
        out.append({
            "name": d,
            "slug": d[4:],
            "vitality": _parse_vitality(jam_dir),
        })
    return out


def collect_active_runs(root):
    """Run folders under step-5-pipeline/<date>/ (excludes PENDING)."""
    pipeline = os.path.join(root, "docs/step-5-pipeline")
    runs = []
    if os.path.isdir(pipeline):
        for date in sorted(os.listdir(pipeline)):
            dd = os.path.join(pipeline, date)
            if date == "PENDING" or not os.path.isdir(dd):
                continue
            if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
                continue
            for run in sorted(os.listdir(dd)):
                if os.path.isdir(os.path.join(dd, run)):
                    runs.append(f"{date}/{run}")
    return runs


def collect_pending_handoffs(root):
    """PENDING handoffs NOT yet executed (no COMPLETE-/RESULT-/SUPERSEDED- prefix,
    no EXECUTED/COMPLETE status line)."""
    pending = os.path.join(root, "docs/step-5-pipeline/PENDING")
    out = []
    if not os.path.isdir(pending):
        return out
    for f in sorted(os.listdir(pending)):
        if not f.endswith(".md") or f == "README.md":
            continue
        if f.startswith(("COMPLETE-", "RESULT-", "SUPERSEDED-")):
            continue
        p = os.path.join(pending, f)
        executed = False
        try:
            with open(p, encoding="utf-8") as fh:
                head = fh.read(2000)
            if re.search(r"^\*\*Status:\*\*.*(EXECUTED|COMPLETE|DONE|SHIPPED)",
                         head, re.MULTILINE | re.IGNORECASE):
                executed = True
        except OSError:
            pass
        if not executed:
            out.append(f)
    return out


def collect_operator_answer_needed(root):
    """[OPERATOR ANSWER NEEDED] markers across step-3 and step-4 (best-effort grep)."""
    hits = []
    for sub in ("docs/step-3-specs", "docs/step-5-pipeline"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        try:
            out = subprocess.run(
                ["grep", "-rlI", "OPERATOR ANSWER NEEDED", d],
                capture_output=True, text=True, check=False,
            )
            for line in out.stdout.splitlines():
                if line.strip():
                    hits.append(os.path.relpath(line.strip(), root))
        except Exception:
            pass
    return sorted(set(hits))


def collect_done_this_week(root):
    """Run folders moved to step-6-done within the last 7 days (by mtime/git)."""
    done = os.path.join(root, "docs/step-6-done")
    runs = []
    cutoff = datetime.datetime.now().timestamp() - 7 * 86400
    if os.path.isdir(done):
        for date in sorted(os.listdir(done)):
            dd = os.path.join(done, date)
            if not os.path.isdir(dd) or not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
                continue
            for run in sorted(os.listdir(dd)):
                rp = os.path.join(dd, run)
                if os.path.isdir(rp):
                    try:
                        if os.path.getmtime(rp) >= cutoff:
                            runs.append(f"{date}/{run}")
                    except OSError:
                        pass
    return runs


def _followup_delta_count(path):
    """Parse a delta count out of a FOLLOWUP stub (the stub records `delta count`)."""
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read(4000)
        m = re.search(r"(\d+)\s+delta", txt, re.IGNORECASE)
        if m:
            return int(m.group(1))
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------


def render(root, today):
    backlog = collect_backlog(root)
    backlog_shelf = collect_backlog_shelf(root)
    parked = collect_parked(root)
    chores = collect_chores(root)
    specs = collect_specs(root)
    jams = collect_jams(root)
    active = collect_active_runs(root)
    pending = collect_pending_handoffs(root)
    answer_needed = collect_operator_answer_needed(root)
    done_week = collect_done_this_week(root)

    spec_deltas_total = sum(s["deltas"] for s in specs)

    o = []
    o.append("# docs/ — operator dashboard (generated)\n\n")
    o.append(
        "> **Generated by `core/scripts/docs-index.py`** (ADR-087 D5). Disposable — "
        "regenerate anytime: `python3 core/scripts/docs-index.py`. The on-disk folders are "
        "the source of truth; **location is status**. Runs at `/sweep` + close-out time.\n\n"
    )

    # --- Per-stage counts ---
    o.append("## Stage counts\n\n")
    o.append("| Stage | Count | Detail |\n")
    o.append("|---|---:|---|\n")
    o.append(
        f"| step-1-ideas | {len(backlog['ideas']) + len(backlog['defers']) + len(backlog['followups'])} "
        f"| ideas {len(backlog['ideas'])} · DEFER {len(backlog['defers'])} · FOLLOWUP {len(backlog['followups'])} "
        f"· oldest {backlog['oldest']}d ({backlog['older_30']} >30d) |\n"
    )
    o.append(f"| step-2-planning (jams) | {len(jams)} | {', '.join(j['slug'] for j in jams) if jams else '—'} |\n")
    o.append(
        f"| step-3-specs | {len(specs)} | {spec_deltas_total} pending delta(s) across specs |\n"
    )
    o.append(f"| step-5-pipeline (active runs) | {len(active)} | {', '.join(active) if active else '—'} |\n")
    o.append(
        f"| backlog (we're doing this, just not now) | {len(backlog_shelf['items'])} "
        f"| {'shelf present' if backlog_shelf['present'] else 'no shelf yet'} |\n"
    )
    o.append(f"| parked (shelved, maybe never) | {len(parked['items'])} | {'shelf present' if parked['present'] else 'no shelf yet'} |\n")
    o.append(
        f"| chores (ready to execute — ADR-090) | {len(chores['items'])} "
        f"| {', '.join(i['name'] for i in chores['items']) if chores['items'] else ('lane present' if chores['present'] else 'no lane yet')} |\n"
    )
    o.append(f"| done (last 7d) | {len(done_week)} | {', '.join(done_week) if done_week else '—'} |\n")
    o.append("\n")

    # --- Waiting on you ---
    waiting_n = len(pending) + len(answer_needed) + len(backlog["followups"])
    o.append(f"## Waiting on you ({waiting_n})\n\n")
    if not waiting_n:
        o.append("_Nothing is blocked on an operator decision._\n\n")
    else:
        if pending:
            o.append("**Unexecuted PENDING handoffs:**\n\n")
            for f in pending:
                o.append(f"- `{f}`\n")
            o.append("\n")
        if backlog["followups"]:
            o.append("**Follow-up stubs (deltas against locked specs — ripeness):**\n\n")
            for f in backlog["followups"]:
                n = _followup_delta_count(f)
                cnt = f" — {n} delta(s)" if n is not None else ""
                o.append(f"- `{os.path.basename(f)}`{cnt}\n")
            o.append("\n")
        if answer_needed:
            o.append("**`[OPERATOR ANSWER NEEDED]` markers:**\n\n")
            for h in answer_needed:
                o.append(f"- `{h}`\n")
            o.append("\n")
    if backlog["oldest"] > 0:
        o.append(f"_Oldest backlog item: {backlog['oldest']} days._\n\n")

    # --- Parked shelf ---
    o.append(f"## Parked shelf ({len(parked['items'])})\n\n")
    if not parked["items"]:
        o.append("_Nothing shelved._ " + ("(`docs/parked/` not yet created.)\n\n"
                                           if not parked["present"] else "\n\n"))
    else:
        o.append("| Item | Age | Reason (first line) |\n")
        o.append("|---|---:|---|\n")
        for it in parked["items"]:
            reason = (it["reason"] or "—").replace("|", "\\|")
            o.append(f"| `{it['name']}` | {it['age']}d | {reason} |\n")
        o.append("\n")

    # --- Plan vitality (ADR-089 D5) — per step-2 jam ---
    if jams:
        o.append("## Plan vitality (jams)\n\n")
        o.append("| Jam | Absorbed | Passes | Last reconverged | Pending |\n")
        o.append("|---|---:|---:|---|---:|\n")
        for j in jams:
            v = j["vitality"]
            if v is None:
                o.append(f"| `{j['slug']}` | — | — | — | — |\n")
            else:
                o.append(
                    f"| `{j['slug']}` | {v['absorbed']} | {v['passes']} "
                    f"| {v['last']} | {v['pending']} |\n"
                )
        o.append("\n")

    # --- Spec delta ripeness ---
    if specs:
        o.append("## Spec delta pools (ripeness)\n\n")
        o.append("| Spec | Pending deltas |\n")
        o.append("|---|---:|\n")
        for s in sorted(specs, key=lambda x: -x["deltas"]):
            o.append(f"| `{s['slug']}` | {s['deltas']} |\n")
        o.append("\n")

    # --- Pre-migration note (only when legacy paths still present) ---
    if os.path.basename(backlog["dir"]) != "step-1-ideas" or backlog["legacy_deferrals_pending"]:
        o.append(
            "> **Pre-migration tree detected.** The inbox is reading the legacy "
            f"`{os.path.relpath(backlog['dir'], root)}/`"
            + (f" + {backlog['legacy_deferrals_pending']} `docs/deferrals/OPEN-*` not yet folded in"
               if backlog["legacy_deferrals_pending"] else "")
            + ". Run `bash core/scripts/migrate-doc-lifecycle.sh`, then "
            "`git mv docs/step-1-backlog docs/step-1-ideas` (ADR-089 rename), to reach the current shape.\n\n"
        )

    o.append(
        f"---\n*Generated {today} by docs-index.py. "
        "Regenerate: `python3 core/scripts/docs-index.py`.*\n"
    )
    return "".join(o)


def render_build_status(root, today):
    """Render docs/BUILD-STATUS.md — the main-resident built-vs-unmerged roster (ADR-109 W3).

    RENDERED, never authored: every line reproducible from launch-manifest features[] + git branch
    state + inbox readiness buckets. Opens with a generated-by header mirroring render() L368-373; a
    second render is byte-identical modulo the date stamp (the --check round-trip reuses main()'s
    date-normalization regex)."""
    bs = collect_build_status(root)
    feats = bs["features"]
    built_unmerged = [f for f in feats if f["status"] == "done" and not f["merged"]]
    merged = [f for f in feats if f["merged"]]
    to_build = [f for f in feats if f["status"] in ("queued", "running", "blocked", "failed")]

    o = []
    o.append("# docs/BUILD-STATUS.md — built-vs-unmerged roster (generated)\n\n")
    o.append(
        "> **Generated by `core/scripts/docs-index.py`** (ADR-109 W3). RENDERED, never authored — "
        "every line is reproducible from `launch-manifest.py` `features[]` (status+branch) + git branch "
        "state + the inbox readiness buckets. Disposable; regenerate anytime: "
        "`python3 core/scripts/docs-index.py`. The on-disk folders + manifest are the source of truth; "
        "**location is status**.\n\n"
    )

    o.append("## Built-but-unmerged (feature work on a branch, not yet on main)\n\n")
    if not built_unmerged:
        o.append("_Nothing built-but-unmerged (no fleet feature is `done` on an unmerged branch)._\n\n")
    else:
        o.append("| Feature | Fleet | Status | Branch |\n")
        o.append("|---|---|---|---|\n")
        for f in built_unmerged:
            o.append(f"| `{f['label']}` | `{f['fleet']}` | {f['status']} | `{f['branch']}` |\n")
        o.append("\n")

    o.append("## Still-to-build (queued / running / blocked / failed)\n\n")
    if not to_build:
        o.append("_Nothing queued or in flight in any fleet manifest._\n\n")
    else:
        o.append("| Feature | Fleet | Status | Branch |\n")
        o.append("|---|---|---|---|\n")
        for f in to_build:
            o.append(f"| `{f['label']}` | `{f['fleet']}` | {f['status']} | `{f['branch']}` |\n")
        o.append("\n")

    o.append("## Merged (landed on main)\n\n")
    if not merged:
        o.append("_No fleet feature has a branch merged into main._\n\n")
    else:
        o.append("| Feature | Fleet | Status | Branch |\n")
        o.append("|---|---|---|---|\n")
        for f in merged:
            o.append(f"| `{f['label']}` | `{f['fleet']}` | {f['status']} | `{f['branch']}` |\n")
        o.append("\n")

    # Inbox readiness — EXTENDS the roster (not a parallel bucket tree).
    r = bs["readiness"]
    o.append("## Inbox readiness (step-1-ideas buckets)\n\n")
    o.append("| Bucket | Count |\n")
    o.append("|---|---:|\n")
    o.append(f"| ready-to-build | {r['ready-to-build']} |\n")
    o.append(f"| needs-shaping | {r['needs-shaping']} |\n")
    o.append(f"| blocked-on-dependency | {r['blocked-on-dependency']} |\n")
    o.append("\n")

    o.append(
        f"_Branch state: {bs['n_branches']} local branch(es), {bs['n_merged']} merged into main._\n\n"
    )
    o.append(
        f"---\n*Generated {today} by docs-index.py. "
        "Regenerate: `python3 core/scripts/docs-index.py`.*\n"
    )
    return "".join(o)


def main():
    ap = argparse.ArgumentParser(
        description="Regenerate the operator dashboard docs/INDEX.md (ADR-087 D5).",
    )
    ap.add_argument("--root", default=None, help="repo root (default: auto-detect)")
    ap.add_argument("--print", dest="to_stdout", action="store_true", help="print, don't write")
    ap.add_argument("--check", action="store_true", help="exit 1 if INDEX.md is stale; write nothing")
    args = ap.parse_args()

    root = _repo_root(args.root)
    if not os.path.isdir(os.path.join(root, "docs")):
        sys.stderr.write(f"docs-index: no docs/ under {root}\n")
        sys.exit(2)

    today = datetime.date.today().isoformat()
    rendered = render(root, today)
    index_path = os.path.join(root, "docs", "INDEX.md")
    # ADR-109 W3: BUILD-STATUS.md is a SECOND writer on the SAME run that writes INDEX.md.
    build_status = render_build_status(root, today)
    build_status_path = os.path.join(root, "docs", "BUILD-STATUS.md")

    norm = lambda s: re.sub(r"Generated \d{4}-\d{2}-\d{2}", "Generated <date>", s)

    if args.check:
        stale = []
        for path, fresh in ((index_path, rendered), (build_status_path, build_status)):
            existing = ""
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    existing = f.read()
            if norm(existing) != norm(fresh):
                stale.append(os.path.relpath(path, root))
        if stale:
            sys.stderr.write(
                f"docs-index: stale ({', '.join(stale)}) — run `python3 core/scripts/docs-index.py`.\n")
            sys.exit(1)
        print("docs-index: INDEX.md and BUILD-STATUS.md are current.")
        return

    if args.to_stdout:
        sys.stdout.write(rendered)
        sys.stdout.write("\n")
        sys.stdout.write(build_status)
        return

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(rendered)
    with open(build_status_path, "w", encoding="utf-8") as f:
        f.write(build_status)
    print(f"docs-index: wrote {index_path} and {build_status_path}.")


if __name__ == "__main__":
    main()
