#!/usr/bin/env python3
"""merge-orchestrate.py — the deterministic merge/landing engine (ADR-071 Part 2).

Scripts the safe-landing flow currently hand-walked in core/skills/merge-orchestrator/SKILL.md.
Makes the deterministic steps automatic and the conflict halt STRUCTURAL — the script
physically cannot auto-resolve a conflict, push, force-anything, or `reset --hard`.

The reconvergence problem (ADR-071) is "many sequentially-built branches must land on main
without conflicts, silent semantic breakage, or lost work." This script handles the
landing flow. It does NOT dispatch agents (that stays orchestrator-side); it emits the
machine-readable signal `AGENT_GATE_PENDING` after a clean merge so the orchestrator can
invoke the Wave-1 batch-gate against the merged state.

Subcommands (each idempotent; each writes state atomically; each prints a parseable
final-line summary):

    scan       --base REF [--run-dir DIR] BRANCH...
        Conflict matrix via `git merge-tree` (textual conflict detection WITHOUT touching
        the working tree). Each branch×base AND branch×branch. Derive a deterministic
        recommended merge order (reds first, then overlapping yellows grouped, greens
        last; stable). Writes {run_dir}/conflict-scan.md when --run-dir is given. NO
        mutation. The `--dry-run` path that replaces the textual half of
        @merge-conflict-scanner.

    preflight  --base REF BRANCH...
        Step-1 hard checks (base tree clean; each branch resolves; base ahead/behind
        origin; upstream-exists per branch). Reports; exits non-zero on any hard failure.
        NO auto-fix.

    init       --base REF --run-dir DIR [--strategy squash|ff] BRANCH...
        Create the run folder + atomic merge-state.json (schema below). Refuses to
        clobber an existing non-empty state file.

    merge-next --run-dir DIR
        Process the next `pending` branch deterministically:
          1. rebase-if-behind onto base. On rebase conflict → `git rebase --abort` to
             leave tree CLEAN → record conflict files → branch `blocked`, top-level
             `halted` → exit non-zero with structured halt payload. NEVER continue,
             NEVER resolve.
          2. squash-merge onto base; capture merge SHA.
          3. run deterministic post-merge checks (typecheck + tests — discovered via the
             same mechanism /post-merge-gate uses). Red → halt (branch stays merged,
             top-level `halted`, halt_reason: post_merge_gate_red); do NOT auto-revert
             (revert is an operator choice — emit the option, don't take it).
          4. green → branch `done`; emit AGENT_GATE_PENDING so the orchestrator/skill
             runs the Wave-1 gate AGENTS (the script does NOT dispatch agents).

    status     --run-dir DIR
        Print next-action / current state (one line per branch).

    resume     --run-dir DIR
        Re-enter the loop per the SKILL's resumption semantics:
          - done/skipped/reverted: skipped.
          - blocked: re-attempted from rebase.
          - pending: processed in order.

STRUCTURAL invariants (cannot be flag-overridden — these are the ADR-071 blast-radius
controls made structural, not behavioral):
    - never `git push` / `--force` / `--force-with-lease` (the script issues no push at all).
    - never `git reset --hard` (uses `git rebase --abort` to leave the tree clean).
    - never auto-resolve a textual or rebase conflict (`--abort` + halt non-zero).
    - squash is the default strategy.
    - ≤6 branches per run (warn-and-refuse above; rules-git.md).
    - state writes are atomic (tmp + os.replace).

State file schema (`{run_dir}/merge-state.json`):
    {
      "schema": "merge-state/1",
      "started_at": "ISO8601Z",
      "base_ref": "main",
      "strategy": "squash",            # squash | ff
      "run_dir": "...",
      "branches": [
        {"name": "feature/foo",
         "status": "pending",          # pending | in_progress | done | reverted | skipped | blocked
         "merge_sha": null,
         "post_gate_verdict": null,    # null | green | red
         "conflict_files": [],         # populated on blocked rebase
         "notes": null}
      ],
      "current_index": -1,
      "halted": false,
      "halt_reason": null,             # null | rebase_conflict | squash_conflict | post_merge_gate_red | refused
      "halt_branch": null,
      "updated_at": "ISO8601Z"
    }

Exit codes:
    0   success / clean step
    1   halted (rebase conflict, red post-merge gate, refused preflight, etc.)
    2   usage / validation error (bad args, missing run-dir, etc.)
"""
import argparse
import datetime
import json
import os
import re
import secrets
import subprocess
import sys

SCHEMA = "merge-state/1"
MAX_BRANCHES = 6
DEFAULT_BASE = "main"
DEFAULT_STRATEGY = "squash"

BRANCH_STATUSES = {"pending", "in_progress", "done", "reverted", "skipped", "blocked"}


# ---------------------------------------------------------------------------
# Small utilities — all stdlib, atomic writes, parseable final line.
# ---------------------------------------------------------------------------

def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _die(msg, code=2):
    sys.stderr.write(f"merge-orchestrate: {msg}\n")
    sys.exit(code)


def _tmp_path(path):
    """Return an unpredictable sibling tmp path for atomic-write helpers (SA-004).

    Uses pid + 16-byte token from `secrets` rather than a fixed `.tmp` suffix so a local
    attacker (same uid, predictable working dir) cannot pre-create / symlink the tmp file.
    The tmp lives in the same directory as `path` so `os.replace` stays atomic (same fs).
    """
    return f"{path}.{os.getpid()}.{secrets.token_hex(8)}.tmp"


