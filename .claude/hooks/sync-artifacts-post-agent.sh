#!/usr/bin/env bash
# PostToolUse hook: Observer + local state manager
# Matcher: Agent|Write
# Event: PostToolUse
#
# This hook observes the orchestrator's natural actions and manages all run
# state automatically. The LLM never writes state files — this hook creates
# and updates them on disk.
#
# Two responsibilities (the v1 LOCAL PLAN STEPS arm was retired with the phase
# state machine — ADR-079 D3; plan-steps.json has no reader in any surviving track):
#   1. AUTO-STATE      — On prompt.md write, auto-create the run state file
#   2. AGENT TRACKING  — On Agent completion, append to completed_agents
#
# All state lives on the local filesystem. There is no remote sync.
# Exit 0 always — this hook is advisory and never blocks.
#
# Concurrency safety (INFRA-007): under wave-mode parallel Agent dispatch,
# multiple PostToolUse fires can occur near-simultaneously, all racing to
# read-modify-write the same state file's `completed_agents` array (and
# `last_activity_at` field). Without serialization, updates are lost.
# We use a portable mkdir-based mutex (atomic on POSIX filesystems) — flock
# is not available by default on macOS Darwin. Lock granularity is per-state-
# file: different runs do not block each other.

set -uo pipefail
# NOTE: set -e is intentionally omitted. This hook is advisory and must
# always exit 0. Individual command failures are handled inline.

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

if ! command -v jq &>/dev/null; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# --- Ensure active-runs dir exists ---
RUNS_DIR=".claude/agent-memory/active-runs"
mkdir -p "$RUNS_DIR"

# --- recovery_log helper (Phase 1 A4 fail-open audit) ---
# Append a single dated line to ${run_dir}/recovery-log.md when the hook
# encounters a fail-open arm that previously silently no-op'd. The hook
# continues to exit 0 (advisory contract preserved); this helper makes
# silent failures durable and queryable.
sync_recovery_log() {
  local rd="$1" ctx="$2" detail="${3:-}"
  [ -z "$rd" ] && return 0
  [ ! -d "$rd" ] && return 0
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s [%s] %s\n' "$ts" "$ctx" "$detail" \
    >> "$rd/recovery-log.md" 2>/dev/null || true
}

# ==========================================================================
# CONCURRENCY LOCK: Serialize read-modify-write of state files (INFRA-007)
# ==========================================================================
#
# Kept deliberately (ADR-079 K2): the mkdir-mutex stays because it is cheap and
# `/launch` multi-session fleets — plus any future parallel dispatch — make a
# serialized read-modify-write the safer default for the auto-state and
# completed_agents updates below.
#
# Acquire an exclusive lock on a state file using a mkdir-based mutex.
# Returns 0 on success, 1 on timeout (after ~5 seconds with stale-lock
# fallback). The caller MUST release the lock with release_state_lock when
# done; if acquire returns 1, the caller should skip the update rather than
# risk corrupting the state file.
#
# This protects the read-modify-write cycles in track_agent_completion and
# the last_activity_at update loop from racing under wave-mode parallel
# Agent dispatch. The acquire+release pair is per-state-file so different
# runs don't block each other.

acquire_state_lock() {
  local state_file="$1"
  local lock_dir="${state_file}.lock"
  local max_wait=50  # 50 attempts × 0.1s = 5s before stale-lock fallback
  local i=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -ge "$max_wait" ]; then
      # Stale-lock fallback: a prior hook may have crashed leaving an
      # orphaned lock dir. Remove it and retry once. Cost of false-positive
      # (stomping on a real concurrent holder) is bounded — the holder's
      # write is still atomic per the printf > pattern.
      rm -rf "$lock_dir"
      mkdir "$lock_dir" 2>/dev/null && return 0
      return 1
    fi
    sleep 0.1
  done
  return 0
}

release_state_lock() {
  local state_file="$1"
  rm -rf "${state_file}.lock"
}

# ==========================================================================
# AUTO-STATE: Detect prompt.md write and create state file automatically
# ==========================================================================

