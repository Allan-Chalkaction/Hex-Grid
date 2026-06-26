#!/usr/bin/env bash
# test-capture-report-class.sh — synthetic test for the report-class capture arm
# in sync-artifacts-post-agent.sh (ADR-080 D2).
#
# Drives the hook with synthetic PostToolUse Agent JSON on stdin (mirrors the
# test-protocol-hook.sh fixture style) in an isolated tempdir, then asserts
# whether an AUDIT findings file was scaffolded.
#
# Cases:
#   1. report-class agent + no active run + big output  -> file created
#   2. non-report agent (Explore)                        -> no scaffold
#   3. report-class agent BUT active run exists          -> no scaffold
#   4. report-class agent BUT tiny output (<500 bytes)   -> no scaffold
#
# Exit 0: all assertions passed. Exit 1: at least one failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="${REPO_ROOT}/core/hooks/sync-artifacts-post-agent.sh"

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found at $HOOK" >&2
  exit 2
fi
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq unavailable" >&2
  exit 2
fi

echo "=== test-capture-report-class.sh ==="
echo "HOOK: $HOOK"
echo

total=0
failures=0

# A >500-byte report body (the non-trivial floor is 500 bytes).
BIG_TEXT=$(printf 'VERDICT: CHANGES_REQUESTED\n\n%s' "$(head -c 800 < /dev/zero | tr '\0' 'x')")
SMALL_TEXT="tiny"

# Build a PostToolUse Agent JSON payload.
#   $1 = subagent_type, $2 = session_id, $3 = output text
mk_input() {
  local agent="$1" sid="$2" text="$3"
  jq -nc \
    --arg agent "$agent" \
    --arg sid "$sid" \
    --arg text "$text" \
    '{
      tool_name: "Agent",
      session_id: $sid,
      tool_input: { subagent_type: $agent },
      tool_response: { output: { content: [ { type: "text", text: $text } ] } }
    }'
}

# run_case <name> <agent> <sid> <text> <create_state?yes|no> <expect_file?yes|no>
run_case() {
  local name="$1" agent="$2" sid="$3" text="$4" create_state="$5" expect="$6"
  total=$((total + 1))

  local work
  work=$(mktemp -d)
  mkdir -p "$work/.claude/agent-memory/active-runs"

  if [ "$create_state" = "yes" ]; then
    cat > "$work/.claude/agent-memory/active-runs/${sid}-1432-nimble-foo.json" <<EOF
{"session_id":"${sid}","slug":"1432-nimble-foo","track":"nimble","run_dir":"docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo","current_phase":"execute","completed_agents":[]}
EOF
  fi

  # Run the hook from inside the tempdir (it writes relative to cwd).
  ( cd "$work" && mk_input "$agent" "$sid" "$text" | bash "$HOOK" >/dev/null 2>&1 )

  # Did any AUDIT findings file for this agent get created?
  local found="no"
  if compgen -G "$work/docs/step-5-pipeline/*/*-AUDIT-${agent}/findings/${agent}.md" >/dev/null 2>&1; then
    found="yes"
  fi

  if [ "$found" = "$expect" ]; then
    echo "PASS: $name (file=${found}, expected=${expect})"
  else
    failures=$((failures + 1))
    echo "FAIL: $name (file=${found}, expected=${expect})"
  fi

  rm -rf "$work"
}

# Case 1: report-class + no active run + big output -> file created
run_case "report-class off-engine big output -> captured" \
  "security-auditor" "sess-1" "$BIG_TEXT" "no" "yes"

# Case 2: non-report agent -> no scaffold
run_case "non-report agent (Explore) -> not captured" \
  "Explore" "sess-2" "$BIG_TEXT" "no" "no"

# Case 3: report-class but active run exists -> no scaffold (engine persists)
run_case "report-class WITH active run -> not captured" \
  "code-reviewer" "sess-3" "$BIG_TEXT" "yes" "no"

# Case 4: report-class but tiny output -> no scaffold
run_case "report-class tiny output -> not captured" \
  "cto-advisor" "sess-4" "$SMALL_TEXT" "no" "no"

echo
echo "=== Summary: $((total - failures))/${total} passed ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0
