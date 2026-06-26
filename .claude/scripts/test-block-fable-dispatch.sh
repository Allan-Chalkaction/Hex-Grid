#!/usr/bin/env bash
# test-block-fable-dispatch.sh — synthetic battery for core/hooks/block-fable-dispatch.sh.
# Hermetic: fixtures live in a mktemp project dir; HOME is overridden so real ~/.claude/agents
# can't leak into resolution. Pattern mirrors test-require-protocol-v2.sh (stdin JSON -> exit code).

set -u
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/block-fable-dispatch.sh"

total=0; failures=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/proj/.claude/agents" "$TMP/proj/core/agents"
export CLAUDE_PROJECT_DIR="$TMP/proj"

# Fixtures: agent files with frontmatter pins.
cat > "$TMP/proj/.claude/agents/pinned-opus.md" <<'EOF'
---
name: pinned-opus
model: claude-opus-4-8[1m]
---
body
EOF
cat > "$TMP/proj/.claude/agents/examiner.md" <<'EOF'
---
name: examiner
model: claude-fable-5
---
body
EOF
cat > "$TMP/proj/.claude/agents/evil-fable.md" <<'EOF'
---
name: evil-fable
model: claude-fable-5
---
body
EOF
cat > "$TMP/proj/.claude/agents/no-pin.md" <<'EOF'
---
name: no-pin
description: an agent file with no model pin
---
body
EOF
# Fixtures in the canonical source location (core/agents/) — the claude-infra repo keeps its
# agents here un-symlinked, so the hook MUST resolve pins from core/agents/ too.
cat > "$TMP/proj/core/agents/core-opus.md" <<'EOF'
---
name: core-opus
model: claude-opus-4-8[1m]
---
body
EOF
cat > "$TMP/proj/core/agents/core-fable.md" <<'EOF'
---
name: core-fable
model: claude-fable-5
---
body
EOF

run_case() {
  local desc="$1" stdin_json="$2" expected_exit="$3" expected_pattern="${4:-}"
  total=$((total+1))
  local stderr actual_exit
  stderr=$(echo "$stdin_json" | bash "$HOOK" 2>&1 1>/dev/null)
  actual_exit=$?
  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "FAIL: $desc — expected exit $expected_exit, got $actual_exit (stderr: $stderr)"
    failures=$((failures+1)); return
  fi
  if [ -n "$expected_pattern" ] && ! echo "$stderr" | grep -q "$expected_pattern"; then
    echo "FAIL: $desc — stderr missing pattern '$expected_pattern' (stderr: $stderr)"
    failures=$((failures+1)); return
  fi
  echo "PASS: $desc"
}

# 1. Explicit fable param -> blocked, regardless of type (even examiner).
run_case "explicit model fable blocked" \
  '{"session_id":"s1","tool_input":{"subagent_type":"general-purpose","model":"fable"}}' 2 "Fable may not be dispatched"
run_case "explicit fable blocked even for examiner type" \
  '{"session_id":"s1","tool_input":{"subagent_type":"examiner","model":"fable"}}' 2 "Fable may not be dispatched"

# 2. Explicit non-fable model -> allowed.
run_case "explicit sonnet allowed (built-in type)" \
  '{"session_id":"s1","tool_input":{"subagent_type":"general-purpose","model":"sonnet"}}' 0
run_case "explicit haiku allowed (unknown type)" \
  '{"session_id":"s1","tool_input":{"subagent_type":"Explore","model":"haiku"}}' 0

# 3. No model param: frontmatter pin governs. Only DETECTABLE Fable blocks; an
#    unresolvable/pinless dispatch ALLOWS (the hook cannot see the parent model, so
#    over-blocking every unpinned dispatch would brick the substrate).
run_case "unpinned built-in (Explore) allowed — undeterminable, no detectable fable" \
  '{"session_id":"s1","tool_input":{"subagent_type":"Explore"}}' 0
run_case "missing subagent_type (general-purpose, no agent file) allowed" \
  '{"session_id":"s1","tool_input":{}}' 0
run_case "opus-pinned agent allowed without model param" \
  '{"session_id":"s1","tool_input":{"subagent_type":"pinned-opus"}}' 0
run_case "examiner fable pin allowlisted (ADR-088)" \
  '{"session_id":"s1","tool_input":{"subagent_type":"examiner"}}' 0
run_case "non-examiner fable pin blocked" \
  '{"session_id":"s1","tool_input":{"subagent_type":"evil-fable"}}' 2 "only 'examiner'"
run_case "agent file present but pinless -> allowed (pin-existence is a lint, not this gate)" \
  '{"session_id":"s1","tool_input":{"subagent_type":"no-pin"}}' 0

# 4. Pin resolution from the canonical core/agents/ location (the infra-repo path the
#    original single-path version could not see — the bug that bricked the substrate).
run_case "opus pin resolved from core/agents/ allowed" \
  '{"session_id":"s1","tool_input":{"subagent_type":"core-opus"}}' 0
run_case "fable non-examiner pin in core/agents/ blocked" \
  '{"session_id":"s1","tool_input":{"subagent_type":"core-fable"}}' 2 "only 'examiner'"

# 5. Fail-closed boundary + hardening (SA-002 object-shape, SA-003 traversal).
run_case "empty stdin fails closed" \
  '' 2 "empty stdin"
run_case "malformed JSON fails closed" \
  'not-json' 2 "not valid JSON"
run_case "non-object array fails closed (SA-002)" \
  '[]' 2 "not a JSON object"
run_case "non-object string fails closed (SA-002)" \
  '"juststring"' 2 "not a JSON object"
run_case "path-traversal subagent_type is not resolved -> allowed (SA-003)" \
  '{"session_id":"s1","tool_input":{"subagent_type":"../../examiner"}}' 0

echo "---"
echo "test-block-fable-dispatch: $((total-failures))/$total passed"
[ "$failures" -eq 0 ] || exit 1
exit 0