auto_create_state() {
  # Return values (Phase 1 A4 — distinguish not-applicable from real-failure):
  #   0 — state file was created successfully
  #   1 — not applicable (this Write isn't a state-creating prompt.md or sentinel write)
  #   2 — applicable but autostate FAILED (real bug; caller should fail-loud)
  local written_path="$1"

  local filename
  filename=$(basename "$written_path")

  # Trigger detection — two shapes, both routed into the same state-creation block:
  #   (a) prompt.md inside docs/step-5-pipeline/YYYY-MM-DD/HHMM-TRACK-slug/   (canonical)
  #   (b) .planner-jam-active sentinel inside docs/step-2-planning/jam-<topic>/  (T-007 sentinel-state-write
  #       per ADR-049 follow-up; no dated pipeline folder, the jam workspace IS the run_dir).
  # Anything else: return 1 (not applicable).
  local track=""
  local slug=""
  local run_dir=""

  if [ "$filename" = ".planner-jam-active" ]; then
    # Sentinel-state-write arm (ADR-049 follow-up — T-007). Security posture (mirror the
    # block-source-edits-planner.sh jam carve-out): anchor on docs/{step-2-planning,planning}/jam-,
    # refuse path-traversal (any `..`), refuse absolute paths once CWD-stripped.
    local sentinel_dir_abs
    sentinel_dir_abs=$(dirname "$written_path")
    run_dir="${sentinel_dir_abs#$PWD/}"
    if [ "$run_dir" = "$sentinel_dir_abs" ]; then
      run_dir="$sentinel_dir_abs"
    fi
    # Refuse path traversal or an absolute path (a leading `/` would survive a CWD-strip
    # only if the file lived outside the project root — refuse that, this hook is project-local).
    case "$run_dir" in
      *..* )   return 1 ;;
      /* )     return 1 ;;
    esac
    # Must anchor on a jam workspace directory. Accept the post-Wave-B path
    # (docs/step-2-planning/jam-<topic>/) AND the legacy pre-Wave-B path (docs/planning/jam-<topic>/);
    # both are inside the security carve-out of ADR-049.
    case "$run_dir" in
      docs/step-2-planning/jam-*) ;;
      docs/planning/jam-*) ;;
      *) return 1 ;;
    esac
    local jam_folder
    jam_folder=$(basename "$run_dir")
    # jam_folder is `jam-<topic>`; refuse if topic is empty or contains a path separator.
    case "$jam_folder" in
      jam-*/*|jam-) return 1 ;;
      jam-*) ;;
      *) return 1 ;;
    esac
    local topic="${jam_folder#jam-}"
    # The slug is HHMM-planner-jam-<topic> so the state file is uniquely named even if the
    # same topic is reopened in a fresh session.
    local hhmm
    hhmm=$(date +%H%M)
    track="planner"
    slug="${hhmm}-planner-jam-${topic}"
    # folder_name is referenced in the error-log path below; set it to a sensible value for
    # diagnostics if the downstream slug/track empty-check were ever to fire (it won't here —
    # both are populated — but the variable must be defined for the log message to render).
    local folder_name="$jam_folder"
  else
    # Non-sentinel arm: must be a prompt.md write into a dated run folder.
    if [ "$filename" != "prompt.md" ]; then
      return 1
    fi

    # Check path matches run folder pattern:
    #   docs/step-5-pipeline/YYYY-MM-DD/HHMM-TRACK-slug/prompt.md   (canonical)
    #   docs/nimble/YYYY-MM-DD/HHMM-slug/prompt.md           (alternate)
    #   docs/step-5-pipeline/YYYY-MM-DD/HHMM-slug/prompt.md         (alternate)
    local run_dir_abs
    run_dir_abs=$(dirname "$written_path")
    # Convert to relative path for state file (strip CWD prefix)
    run_dir="${run_dir_abs#$PWD/}"
    if [ "$run_dir" = "$run_dir_abs" ]; then
      run_dir="$run_dir_abs"
    fi
    local folder_name
    folder_name=$(basename "$run_dir")

    # Validate structure: folder should start with HHMM (4 digits)
    case "$folder_name" in
      [0-9][0-9][0-9][0-9]-*) ;;
      *) return 1 ;;
    esac

    # Orchestrated-mode ticket subfolder: do NOT autostate.
    # The wave-level state file owns the run. Ticket subfolders
    # are written by the orchestrator skill, not by autostate.
    case "$run_dir" in
      *-WAVE-*/tickets/*) return 1 ;;
    esac

    # Extract track — from folder name if present, otherwise from ancestor path
    case "$folder_name" in
      *-NIMBLE-*)   track="nimble" ;;
      *-PIPELINE-*) track="pipeline" ;;
      *-ADHOC-*)    track="adhoc" ;;
      *-ROADMAP-*)  track="roadmap" ;;
      *-PLANNER-*)  track="planner" ;;
      *-WAVE-*)     track="orchestrated" ;;
      *)
        case "$run_dir" in
          */nimble/*)   track="nimble" ;;
          */pipeline/*) track="pipeline" ;;
          *)            track="nimble" ;;
        esac
        ;;
    esac

    # Extract slug: strip the TRACK marker, keep the HHMM timestamp prefix.
    case "$folder_name" in
      ????-NIMBLE-*)   slug="${folder_name//-NIMBLE/}" ;;
      ????-PIPELINE-*) slug="${folder_name//-PIPELINE/}" ;;
      ????-ADHOC-*)    slug="${folder_name//-ADHOC/}" ;;
      ????-ROADMAP-*)  slug="${folder_name//-ROADMAP/}" ;;
      ????-PLANNER-*)  slug="${folder_name//-PLANNER/}" ;;
      ????-WAVE-*)     slug="${folder_name//-WAVE/}" ;;
      ????-*)          slug="${folder_name#????-}" ;;
    esac
  fi

  if [ -z "$slug" ] || [ -z "$track" ]; then
    # We matched the prompt.md + HHMM-prefix preconditions but couldn't
    # derive slug/track. This is a structural failure (folder convention
    # broken). Surface as return 2 so the caller fails loud rather than
    # silently no-op'ing the state-file creation.
    sync_recovery_log "$run_dir" "sync:auto-create-state:slug-derivation-failed" "folder_name=${folder_name}; slug=${slug:-<empty>}; track=${track:-<empty>}; run_dir=${run_dir}"
    return 2
  fi

  # --- Run transition: clean up state files for THIS session's previous runs ---
  local effective_sid="$SESSION_ID"

  for existing in "$RUNS_DIR"/*.json; do
    [[ "$existing" == *.tmp ]] && continue
    [ -f "$existing" ] || continue
    local existing_fname
    existing_fname=$(basename "$existing")
    if [ -n "$effective_sid" ]; then
      case "$existing_fname" in "${effective_sid}-"*) ;; *) continue ;; esac
    fi
    local expected_name="${effective_sid}-${slug}.json"
    if [ -n "$effective_sid" ] && [ "$existing_fname" != "$expected_name" ]; then
      rm -f "$existing"
    elif [ -z "$effective_sid" ] && [ "$existing_fname" != "${slug}.json" ]; then
      rm -f "$existing"
    fi
  done

  # --- Extract ticket key from prompt.md content (freeform string label) ---
  local ticket_key=""
  if [ -f "$written_path" ]; then
    ticket_key=$(grep -oE '[A-Z]{2,4}-[0-9]{1,4}' "$written_path" 2>/dev/null | head -1 || true)
  fi

  # --- Read pending-initiation trigger file (written by workflow-state-inject.sh) ---
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local initiated_by=""
  local state_sid=""
  local pending_file=".claude/agent-memory/pending-initiation-${SESSION_ID}.json"
  if [ -f "$pending_file" ]; then
    initiated_by=$(jq -r '.initiated_by // empty' "$pending_file" 2>/dev/null)
    state_sid=$(jq -r '.session_id // empty' "$pending_file" 2>/dev/null)
    rm -f "$pending_file"
  else
    local legacy_pending=".claude/agent-memory/pending-initiation.json"
    if [ -f "$legacy_pending" ]; then
      local legacy_sid
      legacy_sid=$(jq -r '.session_id // empty' "$legacy_pending" 2>/dev/null)
      if [ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]; then
        initiated_by=$(jq -r '.initiated_by // empty' "$legacy_pending" 2>/dev/null)
        state_sid=$(jq -r '.session_id // empty' "$legacy_pending" 2>/dev/null)
        rm -f "$legacy_pending"
      fi
    fi
  fi
  # Fallback: infer initiated_by from track (derived from run_dir path)
  if [ -z "$initiated_by" ] && [ -n "$track" ]; then
    initiated_by="$track"
  fi
  if [ -z "$state_sid" ]; then
    state_sid="$SESSION_ID"
  fi

  # --- Write state file (atomic: write tmp then move) ---
  # Determine initial phase: adhoc starts in "advisory"; roadmap starts in
  # "round-loop" (ADR-030 — iterative planning, never "setup", so the
  # advance-workflow-phase setup→next handler never fires); all others "setup".
  local initial_phase="setup"
  if [ "$track" = "adhoc" ]; then
    initial_phase="advisory"
  elif [ "$track" = "roadmap" ]; then
    initial_phase="round-loop"
  elif [ "$track" = "planner" ]; then
    initial_phase="planner-loop"
  fi

  local state_content
  state_content=$(jq -n \
    --arg ticket_key "$ticket_key" \
    --arg run_dir "$run_dir" \
    --arg slug "$slug" \
    --arg track "$track" \
    --arg created_at "$now" \
    --arg initiated_by "$initiated_by" \
    --arg session_id "$state_sid" \
    --arg initial_phase "$initial_phase" \
    '{
      ticket_key: $ticket_key,
      run_dir: $run_dir,
      slug: $slug,
      track: $track,
      session_id: (if $session_id == "" then null else $session_id end),
      created_at: $created_at,
      last_activity_at: $created_at,
      current_phase: $initial_phase,
      initiated_by: (if $initiated_by == "" then null else $initiated_by end),
      completed_agents: []
    }')

  local state_path
  if [ -n "$state_sid" ]; then
    state_path="$RUNS_DIR/${state_sid}-${slug}.json"
  else
    state_path="$RUNS_DIR/${slug}.json"
  fi
  printf '%s\n' "$state_content" > "${state_path}.tmp"
  mv "${state_path}.tmp" "$state_path"

  # --- Clean up orphaned pending-initiation files older than 1 hour ---
  local pending_dir=".claude/agent-memory"
  for orphan in "$pending_dir"/pending-initiation-*.json; do
    [ -f "$orphan" ] || continue
    local orphan_mtime=0
    if stat -f %m "$orphan" &>/dev/null; then
      orphan_mtime=$(stat -f %m "$orphan")
    else
      orphan_mtime=$(stat -c %Y "$orphan" 2>/dev/null || echo "0")
    fi
    local now_epoch
    now_epoch=$(date +%s)
    local age=$(( now_epoch - orphan_mtime ))
    if [ "$age" -gt 3600 ]; then
      rm -f "$orphan"
    fi
  done

  return 0
}

# ==========================================================================
# AGENT TRACKING: Append to completed_agents on Agent completion
# ==========================================================================

track_agent_completion() {
  local agent_type="$1"

  if [ -z "$agent_type" ] || [ "$agent_type" = "null" ]; then
    return 0
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local latest_file=""
  local latest_mtime=0
  for state_file in "$RUNS_DIR"/*.json; do
    [[ "$state_file" == *.tmp ]] && continue
    [ -f "$state_file" ] || continue
    if [ -n "$SESSION_ID" ]; then
      local _tf
      _tf=$(basename "$state_file")
      case "$_tf" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    jq -e '.slug' "$state_file" &>/dev/null || continue
    local mtime
    if stat -f %m "$state_file" &>/dev/null; then
      mtime=$(stat -f %m "$state_file")
    else
      mtime=$(stat -c %Y "$state_file")
    fi
    if [ "$mtime" -gt "$latest_mtime" ] 2>/dev/null; then
      latest_mtime="$mtime"
      latest_file="$state_file"
    fi
  done

  if [ -n "$latest_file" ]; then
    # INFRA-007: serialize the read-modify-write so parallel Agent
    # completions don't lose updates to completed_agents.
    if acquire_state_lock "$latest_file"; then
      local updated
      updated=$(jq \
        --arg agent "$agent_type" \
        --arg ts "$now" \
        '.completed_agents += [{"type": $agent, "at": $ts}] | .last_activity_at = $ts' \
        "$latest_file" 2>/dev/null) || true
      if [ -n "$updated" ]; then
        printf '%s\n' "$updated" > "$latest_file"
      else
        # Phase 1 A4: jq update produced empty output; existing state file
        # is preserved (we don't overwrite with an empty string), but the
        # agent completion is silently dropped. Log to recovery-log.md so
        # the failure is durable.
        local _state_run_dir
        _state_run_dir=$(jq -r '.run_dir // empty' "$latest_file" 2>/dev/null)
        sync_recovery_log "$_state_run_dir" "sync:track-agent-completion:jq-update-empty" "agent_type=${agent_type}; state file ${latest_file} preserved; completion entry dropped (this fire only — next Agent fire will record its own entry)"
      fi
      release_state_lock "$latest_file"
    fi
    # Lock-acquire timeout: skip the update rather than corrupt the file.
    # On the next Agent completion, the latest fire's update will succeed
    # and the missed entry will be lost — acceptable cost vs corruption.
  fi
}

# ==========================================================================
# REPORT-CLASS CAPTURE (ADR-080 D2 — amends ADR-050)
# ==========================================================================
#
# ADR-050's auto-scaffold ("when a report-class agent runs off-engine, scaffold
# an AUDIT folder and persist its findings before acting") was model-remembered.
# It becomes a deterministic PostToolUse arm here: on Agent completion where
#   (a) the agent type ∈ the report-class list,
#   (b) NO active-run state file exists for this session (off-engine — engine
#       runs already persist via persist-run-artifacts.py), and
#   (c) the agent's final text is non-trivial (> a small floor),
# scaffold docs/step-5-pipeline/<date>/<HHMM>-AUDIT-<agent>/findings/ and write
# the agent output to findings/<agent>.md.
#
# Idempotent per invocation; fail-open (capture failure never blocks the turn;
# logged to the recovery path). The agent list's SOURCE OF TRUTH is this hook.

# Report-class agents (deliverable is a durable document). Keep in sync with
# core/rules/rules-agent-routing.md's pointer + ADR-050/ADR-080 D2.
REPORT_CLASS_AGENTS="accessibility-auditor security-auditor code-reviewer performance-reviewer db-migration-reviewer dependency-auditor spec-conformance merge-conflict-scanner architect-review cto-advisor ui-review examiner"

# Minimum bytes of agent text below which we treat the output as trivial
# (a cheap one-shot @-question, not a report-class deliverable).
REPORT_CAPTURE_MIN_BYTES=500

# Does this session have an active-run state file? (engine run in progress)
session_has_active_run() {
  local sf _fname
  for sf in "$RUNS_DIR"/*.json; do
    [[ "$sf" == *.tmp ]] && continue
    [ -f "$sf" ] || continue
    if [ -n "$SESSION_ID" ]; then
      _fname=$(basename "$sf")
      case "$_fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    jq -e '.slug' "$sf" &>/dev/null && return 0
  done
  return 1
}

capture_report_class() {
  local agent_type="$1" agent_output="$2"

  # (a) report-class membership (word-boundary match against the space-list).
  case " $REPORT_CLASS_AGENTS " in
    *" $agent_type "*) ;;
    *) return 0 ;;   # not report-class — nothing to do
  esac

  # (b) off-engine only — skip when an engine run owns this session.
  if session_has_active_run; then
    return 0
  fi

  # Extract the agent's final text. tool_response.output may be a JSON wrapper
  # with the content nested under .content[0].text (mirror the retired
  # plan-steps arm's extraction pattern); fall back to the raw output.
  local inner_text=""
  inner_text=$(printf '%s' "$agent_output" | jq -r '.content[0].text // empty' 2>/dev/null) || true
  if [ -z "$inner_text" ] || [ "$inner_text" = "null" ]; then
    inner_text=$(printf '%s' "$agent_output" | jq -r 'if type=="string" then . else empty end' 2>/dev/null) || true
  fi
  if [ -z "$inner_text" ] || [ "$inner_text" = "null" ]; then
    inner_text="$agent_output"
  fi

  # (c) non-trivial floor.
  local nbytes
  nbytes=$(printf '%s' "$inner_text" | wc -c | tr -d ' ')
  if [ "${nbytes:-0}" -lt "$REPORT_CAPTURE_MIN_BYTES" ]; then
    return 0
  fi

  # Scaffold + write. Fail-open: any error logs to recovery + returns 0.
  local date_dir hhmm run_dir findings_dir out_file
  date_dir=$(date +%Y-%m-%d)
  hhmm=$(date +%H%M)
  run_dir="docs/step-5-pipeline/${date_dir}/${hhmm}-AUDIT-${agent_type}"
  findings_dir="${run_dir}/findings"
  if ! mkdir -p "$findings_dir" 2>/dev/null; then
    sync_recovery_log "." "sync:capture-report-class:mkdir-failed" "agent=${agent_type}; run_dir=${run_dir}"
    return 0
  fi
  out_file="${findings_dir}/${agent_type}.md"
  {
    printf '# %s — captured report (off-engine @-agent, ADR-080 D2)\n\n' "$agent_type"
    printf '_Auto-captured by sync-artifacts-post-agent.sh on Agent completion (no active run; report-class)._\n\n'
    printf '%s\n' "$inner_text"
  } > "${out_file}.tmp" 2>/dev/null \
    && mv "${out_file}.tmp" "$out_file" 2>/dev/null \
    || { rm -f "${out_file}.tmp" 2>/dev/null
         sync_recovery_log "$run_dir" "sync:capture-report-class:write-failed" "agent=${agent_type}; out_file=${out_file}"; }

  # ---- AMS-T11 (wave-4, AC-006..AC-009): opt-in report-class verdict write to memory ----
  # Hang the memory write off THIS existing arm — right after the findings/<agent>.md write — so the
  # high-signal verdict is recallable. We inherit ALL FOUR gates already passed above for free:
  #   (a) REPORT_CLASS_AGENTS membership (line 447 stays the single source — no second list)
  #   (b) off-engine only (session_has_active_run guard above — engine runs persist via
  #       persist-run-artifacts.py (W1); a write here on an engine run would be a double-write defect)
  #   (c) REPORT_CAPTURE_MIN_BYTES non-trivial floor
  #   (d) text extraction (reuse $inner_text / $agent_type — no re-parse of agent output)
  #
  # Contract (binding):
  #   - OFF BY DEFAULT (AC-009): gated behind GRAPHITI_REPORT_CLASS_WRITE; unset/0 => no write.
  #   - SOLE WRITE RAIL (AC-022): shells into graphiti_write CLI (-> write_fact()) and nothing else —
  #     scrub + fail-closed group_id + uuid5 idempotency inherited; no graph client / add_episode here.
  #   - HEAD-CAPPED: pass a sensible head of $inner_text (the goal is a recallable VERDICT, not the
  #     whole document — the full report is already on disk at $out_file). The funnel still scrubs.
  #   - FAIL-OPEN (AC-009): `|| true` + hard timeout; a write failure never aborts this arm or the
  #     PostToolUse hook (which runs `set -uo pipefail` without `set -e`).
  #   - REVERSIBLE (AC-021): deleting this block leaves the capture arm byte-identical to pre-W4.
  if [ "${GRAPHITI_REPORT_CLASS_WRITE:-0}" = "1" ]; then
    local gw="core/scripts/graphiti_write.py"
    if [ -f "$gw" ] && command -v python3 &>/dev/null; then
      local to_cmd=""
      command -v timeout &>/dev/null && to_cmd="timeout 5"
      printf '%s' "$inner_text" | head -c 4000 \
        | $to_cmd python3 "$gw" \
            --cwd "$PWD" \
            --source "report-class @-agent verdict (${agent_type}, off-engine, ADR-050)" \
            --name "verdict ${agent_type} ${date_dir} ${hhmm}" \
            >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ==========================================================================
# MAIN: Determine trigger mode and dispatch
# ==========================================================================

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

if [ "$TOOL_NAME" = "Write" ]; then
  WRITTEN_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  if [ -z "$WRITTEN_PATH" ]; then
    exit 0
  fi

  # AUTO-STATE: detect prompt.md and create state file.
  # Phase 1 A4: fail-loud on real failures (return 2 = applicable but
  # autostate failed); silent on return 1 (this Write isn't a state-creating
  # prompt.md write — every other Write in the session lands here).
  auto_create_state "$WRITTEN_PATH"
  AUTOSTATE_RC=$?
  if [ "$AUTOSTATE_RC" = "2" ]; then
    echo "sync-artifacts-post-agent: auto_create_state failed for ${WRITTEN_PATH}" >&2
    echo "sync-artifacts-post-agent: run-folder convention may be broken (slug/track derivation failed); see recovery-log.md in the affected run dir" >&2
    # PostToolUse exit 2 surfaces stderr to the conversation per Claude Code
    # hook semantics. The Write itself already succeeded; this just tells
    # the orchestrator the autostate didn't fire so it can investigate.
    exit 2
  fi

  # Update last_activity_at on any write within an active run dir
  for state_file in "$RUNS_DIR"/*.json; do
    [[ "$state_file" == *.tmp ]] && continue
    [ -f "$state_file" ] || continue
    if [ -n "$SESSION_ID" ]; then
      _sf_name=$(basename "$state_file")
      case "$_sf_name" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    RUN_DIR=$(jq -r '.run_dir // empty' "$state_file" 2>/dev/null)
    [ -z "$RUN_DIR" ] && continue

    ABS_RUN_DIR="$(cd "$(dirname "$RUN_DIR")" 2>/dev/null && pwd)/$(basename "$RUN_DIR")" 2>/dev/null || ABS_RUN_DIR="$PWD/$RUN_DIR"

    case "$WRITTEN_PATH" in
      "$ABS_RUN_DIR"/*|"$RUN_DIR"/*)
        WRITE_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        # INFRA-007: serialize the read-modify-write so concurrent fires
        # (e.g., a wave's parallel atoms each writing to the run dir) don't
        # lose updates to last_activity_at.
        if acquire_state_lock "$state_file"; then
          UPDATED_STATE=$(jq --arg ts "$WRITE_NOW" '.last_activity_at = $ts' "$state_file" 2>/dev/null) || true
          if [ -n "$UPDATED_STATE" ]; then
            printf '%s\n' "$UPDATED_STATE" > "$state_file"
          else
            # Phase 1 A4: jq update returned empty; preserve the existing
            # state file (don't overwrite with empty) and log the dropped
            # last_activity_at update. Low blast radius — single missed
            # timestamp; next write will refresh it.
            sync_recovery_log "$RUN_DIR" "sync:last-activity-at:jq-update-empty" "WRITTEN_PATH=${WRITTEN_PATH}; state_file=${state_file} preserved; this timestamp update dropped"
          fi
          release_state_lock "$state_file"
        fi
        exit 0
        ;;
    esac
  done

elif [ "$TOOL_NAME" = "Agent" ]; then
  AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)

  # REPORT-CLASS CAPTURE (ADR-080 D2): persist an off-engine report-class agent's
  # output to an AUDIT folder BEFORE tracking — the active-run check must see the
  # session state as it was at dispatch. Fail-open (never blocks the turn).
  AGENT_OUTPUT=$(printf '%s' "$INPUT" | jq -r '.tool_response.output // .tool_response // empty' 2>/dev/null) || true
  capture_report_class "$AGENT_TYPE" "$AGENT_OUTPUT"

  # AGENT TRACKING: append to completed_agents
  track_agent_completion "$AGENT_TYPE"
fi

exit 0
