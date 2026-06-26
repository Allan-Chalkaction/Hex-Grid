#!/usr/bin/env bash
# PreToolUse hook: Source-protection — guards application source files AND
# active-runs state files from direct orchestrator edits.
# Matches: Edit|Write
#
# Exit code 0 = allow
# Exit code 2 = block the action
#
# This hook merges two former hooks (claude-infra v2 T2):
#   1. active-runs guard (was block-active-runs-edits.sh) — a HARD block on
#      Edit/Write to .claude/agent-memory/active-runs/*. Runs FIRST, before the
#      bypass short-circuit: the state machine owns phase transitions, and that
#      invariant is NOT lifted by /bypass (state mutations use Bash+jq+tmp+mv).
#   2. source-edit guard — the orchestrator must NEVER edit application source
#      directly; it delegates to implementer agents (which run in worktrees, a
#      different cwd, and are not blocked here). Bypass DOES lift this one.
#
# Ordering is load-bearing: active-runs (no bypass) precedes the bypass check.

set -euo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# Extract file path and session_id from tool input
FILE_PATH=""
SESSION_ID=""
if command -v jq &> /dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
else
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# --- ACTIVE-RUNS GUARD (merged from block-active-runs-edits.sh) ---
# HARD block — runs before the bypass short-circuit. The state machine manages
# phase transitions; the orchestrator never edits state files directly. Not
# lifted by bypass (orchestrator state mutations must use Bash + jq + tmp + mv).
case "$FILE_PATH" in
  */.claude/agent-memory/active-runs/*|*agent-memory/active-runs/*)
    echo "BLOCKED: Do not modify state files directly. The state machine manages phase transitions automatically." >&2
    exit 2
    ;;
esac

# --- BYPASS CHECK: orchestrator gains direct edit capability in bypass mode ---
# Pattern mirrors require-nimble-protocol.sh:58-65. When bypass-active.json
# exists with enabled:true, source-file edits from the orchestrator are
# permitted (the orchestrator is in /bypass mode and may make small,
# obvious changes itself rather than dispatching an implementer).
# Anchor to the project dir: hooks can fire with a drifted cwd, which made the
# bypass flag silently "drop" mid-session. Prefer $CLAUDE_PROJECT_DIR; else the
# git toplevel (found by walking up, cwd-independent); else the relative fallback.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
# Session-scoped bypass flag (ADR-052): keyed to THIS session so concurrent
# sessions in one repo have independent bypass state, and one session's start
# can't wipe another's. The legacy repo-global bypass-active.json is no longer
# honored (it leaked across sessions); session-cleanup removes it.
if [ -n "$SESSION_ID" ]; then
  BYPASS_FILE="$PROJECT_DIR/.claude/agent-memory/bypass-active-${SESSION_ID}.json"
  if [ -f "$BYPASS_FILE" ]; then
    BYPASS_ENABLED=$(jq -r '.enabled // false' "$BYPASS_FILE" 2>/dev/null)
    if [ "$BYPASS_ENABLED" = "true" ]; then
      exit 0
    fi
  fi
fi

# Allow edits to non-source files (docs, config, pipeline artifacts, etc.)
case "$FILE_PATH" in
  # Pipeline artifacts and docs — orchestrator is allowed to write these
  */docs/step-5-pipeline/*|*/docs/step-2-planning/*|*/docs/step-3-specs/*|*/docs/decisions/*)
    exit 0
    ;;
  # Claude config — orchestrator is allowed (active-runs/ guarded by block-active-runs-edits.sh)
  */.claude/agent-memory/*|*/.claude/settings*|*/.claude/project-paths*)
    exit 0
    ;;
  # CLAUDE.md and rules/skills — orchestrator is allowed
  */CLAUDE.md|*/.claude/rules/*|*/.claude/skills/*|*/.claude/agents/*|*/.claude/commands/*|*/.claude/hooks/*)
    exit 0
    ;;
  # Package.json, tsconfig, config files — orchestrator is allowed.
  # NOTE: .env* intentionally removed (SH-1 #4) — protected-files.sh owns the
  # secrets verdict and blocks .env unconditionally. Leaving a .env allow here
  # produced an allow/block contradiction between the two hooks.
  */package.json|*/tsconfig*.json|*/vite.config*|*/tailwind.config*|*/postcss.config*)
    exit 0
    ;;
  # Sprint logs, changelogs, READMEs
  */sprint-log.md|*/CHANGELOG*|*/README*)
    exit 0
    ;;
