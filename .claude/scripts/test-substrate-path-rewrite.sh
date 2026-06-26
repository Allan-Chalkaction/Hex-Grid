#!/usr/bin/env bash
# ADR-031 synthetic test — substrate path resolution.
#
# Exercises BOTH defect classes in BOTH repo contexts (the ADR-031 Verification
# contract):
#   - Defect 1: substrate-script reference (core/scripts/wave-manifest.py)
#   - Defect 2: gate-prompt reference (core/gate-prompts/code-reviewer-ticket.md)
#   - Context A: claude-infra native (core/scripts present) — no rewrite fires
#   - Context B: consumer project (.claude/scripts present, no core/) — rewrite fires
#
# The injected-doc fix (workflow-state-inject.sh inject-time rewrite) and the
# non-injected gate-prompt fix (self-detected $SUBSTRATE) are distinct delivery
# paths; both are covered.
#
# Tests:
#   test_consumer_rewrite        — 4 prefixes translated, runtime-local untouched, prose non-goal preserved
#   test_infra_no_rewrite        — claude-infra cwd: guard false, nothing rewritten
#   test_hook_source_has_block   — the real hook carries the guard + 4 sed prefixes (ties replica to source)
#   test_gate_prompt_self_detect — gate-prompt $SUBSTRATE resolves .claude/core per context; file uses it
#   test_e2e_resolution          — both ref classes resolve against simulated symlink layout, both contexts
#   test_setup_links_gate_prompts— setup.sh symlinks core/gate-prompts (Defect 2)
#   test_no_infra_root_residue   — Finding-1 regression guard: no INFRA_ROOT left in injected orchestrated docs
#
# Usage:   bash core/scripts/test-substrate-path-rewrite.sh
# Exit:    0 — all PASS; N — N failures.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INJECT_HOOK="${REPO_ROOT}/core/hooks/workflow-state-inject.sh"
SETUP="${REPO_ROOT}/setup.sh"
GATE="${REPO_ROOT}/core/gate-prompts/end-of-wave-gates.md"

# Replica of the hook's inject-time rewrite. test_hook_source_has_block ties this
# replica to the real hook source so drift is caught.
rewrite() {
  local txt; txt=$(cat)
  if [ ! -d core/scripts ] && [ -d .claude/scripts ]; then
    printf '%s\n' "$txt" | sed \
      -e 's|core/scripts/|.claude/scripts/|g' \
      -e 's|core/gate-prompts/|.claude/gate-prompts/|g' \
      -e 's|core/config/|.claude/config/|g' \
      -e 's|core/hooks/|.claude/hooks/|g'
  else
    printf '%s\n' "$txt"
  fi
}

SAMPLE='run: python3 core/scripts/wave-manifest.py find-tickets-for-file
prompt: core/gate-prompts/code-reviewer-ticket.md
cfg: core/config/wave-mode.json
hook: core/hooks/sync-artifacts-post-agent.sh
local: .claude/agent-memory/active-runs/x.json
prose: see core/rules/rules-orchestrated-mode.md'

# ---------------------------------------------------------------------------
test_consumer_rewrite() {
  local d out; d=$(mktemp -d); mkdir -p "$d/.claude/scripts"
  out=$(cd "$d" && printf '%s\n' "$SAMPLE" | rewrite); rm -rf "$d"
  grep -qF '.claude/scripts/wave-manifest.py' <<<"$out"                 || { echo "FAIL: test_consumer_rewrite — script prefix not rewritten"; return 1; }
  grep -qF '.claude/gate-prompts/code-reviewer-ticket.md' <<<"$out"     || { echo "FAIL: test_consumer_rewrite — gate-prompt prefix not rewritten"; return 1; }
  grep -qF '.claude/config/wave-mode.json' <<<"$out"                    || { echo "FAIL: test_consumer_rewrite — config prefix not rewritten"; return 1; }
  grep -qF '.claude/hooks/sync-artifacts-post-agent.sh' <<<"$out"       || { echo "FAIL: test_consumer_rewrite — hooks prefix not rewritten"; return 1; }
  grep -qF '.claude/agent-memory/active-runs/x.json' <<<"$out"          || { echo "FAIL: test_consumer_rewrite — runtime-local .claude path corrupted"; return 1; }
  grep -qF 'core/rules/rules-orchestrated-mode.md' <<<"$out"            || { echo "FAIL: test_consumer_rewrite — prose core/rules wrongly rewritten (must be non-goal)"; return 1; }
  echo "PASS: test_consumer_rewrite"; return 0
}

test_infra_no_rewrite() {
  local d out; d=$(mktemp -d); mkdir -p "$d/core/scripts"
  out=$(cd "$d" && printf '%s\n' "$SAMPLE" | rewrite); rm -rf "$d"
  grep -qF 'core/scripts/wave-manifest.py' <<<"$out"          || { echo "FAIL: test_infra_no_rewrite — native script path mangled"; return 1; }
  grep -qF 'core/gate-prompts/code-reviewer-ticket.md' <<<"$out" || { echo "FAIL: test_infra_no_rewrite — native gate path mangled"; return 1; }
  if grep -qF '.claude/scripts/' <<<"$out"; then echo "FAIL: test_infra_no_rewrite — rewrite fired in claude-infra context"; return 1; fi
  echo "PASS: test_infra_no_rewrite"; return 0
}