def _atomic_write_json(path, obj):
    """Atomic JSON write: tmp + os.replace. Stamps updated_at."""
    obj["updated_at"] = _now()
    tmp = _tmp_path(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def _atomic_write_text(path, text):
    """Atomic text write: tmp + os.replace."""
    tmp = _tmp_path(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def _read_state(run_dir):
    path = os.path.join(run_dir, "merge-state.json")
    if not os.path.isfile(path):
        _die(f"merge-state.json not found at {path}")
    with open(path, encoding="utf-8") as f:
        return json.load(f), path


def _git(args, cwd=None, check=False, capture=True):
    """Run a git command. NEVER shell=True. Returns CompletedProcess."""
    if not isinstance(args, list):
        raise TypeError("_git args must be a list")
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=capture,
        text=True,
        check=check,
    )


def _git_ok(args, cwd=None):
    """True iff git returns 0."""
    return _git(args, cwd=cwd, check=False).returncode == 0


def _git_out(args, cwd=None):
    """Return git stdout (stripped), or '' on failure."""
    r = _git(args, cwd=cwd, check=False)
    return r.stdout.strip() if r.returncode == 0 else ""


# ---------------------------------------------------------------------------
# Structural invariant guards — defensive belt-and-braces.
#
# The script itself NEVER constructs forbidden git verbs; this guard exists so
# any future mistake refuses at runtime. Tests grep the script for these tokens
# to confirm they appear NOWHERE in mutating subprocess invocations.
# ---------------------------------------------------------------------------

# Git flags that can be weaponized into arbitrary code execution. `--exec` (rebase) runs
# a shell command at each rewritten commit. `--upload-pack` / `--receive-pack` (fetch /
# clone / push) substitute a different remote-side program — an attacker-supplied path
# becomes a local exec. We reject these tokens in any git arg position (SA-001 / SA-006).
_RCE_FLAG_TOKENS = ("--exec", "--upload-pack", "--receive-pack")
_RCE_FLAG_PREFIXES = ("--exec=", "--upload-pack=", "--receive-pack=")


def _refuse_forbidden(args):
    """Refuse to invoke a forbidden git verb combination. The script never
    constructs these; this is a defensive last line of defense.

    Scans ALL positions for push/reset --hard (not just args[0]) so a refused verb
    embedded mid-args (e.g. `git -C ... push`) still refuses (SA-006). Also blocks the
    git-RCE flags (`--exec`, `--upload-pack`, `--receive-pack` and their `=value` forms)
    that turn a controlled-ref injection into command execution (SA-001).
    """
    if not args:
        return
    # any 'push' anywhere in args (not just args[0]) — covers `-C path push` shapes.
    if any(a == "push" for a in args):
        _die("refusing forbidden 'git push' — the script never pushes (rules-git, ADR-071)", code=2)
    # 'reset --hard' anywhere in args — `reset` co-occurring with `--hard`.
    if any(a == "reset" for a in args) and any(a == "--hard" for a in args):
        _die("refusing forbidden 'git reset --hard' — use revert (rules-git, ADR-071)", code=2)
    # any --force / --force-with-lease anywhere.
    if any(a in ("--force", "--force-with-lease") for a in args):
        _die(f"refusing forbidden force flag in git args: {args} (rules-git, ADR-071)", code=2)
    # RCE flag tokens (exact match) — anywhere in args.
    if any(a in _RCE_FLAG_TOKENS for a in args):
        _die(f"refusing git RCE flag (token form) in args: {args} (SA-001)", code=2)
    # RCE flag prefixes (--exec=cmd / --upload-pack=path / --receive-pack=path) — anywhere.
    if any(isinstance(a, str) and a.startswith(_RCE_FLAG_PREFIXES) for a in args):
        _die(f"refusing git RCE flag (=value form) in args: {args} (SA-001)", code=2)


def _validate_ref(ref):
    """Validate a user-supplied git ref/branch name. Reject empty refs, leading-`-`
    refs (would be parsed as a flag), and refs that fail `git check-ref-format`.

    This is the ARGV-injection guard for SA-001: branch names and base refs reach
    `git` argv directly, so a `--exec=…` shaped "branch" or a flag-shaped base ref must
    be rejected before any subprocess call. Called at every CLI ref entry point AND
    defensively on every ref read back from state in `_process_one` (SA-005).

    Dies (exit 2) with a clear message on failure; returns the ref unchanged on success.
    """
    if ref is None or not isinstance(ref, str) or not ref:
        _die("invalid ref: empty / non-string", code=2)
    if ref.startswith("-"):
        # Leading-`-` is the argv-injection vector: git parses it as a flag. Reject before
        # check-ref-format (which also rejects it but is less explicit about the threat).
        _die(f"refusing flag-shaped ref (leading '-'): {ref!r} (SA-001)", code=2)
    # NUL byte and newline are blanket-bad in argv.
    if "\x00" in ref or "\n" in ref:
        _die(f"refusing ref containing NUL or newline: {ref!r}", code=2)
    # Defer the rest to git's own validator. `--allow-onelevel` permits single-component
    # branch names (e.g. "main") AND multi-component refs (e.g. "feature/foo"), and
    # rejects the standard bad shapes (".bad", "bad..name", control chars, etc.).
    # (`--branch` is an alternative usage form, not a co-flag — they're mutually exclusive.
    # Per the leading-`-` guard above, flag-shaped refs are already rejected before this
    # call, so the only remaining job is the syntactic refname check.)
    r = subprocess.run(
        ["git", "check-ref-format", "--allow-onelevel", ref],
        capture_output=True, text=True, check=False,
    )
    if r.returncode != 0:
        _die(f"invalid ref (git check-ref-format refused): {ref!r}", code=2)
    return ref


def _validate_refs(refs):
    """Validate a list of refs. Returns the list unchanged on success; dies on the
    first invalid one. Convenience wrapper for the CLI entry points."""
    for r in refs:
        _validate_ref(r)
    return list(refs)


def _guarded_git(args, cwd=None, check=False, capture=True):
    """All write-path git invocations route through this guard."""
    _refuse_forbidden(args)
    return _git(args, cwd=cwd, check=check, capture=capture)


# ---------------------------------------------------------------------------
# scan — conflict matrix via git merge-tree, no mutation.
# ---------------------------------------------------------------------------

def _resolve(ref):
    return _git_out(["rev-parse", "--verify", f"{ref}^{{commit}}"])


def _merge_base(a, b):
    return _git_out(["merge-base", a, b])


def _changed_files(base_sha, branch):
    """Return the set of paths the branch changes vs the merge-base."""
    out = _git_out(["diff", "--name-only", f"{base_sha}..{branch}"])
    return set(out.splitlines()) if out else set()


def _merge_tree_conflict(a, b):
    """Use `git merge-tree --write-tree` (git ≥2.38). Returns (status, conflict_files).

    status ∈ {'clean', 'textual', 'inconclusive'}.
    conflict_files: list of paths with conflict markers (only populated when 'textual').
    """
    base = _merge_base(a, b)
    if not base:
        return ("inconclusive", [])
    # Modern form: exits 0 with tree SHA on clean; non-zero with conflict info on conflict.
    r = subprocess.run(
        ["git", "merge-tree", "--write-tree", "--merge-base", base, a, b],
        capture_output=True, text=True, check=False,
    )
    if r.returncode == 0:
        return ("clean", [])
    # Conflict path. The exit-1 output starts with a tree-SHA line, then "Conflict"
    # / file lines. Be liberal: any non-blank token-tail that looks like a path is
    # captured. Falls back to "textual" with empty file list if nothing parseable.
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    conflict_files = []
    for ln in lines[1:]:
        parts = ln.split()
        cand = parts[-1] if parts else ln.strip()
        if cand and cand not in conflict_files and not cand.startswith("CONFLICT"):
            conflict_files.append(cand)
    return ("textual", conflict_files)


def _scan_matrix(base_ref, branches):
    """Build the conflict matrix. Returns a dict with per-branch + pair info."""
    base_sha = _resolve(base_ref)
    if not base_sha:
        _die(f"base ref does not resolve: {base_ref}", code=2)
    per_branch = []
    unresolved = []
    for b in branches:
        sha = _resolve(b)
        if not sha:
            unresolved.append(b)
            per_branch.append({"name": b, "resolved": False})
            continue
        mb = _merge_base(base_ref, b)
        files = _changed_files(mb, b) if mb else set()
        # ahead/behind vs base. `git rev-list --left-right --count A...B`:
        # left=A-only count, right=B-only count. With A=branch, B=base:
        # left=ahead-of-base, right=behind-base.
        ahead, behind = 0, 0
        rl = _git_out(["rev-list", "--left-right", "--count", f"{b}...{base_ref}"])
        if rl:
            try:
                a_str, b_str = rl.split()
                ahead, behind = int(a_str), int(b_str)
            except (ValueError, IndexError):
                pass
        vs_base_status, vs_base_files = _merge_tree_conflict(base_ref, b)
        per_branch.append({
            "name": b,
            "resolved": True,
            "tip": sha,
            "merge_base": mb,
            "changed_files": sorted(files),
            "ahead": ahead,
            "behind": behind,
            "vs_base": vs_base_status,             # clean | textual | inconclusive
            "vs_base_conflict_files": vs_base_files,
        })

    # Pairwise matrix (only over resolved branches).
    resolved_names = [pb["name"] for pb in per_branch if pb["resolved"]]
    file_map = {pb["name"]: set(pb["changed_files"]) for pb in per_branch if pb["resolved"]}
    pairs = []
    for i, a in enumerate(resolved_names):
        for bb in resolved_names[i + 1:]:
            status, conflict_files = _merge_tree_conflict(a, bb)
            shared = sorted(file_map[a] & file_map[bb])
            if status == "clean" and shared:
                pair_state = "overlap"
            else:
                pair_state = status  # clean | textual | inconclusive
            pairs.append({
                "a": a, "b": bb,
                "state": pair_state,                # clean | overlap | textual | inconclusive
                "shared_files": shared,
                "conflict_files": conflict_files,
            })

    # Per-branch severity (mirrors @merge-conflict-scanner Step 4).
    severity = {}
    for pb in per_branch:
        if not pb["resolved"]:
            severity[pb["name"]] = "unknown"
            continue
        if pb["vs_base"] == "textual":
            severity[pb["name"]] = "red"
            continue
        has_textual = any(p["state"] == "textual" and pb["name"] in (p["a"], p["b"]) for p in pairs)
        has_overlap = any(p["state"] == "overlap" and pb["name"] in (p["a"], p["b"]) for p in pairs)
        if has_textual:
            severity[pb["name"]] = "orange"
        elif has_overlap:
            severity[pb["name"]] = "yellow"
        else:
            severity[pb["name"]] = "green"
        if pb["behind"] > 100 and severity[pb["name"]] == "green":
            # Stale flag (only when otherwise clean) — augments without overriding red.
            severity[pb["name"]] = "stale"

    # Deterministic merge order: reds first (smallest-diff first), then any branch with
    # overlap (orange/yellow, grouped, smallest-diff first), then greens (smallest-diff
    # first). Ties broken by branch name. Stales + unknowns excluded from the order.
    def _diff_size(name):
        return len(file_map.get(name, set()))

    def _sort_key(name):
        return (_diff_size(name), name)

    reds = sorted([n for n, s in severity.items() if s == "red"], key=_sort_key)
    others = sorted(
        [n for n, s in severity.items() if s in ("orange", "yellow")],
        key=_sort_key,
    )
    greens = sorted([n for n, s in severity.items() if s == "green"], key=_sort_key)
    stales = sorted([n for n, s in severity.items() if s == "stale"], key=_sort_key)
    unknowns = sorted([n for n, s in severity.items() if s == "unknown"], key=_sort_key)
    order = reds + others + greens

    return {
        "base_ref": base_ref,
        "base_sha": base_sha,
        "unresolved": unresolved,
        "branches": per_branch,
        "pairs": pairs,
        "severity": severity,
        "order": order,
        "stales": stales,
        "unknowns": unknowns,
    }


def _render_scan_md(scan):
    """Render the conflict-scan.md (human-friendly). Deterministic ordering."""
    lines = []
    lines.append("# Merge Conflict Scan\n")
    lines.append(f"**Generated:** {_now()}\n")
    lines.append(f"**Base ref:** {scan['base_ref']} (`{scan['base_sha'][:12]}`)\n")
    lines.append(f"**Branches scanned:** {len(scan['branches'])}\n")
    if scan["unresolved"]:
        lines.append(f"**Unresolved branches:** {', '.join(scan['unresolved'])}\n")
    lines.append("")

    lines.append("## Summary\n")
    lines.append("| Branch | Status | Files changed | Behind base | Conflicts vs base |")
    lines.append("|---|---|---:|---:|---|")
    for pb in scan["branches"]:
        if not pb["resolved"]:
            lines.append(f"| {pb['name']} | unknown | — | — | — |")
            continue
        sev = scan["severity"][pb["name"]]
        files = len(pb["changed_files"])
        cv = "none" if pb["vs_base"] == "clean" else (
            f"{len(pb['vs_base_conflict_files'])} files" if pb["vs_base"] == "textual"
            else pb["vs_base"]
        )
        lines.append(f"| {pb['name']} | {sev} | {files} | {pb['behind']} | {cv} |")
    lines.append("")

    if scan["pairs"]:
        lines.append("## Cross-branch matrix\n")
        names = [pb["name"] for pb in scan["branches"] if pb["resolved"]]
        header = "|              | " + " | ".join(names) + " |"
        sep = "|---|" + "---|" * len(names)
        lines.append(header)
        lines.append(sep)
        pair_lookup = {(p["a"], p["b"]): p for p in scan["pairs"]}
        for a in names:
            row = [a]
            for b in names:
                if a == b:
                    row.append("—")
                else:
                    key = (a, b) if (a, b) in pair_lookup else (b, a)
                    p = pair_lookup.get(key)
                    row.append(p["state"] if p else "—")
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")
        lines.append("Legend: clean / overlap (shared files, no textual conflict) / textual / inconclusive\n")

    lines.append("## Recommended merge order\n")
    if not scan["order"]:
        lines.append("_No resolvable branches to order._\n")
    else:
        for i, name in enumerate(scan["order"], 1):
            sev = scan["severity"][name]
            lines.append(f"{i}. **{name}** ({sev})")
        lines.append("")
    if scan["stales"]:
        lines.append("\n## Stale branches (handle separately)\n")
        for s in scan["stales"]:
            lines.append(f"- {s}")
    if scan["unknowns"]:
        lines.append("\n## Unresolved branches\n")
        for u in scan["unknowns"]:
            lines.append(f"- {u}")
    lines.append("")
    return "\n".join(lines)


def cmd_scan(a):
    _validate_ref(a.base)
    branches = _validate_refs(_check_branch_count(a.branches))
    scan = _scan_matrix(a.base, branches)
    if a.run_dir:
        os.makedirs(a.run_dir, exist_ok=True)
        _atomic_write_text(os.path.join(a.run_dir, "conflict-scan.md"), _render_scan_md(scan))
        _atomic_write_json(os.path.join(a.run_dir, "conflict-scan.json"), {
            "schema": "conflict-scan/1",
            "generated_at": _now(),
            **{k: v for k, v in scan.items()},
        })
    # Parseable final-line summary.
    n_red = sum(1 for s in scan["severity"].values() if s == "red")
    n_orange = sum(1 for s in scan["severity"].values() if s == "orange")
    n_yellow = sum(1 for s in scan["severity"].values() if s == "yellow")
    n_green = sum(1 for s in scan["severity"].values() if s == "green")
    verdict = "CONFLICTS" if n_red > 0 else ("CAUTION" if (n_orange + n_yellow) > 0 else "CLEAN")
    order_str = ",".join(scan["order"]) if scan["order"] else "-"
    print(
        f"SCAN: verdict={verdict} red={n_red} orange={n_orange} yellow={n_yellow} "
        f"green={n_green} order={order_str}"
    )


# ---------------------------------------------------------------------------
# preflight — Step 1 hard checks. No auto-fix.
# ---------------------------------------------------------------------------

def cmd_preflight(a):
    _validate_ref(a.base)
    branches = _validate_refs(_check_branch_count(a.branches))
    failures = []

    # Base resolves.
    base_sha = _resolve(a.base)
    if not base_sha:
        failures.append(f"base ref does not resolve: {a.base}")

    # Each branch resolves.
    unresolved = [b for b in branches if not _resolve(b)]
    if unresolved:
        failures.append(f"branches do not resolve: {', '.join(unresolved)}")

    # Working tree clean.
    status_out = _git_out(["status", "--porcelain"])
    if status_out:
        failures.append("working tree is dirty (git status --porcelain non-empty)")

    # Upstream-exists per branch (warn, not blocking — list it).
    warns = []
    for b in branches:
        if not _resolve(b):
            continue
        if not _git_ok(["rev-parse", f"{b}@{{upstream}}"]):
            warns.append(f"branch {b} has no upstream (local-only)")

    # Base ahead/behind origin/<base>. Soft.
    if _git_ok(["rev-parse", f"origin/{a.base}"]):
        rl = _git_out(["rev-list", "--left-right", "--count", f"origin/{a.base}...{a.base}"])
        if rl:
            try:
                left, right = rl.split()
                # left = origin/base-only (i.e. local is behind origin by `left` commits)
                if int(left) > 0:
                    warns.append(f"local {a.base} is {left} commits behind origin/{a.base}")
                if int(right) > 0:
                    warns.append(f"local {a.base} is {right} commits ahead of origin/{a.base}")
            except (ValueError, IndexError):
                pass

    for w in warns:
        print(f"WARN: {w}")
    for f in failures:
        print(f"FAIL: {f}", file=sys.stderr)

    n_fail = len(failures)
    n_warn = len(warns)
    print(f"PREFLIGHT: failures={n_fail} warnings={n_warn} base={a.base} branches={len(branches)}")
    if n_fail:
        sys.exit(1)


# ---------------------------------------------------------------------------
# init — create run folder + atomic merge-state.json.
# ---------------------------------------------------------------------------

def _check_branch_count(branches):
    if not branches:
        _die("at least one branch required", code=2)
    if len(branches) > MAX_BRANCHES:
        _die(
            f"refusing >{MAX_BRANCHES} branches per run (got {len(branches)}). "
            f"Split into smaller invocations (rules-git.md).",
            code=2,
        )
    return list(branches)


def cmd_init(a):
    _validate_ref(a.base)
    branches = _validate_refs(_check_branch_count(a.branches))
    if a.strategy not in ("squash", "ff"):
        _die(f"invalid --strategy '{a.strategy}' (allowed: squash | ff)", code=2)
    os.makedirs(a.run_dir, exist_ok=True)
    state_path = os.path.join(a.run_dir, "merge-state.json")
    if os.path.isfile(state_path) and not a.force:
        _die(f"merge-state.json already exists at {state_path} (pass --force to overwrite)", code=2)
    state = {
        "schema": SCHEMA,
        "started_at": _now(),
        "base_ref": a.base,
        "strategy": a.strategy,
        "run_dir": a.run_dir,
        "branches": [
            {
                "name": b,
                "status": "pending",
                "merge_sha": None,
                "post_gate_verdict": None,
                "conflict_files": [],
                "notes": None,
            }
            for b in branches
        ],
        "current_index": -1,
        "halted": False,
        "halt_reason": None,
        "halt_branch": None,
    }
    _atomic_write_json(state_path, state)
    # Write the prompt-snapshot for traceability (matches the SKILL Step 2 prose).
    prompt_md = (
        f"# Merge orchestrator run\n\n"
        f"**Created:** {state['started_at']}\n\n"
        f"**Base ref:** {a.base}\n\n"
        f"**Strategy:** {a.strategy}\n\n"
        f"**Branches:**\n"
        + "\n".join(f"- `{b}`" for b in branches)
        + "\n"
    )
    _atomic_write_text(os.path.join(a.run_dir, "prompt.md"), prompt_md)
    print(f"INIT: run_dir={a.run_dir} base={a.base} strategy={a.strategy} branches={len(branches)}")


# ---------------------------------------------------------------------------
# merge-next — the deterministic per-branch loop. The structural heart.
# ---------------------------------------------------------------------------

def _next_pending(state):
    """Return (index, branch_dict) of the next non-terminal branch, or (None, None).

    Non-terminal: 'pending' or 'blocked'. 'in_progress' picks up where the prior step left
    off (operator may have invoked resume after a manual fix). Terminal: done, skipped,
    reverted.
    """
    for i, b in enumerate(state["branches"]):
        if b["status"] in ("pending", "blocked", "in_progress"):
            return i, b
    return None, None


def _save(state, state_path):
    _atomic_write_json(state_path, state)


def _set_halt(state, reason, branch_name):
    state["halted"] = True
    state["halt_reason"] = reason
    state["halt_branch"] = branch_name


def _resolve_check_cmds():
    """Three-tier discovery mirroring /post-merge-gate Step 1.
    Returns (typecheck_cmd, test_cmd) — each a string command or None (skip).

    Tier 1: .claude/project-paths.sh exporting TYPECHECK_CMD / TEST_CMD.
    Tier 2: package.json scripts (typecheck, test).
    Tier 3: None (skip — not a failure per /post-merge-gate Step 1).

    SECURITY (SA-002): `.claude/project-paths.sh` is SOURCED by this function and its
    TYPECHECK_CMD / TEST_CMD values are later passed to `subprocess.run(..., shell=True)`
    in `_run_check_cmd`. Both files therefore form an OPERATOR-TRUSTED boundary — they
    must be authored / reviewed by the operator. Do NOT run this script against a
    freshly-cloned untrusted repository without first reading `.claude/project-paths.sh`
    (or, if absent, the `scripts.typecheck` / `scripts.test` entries in `package.json`).
    The same trust requirement applies to `/post-merge-gate`, which uses the same
    three-tier discovery.
    """
    tc, ts = None, None
    pp = ".claude/project-paths.sh"
    if os.path.isfile(pp):
        r = subprocess.run(
            ["bash", "-c",
             f". {pp} >/dev/null 2>&1; "
             f"echo TYPECHECK=\"${{TYPECHECK_CMD:-}}\"; "
             f"echo TEST=\"${{TEST_CMD:-}}\""],
            capture_output=True, text=True, check=False,
        )
        for ln in r.stdout.splitlines():
            if ln.startswith("TYPECHECK="):
                v = ln[len("TYPECHECK="):].strip()
                tc = v or None
            elif ln.startswith("TEST="):
                v = ln[len("TEST="):].strip()
                ts = v or None
    if tc is None or ts is None:
        # Tier 2: package.json
        if os.path.isfile("package.json"):
            try:
                with open("package.json", encoding="utf-8") as f:
                    pkg = json.load(f)
                scripts = pkg.get("scripts", {}) or {}
                if tc is None and "typecheck" in scripts:
                    tc = "npm run typecheck"
                if ts is None and "test" in scripts:
                    ts = "npm test"
            except (OSError, ValueError, json.JSONDecodeError):
                pass
    return tc, ts


def _run_check_cmd(name, cmd):
    """Run a configured check command. Returns (ok, exit_code, tail_output)."""
    if not cmd:
        return True, 0, f"(no {name} command configured — skipped)"
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=False)
    out = (r.stdout or "") + (r.stderr or "")
    tail = "\n".join(out.splitlines()[-50:])
    return (r.returncode == 0), r.returncode, tail