esac

# claude-infra's own infrastructure paths — orchestrator-permitted regardless
# of file extension. The hook's intent is to block direct edits to *application
# code* (the apps/, client/, server/, src/ surfaces of consumer projects), not
# to require bypass for editing claude-infra's own infra (python helpers, hook
# scripts, agent definitions, etc.). This allowlist precedes the source-
# extension blocklist below so .py / .ts files in core/scripts/, core/hooks/,
# etc. are permitted; the same extensions in apps/ / src/ / client/ paths
# remain blocked. Symmetric with the path-prefix allowlist documented in
# core/rules/rules-orchestrator-behavior.md.
case "$FILE_PATH" in
  */core/scripts/*|*/core/hooks/*|*/core/agents/*|*/core/rules/*|*/core/skills/*|*/core/commands/*|*/core/config/*|*/core/gate-prompts/*)
    exit 0
    ;;
esac

# Check if this is a source code file by extension
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.css|*.scss|*.sql|*.astro|*.svelte|*.vue|*.py|*.go|*.rs)
    # This is a source file — check if we're in the main repo or a worktree
    ;;
  *)
    # Not a source file extension — allow
    exit 0
    ;;
esac

# Check if the edit is happening in a worktree (implementer agent)
# Worktrees are created under .claude/worktrees/ or in tmp directories
case "$FILE_PATH" in
  */.claude/worktrees/*|*/tmp/*|*/var/folders/*)
    # Worktree edit — this is an implementer agent, allow it
    exit 0
    ;;
esac

# Fallback for non-worktree implementers: if an active plan step exists for any
# run, an implementer is expected to be editing files. Allow the edit.
# This handles cases where worktrees aren't available (not a git repo, etc.).
RUNS_DIR=".claude/agent-memory/active-runs"
if [ -d "$RUNS_DIR" ] && command -v jq &>/dev/null; then
  for state_file in "$RUNS_DIR"/*.json; do
    [[ "$state_file" == *.tmp ]] && continue
    [ -f "$state_file" ] || continue
    # Session isolation
    if [ -n "$SESSION_ID" ]; then
      _bse_fname=$(basename "$state_file")
      case "$_bse_fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    RUN_DIR=$(jq -r '.run_dir // empty' "$state_file" 2>/dev/null)
    [ -z "$RUN_DIR" ] || [ "$RUN_DIR" = "null" ] && continue
    PLAN_STEPS_FILE="${RUN_DIR}/plan-steps.json"
    if [ -f "$PLAN_STEPS_FILE" ]; then
      ACTIVE_COUNT=$(jq '[.steps // [] | .[] | select(.status == "active")] | length' "$PLAN_STEPS_FILE" 2>/dev/null || echo "0")
      if [ "$ACTIVE_COUNT" != "0" ]; then
        # Active plan step exists — an implementer is expected to be editing
        exit 0
      fi
    fi
  done
fi

# This is a source code edit in the main repo with no active run — block it
echo "BLOCKED: Orchestrator cannot edit source code directly. Delegate to an implementer agent via the /nimble skill protocol. File: ${FILE_PATH}" >&2
echo "" >&2
echo "Required steps:" >&2
echo "  1. Create or select a ticket for this work" >&2
echo "  2. Create a plan step describing the change" >&2
echo "  3. Mark the plan step active" >&2
echo "  4. Invoke the implementer (in a worktree) with the change description" >&2
echo "  5. The implementer runs in a worktree and can edit source files" >&2
exit 2
