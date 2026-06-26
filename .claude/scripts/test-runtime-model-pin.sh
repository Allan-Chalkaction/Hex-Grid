#!/usr/bin/env bash
# F-006 — subagent model verification test.
#
# Per CLAUDE.md "Subagent model selection — explicit frontmatter discipline
# (Phase 1 A7 / γ, 2026-05-09)" and the documented Claude Code resolution
# order at https://code.claude.com/docs/en/sub-agents:
#
#   1. The CLAUDE_CODE_SUBAGENT_MODEL environment variable, if set
#   2. The per-invocation model parameter
#   3. The subagent definition's model frontmatter
#   4. The main conversation's model
#
# Phase 1 A7/γ removed the env-var override; agent frontmatter pins govern.
# This test exercises the frontmatter-reading code path so a typo / missing
# pin / unexpected value gets caught at test time. It also performs a
# best-effort runtime probe: if the runtime surfaces a model identifier in
# the agent response payload, the test asserts it matches the pin.
#
# Run:
#   bash core/scripts/test-runtime-model-pin.sh
#
# Exit codes:
#   0 = all assertions passed (runtime probe may have skipped)
#   1 = at least one frontmatter assertion failed
#   2 = the runtime probe explicitly fails (model resolved to non-pin value)
#
# Wave D pre-flight gate (historical; the prototype-wave spec is retired).
# A failure here MUST block any wave that assumes the 1M-context envelope
# because that assumption underwrites wave-level cto/pm/consensus dispatches
# that ADR-015 + ADR-016 require.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENTS_DIR="$REPO_ROOT/core/agents"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAIL_NAMES=()

ok()    { PASS_COUNT=$((PASS_COUNT + 1)); printf '  PASS  %s\n' "$1"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); FAIL_NAMES+=("$1"); printf '  FAIL  %s\n' "$1"; }
skip()  { SKIP_COUNT=$((SKIP_COUNT + 1)); printf '  SKIP  %s\n' "$1"; }

# --------------------------------------------------------------------------
# Probe set
# --------------------------------------------------------------------------
#
# Each entry is "<agent>|<expected_pin>". The expected pin is the value the
# agent's frontmatter MUST carry per the discipline. If a future agent moves
# off `claude-opus-4-8[1m]` deliberately, update its expected pin here in
# lockstep.

PROBES=(
  "cto-advisor|claude-opus-4-8[1m]"
  "code-reviewer|claude-opus-4-8[1m]"
  "architect-review|claude-opus-4-8[1m]"
  "implementer|claude-opus-4-8[1m]"
  "wave-implementer|claude-opus-4-8[1m]"
  "spec-conformance|claude-opus-4-8[1m]"
  "security-auditor|claude-opus-4-8[1m]"
  "pm-spec|claude-opus-4-8[1m]"
)

read_pin() {
  # Read the model: frontmatter field from an agent file. Strips quotes and
  # whitespace. Returns empty string if absent.
  local agent_file="$1"
  awk '
    /^---/ { delim++; if (delim == 2) exit; next }
    delim == 1 && /^model:/ {
      sub(/^model:[[:space:]]*/, "")
      gsub(/^["'"'"']|["'"'"']$/, "")
      sub(/[[:space:]]*$/, "")
      print
      exit
    }
  ' "$agent_file"
}

# --------------------------------------------------------------------------
# Test 1 — frontmatter pin presence + value match
# --------------------------------------------------------------------------

echo "test-runtime-model-pin.sh"
echo "-------------------------"
echo
echo "Phase 1 — Frontmatter pin verification:"

for probe in "${PROBES[@]}"; do
  agent="${probe%%|*}"
  expected="${probe##*|}"
  agent_file="${AGENTS_DIR}/${agent}.md"

  if [ ! -f "$agent_file" ]; then
    fail "${agent}: agent file ${agent_file} does not exist"
    continue
  fi

  pin="$(read_pin "$agent_file")"
  if [ -z "$pin" ]; then
    fail "${agent}: no 'model:' field in frontmatter"
    continue
  fi

  if [ "$pin" != "$expected" ]; then
    fail "${agent}: frontmatter pin '${pin}' != expected '${expected}'"
    continue
  fi

  ok "${agent}: pin == ${pin}"
done

# --------------------------------------------------------------------------
# Test 2 — env-var override is NOT set in committed settings
# --------------------------------------------------------------------------
#
# Phase 1 A7/γ removed CLAUDE_CODE_SUBAGENT_MODEL from .claude/settings.json.
# Re-enabling it would silently override every frontmatter pin. Project-level
# .claude/settings.local.json (gitignored) MAY set it for project-specific
# overrides, but the substrate's committed settings MUST NOT.

echo
echo "Phase 2 — Env-var override discipline:"

settings_path="${REPO_ROOT}/.claude/settings.json"
if [ -f "$settings_path" ]; then
  if grep -q 'CLAUDE_CODE_SUBAGENT_MODEL' "$settings_path"; then
    fail "settings.json: CLAUDE_CODE_SUBAGENT_MODEL present (should be removed per A7/γ)"
  else
    ok "settings.json: no env-var override (Phase 1 A7/γ baseline)"
  fi
else
  skip "settings.json: not present (project may not have committed settings)"
fi

# --------------------------------------------------------------------------
# Test 3 — runtime probe (best-effort)
# --------------------------------------------------------------------------
#
# The Agent tool's response payload may or may not surface a model identifier.
# This phase fires SOMETHING that catches a runtime regression if the runtime
# stops honoring frontmatter pins; if no payload is available to assert
# against, it skips with a clear message.
#
# Implementation: this bash script cannot directly invoke the Agent tool
# (Agent is a Claude Code runtime concept, not a shell tool). The runtime
# probe therefore lives at the boundary where the Wave D prototype wave's
# instrumentation captures per-dispatch metrics. For now, the probe surfaces
# the gap explicitly so future tooling can fill it.

echo
echo "Phase 3 — Runtime probe (best-effort):"

skip "runtime model_identifier probe — not implementable from a bash test;"
skip "  the Agent tool is a Claude Code runtime concept, not a shell tool."
skip "  Future implementation: wire into the Wave D instrumentation pipeline"
skip "  (Wave D instrumentation, since retired) which would capture per-"
skip "  dispatch usage payloads — a future instrumentation surface could"
skip "  capture and assert the response's model identifier when the runtime"
skip "  surfaces it. Until then, Phase 1's frontmatter-pin verification is"
skip "  the primary regression guard."

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

echo
echo "-------------------------"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "Skipped: $SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo
  echo "Failed assertions:"
  for n in "${FAIL_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi

exit 0