def _rebase_branch_onto_base(branch, base, branch_record, state):
    """Rebase branch onto base. Returns True on clean, False on conflict-and-aborted.

    On conflict: runs `git rebase --abort` to leave tree CLEAN, records conflict files
    to branch_record, and sets state.halted (does NOT exit — caller does the surface).
    """
    co = _guarded_git(["checkout", branch])
    if co.returncode != 0:
        _set_halt(state, "refused", branch)
        branch_record["notes"] = f"checkout failed: {co.stderr.strip()[:200]}"
        return False
    rb = _guarded_git(["rebase", base])
    if rb.returncode == 0:
        return True
    # Conflict — capture file list BEFORE aborting.
    conflict_paths = _git_out(["diff", "--name-only", "--diff-filter=U"])
    files = conflict_paths.splitlines() if conflict_paths else []
    # Abort to leave the tree CLEAN.
    _guarded_git(["rebase", "--abort"])
    branch_record["status"] = "blocked"
    branch_record["conflict_files"] = files
    branch_record["notes"] = "rebase_conflict"
    _set_halt(state, "rebase_conflict", branch)
    return False


def _commit_msg_for(branch):
    """Conventional Commits message derived from the branch prefix (rules-git.md)."""
    typ = "chore"
    if branch.startswith("feature/"):
        typ = "feat"
    elif branch.startswith("fix/"):
        typ = "fix"
    elif branch.startswith("docs/"):
        typ = "docs"
    elif branch.startswith("refactor/"):
        typ = "refactor"
    slug = branch.split("/", 1)[1] if "/" in branch else branch
    return f"{typ}: squash-merge {slug}\n\nSquash-merge of {branch} via merge-orchestrate.py (ADR-071)."


