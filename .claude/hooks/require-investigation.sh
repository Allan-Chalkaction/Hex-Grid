#!/usr/bin/env bash
# PreToolUse hook: Investigation-first floor — the FIRST enforcement backstop for
# the investigation-first discipline (core/rules/rules-implementation-discipline.md),
# which is otherwise BEHAVIORAL-only. Matches: Agent.
#
# Exit code 0 = allow
# Exit code 2 = block the action
#
# THE DETERMINISTIC-SIGNAL-ONLY CONTRACT (ADR-018 + examiner F-004):
#   This hook fires ONLY on the part of the investigation-first rule that has a
#   DETERMINISTIC, grep-verifiable signal: an IMPLEMENTER-tier dispatch on an
#   active run whose state shows ZERO prior Explore/investigation evidence. That
#   is the exact, checkable "investigation-first floor" — it mirrors the
#   completed_agents[] Explore check require-protocol.sh already does, NOT a
#   content heuristic.
#
#   The HEURISTIC classes of the rule — "this looks like scope-slip" / "this
#   prompt is ambiguous" — are FALSE-POSITIVE-PRONE (examiner F-004) and have no
#   precise signal. They are DELIBERATELY EXCLUDED from this hook and surfaced as
#   /doctor ADVISORY lint instead (infra-doctor.sh §10). A blocking hook on a
#   fuzzy signal wedges sessions and trains operators to reflexively bypass —
#   over-applying determinism is itself a named failure mode (ADR-126 D-3 sibling
#   reasoning; examiner F-004). DO NOT add a scope-slip / ambiguity block here.
#
# FAIL-OPEN: any internal error (missing file, bad JSON, jq failure, unreadable
#   state) → exit 0 (allow). A blocking hook that crashes the session is worse
#   than the rule it enforces. This is non-negotiable.
#
# BYPASS: honored FIRST, before any signal check (ADR-052 session-keyed flag),
#   exactly like the sibling gate hooks.
#
# All checks are LOCAL FILE READS — no remote services involved.

# NOTE: deliberately NOT `set -e` — a non-zero from any probe must fall through
# to the fail-open allow at the bottom, never abort the hook with an error code
# the harness could read as a block.
set -uo pipefail

# Fail-open wrapper: if anything below this point unexpectedly errors, the EXIT
# trap returns 0 (allow) rather than leaking a non-zero. Cleared right before an
# intentional exit.
trap 'exit 0' EXIT

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# jq is required to parse the deterministic signal. Absent jq → we cannot read
# the signal → FAIL-OPEN (allow). Never block on a missing tool.
if ! command -v jq &>/dev/null; then
  trap - EXIT
  exit 0
fi

SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")

# --- BYPASS CHECK (FIRST, before any signal check) -------------------------
# Session-scoped bypass flag (ADR-052): keyed to THIS session. Mirrors the exact
# read pattern in block-source-edits.sh / require-protocol.sh. Anchor to the
# project dir (hooks can fire with a drifted cwd → bypass "drops").
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
if [ -n "$SESSION_ID" ]; then
  BYPASS_FILE="$PROJECT_DIR/.claude/agent-memory/bypass-active-${SESSION_ID}.json"
  if [ -f "$BYPASS_FILE" ]; then
    BYPASS_ENABLED=$(jq -r '.enabled // false' "$BYPASS_FILE" 2>/dev/null || echo "false")
    if [ "$BYPASS_ENABLED" = "true" ]; then
      trap - EXIT
      exit 0
    fi
  fi
fi

# --- DETERMINISTIC SIGNAL: implementer-tier dispatch only ------------------
# Only implementer-tier dispatches carry the investigation-first floor. Everything
# else (Explore itself, advisors, gates, utilities, untyped) → allow. This keeps
# the hook narrow: it never fires on the very Explore agent that SATISFIES the
# floor, and never on advisor/gate work.
case "$SUBAGENT_TYPE" in
  implementer|wave-implementer) ;;   # subject to the floor — fall through
  *)
    trap - EXIT
    exit 0
    ;;
esac

# --- Locate the session's run state file (deterministic, folder-as-truth) ---
# Reuse the same session-scoped most-recent-state-file selection require-protocol.sh
# uses. If we cannot find a state file, there is no investigation ledger to read
# → FAIL-OPEN (allow). The protocol gate (require-protocol.sh CHECK 0) owns the
# "no state file" block; this hook does NOT duplicate that — it only enforces the
# Explore floor when a ledger exists.
RUNS_DIR="$PROJECT_DIR/.claude/agent-memory/active-runs"
[ -d "$RUNS_DIR" ] || RUNS_DIR=".claude/agent-memory/active-runs"
STATE_FILE=""
if [ -d "$RUNS_DIR" ]; then
  latest_mtime=0
  for candidate in "$RUNS_DIR"/*.json; do
    [[ "$candidate" == *.tmp ]] && continue
    [ -f "$candidate" ] || continue
    if [ -n "$SESSION_ID" ]; then
      fname=$(basename "$candidate")
      case "$fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    jq -e '.slug' "$candidate" >/dev/null 2>&1 || continue
    cand_mtime=0
    if stat -f %m "$candidate" &>/dev/null; then
      cand_mtime=$(stat -f %m "$candidate")
    else
      cand_mtime=$(stat -c %Y "$candidate" 2>/dev/null || echo "0")
    fi
    if [ "$cand_mtime" -gt "$latest_mtime" ] 2>/dev/null; then
      latest_mtime="$cand_mtime"
      STATE_FILE="$candidate"
    fi
  done
fi

# No state file for this session → FAIL-OPEN. (require-protocol.sh owns the
# no-state-file block; we only gate the Explore floor on an existing ledger.)
if [ -z "$STATE_FILE" ]; then
  trap - EXIT
  exit 0
fi

# --- THE FLOOR: >=1 completed Explore/investigation in the run ledger -------
# Deterministic, grep-verifiable: count completed Explore agents in the state
# file's completed_agents[]. The jq default ( // [] ) and the `|| echo 0` keep a
# malformed/absent ledger from erroring — but a malformed ledger means we cannot
# PROVE the floor was met, and the safe posture for an UNREADABLE signal is
# fail-OPEN (a blocking hook must never wedge on its own parse failure). So a jq
# miss yields count 0 only when the field is genuinely empty; a hard jq error
# falls through the trap to allow.
HAS_EXPLORE=$(jq '[.completed_agents // [] | .[] | select(.type == "Explore" or .type == "investigation")] | length' "$STATE_FILE" 2>/dev/null)
# If jq could not produce a number (hard parse error), treat as unreadable →
# fail-open. Only a CLEAN read of zero blocks.
case "$HAS_EXPLORE" in
  ''|*[!0-9]*)
    # unreadable / non-numeric → fail-open (do not wedge on a parse failure)
    trap - EXIT
    exit 0
    ;;
esac

if [ "$HAS_EXPLORE" -eq 0 ]; then
  trap - EXIT
  echo "BLOCKED: investigation-first floor (ADR-018). An implementer-tier dispatch ('${SUBAGENT_TYPE}') was attempted, but the run ledger shows ZERO completed Explore/investigation passes. Investigate before implementing: spawn at least one Explore agent to validate codebase assumptions first. (This is the deterministic floor only; the heuristic discipline classes are surfaced as /doctor advisory lint, never blocked here — examiner F-004.)" >&2
  exit 2
fi

# Floor satisfied → allow.
trap - EXIT
exit 0
