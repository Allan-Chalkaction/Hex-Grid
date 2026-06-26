#!/usr/bin/env bash
# UserPromptSubmit hook: Require explicit track choice before any new run
# Matcher: (none — fires on every user message)
#
# Blocks the prompt with `decision: "block"` when all of the following hold:
#   1. The prompt does not start with a slash command (slash-prefixed messages
#      are intentional choices and pass through unchanged)
#   2. The prompt body contains no `Track: Nimble` / `Track: Pipeline` marker
#   3. No active (non-done) run state file exists for this session
#   4. Bypass mode is not active
#   5. The prompt is not a harness async-completion (<task-notification>) re-invocation
#
# When blocked, the user sees a message asking them to pick a track:
#   /nimble    — full state-machine track for quick work
#   /pipeline  — full track for new features (cto + spec + adr + decompose)
#   /bypass    — just chat with the orchestrator, no run protocol
#
# Once any of those is in effect, this hook stops firing for the session
# (or until /bypass off + a fresh ungated prompt).

set -uo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

if ! command -v jq &>/dev/null; then
  exit 0
fi

USER_MESSAGE=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# --- Skip empty prompts (defensive) ---
if [ -z "$USER_MESSAGE" ]; then
  exit 0
fi

# --- Skip slash commands (/nimble, /pipeline, /bypass, /help, ...) and ---
# --- @-prefixed agent invocations (@code-reviewer, @implementer, ...) ---
# Both are explicit user choices: slash = skill/command, @ = direct agent.
# require-nimble-protocol.sh still gates the agent call itself when an implementer
# is invoked without the protocol prerequisites — that's the right layer for it.
case "$USER_MESSAGE" in
  /*|@*) exit 0 ;;
esac

# --- Skip harness re-invocations (async task / agent completions) ---
# A background Agent/Workflow that finishes is reported back to the session as a
# UserPromptSubmit whose prompt carries a <task-notification> envelope. That is the
# harness delivering an async RESULT, not the user picking new work. Gating it stalls
# every autonomous build that dispatches background work and waits for it to return:
# bypass may have been cleared by an intervening SessionStart, and a pure Workflow-
# engine run has no active-runs state file, so neither later skip catches it. Pass it
# through unconditionally (the prompt is informational, never a track choice).
case "$USER_MESSAGE" in
  *"<task-notification>"*) exit 0 ;;
esac

# --- Skip if a Track: marker is in the prompt body ---
case "$USER_MESSAGE" in
  *"Track: Nimble"*|*"Track: nimble"*|*"Track: Pipeline"*|*"Track: pipeline"*)
    exit 0
    ;;
esac

# --- Skip if bypass mode is active ---
# Anchor to the project dir (hooks can fire with a drifted cwd → bypass "drops").
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

# --- Skip if an active (non-done) run state file exists for this session ---
RUNS_DIR=".claude/agent-memory/active-runs"
if [ -d "$RUNS_DIR" ] && [ -n "$SESSION_ID" ]; then
  for candidate in "$RUNS_DIR"/*.json; do
    [[ "$candidate" == *.tmp ]] && continue
    [ -f "$candidate" ] || continue
    fname=$(basename "$candidate")
    case "$fname" in
      "${SESSION_ID}-"*)
        phase=$(jq -r '.current_phase // empty' "$candidate" 2>/dev/null)
        if [ -n "$phase" ] && [ "$phase" != "done" ]; then
          # Active run for this session — workflow-state-inject handles routing
          exit 0
        fi
        ;;
    esac
  done
fi

# --- All skip conditions failed: block and ask for a track choice ---
# Menu is grouped under the two-axis model from CLAUDE.md: Execution paths (how should this work
# get built?) and Mode overlays (what's the orchestrator allowed to do?). /resume and /onboard are
# meta-verbs (resume an existing run / wire a fresh repo), not new-work choices — they appear in
# the footer below, not the picker.
REASON="Pick a track before I begin work — two axes (CLAUDE.md / two-axis model):

Execution paths (how should this work get built?):
  /nimble       — quick fix or single-feature work (light engine preset: explore → implement → integrate → batch-gate)
  /orchestrated — run a pre-decomposed wave of tickets on the engine (cto → architect → pm-spec → implement-per-ticket → gate → architect-final)
  /chain        — run a custom ordered agent list (e.g. /chain cto-advisor,implementer,code-reviewer)
  /loop-task    — bounded, test-verifiable grind (ralph-loop plugin)

Mode overlays (what's the orchestrator allowed to do?):
  /bypass       — just chat with me, no run protocol or implementer gating
  /roadmap      — iterative epic→roadmap / wave→spec planning (advisor funnel, round-boundary tuning, no implementers)
  /planner      — repo-aware planning partner (drafts plans/specs/ADRs as files, advisor-only)

Type one of the above (alone to set the mode for the session, or with your prompt after — e.g. \`/nimble fix the auth redirect bug\`).

To invoke a specific agent directly, use \`@<agent-name>\` (e.g., \`@code-reviewer review src/auth.ts\`). For implementer agents you'll need to run \`/bypass\` first, since the protocol hook still requires an active run otherwise.

To resume an interrupted run, use \`/resume\`. To wire a fresh repo into the substrate, use \`/onboard\`."

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
exit 0