def _squash_merge_onto_base(branch, base, branch_record, state):
    """Switch to base, squash-merge branch in, commit. Returns merge SHA or None."""
    co = _guarded_git(["checkout", base])
    if co.returncode != 0:
        _set_halt(state, "refused", branch)
        branch_record["notes"] = f"checkout base failed: {co.stderr.strip()[:200]}"
        return None
    sm = _guarded_git(["merge", "--squash", branch])
    if sm.returncode != 0:
        # Squash merge can hit conflicts even when rebase was clean (rare). Defensive:
        # `git merge --abort` reverts the half-staged merge. NEVER reset --hard / NEVER
        # `checkout -- .` (CR-001 — those silently overwrite uncommitted operator edits
        # with HEAD, violating the script's "never lose work" guarantee).
        _guarded_git(["merge", "--abort"])
        # Confirm the abort left the tree clean. If status is non-empty, halt LOUDER
        # rather than try to "fix" the tree — recovery isn't the script's job.
        leftover = _git_out(["status", "--porcelain"])
        if leftover:
            branch_record["status"] = "blocked"
            branch_record["notes"] = (
                f"squash merge conflict; `git merge --abort` left tree dirty: "
                f"{leftover[:300]}"
            )
            _set_halt(state, "squash_conflict", branch)
            return None
        branch_record["status"] = "blocked"
        branch_record["notes"] = f"squash merge conflict: {sm.stderr.strip()[:200]}"
        # CR-004 — distinct halt reason for squash conflicts (was bucketed into
        # rebase_conflict; obscured the cause).
        _set_halt(state, "squash_conflict", branch)
        return None
    msg = _commit_msg_for(branch)
    cm = _guarded_git(["commit", "-m", msg])
    if cm.returncode != 0:
        # Empty commit (no diff). Treat as no-op: don't allow-empty (silent landing of
        # nothing is worse than a clean skip). Mark skipped and continue.
        branch_record["status"] = "skipped"
        branch_record["notes"] = "nothing to commit (empty diff vs base)"
        return None
    return _git_out(["rev-parse", "HEAD"]) or None


