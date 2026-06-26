#!/usr/bin/env python3
"""closeout-run.py — the doc-lifecycle close-out VERB (ADR-087 D2.3).

Every batch/run close-out performs its MOVE: a completed run folder moves to
`docs/step-6-done/<date>/<same-name>/`, an executed handoff moves to
`docs/step-6-done/handoffs/`. This makes the MOVE part of the run contract, not
operator memory — and ends by rendering the operator's "waiting-on-you" queue so
every close-out surfaces what is still pending.

Extends ADR-066 §5e (the merge-orchestrator post-merge MOVE) to ALL close-outs,
including bypass-mode batches. Same tolerances: idempotent (already-moved -> no-op
note), missing-source-tolerant (WARN + continue). The script STAGES only — `git mv`
then leaves it for the operator/orchestrator to commit. It NEVER commits, NEVER pushes.

Scope gate (ADR-103 W3 — the OUT bookend). Before the MOVE, the run's decided atoms
(the thin manifest's tickets[]) are set-diffed against what shipped (ticket status).
Any unaccounted atom (status != complete) is REFLUXED into docs/step-1-ideas/from-<run-slug>/
as a dossier stub for triage, and the MOVE is HELD (the run stays visibly in step-5-pipeline)
unless --force-partial. Reflux is unconditional (the atom is never lost); the hold is the
escapable part. A run cannot wrap clean while leaving decided scope on the floor. Deterministic
— the manifest IS the decided-atom set, status IS the shipped signal; no LLM judgement. Runs
without a manifest/tickets[] (nimble, single-chain) skip the gate naturally.

Usage:
  python3 core/scripts/closeout-run.py <run_folder> [--handoff <handoff_path>] [--session <id>] [--dry-run]
                                       [--force-partial] [--skip-scope-check]
  python3 core/scripts/closeout-run.py --queue-only           # just render the waiting-on-you queue
  python3 core/scripts/closeout-run.py --help

  <run_folder>        a run folder under docs/step-5-pipeline/<date>/<name> (or already-moved
                      under step-6-done — idempotent no-op).
  --handoff PATH      an executed handoff to move to step-6-done/handoffs/ (optional).
  --dry-run           print the plan, mutate nothing.
  --queue-only        skip the MOVE; only print the operator queue (used by /sweep + dashboards).
  --force-partial     move the run even with unaccounted atoms (still refluxed for triage).
  --skip-scope-check  bypass the OUT-bookend scope gate entirely.

Contract:
  - STAGES (git mv + git add for reflux stubs) only — never commits, never pushes.
  - Idempotent: a run folder already under step-6-done is a no-op; reflux stubs are never overwritten.
  - Missing-source tolerant: an absent run folder/handoff is a WARN, not an error (ADR-066 §5e).
  - Scope gate fail-open on READ: a malformed/absent manifest degrades to a clean skip (the only
    gating is the escapable move-hold; a broken manifest never bricks a wrap).
  - Exits 3 when the scope gate HELDS the move (the run is not done); 0 otherwise.
  - Activation surface (ADR-103 W4): before the MOVE, a NON-BLOCKING advisory check flags any
    wireable file this run built (core/scripts|hooks) that nothing on a live path calls
    (BUILT_NOT_ACTIVATED). Advisory only — it never holds the move; prints only when something
    is flagged. Best-effort (a failure never affects close-out). Skipped with --skip-scope-check.
  - Always ends by printing the waiting-on-you queue (FOLLOWUP stubs + delta counts,
    unexecuted PENDING handoffs, parked/ items).
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys


def _repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=False,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _rel(root, p):
    try:
        return os.path.relpath(p, root)
    except ValueError:
        return p


def _git_mv(root, src, dst, dry):
    """Stage a move src -> dst. Returns one of moved/skipped-exists/missing."""
    if not os.path.exists(src):
        # Idempotency: destination already there means the move already happened.
        if os.path.exists(dst):
            print(f"NOTE: already moved: {_rel(root, dst)} (src absent)")
            return "skipped-exists"
        print(f"WARN: missing source (mv): {_rel(root, src)}")
        return "missing"
    if os.path.exists(dst):
        print(f"WARN: destination exists, not overwriting: {_rel(root, dst)} (src left in place)")
        return "skipped-exists"
    print(f"MOVE: {_rel(root, src)} -> {_rel(root, dst)}")
    if not dry:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        r = subprocess.run(["git", "mv", src, dst], cwd=root, capture_output=True, text=True)
        if r.returncode != 0:
            # untracked? fall back to a plain mv + git add.
            print(f"WARN: git mv failed ({r.stderr.strip()}), using plain mv")
            os.rename(src, dst)
            subprocess.run(["git", "add", dst], cwd=root, capture_output=True, text=True)
    return "moved"


# Stage roots a prune must never walk past (the move never empties a stage root itself).
_STAGE_ROOTS = ("step-5-pipeline", "step-6-done", "step-3-specs")


def _prune_empty_parents(root, src, dry):
    """After a `git mv` empties a SOURCE-side parent dir, git leaves an untracked husk
    (git does not track empty dirs). Walk up from src's parent removing now-empty dirs,
    but NEVER past a stage root (step-5-pipeline/step-6-done/step-3-specs) or repo-root,
    realpath-bounded under repo_root, only genuinely-empty dirs, never recursive-delete,
    never touch the destination (AC-004 / ADR-114 D1).

    src is the (now-absent) source path that was just moved. We prune its emptied parents.
    """
    repo_real = os.path.realpath(root)
    cur = os.path.realpath(os.path.dirname(os.path.abspath(src)))
    while True:
        # Bound: stay strictly under repo_root; never the repo-root itself.
        if not (cur.startswith(repo_real + os.sep)):
            return
        base = os.path.basename(cur)
        # Never remove a stage root — and never walk above it.
        if base in _STAGE_ROOTS:
            return
        if not os.path.isdir(cur):
            return
        # Only prune a GENUINELY-empty dir (never recursive-delete).
        try:
            if os.listdir(cur):
                return
        except OSError:
            return
        print(f"PRUNE: removing emptied parent dir: {_rel(root, cur)}")
        if not dry:
            try:
                os.rmdir(cur)
            except OSError as e:
                print(f"WARN: could not rmdir emptied parent {_rel(root, cur)}: {e}")
                return
        parent = os.path.dirname(cur)
        if parent == cur:
            return
        cur = parent


def _measure_run(root, run_folder, session, dry):
    """Best-effort: fire measure-run.sh --metrics so close-out appends ONE per-run
    measurement line to docs/step-3-specs/_metrics.jsonl (W1M-T1 / ADR-100).

    REUSE-ONLY seam: measure-run.sh owns the cache/token extraction (the REAL keys
    cache_creation_input_tokens / cache_read_input_tokens → subagent_cache_*_tokens)
    and the single-line O_APPEND. We add NO parsing here and pass no per_agent
    breakdown flag (exactly ONE {"kind":"measurement"} line per RUN keeps
    _metrics.jsonl human-readable and the append atomic ≤ PIPE_BUF). A measurement
    failure NEVER fails the MOVE —
    mirrors _git_mv's tolerance discipline (lines 76–82).

    Session resolution: pass --session <id> when known; otherwise fall back to
    --latest <project-substr> (the run folder's repo basename). Both are best-effort.
    """
    measure = os.path.join(root, "core/scripts/measure-run.sh")
    if not os.path.exists(measure):
        print(f"WARN: measure-run.sh not found, skipping measurement: {_rel(root, measure)}")
        return
    task = os.path.basename(run_folder.rstrip("/")) or "closeout"
    if session:
        sel = ["--session", session]
    else:
        # --latest project-substring fallback: match on the repo's basename so the
        # newest transcript for THIS project is picked when the session id is unknown.
        sel = ["--latest", os.path.basename(root)]
    # CR-001 fix: measure-run.sh's `--metrics` REQUIRES a path argument
    # (`--metrics) METRICS="${2:-}"; shift 2`). The earlier `--metrics --task <slug>`
    # form made --metrics swallow `--task`, dropping the slug to "unknown arg" → exit 1
    # → the per-run line was NEVER appended (silently, since this is best-effort). Pass
    # the explicit target path (also measure-run.sh's default, stated for unambiguity).
    metrics_path = os.path.join(root, "docs/step-3-specs/_metrics.jsonl")
    cmd = ["bash", measure, *sel, "--metrics", metrics_path, "--task", task]
    print(f"MEASURE: {' '.join(['measure-run.sh', *sel, '--metrics', _rel(root, metrics_path), '--task', task])} (best-effort)")
    if dry:
        return
    try:
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"WARN: measurement shell-out failed (close-out unaffected): "
                  f"{(r.stderr or '').strip().splitlines()[-1] if r.stderr else 'non-zero exit'}")
        else:
            print("MEASURE: appended one per-run measurement line to _metrics.jsonl")
    except Exception as e:
        print(f"WARN: measurement shell-out raised (close-out unaffected): {e}")


def _append_close_line(run_folder, dry):
    """Append a CLOSED line to the run's run-log.md (creating it if absent)."""
    rl = os.path.join(run_folder, "run-log.md")
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"\nCLOSED: {ts} — moved to step-6-done\n"
    print(f"APPEND: {os.path.basename(rl)} <- 'CLOSED: {ts} — moved to step-6-done'")
    if dry:
        return
    try:
        # Idempotency: don't double-append if already closed.
        if os.path.exists(rl):
            with open(rl, encoding="utf-8") as f:
                if "CLOSED:" in f.read():
                    print("NOTE: run-log already has a CLOSED line — not re-appending")
                    return
        with open(rl, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError as e:
        print(f"WARN: could not append close line: {e}")


# ---------------------------------------------------------------------------
# Scope gate (ADR-103 W3 — the OUT bookend)
# ---------------------------------------------------------------------------
# A run must not wrap clean while leaving decided scope on the floor. Before the
# MOVE, set-diff the run's decided atoms (the thin manifest's tickets[]) against
# what shipped (ticket status). Any unaccounted atom (status != complete) is
# REFLUXED into the ideas inbox at docs/step-1-ideas/from-<run-slug>/ as a dossier
# stub for operator triage, and the MOVE is HELD (the run stays visibly in
# step-5-pipeline) unless --force-partial. Reflux is unconditional — the atom is
# never lost; the hold is the escapable part. This is deterministic (no LLM): the
# manifest IS the decided-atom set, status IS the shipped signal.


def _find_manifest(run_folder):
    """The run's thin manifest — manifest.json (canonical) or run-manifest.json (legacy)."""
    for name in ("manifest.json", "run-manifest.json"):
        p = os.path.join(run_folder, name)
        if os.path.isfile(p):
            return p
    return None


def _is_deferral_class(ticket, safe_key):
    """Deferral-class detection is prefix-OR-schema (W2IO-T17 / AC-021): a ticket is
    deferral-class if its key already carries the `DEFER-` prefix (so a prefix-less stub
    already on disk that was hand-renamed, or a key that arrived prefixed, is still
    recognized) OR its schema marks it a deferral (kind/class/source-pointer fields).
    Prefix OR schema — neither alone is required."""
    # Prefix arm: the key (or its safe form) already begins with DEFER-.
    if str(ticket.get("key", "")).upper().startswith("DEFER-") or safe_key.upper().startswith("DEFER-"):
        return True
    # Schema arm: an explicit kind/class field, or a deferral source pointer.
    kind = str(ticket.get("kind", "") or ticket.get("class", "")).lower()
    if "defer" in kind:
        return True
    if ticket.get("deferred") or ticket.get("defer"):
        return True
    return False


def _reflux_stub(root, run_slug, ticket, dry):
    """Write a dossier-grade reflux stub for one unaccounted ticket. Idempotent (never
    overwrites an existing triage file). Returns the rel path written/already-present, or None.

    W2IO-T17 / AC-021: deferral-class atoms get the `DEFER-` prefix on the emitted filename
    (consistent with /idea + /defer capture-at-bucket conventions, ADR-103 W3 / ADR-111). The
    prefix is KEPT, not merely suggested in the body; detection is prefix-OR-schema so a
    prefix-less deferral file already on disk is still recognized as deferral-class."""
    from_dir = os.path.join(root, "docs/step-1-ideas", f"from-{run_slug}")
    key = ticket.get("key", "UNKNOWN")
    safe_key = re.sub(r"[^A-Za-z0-9._-]", "-", str(key))
    deferral = _is_deferral_class(ticket, safe_key)
    # Emit the DEFER- prefix for deferral-class atoms; KEEP it (do not strip it back out).
    # Avoid a doubled prefix when the key already carries it.
    if deferral and not safe_key.upper().startswith("DEFER-"):
        fname = f"DEFER-{safe_key}.md"
    else:
        fname = f"{safe_key}.md"
    dst = os.path.join(from_dir, fname)
    # Idempotency, prefix-OR-schema aware: an existing stub for this atom under EITHER the
    # prefixed or prefix-less name counts as already-present — never overwrite, never duplicate.
    alt = os.path.join(from_dir, f"{safe_key}.md" if fname.startswith("DEFER-") else f"DEFER-{safe_key}.md")
    for existing in (dst, alt):
        if os.path.exists(existing):
            print(f"NOTE: reflux stub already present (not overwriting): {_rel(root, existing)}")
            return _rel(root, existing)
    status = ticket.get("status", "unknown")
    planned = ticket.get("planned_files", []) or []
    accept = ticket.get("acceptance", []) or []   # W1 atom chain rides into the reflux dossier
    note = ticket.get("note") or "(none)"
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = [
        f"# {key} — unaccounted at close-out (refluxed for triage)",
        "",
        f"- **Source run:** `{run_slug}`",
        f"- **Status at wrap:** `{status}` (NOT complete — declared but unshipped)",
        f"- **Refluxed:** {ts} by `closeout-run.py` (ADR-103 W3 OUT bookend)",
        "",
        "## Why this is here",
        "",
        "This ticket was a decided atom in its run's thin manifest but did not reach"
        " `complete` before the run closed. The OUT bookend refluxed it into the ideas"
        " inbox so it is **triageable, not lost** — the exact silent-drop ADR-103 fixes.",
        "",
        "## Decided scope (carried forward)",
        "",
        f"- **Planned files:** {', '.join(f'`{p}`' for p in planned) if planned else '(none recorded)'}",
        f"- **Acceptance atoms:** {', '.join(f'`{a}`' for a in accept) if accept else '(none recorded)'}",
        f"- **Note at wrap:** {note}",
        "",
        "## Triage (operator)",
        "",
        "- **Build it** — re-open as a wave/ticket (the planned files + acceptance above are the starting scope).",
        "- **Defer it** — rename to `DEFER-…` with a target home if it is genuinely not-now.",
        "- **Drop it** — delete this file if the capability is obsolete (a deliberate, recorded decision).",
        "",
    ]
    print(f"REFLUX: {_rel(root, dst)}  (atom '{key}', status={status})")
    if dry:
        return _rel(root, dst)
    try:
        os.makedirs(from_dir, exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            f.write("\n".join(body))
        subprocess.run(["git", "add", dst], cwd=root, capture_output=True, text=True)
    except OSError as e:
        print(f"WARN: could not write reflux stub for {key}: {e}")
        return None
    return _rel(root, dst)


def verify_scope(root, run_folder, dry):
    """Set-diff decided atoms (manifest tickets[]) vs shipped (status==complete).

    Returns (unaccounted, refluxed_paths). An empty `unaccounted` means clean (or no
    tickets[] to check — nimble/no-manifest runs skip, like the W2 no-jam case). Never
    raises: a malformed/absent manifest degrades to a clean skip with a NOTE (fail-open
    on the READ so a broken manifest can't brick a wrap — the move-hold below is the
    only gating, and it's escapable)."""
    man = _find_manifest(run_folder)
    if not man:
        print("NOTE: scope gate — no thin manifest in run folder (nimble/no-ticket run); skipping.")
        return [], []
    try:
        with open(man, encoding="utf-8") as f:
            m = json.load(f)
    except (OSError, ValueError) as e:
        print(f"WARN: scope gate — could not read manifest ({e}); skipping scope check.")
        return [], []
    tickets = m.get("tickets")
    if not isinstance(tickets, list) or not tickets:
        print("NOTE: scope gate — manifest has no tickets[] (nimble/single-chain run); skipping.")
        return [], []
    unaccounted = [t for t in tickets if isinstance(t, dict) and t.get("status") != "complete"]
    if not unaccounted:
        print(f"SCOPE OK: all {len(tickets)} decided atom(s) shipped (status=complete).")
        return [], []
    run_slug = os.path.basename(run_folder.rstrip("/"))
    print(f"SCOPE GAP: {len(unaccounted)}/{len(tickets)} decided atom(s) did NOT reach complete:")
    refluxed = []
    for t in unaccounted:
        print(f"  - {t.get('key', '?')} (status={t.get('status', '?')})")
        p = _reflux_stub(root, run_slug, t, dry)
        if p:
            refluxed.append(p)
    return unaccounted, refluxed


def _activation_addendum(root, run_folder):
    """Best-effort: run activation-check.py and echo its BUILT_NOT_ACTIVATED surface as a
    NON-BLOCKING wrap-report addendum (ADR-103 W4). Read-only (git grep) — runs even in
    dry-run, and a failure NEVER affects the close-out (mirrors _measure_run's tolerance)."""
    script = os.path.join(root, "core/scripts/activation-check.py")
    if not os.path.exists(script):
        return
    try:
        r = subprocess.run([sys.executable, script, "check", run_folder],
                           cwd=root, capture_output=True, text=True)
        out = (r.stdout or "").strip()
        if out and "ACTIVATION SURFACE" in out:
            # Only surface when something is actually flagged — a clean/NA result stays quiet.
            print("")
            print("--- Activation surface (ADR-103 W4 — advisory, non-blocking) ---")
            print(out)
    except Exception as e:
        print(f"WARN: activation check raised (close-out unaffected): {e}")


def closeout(root, run_folder, handoff, dry, session=None, force_partial=False, skip_scope=False):
    run_folder = os.path.abspath(run_folder)
    pipeline = os.path.join(root, "docs/step-5-pipeline")
    done = os.path.join(root, "docs/step-6-done")

    # --- Scope gate (ADR-103 W3 OUT bookend) — BEFORE the MOVE -----------------
    # Only meaningful for an in-pipeline run with a manifest; an already-moved or
    # absent run folder skips naturally (no manifest to read). Reflux is unconditional;
    # the move-hold is the escapable part (--force-partial). --skip-scope-check bypasses.
    scope_held = False
    if not skip_scope and os.path.isdir(run_folder) \
            and not run_folder.startswith(os.path.abspath(done) + os.sep):
        unaccounted, refluxed = verify_scope(root, run_folder, dry)
        if unaccounted and not force_partial:
            scope_held = True
            print("")
            print(f"SCOPE HOLD: run NOT moved — {len(unaccounted)} unaccounted atom(s) refluxed to "
                  f"docs/step-1-ideas/from-{os.path.basename(run_folder.rstrip('/'))}/ for triage.")
            print("  The run stays in step-5-pipeline (visibly incomplete). To wrap anyway: re-run with "
                  "--force-partial. To finish the work: complete the tickets, then re-run close-out.")
            render_queue(root)
            return {"scope_held": True, "unaccounted": len(unaccounted), "refluxed": refluxed}
        if unaccounted and force_partial:
            print(f"SCOPE FORCED: --force-partial — moving despite {len(unaccounted)} unaccounted atom(s) "
                  f"(refluxed to from-{os.path.basename(run_folder.rstrip('/'))}/ for triage).")

    # Activation surface (ADR-103 W4) — advisory BUILT_NOT_ACTIVATED check BEFORE the MOVE (reads the
    # in-place manifest). Non-blocking; only prints when something is flagged. Skipped with --skip-scope-check.
    if not skip_scope and os.path.isdir(run_folder) \
            and not run_folder.startswith(os.path.abspath(done) + os.sep):
        _activation_addendum(root, run_folder)

    # Best-effort per-run measurement BEFORE the MOVE (so it reads the run folder
    # in place). A failure here never blocks the MOVE — W1M-T1 / ADR-100.
    if os.path.isdir(run_folder) and not run_folder.startswith(os.path.abspath(done) + os.sep):
        _measure_run(root, run_folder, session, dry)

    # Idempotency: already under step-6-done -> no-op.
    if run_folder.startswith(os.path.abspath(done) + os.sep):
        print(f"NOTE: run folder already under step-6-done — close-out is a no-op: {_rel(root, run_folder)}")
    elif not os.path.isdir(run_folder):
        print(f"WARN: run folder not found (close-out tolerant, continuing): {_rel(root, run_folder)}")
    elif not run_folder.startswith(os.path.abspath(pipeline) + os.sep):
        print(f"WARN: run folder is not under step-5-pipeline/ — moving anyway by name: {_rel(root, run_folder)}")
        # Best-effort: move under done/<basename-parent>/<basename>.
        date_dir = os.path.basename(os.path.dirname(run_folder))
        name = os.path.basename(run_folder)
        _append_close_line(run_folder, dry)
        _git_mv(root, run_folder, os.path.join(done, date_dir, name), dry)
        _prune_empty_parents(root, run_folder, dry)
    else:
        date_dir = os.path.basename(os.path.dirname(run_folder))
        name = os.path.basename(run_folder)
        _append_close_line(run_folder, dry)
        _git_mv(root, run_folder, os.path.join(done, date_dir, name), dry)
        # Prune any now-empty SOURCE-side parent (the emptied <date>/ husk), never past a stage root.
        _prune_empty_parents(root, run_folder, dry)

    # Executed handoff -> step-6-done/handoffs/
    if handoff:
        handoff = os.path.abspath(handoff)
        done_handoffs = os.path.join(done, "handoffs")
        _git_mv(root, handoff, os.path.join(done_handoffs, os.path.basename(handoff)), dry)
    return {"scope_held": False}


# ---------------------------------------------------------------------------
# Waiting-on-you queue (rendered at the end of every close-out)
# ---------------------------------------------------------------------------


def _list_md(d):
    if not os.path.isdir(d):
        return []
    return sorted(
        os.path.join(d, f) for f in os.listdir(d)
        if f.endswith(".md") and f not in ("README.md", "INDEX.md")
        and os.path.isfile(os.path.join(d, f))
    )


def _followup_delta_count(path):
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read(4000)
        m = re.search(r"(\d+)\s+delta", txt, re.IGNORECASE)
        if m:
            return int(m.group(1))
    except OSError:
        pass
    return None


def render_queue(root):
    # FOLLOWUP stubs (prefer step-1-ideas, fall back to legacy step-1-backlog)
    backlog = os.path.join(root, "docs/step-1-ideas")
    if not os.path.isdir(backlog):
        backlog = os.path.join(root, "docs/step-1-backlog")
    followups = [f for f in _list_md(backlog) if os.path.basename(f).startswith("FOLLOWUP-")]

    # Unexecuted PENDING handoffs
    pending = os.path.join(root, "docs/step-5-pipeline/PENDING")
    unexec = []
    if os.path.isdir(pending):
        for f in sorted(os.listdir(pending)):
            if not f.endswith(".md") or f == "README.md":
                continue
            if f.startswith(("COMPLETE-", "RESULT-", "SUPERSEDED-")):
                continue
            try:
                with open(os.path.join(pending, f), encoding="utf-8") as fh:
                    head = fh.read(2000)
                if re.search(r"^\*\*Status:\*\*.*(EXECUTED|COMPLETE|DONE|SHIPPED)",
                             head, re.MULTILINE | re.IGNORECASE):
                    continue
            except OSError:
                pass
            unexec.append(f)

    # parked/ items
    parked = _list_md(os.path.join(root, "docs/parked"))

    print("")
    print("=== Waiting on you (close-out queue) ===")
    if followups:
        print(f"  FOLLOWUP stubs ({len(followups)}):")
        for f in followups:
            n = _followup_delta_count(f)
            cnt = f" — {n} delta(s)" if n is not None else ""
            print(f"    - {os.path.basename(f)}{cnt}")
    if unexec:
        print(f"  Unexecuted PENDING handoffs ({len(unexec)}):")
        for f in unexec:
            print(f"    - {f}")
    if parked:
        print(f"  Parked items ({len(parked)}):")
        for f in parked:
            print(f"    - {os.path.basename(f)}")
    if not (followups or unexec or parked):
        print("  (nothing waiting — clean queue)")
    print("  Regenerate the dashboard: python3 core/scripts/docs-index.py")
    print("CLOSEOUT-RUN: QUEUE rendered "
          f"(followups={len(followups)} pending={len(unexec)} parked={len(parked)})")


def run_closeout(run_folder, *, handoff=None, session=None, dry=False,
                 force_partial=False, skip_scope_check=False, root=None):
    """Auto-callable close-out entrypoint (SHR3-T1 / ADR-100) — the importable core
    `main()` delegates to and `persist-run-artifacts.py` wires on terminal completion.

    Runs the FULL close-out: scope gate (reflux + HELD) → MOVE (`_git_mv` +
    `_prune_empty_parents`) → CLOSED line → waiting-on-you render. Returns the same
    EXIT CODE the CLI surfaces so a caller's exit semantics stay bit-identical:

        0  = moved / clean (or already-moved no-op, or missing-source-tolerant continue)
        3  = HELD by the OUT-bookend scope gate (unaccounted atom refluxed; run not moved)

    The waiting-on-you queue is rendered EXACTLY ONCE: a HELD run renders it inside
    `closeout()` (and returns before the tail render); a clean run renders it here.
    Callers (CLI or persist) must NOT render it again. STAGES only — never commits,
    never pushes (ADR-087); the auto path inherits this verbatim.
    """
    if root is None:
        root = _repo_root()
    result = closeout(root, run_folder, handoff, dry, session=session,
                      force_partial=force_partial, skip_scope=skip_scope_check)
    if result and result.get("scope_held"):
        # The scope gate held the move (ADR-103 W3). render_queue already ran inside
        # closeout(); exit-3 semantics surface the hold — the run is NOT done.
        print("CLOSEOUT-RUN: HELD — scope gate refused a clean wrap (unaccounted atoms). "
              "Triage docs/step-1-ideas/from-<run>/ or re-run with --force-partial.")
        return 3
    if dry:
        print("DRY-RUN complete — nothing changed. Re-run without --dry-run to stage the moves.")
    else:
        print("EXECUTE complete — moves are STAGED (git mv), NOT committed. Review `git status` and commit.")
    render_queue(root)
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Doc-lifecycle close-out verb: MOVE a done run + handoff to step-6-done, "
                    "then render the waiting-on-you queue (ADR-087 D2.3).",
    )
    ap.add_argument("run_folder", nargs="?", help="run folder under docs/step-5-pipeline/<date>/<name>")
    ap.add_argument("--handoff", default=None, help="executed handoff path to move to step-6-done/handoffs/")
    ap.add_argument("--session", default=None,
                    help="orchestrator session id for the per-run measurement (best-effort; "
                         "falls back to measure-run.sh --latest <project> when omitted)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, mutate nothing")
    ap.add_argument("--queue-only", action="store_true", help="skip the MOVE; render only the queue")
    ap.add_argument("--force-partial", action="store_true",
                    help="ADR-103 W3: move the run even with unaccounted atoms (they are still refluxed to "
                         "step-1-ideas/from-<run>/ for triage). The escape hatch for a deliberate partial wrap.")
    ap.add_argument("--skip-scope-check", action="store_true",
                    help="ADR-103 W3: bypass the OUT-bookend scope gate entirely (no set-diff, no reflux).")
    args = ap.parse_args()

    root = _repo_root()

    if args.queue_only:
        render_queue(root)
        return

    if not args.run_folder:
        ap.error("run_folder is required unless --queue-only is given")

    mode = "DRY-RUN" if args.dry_run else "EXECUTE"
    print(f"=== closeout-run.py (ADR-087 D2.3) — MODE: {mode} — root: {root} ===")
    # CLI behavior stays bit-identical: parse args, then delegate to the importable core.
    rc = run_closeout(args.run_folder, handoff=args.handoff, session=args.session,
                      dry=args.dry_run, force_partial=args.force_partial,
                      skip_scope_check=args.skip_scope_check, root=root)
    if rc:
        sys.exit(rc)


if __name__ == "__main__":
    main()