test_hook_source_has_block() {
  grep -qF 'if [ ! -d core/scripts ] && [ -d .claude/scripts ]; then' "$INJECT_HOOK" \
    || { echo "FAIL: test_hook_source_has_block — cwd guard missing/changed in workflow-state-inject.sh"; return 1; }
  local pfx
  for pfx in scripts gate-prompts config hooks; do
    grep -qF "s|core/${pfx}/|.claude/${pfx}/|g" "$INJECT_HOOK" \
      || { echo "FAIL: test_hook_source_has_block — hook missing rewrite for core/${pfx}/"; return 1; }
  done
  echo "PASS: test_hook_source_has_block"; return 0
}

test_gate_prompt_self_detect() {
  local d sub
  d=$(mktemp -d); mkdir -p "$d/.claude/scripts"
  sub=$(cd "$d" && bash -c 'echo $([ -d .claude/scripts ] && echo .claude || echo core)'); rm -rf "$d"
  [ "$sub" = ".claude" ] || { echo "FAIL: test_gate_prompt_self_detect — consumer expected .claude, got '$sub'"; return 1; }
  d=$(mktemp -d); mkdir -p "$d/core/scripts"
  sub=$(cd "$d" && bash -c 'echo $([ -d .claude/scripts ] && echo .claude || echo core)'); rm -rf "$d"
  [ "$sub" = "core" ] || { echo "FAIL: test_gate_prompt_self_detect — claude-infra expected core, got '$sub'"; return 1; }
  grep -qF 'SUBSTRATE=$([ -d .claude/scripts ] && echo .claude || echo core)' "$GATE" \
    || { echo "FAIL: test_gate_prompt_self_detect — end-of-wave-gates.md missing SUBSTRATE detection"; return 1; }
  grep -qF 'python3 "$SUBSTRATE/scripts/wave-manifest.py"' "$GATE" \
    || { echo "FAIL: test_gate_prompt_self_detect — end-of-wave-gates.md not using \$SUBSTRATE for wave-manifest.py"; return 1; }
  echo "PASS: test_gate_prompt_self_detect"; return 0
}

test_e2e_resolution() {
  local d script_ref gate_ref
  # Consumer: substrate symlinked under .claude/
  d=$(mktemp -d); mkdir -p "$d/.claude/scripts" "$d/.claude/gate-prompts"
  touch "$d/.claude/scripts/wave-manifest.py" "$d/.claude/gate-prompts/code-reviewer-ticket.md"
  script_ref=$(cd "$d" && printf '%s\n' 'core/scripts/wave-manifest.py' | rewrite)
  gate_ref=$(cd "$d" && printf '%s\n' 'core/gate-prompts/code-reviewer-ticket.md' | rewrite)
  ( cd "$d" && [ -f "$script_ref" ] ) || { echo "FAIL: test_e2e_resolution — consumer script ref '$script_ref' does not resolve"; rm -rf "$d"; return 1; }
  ( cd "$d" && [ -f "$gate_ref" ] )   || { echo "FAIL: test_e2e_resolution — consumer gate ref '$gate_ref' does not resolve"; rm -rf "$d"; return 1; }
  rm -rf "$d"
  # claude-infra: substrate under core/
  d=$(mktemp -d); mkdir -p "$d/core/scripts" "$d/core/gate-prompts"
  touch "$d/core/scripts/wave-manifest.py" "$d/core/gate-prompts/code-reviewer-ticket.md"
  script_ref=$(cd "$d" && printf '%s\n' 'core/scripts/wave-manifest.py' | rewrite)
  gate_ref=$(cd "$d" && printf '%s\n' 'core/gate-prompts/code-reviewer-ticket.md' | rewrite)
  ( cd "$d" && [ -f "$script_ref" ] ) || { echo "FAIL: test_e2e_resolution — infra script ref '$script_ref' does not resolve"; rm -rf "$d"; return 1; }
  ( cd "$d" && [ -f "$gate_ref" ] )   || { echo "FAIL: test_e2e_resolution — infra gate ref '$gate_ref' does not resolve"; rm -rf "$d"; return 1; }
  rm -rf "$d"
  echo "PASS: test_e2e_resolution"; return 0
}

test_setup_links_gate_prompts() {
  grep -qF 'link_dir "$INFRA_DIR/core/gate-prompts" "$PROJECT_DIR/.claude/gate-prompts"' "$SETUP" \
    || { echo "FAIL: test_setup_links_gate_prompts — setup.sh missing core/gate-prompts link_dir"; return 1; }
  echo "PASS: test_setup_links_gate_prompts"; return 0
}

test_no_infra_root_residue() {
  local n; n=$(grep -rl 'INFRA_ROOT' "${REPO_ROOT}/core/config/phases/orchestrated/" 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "0" ] || { echo "FAIL: test_no_infra_root_residue — INFRA_ROOT still present in injected orchestrated docs (${n} files)"; return 1; }
  echo "PASS: test_no_infra_root_residue"; return 0
}

failures=0
test_consumer_rewrite         || failures=$(( failures + 1 ))
test_infra_no_rewrite         || failures=$(( failures + 1 ))
test_hook_source_has_block    || failures=$(( failures + 1 ))
test_gate_prompt_self_detect  || failures=$(( failures + 1 ))
test_e2e_resolution           || failures=$(( failures + 1 ))
test_setup_links_gate_prompts || failures=$(( failures + 1 ))
test_no_infra_root_residue    || failures=$(( failures + 1 ))

if [ "$failures" -eq 0 ]; then
  echo ""
  echo "All 7 tests PASSED — ADR-031 substrate path resolution is correctly wired (both defect classes, both contexts)."
else
  echo ""
  echo "${failures} test(s) FAILED. See FAIL: messages above."
fi
exit "$failures"