def _ff_merge_onto_base(branch, base, branch_record, state):
    co = _guarded_git(["checkout", base])
    if co.returncode != 0:
        _set_halt(state, "refused", branch)
        return None
    mr = _guarded_git(["merge", "--ff-only", branch])
    if mr.returncode != 0:
        branch_record["status"] = "blocked"
        branch_record["notes"] = f"ff merge refused (non-fast-forward): {mr.stderr.strip()[:200]}"
        _set_halt(state, "rebase_conflict", branch)
        return None
    return _git_out(["rev-parse", "HEAD"]) or None


def _process_one(state, state_path):
    """Run one merge-next iteration. Returns one of:
        'CLEAN'              — branch landed green, AGENT_GATE_PENDING signal due
        'SKIPPED'            — branch had no diff; marked skipped, continue
        'HALT:<reason>'      — halted; caller prints the halt surface and exits non-zero
        'COMPLETE'           — every branch terminal
    """
    if state["halted"]:
        return f"HALT:{state['halt_reason']}"

    # CR-002 — structural dirty-tree guard. The script's "never lose work" guarantee
    # depends on starting from a clean tree (the merge / rebase paths assume HEAD reflects
    # the only committed state). If the operator (or some other tool) left edits in the
    # working tree, halt BEFORE selecting a branch — refuse to act on a dirty tree rather
    # than risk overwriting those edits in a subsequent checkout / merge / rebase.
    dirty = _git_out(["status", "--porcelain"])
    if dirty:
        # We have no current branch yet; record the halt at the run level (halt_branch=None).
        state["halted"] = True
        state["halt_reason"] = "refused"
        state["halt_branch"] = None
        # Surface the dirty paths in the run-level halt so the operator can find them.
        state["halt_notes"] = (
            "refused: pre-existing dirty working tree (commit, stash, or discard your "
            "edits before re-running). Status:\n" + dirty[:500]
        )
        _save(state, state_path)
        return "HALT:refused"

    idx, branch_record = _next_pending(state)
    if branch_record is None:
        return "COMPLETE"

    branch = branch_record["name"]
    base = state["base_ref"]
    # SA-005 — defensive ref validation on state replay. State files can be hand-edited
    # or authored by an older version; revalidate every ref before it reaches `git` argv.
    _validate_ref(branch)
    _validate_ref(base)
    branch_record["status"] = "in_progress"
    branch_record["notes"] = None
    branch_record["conflict_files"] = []
    state["current_index"] = idx
    _save(state, state_path)

    # ---- Step 5b: rebase-if-behind (rebase is a no-op if up-to-date) ----
    behind = 0
    rl = _git_out(["rev-list", "--left-right", "--count", f"{branch}...{base}"])
    if rl:
        try:
            _ahead, _behind = rl.split()
            behind = int(_behind)
        except (ValueError, IndexError):
            behind = 0
    if behind > 0:
        ok = _rebase_branch_onto_base(branch, base, branch_record, state)
        _save(state, state_path)
        if not ok:
            return f"HALT:{state['halt_reason']}"

    # ---- Step 5c: merge onto base (squash default, ff opt-in) ----
    if state["strategy"] == "ff":
        merge_sha = _ff_merge_onto_base(branch, base, branch_record, state)
    else:
        merge_sha = _squash_merge_onto_base(branch, base, branch_record, state)
    if merge_sha is None:
        _save(state, state_path)
        if branch_record["status"] == "skipped":
            return "SKIPPED"
        return f"HALT:{state['halt_reason']}"
    branch_record["merge_sha"] = merge_sha
    _save(state, state_path)

    # ---- Step 5d: deterministic post-merge checks (typecheck + tests) ----
    tc_cmd, test_cmd = _resolve_check_cmds()
    tc_ok, tc_rc, tc_tail = _run_check_cmd("typecheck", tc_cmd)
    ts_ok, ts_rc, ts_tail = _run_check_cmd("tests", test_cmd)
    if not (tc_ok and ts_ok):
        # Branch stays merged; halt — operator decides revert vs fix-forward.
        branch_record["post_gate_verdict"] = "red"
        _set_halt(state, "post_merge_gate_red", branch)
        _save(state, state_path)
        per_dir = os.path.join(state["run_dir"], "per-branch", _safe(branch))
        os.makedirs(per_dir, exist_ok=True)
        _atomic_write_text(
            os.path.join(per_dir, "post-merge-gate-report.md"),
            f"# Post-merge gate report — {branch}\n\n"
            f"**Merge SHA:** {merge_sha}\n\n"
            f"## Typecheck\n\nCommand: `{tc_cmd or '(none)'}`\nExit: {tc_rc}\n\n"
            f"```\n{tc_tail}\n```\n\n"
            f"## Tests\n\nCommand: `{test_cmd or '(none)'}`\nExit: {ts_rc}\n\n"
            f"```\n{ts_tail}\n```\n",
        )
        return f"HALT:{state['halt_reason']}"

    # Green: mark done, caller emits AGENT_GATE_PENDING.
    branch_record["status"] = "done"
    branch_record["post_gate_verdict"] = "green"
    _save(state, state_path)
    return "CLEAN"


