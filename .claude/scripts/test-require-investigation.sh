#!/usr/bin/env bash
# Synthetic test for require-investigation.sh — the deterministic investigation-first
# floor hook (SHR3-T6, ADR-018, examiner F-004).
#
# Asserts the THREE load-bearing properties:
#   (1) TRUE-POSITIVE — the deterministic signal present (implementer dispatch +
#       zero completed Explore in the run ledger) -> BLOCKS (exit 2).
#   (2) FALSE-POSITIVE-BOUND — the load-bearing test: an ambiguous-but-INVESTIGATED
#       run (>=1 completed Explore) -> does NOT block (exit 0). This proves the hook
#       fires on the deterministic signal, NOT a content heuristic.
#   (3) BYPASS — the session-scoped bypass flag on -> allow (exit 0), short-circuit
#       FIRST before any signal check.
# Plus fail-open + scope guards.
#
# Exit 0: all assertions passed. Exit 1: at least one failed.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="${REPO_ROOT}/core/hooks/require-investigation.sh"
if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 2
fi

echo "=== test-require-investigation.sh ==="
echo "HOOK: $HOOK"
echo

# Isolated tempdir mimicking the repo layout. CLAUDE_PROJECT_DIR points the hook
# at this hermetic tree so it reads our seeded state files, not the real repo's.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude/agent-memory/active-runs"
export CLAUDE_PROJECT_DIR="$WORK"

total=0
failures=0

# Seed a run state file (the observer-hook shape require-protocol.sh reads).
mk_state() {  # sid slug track agents_json
  local sid="$1" slug="$2" track="$3" agents="$4"
  cat > "$WORK/.claude/agent-memory/active-runs/${sid}-${slug}.json" <<EOF
{"session_id":"${sid}","slug":"${slug}","track":"${track}","run_dir":"docs/x","current_phase":"setup","completed_agents":${agents}}
EOF
}

reset_state() {
  rm -f "$WORK/.claude/agent-memory/active-runs"/*.json 2>/dev/null || true
  rm -f "$WORK/.claude/agent-memory/bypass-active-"*.json 2>/dev/null || true
}

# Run one case: name, expected_exit, [expected_stderr_pattern], stdin_json
run_case() {
  local name="$1" exp_exit="$2" exp_pat="$3" stdin_json="$4"
  total=$((total + 1))
  set +e
  local stderr actual_exit
  stderr=$(echo "$stdin_json" | bash "$HOOK" 2>&1 1>/dev/null)
  actual_exit=$?
  set -e
  local pass=true
  [ "$actual_exit" != "$exp_exit" ] && pass=false
  if [ -n "$exp_pat" ] && ! printf '%s' "$stderr" | grep -q "$exp_pat"; then pass=false; fi
  if [ "$pass" = true ]; then
    printf '  PASS  %-48s exit=%s\n' "$name" "$actual_exit"
  else
    printf '  FAIL  %-48s exit=%s (expected %s, stderr~/%s/)\n' "$name" "$actual_exit" "$exp_exit" "$exp_pat"
    [ -n "$stderr" ] && printf '        stderr: %s\n' "$(printf '%s' "$stderr" | head -1)"
    failures=$((failures + 1))
  fi
}

# --- Case 1: TRUE-POSITIVE — implementer dispatch, ZERO Explore -> BLOCK (exit 2) ---
reset_state
mk_state "s1" "feat" "nimble" '[]'
run_case "true-positive: impl + no-explore -> block" "2" "investigation-first floor" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 2: FALSE-POSITIVE-BOUND (load-bearing) — investigated run -> ALLOW (exit 0) ---
# The run ledger shows a completed Explore (the run WAS investigated). Even though the
# work might be "ambiguous", the hook must NOT block — it gates only the deterministic
# zero-investigation signal, not a heuristic.
reset_state
mk_state "s1" "feat" "nimble" '[{"type":"Explore"}]'
run_case "false-positive-bound: investigated -> allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 2b: investigation-typed evidence also satisfies the floor -> ALLOW ---
reset_state
mk_state "s1" "feat" "nimble" '[{"type":"investigation"}]'
run_case "investigation-typed evidence -> allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 3: BYPASS — flag on -> ALLOW (exit 0), short-circuit FIRST ---
# Even with the blocking signal (zero Explore), bypass short-circuits before the check.
reset_state
mk_state "s1" "feat" "nimble" '[]'
echo '{"enabled":true,"activated_at":"2026-06-17T00:00:00Z","session_id":"s1","reason":"test"}' \
  > "$WORK/.claude/agent-memory/bypass-active-s1.json"
run_case "bypass on -> allow (short-circuit first)" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 4: SCOPE — non-implementer dispatch is never gated -> ALLOW ---
# A cto-advisor / Explore / gate dispatch carries no investigation-first floor.
reset_state
mk_state "s1" "feat" "nimble" '[]'
run_case "non-implementer (cto-advisor) -> allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"cto-advisor"}}'

reset_state
mk_state "s1" "feat" "nimble" '[]'
run_case "Explore dispatch itself -> allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"Explore"}}'

# --- Case 5: FAIL-OPEN — no state file for the session -> ALLOW (exit 0) ---
# (require-protocol.sh owns the no-state-file block; this hook only gates the floor
# when a ledger exists. No ledger -> fail-open.)
reset_state
run_case "no state file -> fail-open allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 6: FAIL-OPEN — malformed JSON state file -> ALLOW (never wedge) ---
reset_state
echo 'NOT JSON {{{' > "$WORK/.claude/agent-memory/active-runs/s1-broken.json"
run_case "malformed state file -> fail-open allow" "0" "" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Case 7: wave-implementer is also gated (sibling implementer tier) ---
reset_state
mk_state "s1" "feat" "orchestrated" '[]'
run_case "wave-implementer + no-explore -> block" "2" "investigation-first floor" \
  '{"session_id":"s1","tool_input":{"subagent_type":"wave-implementer"}}'

# --- Case 8: session isolation — another session's Explore does NOT satisfy our floor ---
# A different session has a state file WITH Explore; ours (s1) has none -> block s1.
reset_state
mk_state "other" "x" "nimble" '[{"type":"Explore"}]'
mk_state "s1" "feat" "nimble" '[]'
run_case "session isolation: other's explore doesn't count" "2" "investigation-first floor" \
  '{"session_id":"s1","tool_input":{"subagent_type":"implementer"}}'

# --- Static guard: the hook must NOT block on the heuristic classes (AC-018) ---
echo
echo "=== static: hook does not block on heuristic classes ==="
total=$((total + 1))
# AC-018: the heuristic classes must NOT drive this blocking hook. Assert every
# reference to scope-slip/ambiguity in the hook is a COMMENT line (explaining the
# EXCLUSION) — never executable code. A non-comment reference would mean the hook
# reaches for the heuristic signal, which examiner F-004 forbids.
NONCOMMENT_HEURISTIC=$(grep -nE 'scope.?slip|ambiguity' "$HOOK" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ -n "$NONCOMMENT_HEURISTIC" ]; then
  printf '  FAIL  hook references a heuristic class (scope-slip/ambiguity) in executable code:\n'
  printf '        %s\n' "$NONCOMMENT_HEURISTIC"
  failures=$((failures + 1))
else
  printf '  PASS  scope-slip/ambiguity appear only in comments (never an executable/blocking condition)\n'
fi

echo
echo "=== Summary ==="
echo "Total: $total  Failures: $failures"
if [ "$failures" -eq 0 ]; then
  echo "RESULT: PASS"
  exit 0
else
  echo "RESULT: FAIL"
  exit 1
fi
