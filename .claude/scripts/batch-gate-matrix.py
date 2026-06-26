#!/usr/bin/env python3
"""batch-gate-matrix.py — the DETERMINISTIC change-surface -> gate-agent floor (ADR-126, F9; SHR3-T5).

F9 BINDING (ADR-126 D-1) — ZERO LLM involvement in the decision. This script answers ONE question
deterministically: "given a set of changed files, which gate agents does the change-surface trigger?" It is
the executable form of the `/batch-gate` SKILL.md § 2 quality-gate matrix — a pure surface -> agent map, no
model inference. The selection is THIS script's, never a model's. The only LLM role is **advisory-only**
(the caller may add a hint) and NEVER overrides the computed gate set — exactly `queue-order.py`'s discipline.

This is a TOTAL map (every change-surface resolves deterministically), so there is no abstain band here — the
matrix is complete and the verdict is always a concrete agent list. The no-guess discipline (ADR-126 D-3)
shows up as the matrix's *closed* rule set: a surface either matches a rule (the agent is added) or it does
not (the agent is not) — the script never guesses an agent the matrix does not name. `code-reviewer` is the
unconditional floor (the "Always" row).

The overlay tokens (`MIGRATIONS_PATTERN`, `EDGE_FUNCTIONS_PATTERN`, `DATA_HOOKS_PATTERN`,
`E2E_CONFIG_PATTERN`) match the SKILL.md A1 project-layout overlay: defaults are the original Supabase shape;
a consumer overrides via flags (the skill reads `.claude/agent-context/batch-gate.md` and passes them). An
EMPTY overlay value suppresses that row (the skill's `EDGE_FUNCTIONS_PATTERN=` → row off).

The `reason` field (ADR-126 D-2) is the script's OWN deterministic justification — the matrix rows that
fired and the file that triggered each (e.g. "MIGRATIONS_PATTERN matched supabase/migrations/001.sql →
db-migration-reviewer, security-auditor").

folder-as-truth (ADR-126 D-4): the `E2E_CONFIG_PATTERN` presence check reads the LIVE repo (`--repo-root`)
for a playwright config; the changed-file set is the live `git diff --name-only` the caller passes in.

Subcommands:
  select  --files CSV [--repo-root DIR] [--migrations P] [--edge P] [--data-hooks P] [--e2e P]

`select` prints {"decision": ["agent", ...], "reason": <str>, "confidence": "deterministic", "advisory": null}.
The agent list is sorted + de-duplicated for stable, reproducible output. Exit 0 always (a total map has no
conflict flag — every surface has a defined gate set).
"""
import json
import os
import re
import sys
import argparse
import fnmatch

# Overlay defaults — the original Supabase/React/Playwright consumer shape (SKILL.md § 2 A1). A consumer
# overrides via flags; an EMPTY value suppresses the row.
DEFAULT_MIGRATIONS = "supabase/migrations/"
DEFAULT_EDGE = "supabase/functions/"
DEFAULT_DATA_HOOKS = "client/src/hooks/use-*.ts*"
DEFAULT_E2E = "playwright.config.*"

# Visual UI extensions + dir tokens (SKILL.md "Any UI surface" row).
_UI_EXTS = (".tsx", ".jsx", ".vue", ".svelte", ".css", ".scss")
_UI_DIR_RE = re.compile(r"(^|/)(components|app|pages|ui)(/|$)")
# Files whose visual output gates e2e (a .tsx — the SKILL.md "visual output" row, conservatively any .tsx).
_VISUAL_TSX_RE = re.compile(r"\.tsx$")
_MANY_FILES = 10  # SKILL.md "10+ files changed -> performance-reviewer".


def _die(msg, code=2):
    sys.stderr.write(f"batch-gate-matrix: {msg}\n")
    sys.exit(code)


def _prefix_match(files, prefix):
    """A path-prefix overlay (e.g. MIGRATIONS_PATTERN=supabase/migrations/). Empty prefix -> row suppressed."""
    if not prefix:
        return []
    return [f for f in files if f.startswith(prefix)]


def _glob_match(files, pattern):
    """A glob overlay (e.g. DATA_HOOKS_PATTERN=client/src/hooks/use-*.ts*). Empty pattern -> row suppressed."""
    if not pattern:
        return []
    return [f for f in files if fnmatch.fnmatch(f, pattern) or fnmatch.fnmatch(os.path.basename(f), pattern)]