def _safe(name):
    return re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-") or "branch"


def cmd_merge_next(a):
    state, state_path = _read_state(a.run_dir)
    result = _process_one(state, state_path)
    branch_record = (
        state["branches"][state["current_index"]]
        if 0 <= state["current_index"] < len(state["branches"])
        else None
    )
    branch_name = branch_record["name"] if branch_record else "-"
    if result == "COMPLETE":
        print("MERGE-NEXT: status=complete (every branch terminal)")
        return
    if result == "SKIPPED":
        print(f"MERGE-NEXT: status=skipped branch={branch_name} (no diff vs base)")
        return
    if result.startswith("HALT:"):
        reason = result.split(":", 1)[1]
        payload = {
            "status": "halted",
            "halt_reason": reason,
            "halt_branch": state["halt_branch"],
            "branch": branch_name,
            "merge_sha": branch_record.get("merge_sha") if branch_record else None,
            "conflict_files": branch_record.get("conflict_files", []) if branch_record else [],
            "run_dir": state["run_dir"],
        }
        print(f"HALT-PAYLOAD: {json.dumps(payload)}")
        print(f"MERGE-NEXT: status=halted reason={reason} branch={branch_name}")
        sys.exit(1)
    # CLEAN — emit the agent-gate pending signal for the orchestrator.
    print(f"AGENT_GATE_PENDING branch={branch_name} merge_sha={branch_record['merge_sha']}")
    print(f"MERGE-NEXT: status=clean branch={branch_name} merge_sha={branch_record['merge_sha']}")


