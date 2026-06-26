#!/usr/bin/env bash
# PreToolUse hook: Gate — enforce protocol before agent invocations
# Matches: Agent
#
# Exit code 0 = allow
# Exit code 2 = block the action
#
# Three agent tiers:
#   STATELESS (Explore, Plan) — always allowed, zero checks
#   PHASE (cto-advisor, pm-spec, gates, utilities) — CHECK 0 + phase boundary
#   IMPLEMENTER (implementer, wave-implementer) — all checks
#
# PHASE BOUNDARY ENFORCEMENT (phase-tier agents):
# Phase-tier agents are only allowed if they belong to the current phase.
# This is a v1-phase-machine guard (relevant to the dormant pipeline track).
#
# IMPLEMENTER GATING — v2 alignment (ADR-085 D1):
# For the live v2 engine tracks {nimble, orchestrated, chain} the Workflow
# script IS the sequencing authority (ADR-039) — there is no phase machine to
# advance current_phase off "setup", and the thin run-manifest.json does not
# exist on disk until the post-run persist. So for these tracks the implementer
# gate is CHECK 0 (state file exists) + CHECK 5 (>=1 completed Explore) ONLY.
# CHECK 0b (the v1 phase whitelist) and the v1 per-ticket invariants
# (wave-manifest existence, in-progress ticket) are SCOPED OUT for engine tracks
# and retained verbatim ONLY for the dormant v1 pipeline) arm.
#
# All checks are LOCAL FILE READS — no remote services involved.
# State files are auto-created by the PostToolUse observer hook on prompt.md write.

set -uo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# Extract subagent_type and session_id from Agent tool input
SUBAGENT_TYPE=""
SESSION_ID=""
if command -v jq &> /dev/null; then
  SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

# --- Agent classification ---
AGENT_TIER="implementer"  # Default: full enforcement

case "$SUBAGENT_TYPE" in
  # Stateless — always allowed, zero checks
  Explore|Plan|claude-code-guide|statusline-setup)
    exit 0
    ;;
  # Phase agents — need state file but not full enforcement
  cto-advisor|pm-spec|architect-review|ui-spec|spec-decomposer|spec-conformance)
    AGENT_TIER="phase"
    ;;
  ui-review|code-reviewer|security-auditor|accessibility-auditor|performance-reviewer|db-migration-reviewer|dependency-auditor|smoke-tester|merge-conflict-scanner)
    AGENT_TIER="phase"
    ;;
  resolver|session-logger|docs-writer|smart-commit|adr-scanner|environment-validator)
    AGENT_TIER="phase"
    ;;
  # General-purpose dispatch, or no subagent_type — treat as phase-tier
  # (state-file required, but NOT full implementer-tier execute-phase enforcement).
  # general-purpose is a generic worker the orchestrator uses for research/search;
  # gating it as implementer-tier (the prior default) would have blocked it without
  # bypass even though it does no privileged plan-step work (SH-1 C2).
  general-purpose|"")
    AGENT_TIER="phase"
    ;;
esac

# --- BYPASS CHECK: skip all protocol gating if bypass mode is active ---
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

# --- CHECK 0: State file must exist (all non-stateless agents) ---
# The observer hook auto-creates this when prompt.md is written.
# If it doesn't exist, the orchestrator hasn't written prompt.md yet.

RUNS_DIR=".claude/agent-memory/active-runs"
STATE_FILE=""