def _is_ui(f):
    return f.endswith(_UI_EXTS) or bool(_UI_DIR_RE.search(f))


def _e2e_config_present(repo_root, pattern):
    """folder-as-truth: scan the LIVE repo for a file matching the e2e config glob. Empty pattern -> absent."""
    if not pattern or not repo_root or not os.path.isdir(repo_root):
        return False
    base_glob = os.path.basename(pattern)
    for root, dirs, files in os.walk(repo_root):
        # Skip noisy/irrelevant trees for a bounded, deterministic walk.
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "dist", "build")]
        for fn in files:
            if fnmatch.fnmatch(fn, base_glob):
                return True
    return False


def cmd_select(a):
    files = [f for f in (a.files.split(",") if a.files else []) if f.strip()]
    files = [f.strip() for f in files]

    gates = set()
    fired = []  # deterministic justification fragments

    # --- the matrix (SKILL.md § 2) — a closed, total surface -> agent map ---
    # Always: code-reviewer (the unconditional floor).
    gates.add("code-reviewer")
    fired.append("Always -> code-reviewer")

    # Any UI surface -> ui-review.
    ui_hits = [f for f in files if _is_ui(f)]
    if ui_hits:
        gates.add("ui-review")
        fired.append(f"UI surface ({ui_hits[0]}) -> ui-review")

    # MIGRATIONS_PATTERN -> db-migration-reviewer + security-auditor.
    mig = _prefix_match(files, a.migrations)
    if mig:
        gates.update(("db-migration-reviewer", "security-auditor"))
        fired.append(f"MIGRATIONS_PATTERN matched {mig[0]} -> db-migration-reviewer, security-auditor")

    # EDGE_FUNCTIONS_PATTERN -> security-auditor.
    edge = _prefix_match(files, a.edge)
    if edge:
        gates.add("security-auditor")
        fired.append(f"EDGE_FUNCTIONS_PATTERN matched {edge[0]} -> security-auditor")

    # package.json modified -> dependency-auditor.
    pkg = [f for f in files if os.path.basename(f) == "package.json"]
    if pkg:
        gates.add("dependency-auditor")
        fired.append(f"package.json modified ({pkg[0]}) -> dependency-auditor")

    # DATA_HOOKS_PATTERN -> performance-reviewer.
    hooks = _glob_match(files, a.data_hooks)
    if hooks:
        gates.add("performance-reviewer")
        fired.append(f"DATA_HOOKS_PATTERN matched {hooks[0]} -> performance-reviewer")

    # 10+ files changed -> performance-reviewer.
    if len(files) >= _MANY_FILES:
        gates.add("performance-reviewer")
        fired.append(f"{len(files)} files changed (>= {_MANY_FILES}) -> performance-reviewer")

    # Any visual .tsx AND an e2e config present in the repo -> e2e-test-writer.
    visual_tsx = [f for f in files if _VISUAL_TSX_RE.search(f)]
    if visual_tsx and _e2e_config_present(a.repo_root, a.e2e):
        gates.add("e2e-test-writer")
        fired.append(f"visual .tsx ({visual_tsx[0]}) + e2e config present -> e2e-test-writer")

    decision = sorted(gates)
    reason = "; ".join(fired)
    out = {"decision": decision, "reason": reason, "confidence": "deterministic", "advisory": None}
    print(json.dumps(out))


def main():
    p = argparse.ArgumentParser(prog="batch-gate-matrix")
    sub = p.add_subparsers(required=True)
    ps = sub.add_parser("select")
    ps.add_argument("--files", required=True, help="comma-separated changed files (git diff --name-only)")
    ps.add_argument("--repo-root", default=".", help="repo root for the live e2e-config presence check")
    ps.add_argument("--migrations", default=DEFAULT_MIGRATIONS, help="MIGRATIONS_PATTERN overlay (empty suppresses)")
    ps.add_argument("--edge", default=DEFAULT_EDGE, help="EDGE_FUNCTIONS_PATTERN overlay (empty suppresses)")
    ps.add_argument("--data-hooks", default=DEFAULT_DATA_HOOKS, help="DATA_HOOKS_PATTERN overlay (empty suppresses)")
    ps.add_argument("--e2e", default=DEFAULT_E2E, help="E2E_CONFIG_PATTERN overlay (empty suppresses)")
    ps.set_defaults(fn=cmd_select)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