# ---------------------------------------------------------------------------
# status / resume.
# ---------------------------------------------------------------------------

def cmd_status(a):
    state, _ = _read_state(a.run_dir)
    n_done = sum(1 for b in state["branches"] if b["status"] == "done")
    n_pending = sum(1 for b in state["branches"] if b["status"] == "pending")
    n_blocked = sum(1 for b in state["branches"] if b["status"] == "blocked")
    n_skipped = sum(1 for b in state["branches"] if b["status"] in ("skipped", "reverted"))
    print(f"# merge-state.json @ {state['run_dir']}")
    print(f"#   base: {state['base_ref']}  strategy: {state['strategy']}  halted: {state['halted']}")
    if state["halted"]:
        print(f"#   halt: reason={state['halt_reason']} branch={state['halt_branch']}")
    for i, b in enumerate(state["branches"]):
        mark = ">" if i == state["current_index"] else " "
        sha = (b["merge_sha"] or "")[:12]
        gate = b["post_gate_verdict"] or "-"
        print(f"{mark} {b['name']:50s} status={b['status']:11s} sha={sha:12s} gate={gate}")
    print(
        f"STATUS: done={n_done} pending={n_pending} blocked={n_blocked} "
        f"skipped+reverted={n_skipped} halted={state['halted']}"
    )


