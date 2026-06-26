#!/usr/bin/env bash
# Synthetic test harness for the protocol gate hook.
#
# Usage:
#   HOOK_PATH=core/hooks/require-nimble-protocol.sh ./test-protocol-hook.sh   # pre-rename
#   HOOK_PATH=core/hooks/require-protocol.sh        ./test-protocol-hook.sh   # post-rename
#
# Auto-detects pre/post-rename phase by scanning the hook content for the
# track-aware `case "$TRACK"` block (post-rename marker). Encoded expected
# outcomes per case + phase. Pipeline-byte-identical assertions: cases 1-5,
# 6, 8, 9 should be IDENTICAL pre and post rename. Case 7 is the ONLY case
# that differs: pre-rename BLOCKS (decomposer required), post-rename ALLOWS
# (decomposer no longer required for nimble).
#
# Modes:
#   MODE=capture: write structured log to ${BASELINE_FILE} (use against pre-rename hook)
#   MODE=test (default): run cases, assert encoded outcomes for the detected phase
#
# Exit 0: all assertions passed.
# Exit 1: at least one assertion failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Resolve HOOK to an absolute path before we cd into the temp working dir.
# Accept relative paths in HOOK_PATH (resolved against REPO_ROOT) or absolute paths.
if [ -n "${HOOK_PATH:-}" ]; then
  case "$HOOK_PATH" in
    /*) HOOK="$HOOK_PATH" ;;
    *) HOOK="${REPO_ROOT}/${HOOK_PATH}" ;;
  esac
else
  HOOK="${REPO_ROOT}/core/hooks/require-protocol.sh"
fi
if [ ! -f "$HOOK" ]; then
  HOOK="${REPO_ROOT}/core/hooks/require-nimble-protocol.sh"
fi

if [ ! -f "$HOOK" ]; then
  echo "ERROR: no protocol hook found at either core/hooks/require-protocol.sh or core/hooks/require-nimble-protocol.sh" >&2
  exit 2
fi

BASELINE_FILE="${REPO_ROOT}/core/scripts/test-protocol-hook.baseline.txt"
MODE="${MODE:-test}"

# Detect rename phase by checking for the track-aware case block.
# Post-rename: contains `case "$TRACK"` (Nimble branch only checks Explore).
# Pre-rename: no track-aware case (all checks fire regardless of track).
if grep -qE 'case[[:space:]]+"\$TRACK"' "$HOOK"; then
  PHASE="post-rename"
else
  PHASE="pre-rename"
fi

echo "=== test-protocol-hook.sh ==="
echo "HOOK:     $HOOK"
echo "PHASE:    $PHASE (auto-detected)"
echo "MODE:     $MODE"
echo "BASELINE: $BASELINE_FILE"
echo

# Working directory — isolated tempdir mimicking repo layout
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p .claude/agent-memory/active-runs

# Output buffer for current run
LOG=$(mktemp)
# Append both LOG and WORK cleanup to existing trap
trap 'rm -rf "$WORK"; rm -f "$LOG"' EXIT

# Counters
total=0
failures=0

# Per-case helpers
mk_state() {
  local sid="$1" slug="$2" track="$3" phase="$4" run_dir="$5" agents="$6"
  # Empty track sentinel → omit the track field entirely (case 11 "track missing").
  if [ -z "$track" ]; then
    cat > ".claude/agent-memory/active-runs/${sid}-${slug}.json" <<EOF
{"session_id":"${sid}","slug":"${slug}","run_dir":"${run_dir}","current_phase":"${phase}","completed_agents":${agents}}
EOF
  else
    cat > ".claude/agent-memory/active-runs/${sid}-${slug}.json" <<EOF
{"session_id":"${sid}","slug":"${slug}","track":"${track}","run_dir":"${run_dir}","current_phase":"${phase}","completed_agents":${agents}}
EOF
  fi
}

mk_plan_steps() {
  local run_dir="$1" mode="$2"
  mkdir -p "$run_dir"
  case "$mode" in
    active) echo '{"steps":[{"step_number":1,"status":"active"}]}' > "$run_dir/plan-steps.json" ;;
    pending) echo '{"steps":[{"step_number":1,"status":"pending"}]}' > "$run_dir/plan-steps.json" ;;
    none) ;; # do not create the file
  esac
}

# NOTE: mk_wave_manifest / mk_state_orchestrated helpers were removed with the
# v1 orchestrated arm (wave-manifest existence + in-progress ticket) — ADR-085 D1.
# Orchestrated cases now use mk_state with a v2-shape state file (track=orchestrated,
# current_phase=setup) like nimble/chain.

reset_state() {
  rm -rf .claude/agent-memory/active-runs/*.json 2>/dev/null || true
  rm -rf docs 2>/dev/null || true
  rm -f .claude/agent-memory/bypass-active.json 2>/dev/null || true
  rm -f .claude/agent-memory/bypass-active-*.json 2>/dev/null || true  # ADR-052 scoped flags
}

# Run one case. Records to LOG. Asserts against expected.
# Args: case_name, expected_exit, expected_stderr_pattern, stdin_json
run_case() {
  local name="$1" expected_exit="$2" expected_pattern="$3" stdin_json="$4"
  total=$((total + 1))

  set +e
  local stderr
  stderr=$(echo "$stdin_json" | bash "$HOOK" 2>&1 1>/dev/null)
  local actual_exit=$?
  set -e

  local first_line
  first_line=$(printf '%s' "$stderr" | head -1)

  printf '\n=== %s ===\n' "$name" >>"$LOG"
  printf 'EXIT: %d\n' "$actual_exit" >>"$LOG"
  printf 'STDERR_FIRST_LINE: %s\n' "$first_line" >>"$LOG"
  printf 'EXPECTED_EXIT: %s\n' "$expected_exit" >>"$LOG"
  printf 'EXPECTED_PATTERN: %s\n' "$expected_pattern" >>"$LOG"

  local pass=true
  if [ "$actual_exit" != "$expected_exit" ]; then
    pass=false
  fi
  if [ -n "$expected_pattern" ] && ! printf '%s' "$stderr" | grep -q "$expected_pattern"; then
    pass=false
  fi

  if [ "$pass" = "true" ]; then
    printf '%-42s  exit=%s  PASS\n' "$name" "$actual_exit"
    printf 'RESULT: PASS\n' >>"$LOG"
  else
    printf '%-42s  exit=%s  FAIL  (expected exit=%s, stderr~/%s/)\n' "$name" "$actual_exit" "$expected_exit" "$expected_pattern"
    printf 'RESULT: FAIL\n' >>"$LOG"
    if [ -n "$stderr" ]; then
      printf '  stderr: %s\n' "$stderr" | head -5
    fi
    failures=$((failures + 1))
  fi
}

# ---------- Cases ----------

# Case 1: pipeline-happy-path  (Pipeline byte-identical assertion)
reset_state
mk_state "sess1" "p1" "pipeline" "execute" "docs/step-5-pipeline/test1" '[{"type":"Explore"},{"type":"spec-decomposer"}]'
mk_plan_steps "docs/step-5-pipeline/test1" "active"
run_case "01-pipeline-happy-path" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 2: pipeline-no-explore (Pipeline byte-identical)
reset_state
mk_state "sess1" "p2" "pipeline" "execute" "docs/step-5-pipeline/test2" '[]'
mk_plan_steps "docs/step-5-pipeline/test2" "active"
run_case "02-pipeline-no-explore" "2" "No Explore agent has completed" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 3: pipeline-no-decomposer (Pipeline byte-identical)
reset_state
mk_state "sess1" "p3" "pipeline" "execute" "docs/step-5-pipeline/test3" '[{"type":"Explore"}]'
mk_plan_steps "docs/step-5-pipeline/test3" "active"
run_case "03-pipeline-no-decomposer" "2" "spec-decomposer has not completed" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 4: pipeline-no-active-step (Pipeline byte-identical)
reset_state
mk_state "sess1" "p4" "pipeline" "execute" "docs/step-5-pipeline/test4" '[{"type":"Explore"},{"type":"spec-decomposer"}]'
mk_plan_steps "docs/step-5-pipeline/test4" "pending"
run_case "04-pipeline-no-active-step" "2" "No active plan step" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 5: pipeline-cto-gate (phase-tier agent during cto-gate phase)
reset_state
mk_state "sess1" "p5" "pipeline" "cto-gate" "docs/step-5-pipeline/test5" '[]'
run_case "05-pipeline-cto-gate" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"cto-advisor"}}'

# Case 6: nimble-decomposer-flow (legacy nimble — same outcome pre/post)
reset_state
mk_state "sess1" "n6" "nimble" "execute" "docs/step-5-pipeline/test6" '[{"type":"Explore"},{"type":"spec-decomposer"}]'
mk_plan_steps "docs/step-5-pipeline/test6" "active"
run_case "06-nimble-decomposer-flow" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 7: nimble-new-flow-no-decomposer (THE phase-dependent case)
# pre-rename: BLOCK (decomposer required for all tracks)
# post-rename: ALLOW (Nimble branch only checks Explore)
reset_state
mk_state "sess1" "n7" "nimble" "execute" "docs/step-5-pipeline/test7" '[{"type":"Explore"}]'
mk_plan_steps "docs/step-5-pipeline/test7" "none"  # no plan-steps.json
mkdir -p docs/step-5-pipeline/test7
if [ "$PHASE" = "post-rename" ]; then
  run_case "07-nimble-new-flow-no-decomposer" "0" "" \
    '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'
else
  run_case "07-nimble-new-flow-no-decomposer" "2" "spec-decomposer has not completed" \
    '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'
fi

# Case 8: nimble-no-explore (same outcome pre/post)
reset_state
mk_state "sess1" "n8" "nimble" "execute" "docs/step-5-pipeline/test8" '[]'
mk_plan_steps "docs/step-5-pipeline/test8" "active"
run_case "08-nimble-no-explore" "2" "No Explore agent has completed" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 9: bypass-active (same outcome pre/post — short-circuits at the top).
# ADR-052: the flag is session-scoped (bypass-active-<session_id>.json), keyed to
# the same session_id the stdin payload carries (sess1).
reset_state
mk_state "sess1" "by" "nimble" "execute" "docs/step-5-pipeline/test9" '[]'
echo '{"enabled":true,"activated_at":"2026-05-04T00:00:00Z","session_id":"sess1","reason":"test"}' > .claude/agent-memory/bypass-active-sess1.json
run_case "09-bypass-active" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 10: no state file at all — CHECK 0 BLOCK with EXISTING stderr.
# Same outcome pre/post (CHECK 0 sits above the track-aware case block;
# its stderr is not changed by Step 3.3).
reset_state
# (intentionally NO mk_state call)
run_case "10-no-state-file" "2" "No run state file found" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 11: state file exists but track field is MISSING.
# pre-rename: hook ignores .track, runs every check. With Explore + decomposer
#             + active step, all checks pass → exit 0 (ALLOW).
# post-rename: case "$TRACK" → default → fail loud with NEW stderr.
# Phase-dependent like case 7. Excluded from byte-identical baseline diff.
reset_state
mk_state "sess1" "n11" "" "execute" "docs/step-5-pipeline/test11" '[{"type":"Explore"},{"type":"spec-decomposer"}]'
mk_plan_steps "docs/step-5-pipeline/test11" "active"
if [ "$PHASE" = "post-rename" ]; then
  run_case "11-state-file-no-track" "2" "TRACK is unset or unrecognized" \
    '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'
else
  run_case "11-state-file-no-track" "0" "" \
    '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'
fi

# ----- orchestrated-mode cases (12-15). Phase-dependent — only fire when -----
# post-rename hook detected (pre-rename has no orchestrated mode).
#
# ADR-085 D1 REWRITE: the orchestrated arm is now CHECK 5-only (>=1 Explore),
# matching nimble/chain. The v1 invariants these cases used to assert —
# wave-manifest.json existence, an in-progress ticket, the run_dir path-traversal
# guard guarding MANIFEST_FILE construction — were REMOVED with the arm (the
# manifest is written post-run via persist, ADR-039 contract 2; the
# one-implementer-per-wave model has no in-progress ticket at dispatch). The
# v2-shape state file carries current_phase:"setup" (what the observer hook
# actually writes for engine tracks). Dedicated hermetic coverage of the new
# contract lives in core/scripts/test-require-protocol-v2.sh.
if [ "$PHASE" = "post-rename" ]; then

# Case 12: orchestrated happy path (v2 shape).
# track=orchestrated + setup + Explore → ALLOWED (no manifest / no ticket needed).
reset_state
mk_state "sess1" "o12" "orchestrated" "setup" "docs/step-5-pipeline/test12" '[{"type":"Explore"}]'
run_case "12-orchestrated-happy-path" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 13: orchestrated + setup + NO Explore → BLOCKED on CHECK 5 (the only gate).
reset_state
mk_state "sess1" "o13" "orchestrated" "setup" "docs/step-5-pipeline/test13" '[]'
run_case "13-orchestrated-no-explore" "2" "No Explore agent has completed" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

# Case 14: pipeline + execute + spec-conformance → ALLOWED (SA-004 regression guard).
# V2-W0-T01 reclassified spec-conformance to phase-tier; this guards the
# matching execute) arm allowlist extension that restores INFRA-001 behavior.
reset_state
mk_state "sess1" "p14" "pipeline" "execute" "docs/step-5-pipeline/test14" '[{"type":"Explore"},{"type":"spec-decomposer"}]'
mk_plan_steps "docs/step-5-pipeline/test14" "active"
run_case "14-pipeline-execute-spec-conformance" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"spec-conformance"}}'

# Case 15: orchestrated + setup + Explore but NO wave-manifest on disk → ALLOWED.
# Explicit guard that the removed wave-manifest existence check no longer blocks
# (ADR-085 D1). No manifest file is created in this hermetic dir.
reset_state
mk_state "sess1" "o15" "orchestrated" "setup" "docs/step-5-pipeline/test15" '[{"type":"Explore"}]'
run_case "15-orchestrated-no-manifest-allowed" "0" "" \
  '{"session_id":"sess1","tool_input":{"subagent_type":"implementer"}}'

fi  # end post-rename phase-dependent block

# ---------- Summary ----------
echo
echo "=== Summary ==="
echo "Total cases: $total"
echo "Failures:    $failures"
echo

# Capture mode: write structured log to baseline
if [ "$MODE" = "capture" ]; then
  cp "$LOG" "$BASELINE_FILE"
  echo "Baseline written: $BASELINE_FILE"
  echo
fi

# Show full structured log
echo "=== Full structured log ==="
cat "$LOG"
echo

# Byte-identical Pipeline assertion: in test mode against post-rename hook,
# diff LOG vs BASELINE excluding the phase-dependent cases (07 and 11).
# All other cases should be byte-identical pre/post.
# =====================================================================
# Phase 1 A4 — Hook script naming + setup.sh registration consistency
# =====================================================================
# Assert post-rename invariants: substrate has require-protocol.sh
# (not require-nimble-protocol.sh) and setup.sh registers the new name.
echo "=== A4 — Hook naming + setup.sh registration consistency ==="
hook_naming_failure=0

# 1. Post-rename file presence: require-protocol.sh must exist.
if [ -f "$REPO_ROOT/core/hooks/require-protocol.sh" ]; then
  echo "  PASS  core/hooks/require-protocol.sh present"
else
  echo "  FAIL  core/hooks/require-protocol.sh missing"
  hook_naming_failure=1
fi

# 2. Stale name absence: require-nimble-protocol.sh must NOT exist
#    in core/hooks/. (A consumer's .claude/hooks/ may still have a
#    symlink or dead reference; that's the consumer-side concern.)
if [ ! -f "$REPO_ROOT/core/hooks/require-nimble-protocol.sh" ]; then
  echo "  PASS  core/hooks/require-nimble-protocol.sh absent (renamed)"
else
  echo "  FAIL  core/hooks/require-nimble-protocol.sh still present (rename incomplete)"
  hook_naming_failure=1
fi

# 3. setup.sh registers the new name.
if grep -q 'require-protocol\.sh' "$REPO_ROOT/setup.sh" 2>/dev/null; then
  echo "  PASS  setup.sh registers require-protocol.sh"
else
  echo "  FAIL  setup.sh does not register require-protocol.sh"
  hook_naming_failure=1
fi

# 4. setup.sh has migration logic for stale require-nimble-protocol entries.
#    The migration block removes any prior registration before adding the
#    new one (idempotent on consumer projects that ran older setup.sh).
if grep -q 'STALE_NIMBLE\|require-nimble-protocol' "$REPO_ROOT/setup.sh" 2>/dev/null; then
  echo "  PASS  setup.sh has migration for stale require-nimble-protocol registration"
else
  echo "  FAIL  setup.sh missing migration logic; consumer projects with stale registrations will fail-open silently"
  hook_naming_failure=1
fi

# 5. Hook-presence verification step exists in setup.sh.
if grep -q 'Validate hook script presence\|HOOK_REFS_MISSING' "$REPO_ROOT/setup.sh" 2>/dev/null; then
  echo "  PASS  setup.sh has hook-presence verification (Step 8b)"
else
  echo "  FAIL  setup.sh missing hook-presence verification step"
  hook_naming_failure=1
fi

# 6. advance-workflow-phase.sh was RETIRED with the v1 phase state machine (ADR-079 D1).
# Assert it is now absent rather than auditing its fail-mode arms.
if [ ! -f "$REPO_ROOT/core/hooks/advance-workflow-phase.sh" ]; then
  echo "  PASS  advance-workflow-phase.sh absent (retired, ADR-079 D1)"
else
  echo "  FAIL  advance-workflow-phase.sh still present (should be retired per ADR-079 D1)"
  hook_naming_failure=1
fi

# 7. Same for sync-artifacts-post-agent.sh.
if grep -q 'sync_recovery_log\|AUTOSTATE_RC' "$REPO_ROOT/core/hooks/sync-artifacts-post-agent.sh" 2>/dev/null; then
  echo "  PASS  sync-artifacts-post-agent.sh has fail-mode audit"
else
  echo "  FAIL  sync-artifacts-post-agent.sh missing fail-mode audit"
  hook_naming_failure=1
fi

# 8. RETIRED (T5b / ADR-040): the orchestrated SKILL resume-synthesis assertion checked the v1
#    phase-machine SKILL.md (state-file synthesis carrying completed_agents across a cross-session
#    resume). The v2 orchestrated track runs on the Workflow engine (core/scripts/workflows/
#    orchestrated.js) with the thin-manifest tickets[] as the resume substrate — there is no
#    active-runs state-file synthesis to assert. The require-protocol.sh hook behavior this file
#    tests (cases 12-15 orchestrated arm + the nimble/pipeline arms) — the orchestrated arm is now
#    CHECK 5-only per ADR-085 D1; cases 12/13/15 were updated to the v2 contract.

echo

byte_identical_failure=0
if [ "$MODE" = "test" ] && [ "$PHASE" = "post-rename" ] && [ -f "$BASELINE_FILE" ]; then
  echo "=== Byte-identical Pipeline-assertions check (post-rename vs pre-rename baseline) ==="
  # Extract everything EXCEPT cases 07 and 11's sections from a structured log.
  # Sections are delimited by `=== <case_name> ===`. Each phase-dependent
  # case runs from its `=== ... ===` header until the next `=== ` header
  # or EOF.
  filtered_log=$(mktemp)
  filtered_baseline=$(mktemp)
  # Cases 12-15 are V2-W0-T01 orchestrated-mode additions; the pre-rename
  # baseline does not contain them, so they're excluded from the byte-
  # identical diff (post-rename-only behavior, by design).
  awk '
    /^=== 07-nimble-new-flow-no-decomposer ===$/ { skip=1; next }
    /^=== 11-state-file-no-track ===$/ { skip=1; next }
    /^=== 12-orchestrated-happy-path ===$/ { skip=1; next }
    /^=== 13-orchestrated-no-explore ===$/ { skip=1; next }
    /^=== 14-pipeline-execute-spec-conformance ===$/ { skip=1; next }
    /^=== 15-orchestrated-no-manifest-allowed ===$/ { skip=1; next }
    /^=== / { skip=0 }
    !skip { print }
  ' "$LOG" > "$filtered_log"
  awk '
    /^=== 07-nimble-new-flow-no-decomposer ===$/ { skip=1; next }
    /^=== 11-state-file-no-track ===$/ { skip=1; next }
    /^=== 12-orchestrated-happy-path ===$/ { skip=1; next }
    /^=== 13-orchestrated-no-explore ===$/ { skip=1; next }
    /^=== 14-pipeline-execute-spec-conformance ===$/ { skip=1; next }
    /^=== 15-orchestrated-no-manifest-allowed ===$/ { skip=1; next }
    /^=== / { skip=0 }
    !skip { print }
  ' "$BASELINE_FILE" > "$filtered_baseline"
  if diff -u "$filtered_baseline" "$filtered_log" >/dev/null 2>&1; then
    echo "PASS — Pipeline + unchanged-Nimble assertions are byte-identical to baseline."
  else
    echo "FAIL — behavior diverged from baseline on a case that should be unchanged:"
    diff -u "$filtered_baseline" "$filtered_log" || true
    byte_identical_failure=1
  fi
  rm -f "$filtered_log" "$filtered_baseline"
  echo
fi

if [ "$failures" -eq 0 ] && [ "$byte_identical_failure" -eq 0 ] && [ "$hook_naming_failure" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL  (per-case=$failures, byte-identical=$byte_identical_failure, hook-naming=$hook_naming_failure)"
  exit 1
fi
