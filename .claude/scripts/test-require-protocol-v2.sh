#!/usr/bin/env bash
# Hermetic hook-level fixture test for require-protocol.sh — v2 alignment (ADR-085 D1).
#
# Asserts the post-ADR-085 contract: for the live v2 engine tracks
# {nimble, orchestrated, chain} the implementer gate is CHECK 0 (state file
# exists) + CHECK 5 (>=1 completed Explore) ONLY — current_phase:"setup" no
# longer blocks (CHECK 0b is scoped to the dormant v1 pipeline track), and the
# orchestrated arm no longer requires wave-manifest.json or an in-progress
# ticket.
#
# Harness pattern mirrors core/scripts/test-protocol-hook.sh: build an isolated
# tempdir mimicking the repo's .claude/agent-memory/active-runs layout, write a
# fixture state file, then invoke the hook the way the PreToolUse:Agent harness
# does — feed stdin JSON carrying session_id + tool_input.subagent_type — and
# assert exit code + stderr pattern.
#
# Exit 0: all assertions passed.
# Exit 1: at least one assertion failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Resolve HOOK to an absolute path (accept relative HOOK_PATH against REPO_ROOT,
# or an absolute HOOK_PATH; default to the canonical location).
if [ -n "${HOOK_PATH:-}" ]; then
  case "$HOOK_PATH" in
    /*) HOOK="$HOOK_PATH" ;;
    *) HOOK="${REPO_ROOT}/${HOOK_PATH}" ;;
  esac
else
  HOOK="${REPO_ROOT}/core/hooks/require-protocol.sh"
fi

if [ ! -f "$HOOK" ]; then
  echo "ERROR: protocol hook not found at $HOOK" >&2
  exit 2
fi

echo "=== test-require-protocol-v2.sh (ADR-085 D1) ==="
echo "HOOK: $HOOK"
echo

# Isolated working dir mimicking the repo layout.
WORK=$(mktemp -d)
LOG=$(mktemp)
trap 'rm -rf "$WORK"; rm -f "$LOG"' EXIT
cd "$WORK"
mkdir -p .claude/agent-memory/active-runs

total=0
failures=0

# Write a v2 engine-track state file (current_phase:"setup", as the observer
# hook actually writes for nimble/orchestrated/chain).
mk_state() {
  local sid="$1" slug="$2" track="$3" phase="$4" agents="$5"
  cat > ".claude/agent-memory/active-runs/${sid}-${slug}.json" <<EOF
{"session_id":"${sid}","slug":"${slug}","track":"${track}","run_dir":"docs/step-5-pipeline/${slug}","current_phase":"${phase}","completed_agents":${agents}}
EOF
}

reset_state() {
  rm -f .claude/agent-memory/active-runs/*.json 2>/dev/null || true
  rm -f .claude/agent-memory/bypass-active-*.json 2>/dev/null || true
}

# Run one case: name, expected_exit, expected_stderr_pattern, stdin_json.
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
  printf 'EXIT: %d (expected %s)\n' "$actual_exit" "$expected_exit" >>"$LOG"
  printf 'STDERR_FIRST_LINE: %s\n' "$first_line" >>"$LOG"

  local pass=true
  [ "$actual_exit" != "$expected_exit" ] && pass=false
  if [ -n "$expected_pattern" ] && ! printf '%s' "$stderr" | grep -q "$expected_pattern"; then
    pass=false
  fi

  if [ "$pass" = "true" ]; then
    printf '%-46s  exit=%s  PASS\n' "$name" "$actual_exit"
  else
    printf '%-46s  exit=%s  FAIL  (expected exit=%s, stderr~/%s/)\n' \
      "$name" "$actual_exit" "$expected_exit" "$expected_pattern"
    [ -n "$stderr" ] && printf '  stderr: %s\n' "$first_line"
    failures=$((failures + 1))
  fi
}

# --- Case 1: orchestrated + setup + Explore → PASSES (the core ADR-085 fix) ---
# This is the exact regression fixture ADR-085 D1 names: current_phase:"setup",
# track:"orchestrated", >=1 Explore → implementer dispatch passes WITHOUT bypass.
reset_state
mk_state "sessv2" "o1" "orchestrated" "setup" '[{"type":"Explore"}]'
run_case "01-orchestrated-setup-with-explore-PASS" "0" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 2: orchestrated + setup, NO Explore → BLOCKED (CHECK 5) ---
reset_state
mk_state "sessv2" "o2" "orchestrated" "setup" '[]'
run_case "02-orchestrated-setup-no-explore-BLOCK" "2" "No Explore agent has completed" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 3: nimble + setup + Explore → PASSES ---
reset_state
mk_state "sessv2" "n3" "nimble" "setup" '[{"type":"Explore"}]'
run_case "03-nimble-setup-with-explore-PASS" "0" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 4: chain + setup + Explore → PASSES (chain is a v2 engine track) ---
reset_state
mk_state "sessv2" "c4" "chain" "setup" '[{"type":"Explore"}]'
run_case "04-chain-setup-with-explore-PASS" "0" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 5: dormant pipeline track + setup phase → STILL BLOCKED by CHECK 0b ---
# Unchanged v1 behavior: pipeline requires phase 'execute'; 'setup' is rejected
# by the (now pipeline-scoped) phase whitelist, before CHECK 5 even runs.
reset_state
mk_state "sessv2" "p5" "pipeline" "setup" '[{"type":"Explore"}]'
run_case "05-pipeline-setup-STILL-BLOCKED-0b" "2" "only allowed during the 'execute' phase" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 6: bypass flag present → PASSES regardless (short-circuit at top) ---
# Use an orchestrated state file that would otherwise pass anyway, but strip the
# Explore so the ONLY thing that can let it through is the bypass short-circuit.
reset_state
mk_state "sessv2" "b6" "orchestrated" "setup" '[]'
echo '{"enabled":true,"activated_at":"2026-06-12T00:00:00Z","session_id":"sessv2","reason":"test"}' \
  > .claude/agent-memory/bypass-active-sessv2.json
run_case "06-bypass-active-PASS" "0" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Case 7: orchestrated + setup + Explore but NO wave-manifest on disk → PASSES ---
# Explicit guard that the removed wave-manifest existence check no longer blocks.
# (No manifest file is ever created in this hermetic dir.)
reset_state
mk_state "sessv2" "o7" "orchestrated" "setup" '[{"type":"Explore"}]'
run_case "07-orchestrated-no-manifest-PASS" "0" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

# --- Cases 8-10 (SA-001, batch gate): advisor tracks hard-block implementers ---
# CHECK 0b is pipeline-scoped now, so these arms are the PRIMARY block — pin them.
reset_state
mk_state "sessv2" "a8" "adhoc" "advisory" '[{"type":"Explore"}]'
run_case "08-adhoc-implementer-BLOCK" "2" "advisor-only" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

reset_state
mk_state "sessv2" "r9" "roadmap" "round-loop" '[{"type":"Explore"}]'
run_case "09-roadmap-implementer-BLOCK" "2" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

reset_state
mk_state "sessv2" "p10" "planner" "planner-loop" '[{"type":"Explore"}]'
run_case "10-planner-implementer-BLOCK" "2" "" \
  '{"session_id":"sessv2","tool_input":{"subagent_type":"implementer"}}'

echo
echo "=== Summary ==="
echo "Total cases: $total"
echo "Failures:    $failures"
echo
echo "=== Full structured log ==="
cat "$LOG"
echo

if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL ($failures case(s))"
  exit 1
fi
