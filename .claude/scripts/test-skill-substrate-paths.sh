#!/usr/bin/env bash
# ADR-031 (v2 follow-up, 2026-06-07) synthetic test — substrate path resolution
# on the ENTRY-MODE SKILL surface.
#
# Guards the bug class surfaced by the first consumer-context /chain run (Test2):
# v2 skills carry the load-bearing substrate-script invocations themselves
# (Workflow scriptPath + persist/manifest helpers), and were authored with the
# bare `core/scripts/…` prefix — which resolves only inside claude-infra, never
# in a consumer (where the substrate lives under `.claude/`). The inject-time
# rewrite (workflow-state-inject.sh) CANNOT reach skill bodies — they are read
# directly, not injected — so the fix is inline self-detection inside each skill.
#
# This test asserts that no v2 skill regresses back to a bare, unresolved
# executable `core/scripts/…` invocation, and that the inline resolver is wired.
#
# Tests:
#   test_no_bare_executable_core_path — no skill EXECUTES a bare core/scripts/ ref
#                                       (Workflow scriptPath, python3, $(...), or
#                                       a line-leading core/scripts/*.py|*.sh)
#   test_resolver_present             — every skill using $S/ carries the resolver
#   test_scriptpath_fallback_present  — launch skills document the .claude→core
#                                       scriptPath fallback (both prefixes named)
#
# Usage:   bash core/scripts/test-skill-substrate-paths.sh
# Exit:    0 — all PASS; N — N failures.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="${REPO_ROOT}/core/skills"

# The v2 entry-mode skills that drive the Workflow engine + persist/manifest helpers.
V2_SKILLS=(nimble orchestrated chain loop-task resume)
RESOLVER='S=.claude/scripts; [ -d "$S" ] || S=core/scripts'

# Launch skills that invoke the Workflow tool with a preset scriptPath.
LAUNCH_SKILLS=(nimble orchestrated chain)

# ---------------------------------------------------------------------------
# A line "executes" a bare core/scripts ref when it matches any of:
#   - `scriptPath: core/scripts/...`            (Workflow tool arg, old broken form)
#   - `python3 core/scripts/...`                (explicit interpreter invocation)
#   - `$(core/scripts/...`                      (command substitution)
#   - leading-whitespace `core/scripts/<x>.py|.sh`  (direct invocation)
# The legitimate fallback PROSE ("else `core/scripts/workflows/x.js`") and the
# resolver tail (`|| S=core/scripts`) do NOT match — they are not executions.
forbidden_in_file() {
  grep -nE \
    -e 'scriptPath: core/scripts/' \
    -e 'python3[[:space:]]+core/scripts/' \
    -e '\$\(core/scripts/' \
    -e '^[[:space:]]*core/scripts/[^[:space:]]+\.(py|sh)' \
    "$1" 2>/dev/null
}

test_no_bare_executable_core_path() {
  local rc=0 f hits
  for s in "${V2_SKILLS[@]}"; do
    f="${SKILLS_DIR}/${s}/SKILL.md"
    [ -f "$f" ] || { echo "FAIL: test_no_bare_executable_core_path — missing skill: ${s}/SKILL.md"; rc=1; continue; }
    hits=$(forbidden_in_file "$f")
    if [ -n "$hits" ]; then
      echo "FAIL: test_no_bare_executable_core_path — bare core/scripts execution in ${s}/SKILL.md:"
      printf '        %s\n' "$hits"
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] && echo "PASS: test_no_bare_executable_core_path"
  return "$rc"
}

test_resolver_present() {
  local rc=0 f
  for s in "${V2_SKILLS[@]}"; do
    f="${SKILLS_DIR}/${s}/SKILL.md"
    [ -f "$f" ] || { echo "FAIL: test_resolver_present — missing skill: ${s}/SKILL.md"; rc=1; continue; }
    # A skill that uses $S/ MUST define the resolver.
    if grep -qF '$S/' "$f" && ! grep -qF "$RESOLVER" "$f"; then
      echo "FAIL: test_resolver_present — ${s}/SKILL.md uses \$S/ but lacks the resolver line"
      rc=1
    fi
  done
  [ "$rc" -eq 0 ] && echo "PASS: test_resolver_present"
  return "$rc"
}

test_scriptpath_fallback_present() {
  local rc=0 f
  for s in "${LAUNCH_SKILLS[@]}"; do
    f="${SKILLS_DIR}/${s}/SKILL.md"
    [ -f "$f" ] || { echo "FAIL: test_scriptpath_fallback_present — missing skill: ${s}/SKILL.md"; rc=1; continue; }
    grep -qF ".claude/scripts/workflows/${s}.js" "$f" \
      || { echo "FAIL: test_scriptpath_fallback_present — ${s}/SKILL.md missing .claude/scripts/workflows/${s}.js fallback"; rc=1; }
    grep -qF "core/scripts/workflows/${s}.js" "$f" \
      || { echo "FAIL: test_scriptpath_fallback_present — ${s}/SKILL.md missing core/scripts/workflows/${s}.js fallback"; rc=1; }
  done
  [ "$rc" -eq 0 ] && echo "PASS: test_scriptpath_fallback_present"
  return "$rc"
}

failures=0
test_no_bare_executable_core_path || failures=$(( failures + 1 ))
test_resolver_present             || failures=$(( failures + 1 ))
test_scriptpath_fallback_present  || failures=$(( failures + 1 ))

if [ "$failures" -eq 0 ]; then
  echo ""
  echo "All 3 tests PASSED — v2 skills resolve substrate paths consumer-safely (ADR-031 v2 follow-up)."
else
  echo ""
  echo "${failures} test(s) FAILED. See FAIL: messages above."
fi
exit "$failures"