if [ -d "$RUNS_DIR" ]; then
  # Pick the most recently modified state file (scoped to session_id)
  local_latest_mtime=0
  for candidate in "$RUNS_DIR"/*.json; do
    [[ "$candidate" == *.tmp ]] && continue
    [ -f "$candidate" ] || continue
    # Session isolation
    if [ -n "$SESSION_ID" ]; then
      fname=$(basename "$candidate")
      case "$fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    # Skip files that aren't run state files
    jq -e '.slug' "$candidate" >/dev/null 2>&1 || continue
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

if [ -z "$STATE_FILE" ]; then
  echo "BLOCKED: No run state file found. The orchestrator must create a run folder and write prompt.md first — the observer hook auto-creates the state file from that. Follow the skill protocol: create run folder → write {run_dir}/prompt.md with the ticket key." >&2
  exit 2
fi

# --- PHASE BOUNDARY CHECK (phase-tier agents) ---
# Only allow phase agents that belong to the current phase.
# This is the hook enforcement that prevents mid-turn phase skipping.
if [ "$AGENT_TIER" = "phase" ]; then
  CURRENT_PHASE=""
  if command -v jq &>/dev/null; then
    CURRENT_PHASE=$(jq -r '.current_phase // empty' "$STATE_FILE" 2>/dev/null)
  fi

  # Unreadable/empty current_phase. We are already past CHECK 0, so a state file
  # IS present — i.e. this is an ACTIVE run with malformed/unreadable phase. Per
  # the ADR-018 posture ("absent/malformed → fail closed to crit-1"), fail CLOSED
  # here rather than fail-open. The genuine non-workflow case (no state file at
  # all) was already handled by CHECK 0 above, which blocks before we reach here,
  # so there is no legitimate fail-open path left at this point (SH-1 H9).
  if [ -z "$CURRENT_PHASE" ]; then
    echo "BLOCKED: active run state file present but current_phase is unreadable/empty (${STATE_FILE}). Malformed run state — fail closed (ADR-018). Repair or remove the state file before dispatching agents." >&2
    exit 2
  fi

  # Map: which agents are allowed in which phase?
  ALLOWED=false
  case "$CURRENT_PHASE" in
    setup)
      # No agents during setup — only prompt.md write
      ;;
    explore)
      # Explore is stateless tier (already allowed above). No phase agents in explore.
      ;;
    cto-gate)
      case "$SUBAGENT_TYPE" in cto-advisor) ALLOWED=true ;; esac
      ;;
    spec)
      case "$SUBAGENT_TYPE" in pm-spec) ALLOWED=true ;; esac
      ;;
    architecture)
      case "$SUBAGENT_TYPE" in architect-review) ALLOWED=true ;; esac
      ;;
    ui-spec)
      case "$SUBAGENT_TYPE" in ui-spec) ALLOWED=true ;; esac
      ;;
    decompose)
      case "$SUBAGENT_TYPE" in spec-decomposer|ui-spec) ALLOWED=true ;; esac
      ;;
    execute)
      # Phase agents that run during execute: quality gates, reviews,
      # and the in-loop per-step conformance gate (INFRA-001).
      # spec-conformance was added here when V2-W0-T01 reclassified it to
      # phase-tier; pipeline runs invoke it during execute via the inner
      # loop's Step 4b.
      case "$SUBAGENT_TYPE" in
        ui-review|code-reviewer|security-auditor|accessibility-auditor|performance-reviewer|db-migration-reviewer|dependency-auditor|smoke-tester|e2e-test-writer|spec-conformance)
          ALLOWED=true ;;
      esac
      ;;
    wrapup)
      case "$SUBAGENT_TYPE" in session-logger) ALLOWED=true ;; esac
      ;;
    # Orchestrated-mode phases (ADR-008). Each maps to allowed phase-tier agents
    # per the Phase Advancement Map. Implementer-tier phases (t-implement,
    # t-remediate) intentionally do nothing here — the implementer block below
    # gates them via the orchestrated) track arm.
    w-setup)        case "$SUBAGENT_TYPE" in cto-advisor|ui-spec) ALLOWED=true ;; esac ;;
    t-cto)          case "$SUBAGENT_TYPE" in cto-advisor) ALLOWED=true ;; esac ;;
    t-spec)         case "$SUBAGENT_TYPE" in pm-spec) ALLOWED=true ;; esac ;;
    t-consensus)    case "$SUBAGENT_TYPE" in cto-advisor) ALLOWED=true ;; esac ;;
    t-implement)    ;;  # implementer-tier; falls through to implementer block below
    t-validate)     case "$SUBAGENT_TYPE" in spec-conformance) ALLOWED=true ;; esac ;;
    t-review)       case "$SUBAGENT_TYPE" in code-reviewer) ALLOWED=true ;; esac ;;
    t-remediate)    ;;  # implementer-tier
    t-commit)       case "$SUBAGENT_TYPE" in smart-commit) ALLOWED=true ;; esac ;;
    w-finalize)     case "$SUBAGENT_TYPE" in security-auditor|db-migration-reviewer|accessibility-auditor|performance-reviewer|ui-review|code-reviewer|dependency-auditor|architect-review|spec-conformance) ALLOWED=true ;; esac ;;  # spec-conformance added for the v3 wave-end post-impl trio (ADR-026 / INFRA-028 — w-finalize.md Step 4a dispatches it at wave-end)
    # advisory: adhoc mode — all phase-tier agents are allowed (same as catchall,
    # but explicit for auditability, greppability, and self-documentation)
    advisory)
      ALLOWED=true
      ;;
    # round-loop: roadmap mode (ADR-030) — advisor funnel runs freely
    # (cto-advisor → architect-review → ui-spec → pm-spec for Phase W; research
    # Explore agents + cto-advisor for Phase E). Explicit for auditability,
    # mirroring the advisory) case above. Implementers blocked via the
    # roadmap) track arm below.
    round-loop)
      ALLOWED=true
      ;;
    # planner-loop: planner mode (ADR-032) — advisor-only planning partner. All
    # phase-tier agents pass (the planner routes into /research, /roadmap,
    # feature-decomposition, adr, and the advisor agents). Implementers blocked via
    # the planner) track arm below. Explicit for auditability, mirroring round-loop).
    planner-loop)
      ALLOWED=true
      ;;
    *)
      # Unknown phase or utility agents — allow
      ALLOWED=true
      ;;
  esac

  # Utility agents that are phase-independent (no subagent_type, or general tools).
  # general-purpose is phase-independent like the untyped case: a state file is
  # required (CHECK 0 above) but it is not pinned to a specific phase (SH-1 C2).
  case "$SUBAGENT_TYPE" in
    ""|general-purpose|resolver|docs-writer|smart-commit|adr-scanner|environment-validator)
      ALLOWED=true ;;
  esac

  if [ "$ALLOWED" = false ]; then
    echo "BLOCKED: Agent '${SUBAGENT_TYPE}' is not allowed during the '${CURRENT_PHASE}' phase. Complete the current phase first, then stop — the state machine advances your phase on the next user message." >&2
    exit 2
  fi

  exit 0
fi

# ==========================================================================
# IMPLEMENTER-ONLY CHECKS (below)
# ==========================================================================

if ! command -v jq &> /dev/null; then
  echo "BLOCKED: jq is required for implementer checks." >&2
  exit 2
fi

# Read $TRACK from the state file (already verified to exist by CHECK 0 above).
# The track read happens BEFORE CHECK 0b so 0b can be scoped to the dormant v1
# pipeline track only (ADR-085 D1) — v2 engine tracks have no phase machine to
# satisfy the v1 phase whitelist.
TRACK=$(jq -r '.track // empty' "$STATE_FILE" 2>/dev/null)

# --- CHECK 0b: v1 phase whitelist (pipeline track ONLY) ---
# In the dormant v1 pipeline track the phase machine advances current_phase to
# 'execute' before an implementer may run. Under v2 (nimble/orchestrated/chain)
# the Workflow script is the sequencing authority (ADR-039); current_phase is
# fossilized at "setup" (the phase machine that advanced it was deleted,
# ADR-079), so applying this whitelist would block EVERY non-bypass engine run
# (ADR-085 D1). Scope it out for the engine tracks; keep it byte-identical in
# effect for pipeline).
case "$TRACK" in
  pipeline)
    # dormant-by-design (ADR-080 D4): no live door writes track=pipeline; this is the
    # only arm where the v1 CHECK 0b phase whitelist still applies (ADR-085 D1).
    IMPL_PHASE=$(jq -r '.current_phase // empty' "$STATE_FILE" 2>/dev/null)
    if [ -n "$IMPL_PHASE" ] && [ "$IMPL_PHASE" != "execute" ] && [ "$IMPL_PHASE" != "t-implement" ] && [ "$IMPL_PHASE" != "t-remediate" ]; then
      echo "BLOCKED: Implementers are only allowed during the 'execute' phase (current: '${IMPL_PHASE}'). Complete the current phase first, then stop — the state machine advances your phase on the next user message." >&2
      exit 2
    fi
    ;;
esac

# --- TRACK-AWARE IMPLEMENTER CHECKS ---
# Branch the per-track protocol enforcement:
#   pipeline → dormant v1: Explore (CHECK 5) + spec-decomposer (CHECK 4) +
#              active plan step (CHECK 3) — byte-for-byte preserved.
#   nimble | orchestrated | chain → v2 engine tracks: state file (CHECK 0,
#              above) + >=1 completed Explore (CHECK 5) ONLY (ADR-085 D1). The
#              Workflow script is the sequencing authority; no decompose phase,
#              no plan-steps.json, no wave-manifest, no in-progress ticket at
#              dispatch time (one-implementer-per-wave, ADR-062/063 — the
#              manifest is written post-run via persist, ADR-039 contract 2).
#   *        → fail loud. State file present but $TRACK is unset, null, or
#              unrecognized. Refuse to gate rather than silently mis-gate.

case "$TRACK" in
  pipeline)
    # dormant-by-design (ADR-080 D4): no live door writes this track; shrink pass deferred
    # CHECK 5: At least one Explore agent must have completed
    HAS_EXPLORE=$(jq '[.completed_agents // [] | .[] | select(.type == "Explore")] | length' "$STATE_FILE" 2>/dev/null || echo "0")
    if [ "$HAS_EXPLORE" = "0" ]; then
      echo "BLOCKED: No Explore agent has completed for this run. Step 1: spawn 1-3 Explore subagents to validate codebase assumptions before any other work." >&2
      exit 2
    fi

    # CHECK 4: spec-decomposer must have completed
    # (The decomposer includes a built-in verification pass — no separate verifier needed.)
    HAS_DECOMPOSER=$(jq '[.completed_agents // [] | .[] | select(.type == "spec-decomposer")] | length' "$STATE_FILE" 2>/dev/null || echo "0")
    if [ "$HAS_DECOMPOSER" = "0" ]; then
      echo "BLOCKED: spec-decomposer has not completed. Invoke spec-decomposer to produce plan steps (includes built-in verification). The observer hook writes plan-steps.json in the run folder from the decomposer's output." >&2
      exit 2
    fi

    # CHECK 3: Active plan step must exist in {run_dir}/plan-steps.json
    # The observer hook writes plan-steps.json when spec-decomposer completes.
    # The orchestrator marks the next step active by editing the file in-place
    # (jq mutation flipping a step's status from "pending" to "active").
    RUN_DIR=$(jq -r '.run_dir // empty' "$STATE_FILE" 2>/dev/null)
    if [ -z "$RUN_DIR" ] || [ "$RUN_DIR" = "null" ]; then
      echo "BLOCKED: state file has no run_dir. Re-write prompt.md to a run folder so the observer hook can repopulate state." >&2
      exit 2
    fi
    PLAN_STEPS_FILE="${RUN_DIR}/plan-steps.json"
    if [ ! -f "$PLAN_STEPS_FILE" ]; then
      echo "BLOCKED: ${PLAN_STEPS_FILE} does not exist. The observer hook writes it from spec-decomposer output — re-run spec-decomposer if it completed without producing parseable JSON." >&2
      exit 2
    fi
    ACTIVE_COUNT=$(jq '[.steps // [] | .[] | select(.status == "active")] | length' "$PLAN_STEPS_FILE" 2>/dev/null || echo "0")
    if [ "$ACTIVE_COUNT" = "0" ]; then
      echo "BLOCKED: No active plan step in ${PLAN_STEPS_FILE}. Step 3: mark the next pending step active before invoking an implementer. Example: jq '(.steps[] | select(.step_number == 1) | .status) = \"active\"' ${PLAN_STEPS_FILE} > ${PLAN_STEPS_FILE}.tmp && mv ${PLAN_STEPS_FILE}.tmp ${PLAN_STEPS_FILE}" >&2
      exit 2
    fi
    ;;

  # nimble | orchestrated | chain — the v2 engine tracks (ADR-039/085 D1).
  # Single shared gate: CHECK 5 (>=1 completed Explore) only. The Workflow
  # script is the sequencing authority, so there is no decompose phase
  # (CHECK 4), no plan-steps.json (CHECK 3), no wave-manifest existence check,
  # and no in-progress-ticket invariant — those were v1 per-ticket machinery
  # and the one-implementer-per-wave model (ADR-062/063) has no per-ticket
  # status at dispatch time; the manifest is written post-run via persist
  # (ADR-039 contract 2).
  nimble|orchestrated|chain)
    HAS_EXPLORE=$(jq '[.completed_agents // [] | .[] | select(.type == "Explore")] | length' "$STATE_FILE" 2>/dev/null || echo "0")
    if [ "$HAS_EXPLORE" = "0" ]; then
      echo "BLOCKED: No Explore agent has completed for this run. Step 1: spawn 1-3 Explore subagents to validate codebase assumptions before any other work." >&2
      exit 2
    fi
    ;;

  # adhoc: advisor-only mode — implementer-tier agents are never allowed.
  # Phase-boundary check above already allows phase-tier agents via advisory).
  # CHECK 0b no longer guards these arms (it is scoped to pipeline) — ADR-085 D1),
  # so this arm is now the primary block for an implementer-tier dispatch in
  # advisor-only mode, not just defense-in-depth.
  adhoc)
    # dormant-by-design (ADR-080 D4): no live door writes this track; shrink pass deferred
    echo "BLOCKED: Adhoc mode is advisor-only. To implement, run \`/nimble\` or \`/orchestrated\`." >&2
    exit 2
    ;;

  # roadmap: iterative-planning mode (ADR-030). Advisor-only, like adhoc — it
  # plans waves/specs, it does not build them. This arm is the block for an
  # implementer-tier dispatch in roadmap mode (CHECK 0b is scoped to pipeline
  # now — ADR-085 D1), with a mode-specific message, mirroring adhoc).
  roadmap)
    echo "BLOCKED: Roadmap mode is advisor-only (iterative planning). The wave spec it produces is built by \`/orchestrated <slug>\`. To implement now, run \`/roadmap off\` then \`/nimble\` or \`/orchestrated\`." >&2
    exit 2
    ;;

  # planner: planning-partner mode (ADR-032). Advisor-only, like adhoc/roadmap — it
  # drafts plans/specs/prompts, it does not build them. This arm is the block for
  # an implementer-tier dispatch in planner mode (CHECK 0b is scoped to pipeline
  # now — ADR-085 D1), with a mode-specific message.
  planner)
    echo "BLOCKED: Planner mode is advisor-only. The planner drafts artifacts; it does not implement. To build, run \`/planner off\` then \`/nimble\`, \`/chain\`, or \`/orchestrated <slug>\`." >&2
    exit 2
    ;;

  *)
    echo "BLOCKED: \$TRACK is unset or unrecognized in the state file (got: '${TRACK:-<empty>}'). Cannot determine which protocol checks to apply for this dispatch. Fix the state file at ${STATE_FILE} to set track to one of: nimble, orchestrated, chain (v2 engine) or pipeline (dormant v1)." >&2
    exit 2
    ;;
esac

# All checks passed
exit 0