def cmd_resume(a):
    state, state_path = _read_state(a.run_dir)
    # Resume: done/skipped/reverted are terminal; blocked is re-attempted; pending is
    # processed in order. If currently halted, clear halt and try to make progress.
    if state["halted"]:
        state["halted"] = False
        state["halt_reason"] = None
        state["halt_branch"] = None
        _save(state, state_path)
    result = _process_one(state, state_path)
    branch_record = (
        state["branches"][state["current_index"]]
        if 0 <= state["current_index"] < len(state["branches"])
        else None
    )
    branch_name = branch_record["name"] if branch_record else "-"
    if result == "COMPLETE":
        print("RESUME: status=complete (every branch terminal)")
        return
    if result == "SKIPPED":
        print(f"RESUME: status=skipped branch={branch_name} (no diff vs base)")
        return
    if result.startswith("HALT:"):
        reason = result.split(":", 1)[1]
        print(f"RESUME: status=halted reason={reason} branch={branch_name}")
        sys.exit(1)
    print(f"AGENT_GATE_PENDING branch={branch_name} merge_sha={branch_record['merge_sha']}")
    print(f"RESUME: status=clean branch={branch_name} merge_sha={branch_record['merge_sha']}")


# ---------------------------------------------------------------------------
# argparse wiring.
# ---------------------------------------------------------------------------

def _add_base_branches(p):
    p.add_argument("--base", default=DEFAULT_BASE, help=f"base ref (default: {DEFAULT_BASE})")
    p.add_argument("branches", nargs="+", help="feature branch names (≤6)")


def main():
    p = argparse.ArgumentParser(
        prog="merge-orchestrate.py",
        description=(
            "Deterministic merge/landing engine (ADR-071 Part 2). Scripts the safe-landing "
            "flow currently hand-walked in core/skills/merge-orchestrator/SKILL.md. NEVER "
            "pushes, NEVER force-anythings, NEVER reset --hard, NEVER auto-resolves a conflict."
        ),
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("scan", help="conflict matrix via git merge-tree (no mutation)")
    _add_base_branches(ps)
    ps.add_argument("--run-dir", help="optional run dir to write conflict-scan.md + .json")
    ps.set_defaults(fn=cmd_scan)

    pp = sub.add_parser("preflight", help="Step-1 hard checks; non-zero on any failure")
    _add_base_branches(pp)
    pp.set_defaults(fn=cmd_preflight)

    pi = sub.add_parser("init", help="create run folder + merge-state.json")
    pi.add_argument("--base", default=DEFAULT_BASE)
    pi.add_argument("--run-dir", required=True)
    pi.add_argument("--strategy", default=DEFAULT_STRATEGY, choices=("squash", "ff"))
    pi.add_argument("--force", action="store_true", help="overwrite an existing merge-state.json")
    pi.add_argument("branches", nargs="+", help="feature branch names (≤6)")
    pi.set_defaults(fn=cmd_init)

    pm = sub.add_parser("merge-next", help="process the next pending branch deterministically")
    pm.add_argument("--run-dir", required=True)
    pm.set_defaults(fn=cmd_merge_next)

    pst = sub.add_parser("status", help="print current merge-state.json status")
    pst.add_argument("--run-dir", required=True)
    pst.set_defaults(fn=cmd_status)

    pr = sub.add_parser("resume", help="re-enter the loop (clears halt, processes next)")
    pr.add_argument("--run-dir", required=True)
    pr.set_defaults(fn=cmd_resume)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
