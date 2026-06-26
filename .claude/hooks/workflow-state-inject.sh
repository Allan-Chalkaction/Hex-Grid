#!/usr/bin/env bash
# UserPromptSubmit hook: Inject current-phase instructions into context
# Matcher: (none — fires on every user message)
#
# Reads current_phase from the active run state file and injects
# ONLY that phase's instructions. Claude never sees the full sequence.
#
# Activation gating: only injects for runs explicitly started via a known
# entry mode (state file must have initiated_by field). Ad-hoc runs, one-off
# agent invocations, and sessions without a named workflow are not affected.
#
# Exit 0 always. Output JSON with hookSpecificOutput.additionalContext,
# or empty stdout to skip injection.

set -uo pipefail
# NOTE: set -e omitted. This hook must not crash on transient jq/file errors.

# infer_and_persist_migration_fields is defined in this file.
# The full function body (from Section 1) must be included here,
# above the main decision logic. It is not sourced from an external file.

# ==========================================================================
# MIGRATION FUNCTION: Infer current_phase and initiated_by for legacy state files
# ==========================================================================

infer_and_persist_migration_fields() {
  local state_file="$1"

  # --- GUARD: If current_phase already exists, this is NOT a migration.
  # Return immediately. Inference is migration-only for state files created
  # before this system existed. Once current_phase is set (by auto_create_state
  # or by a previous migration), it is authoritative and must not be overwritten
  # by inference.
  local existing_phase
  existing_phase=$(jq -r '.current_phase // empty' "$state_file")
  if [ -n "$existing_phase" ]; then
    return 0
  fi

  local track
  track=$(jq -r '.track // "nimble"' "$state_file")

  # --- Infer initiated_by from run_dir path ---
  # Legacy state files don't have initiated_by, but the run_dir path contains
  # the track marker (NIMBLE or PIPELINE). If the path matches, infer it.
  local run_dir initiated_by=""
  run_dir=$(jq -r '.run_dir // ""' "$state_file")
  case "$run_dir" in
    *-NIMBLE-*)   initiated_by="nimble" ;;
    *-PIPELINE-*) initiated_by="pipeline" ;;
    */nimble/*)   initiated_by="nimble" ;;
    */pipeline/*) initiated_by="pipeline" ;;
  esac

  # --- Infer current_phase from completed_agents ---
  local has_explore has_decomposer has_implementer
  has_explore=$(jq '[.completed_agents // [] | .[] | select(.type == "Explore")] | length' "$state_file")
  has_decomposer=$(jq '[.completed_agents // [] | .[] | select(.type == "spec-decomposer")] | length' "$state_file")
  has_implementer=$(jq '[.completed_agents // [] | .[] | select(.type == "implementer" or .type == "wave-implementer")] | length' "$state_file")

  local inferred_phase=""
  if [ "$track" = "pipeline" ]; then
    local has_cto has_pm has_arch
    has_cto=$(jq '[.completed_agents // [] | .[] | select(.type == "cto-advisor")] | length' "$state_file")
    has_pm=$(jq '[.completed_agents // [] | .[] | select(.type == "pm-spec")] | length' "$state_file")
    has_arch=$(jq '[.completed_agents // [] | .[] | select(.type == "architect-review")] | length' "$state_file")

    if [ "$has_implementer" -gt 0 ]; then inferred_phase="execute"
    elif [ "$has_decomposer" -gt 0 ]; then inferred_phase="decompose"
    elif [ "$has_arch" -gt 0 ]; then inferred_phase="decompose"
    elif [ "$has_pm" -gt 0 ]; then inferred_phase="architecture"
    elif [ "$has_cto" -gt 0 ]; then inferred_phase="spec"
    else inferred_phase="cto-gate"
    fi
  else
    # Nimble
    local has_pm
    has_pm=$(jq '[.completed_agents // [] | .[] | select(.type == "pm-spec")] | length' "$state_file")
    if [ "$has_implementer" -gt 0 ]; then inferred_phase="execute"
    elif [ "$has_decomposer" -gt 0 ]; then inferred_phase="decompose"
    elif [ "$has_pm" -gt 0 ]; then inferred_phase="decompose"
    elif [ "$has_explore" -gt 0 ]; then inferred_phase="spec"
    else inferred_phase="explore"
    fi
  fi

  # --- Persist inferred fields back to state file ---
  # This is a one-time migration write. After this, the guard at the top
  # ensures we never re-infer.
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg phase "$inferred_phase" \
     --arg initiated "$initiated_by" \
     --arg ts "$now" '
    .current_phase = $phase |
    .initiated_by = (if $initiated == "" then null else $initiated end) |
    .last_activity_at = $ts |
    .phase_history = (.phase_history // []) + [{"phase": $phase, "entered_at": $ts}]
  ' "$state_file" > "${state_file}.tmp"
  mv "${state_file}.tmp" "$state_file"
}

# ==========================================================================
# MAIN: Read state, gate on initiated_by, inject phase instructions
# ==========================================================================

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# --- Opt-in debug logging ---
# Fires on every user prompt. Unconditional appends grew hook-debug.log without
# bound (T2 cost fix). Now gated behind WORKFLOW_INJECT_DEBUG=1 (off by default).
if [ "${WORKFLOW_INJECT_DEBUG:-0}" = "1" ]; then
  HOOK_DEBUG_LOG=".claude/agent-memory/hook-debug.log"
  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) inject hook stdin:"; echo "$INPUT" | head -c 500; echo ""; echo "---"; } >> "$HOOK_DEBUG_LOG" 2>/dev/null || true
fi

USER_MESSAGE=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

if ! command -v jq &>/dev/null; then
  exit 0
fi

# --- Detect track invocation and write trigger file ---
# Sources: entry-mode slash commands (/nimble, /adhoc, /roadmap, /planner) or
# a "Track: <name>" marker in the prompt body (e.g., tickets arriving via
# Supabase bridge). We write a SESSION-SCOPED trigger file so that
# auto_create_state (which fires on prompt.md write) can tag the state file
# with initiated_by and session_id. Session-scoped to prevent concurrent
# sessions from stomping each other's files.
PENDING_DIR=".claude/agent-memory"
PENDING_FILE="${PENDING_DIR}/pending-initiation-${SESSION_ID}.json"
case "$USER_MESSAGE" in
  /nimble*|"/nimble"*|*"Track: Nimble"*|*"Track: nimble"*)
    mkdir -p "$PENDING_DIR"
    jq -n --arg initiated "nimble" --arg sid "$SESSION_ID" \
      --arg prefix "$(echo "$USER_MESSAGE" | head -c 100)" \
      '{initiated_by: $initiated, session_id: $sid, message_prefix: $prefix}' > "$PENDING_FILE"
    # Clean up legacy singleton if present
    rm -f "${PENDING_DIR}/pending-initiation.json"
    ;;
  # CHECK: adhoc advisory mode — write pending-initiation with initiated_by: "adhoc"
  /adhoc*|"/adhoc"*|*"Track: Adhoc"*|*"Track: adhoc"*)
    mkdir -p "$PENDING_DIR"
    jq -n --arg initiated "adhoc" --arg sid "$SESSION_ID" \
      --arg prefix "$(echo "$USER_MESSAGE" | head -c 100)" \
      '{initiated_by: $initiated, session_id: $sid, message_prefix: $prefix}' > "$PENDING_FILE"
    # Clean up legacy singleton if present
    rm -f "${PENDING_DIR}/pending-initiation.json"
    ;;
  # CHECK: roadmap iterative-planning mode (ADR-030) — write pending-initiation
  # with initiated_by: "roadmap". Advisor-only like adhoc, but iterative with
  # round-boundary halts. See core/rules/rules-roadmap-mode.md.
  /roadmap*|"/roadmap"*|*"Track: Roadmap"*|*"Track: roadmap"*)
    mkdir -p "$PENDING_DIR"
    jq -n --arg initiated "roadmap" --arg sid "$SESSION_ID" \
      --arg prefix "$(echo "$USER_MESSAGE" | head -c 100)" \
      '{initiated_by: $initiated, session_id: $sid, message_prefix: $prefix}' > "$PENDING_FILE"
    # Clean up legacy singleton if present
    rm -f "${PENDING_DIR}/pending-initiation.json"
    ;;
  # CHECK: planner mode (ADR-032) — write pending-initiation with initiated_by:
  # "planner". Advisor-only planning partner; never "execute". See
  # core/rules/rules-advisory-modes.md.
  /planner*|"/planner"*|*"Track: Planner"*|*"Track: planner"*)
    mkdir -p "$PENDING_DIR"
    jq -n --arg initiated "planner" --arg sid "$SESSION_ID" \
      --arg prefix "$(echo "$USER_MESSAGE" | head -c 100)" \
      '{initiated_by: $initiated, session_id: $sid, message_prefix: $prefix}' > "$PENDING_FILE"
    # Clean up legacy singleton if present
    rm -f "${PENDING_DIR}/pending-initiation.json"
    ;;
esac

# --- Load phase definitions ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASES_CONFIG="${SCRIPT_DIR}/../config/workflow-phases.json"
if [ ! -f "$PHASES_CONFIG" ]; then
  # Fallback: try relative to .claude/hooks/
  PHASES_CONFIG=".claude/config/workflow-phases.json"
fi
if [ ! -f "$PHASES_CONFIG" ]; then
  exit 0
fi

# --- Find active run state file (scoped to session_id) ---
RUNS_DIR=".claude/agent-memory/active-runs"
STATE_FILE=""

if [ -d "$RUNS_DIR" ]; then
  local_latest_mtime=0
  for candidate in "$RUNS_DIR"/*.json; do
    [[ "$candidate" == *.tmp ]] && continue
    [ -f "$candidate" ] || continue
    # Session isolation: only consider state files for this session
    if [ -n "$SESSION_ID" ]; then
      fname=$(basename "$candidate")
      case "$fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    # Skip files that aren't run state files
    jq -e '.slug' "$candidate" &>/dev/null || continue
    cand_mtime=0
    if stat -f %m "$candidate" &>/dev/null; then
      cand_mtime=$(stat -f %m "$candidate")
    else
      cand_mtime=$(stat -c %Y "$candidate" 2>/dev/null || echo "0")
    fi
    if [ "$cand_mtime" -gt "$local_latest_mtime" ] 2>/dev/null; then
      local_latest_mtime="$cand_mtime"
      STATE_FILE="$candidate"
    fi
  done
fi

# --- No state file: nothing to inject ---
if [ -z "$STATE_FILE" ]; then
  exit 0
fi

# --- Run initiation gating ---
# Only inject for runs explicitly started via a known entry mode.
# State files without initiated_by are legacy/ad-hoc — ignore them entirely.
INITIATED_BY=$(jq -r '.initiated_by // empty' "$STATE_FILE")
if [ -z "$INITIATED_BY" ]; then
  # No initiated_by field. Attempt migration for legacy state files.
  # infer_and_persist_migration_fields will set initiated_by from run_dir path
  # if possible (only runs when current_phase is unset — legacy files).
  infer_and_persist_migration_fields "$STATE_FILE"
  INITIATED_BY=$(jq -r '.initiated_by // empty' "$STATE_FILE")

  if [ -z "$INITIATED_BY" ]; then
    # Migration bailed (current_phase already set on new state files).
    # Infer directly from track/run_dir fields — same logic as migration
    # function lines 48-53, but without the current_phase guard.
    local_track=$(jq -r '.track // ""' "$STATE_FILE")
    local_run_dir=$(jq -r '.run_dir // ""' "$STATE_FILE")

    case "$local_run_dir" in
      *-NIMBLE-*)   INITIATED_BY="nimble" ;;
      */nimble/*)   INITIATED_BY="nimble" ;;
      *)
        # Fall back to track field if run_dir doesn't match
        if [ "$local_track" = "nimble" ]; then
          INITIATED_BY="$local_track"
        fi
        ;;
    esac

    if [ -n "$INITIATED_BY" ]; then
      # Persist so we don't re-infer every turn
      NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      jq --arg ib "$INITIATED_BY" --arg ts "$NOW_TS" \
        '.initiated_by = $ib | .last_activity_at = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp"
      mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
      # Truly ad-hoc run — no track signal at all
      exit 0
    fi
  fi
fi

# --- Read current phase ---
TRACK=$(jq -r '.track // "nimble"' "$STATE_FILE")
CURRENT_PHASE=$(jq -r '.current_phase // empty' "$STATE_FILE")

# If current_phase is missing, run migration inference
if [ -z "$CURRENT_PHASE" ]; then
  infer_and_persist_migration_fields "$STATE_FILE"
  CURRENT_PHASE=$(jq -r '.current_phase // empty' "$STATE_FILE")
fi

# --- Terminal state: do not inject ---
# "done" means the run completed. null/empty means no phase set.
# In both cases, do not inject — the run is not active.
if [ -z "$CURRENT_PHASE" ] || [ "$CURRENT_PHASE" = "done" ]; then
  exit 0
fi

# --- Load phase instruction from config ---
PHASE_INSTRUCTION=""
INSTRUCTION_FILE=$(jq -r --arg track "$TRACK" --arg phase "$CURRENT_PHASE" \
  '.tracks[$track].phases[$phase].instruction_file // empty' "$PHASES_CONFIG")

if [ -n "$INSTRUCTION_FILE" ]; then
  CONFIG_DIR=$(dirname "$PHASES_CONFIG")
  PHASE_INSTRUCTION=$(cat "${CONFIG_DIR}/${INSTRUCTION_FILE}" 2>/dev/null || true)
fi

# Fallback: try inline instruction field
if [ -z "$PHASE_INSTRUCTION" ]; then
  PHASE_INSTRUCTION=$(jq -r --arg track "$TRACK" --arg phase "$CURRENT_PHASE" \
    '.tracks[$track].phases[$phase].instruction // empty' "$PHASES_CONFIG")
fi

if [ -z "$PHASE_INSTRUCTION" ]; then
  # Phase not found in config — don't inject anything
  exit 0
fi

# --- Build injection context ---
SLUG=$(jq -r '.slug // ""' "$STATE_FILE")
RUN_DIR=$(jq -r '.run_dir // ""' "$STATE_FILE")
TICKET_KEY=$(jq -r '.ticket_key // ""' "$STATE_FILE")
# Orchestrated-mode phase files reference these two additional placeholders
# (V2-W0-T02). Pipeline/nimble phase files do not — the substitution is a
# no-op for tracks that don't reference them.
CURRENT_TICKET=$(jq -r '.current_ticket // ""' "$STATE_FILE")

# Variable substitution in the phase instruction
PHASE_INSTRUCTION=$(echo "$PHASE_INSTRUCTION" | sed \
  -e "s|\${slug}|${SLUG}|g" \
  -e "s|\${run_dir}|${RUN_DIR}|g" \
  -e "s|\${ticket_key}|${TICKET_KEY}|g" \
  -e "s|\${track}|${TRACK}|g" \
  -e "s|\${session_id}|${SESSION_ID}|g" \
  -e "s|\${current_ticket}|${CURRENT_TICKET}|g")

# --- Substrate path resolution (ADR-031) ---
# Phase docs are authored with claude-infra's self-relative core/ paths. At runtime in
# a consumer project the substrate is symlinked under .claude/ (setup.sh Step 3), so an
# injected command like `python3 core/scripts/wave-manifest.py ...` does not resolve
# (there is no core/ dir in a consumer). Rewrite the four command-bearing substrate
# prefixes — core/{scripts,gate-prompts,config,hooks}/ — to .claude/ in the INJECTED
# COPY ONLY; the source docs keep core/ as the single authoring source of truth.
# Consumer-only, detected by cwd: core/scripts absent AND .claude/scripts present.
# Inert in claude-infra itself (core/scripts present → guard false → no rewrite).
# Runtime-local .claude/ paths (agent-memory, agent-context, worktrees) have no core/
# form and are untouched. Prose cross-refs to core/{rules,agents,skills,commands} are an
# explicit non-goal (documentation pointers, never executed). Track-agnostic across all
# entry modes. See docs/decisions/ADR-031-substrate-path-resolution.md.
if [ ! -d core/scripts ] && [ -d .claude/scripts ]; then
  PHASE_INSTRUCTION=$(echo "$PHASE_INSTRUCTION" | sed \
    -e 's|core/scripts/|.claude/scripts/|g' \
    -e 's|core/gate-prompts/|.claude/gate-prompts/|g' \
    -e 's|core/config/|.claude/config/|g' \
    -e 's|core/hooks/|.claude/hooks/|g')
fi

# Wrap in a clear header — always injected when current_phase is active.
# No keyword suppression: if the user is course-correcting mid-phase, the
# phase context header gives Claude enough awareness to respond appropriately
# without disrupting the workflow.
#
# Both tracks are autonomous — Claude drives forward without waiting for user input.
# Genuine stop points (CTO NO-GO, architecture blockers, implementer failures) are
# handled by the phase instruction files themselves, not by the footer.
PHASE_FOOTER="Phase instructions above are authoritative. Proceed immediately to the next action as instructed — do not wait for user input."

INJECTION="WORKFLOW STATE MACHINE — PHASE: ${CURRENT_PHASE} (${TRACK} track)
Run: ${SLUG} | Dir: ${RUN_DIR} | Ticket: ${TICKET_KEY}

${PHASE_INSTRUCTION}

${PHASE_FOOTER}"

jq -n --arg ctx "$INJECTION" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
