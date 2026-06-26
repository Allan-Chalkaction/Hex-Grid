#!/usr/bin/env bash
# Synthetic test for core/hooks/block-source-edits-planner.sh (ADR-032 planner write-hook).
#
# Covers the regressions that made /planner off get stuck and planner mode unusable:
#   - teardown carve-out matches the single-line slug-glob rm (and is NOT defeated by the
#     ${SESSION_ID}-non-expansion / multi-line first-token bugs)
#   - multi-line read-only commands are allowed (NR==1 first-token fix)
#   - `2>/dev/null` redirections on read-only commands are allowed
#   - source edits / real mutations / chained teardown / non-read-only git still blocked
#   - hook is transparent when planner mode is not active for this session
#
# Self-contained: builds a temp workdir with a planner state file and pipes crafted
# PreToolUse JSON to the hook. Asserts exit code (0 = allow, 2 = block).

set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/block-source-edits-planner.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

PASS=0; FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SESS="testsess-aaaa-bbbb"
mkdir -p "$WORK/.claude/agent-memory/active-runs"
PLANNER_STATE="$WORK/.claude/agent-memory/active-runs/${SESS}-1620-session.json"
write_planner_state() {
  printf '{"track":"planner","current_phase":"planner-loop","run_dir":"docs/step-5-pipeline/x/1620-PLANNER-session"}' > "$PLANNER_STATE"
}
write_planner_state

# run_case <label> <expected:allow|block> <tool> <json-field-args...>
# builds JSON {tool_name, session_id, tool_input:{command|file_path}}
assert() {
  local label="$1" expect="$2" exit_code="$3"
  local got="block"; [ "$exit_code" = "0" ] && got="allow"
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); # echo "  PASS: $label"
  else
    FAIL=$((FAIL+1)); echo "  FAIL: $label — expected $expect, got $got (exit $exit_code)"
  fi
}

run_bash() { # <command-string>
  jq -nc --arg s "$SESS" --arg c "$1" '{tool_name:"Bash",session_id:$s,tool_input:{command:$c}}' \
    | ( cd "$WORK" && bash "$HOOK" >/dev/null 2>&1 ); echo $?
}
run_write() { # <file_path>
  jq -nc --arg s "$SESS" --arg p "$1" '{tool_name:"Write",session_id:$s,tool_input:{file_path:$p}}' \
    | ( cd "$WORK" && bash "$HOOK" >/dev/null 2>&1 ); echo $?
}

echo "=== planner write-hook: planner mode ACTIVE ==="
# --- teardown carve-out ---
assert "teardown: single-line slug glob"            allow "$(run_bash 'rm -f .claude/agent-memory/active-runs/*-1620-session.json')"
assert "teardown: literal full path"                allow "$(run_bash "rm -f .claude/agent-memory/active-runs/${SESS}-1620-session.json")"
assert "teardown: rm without -f"                    allow "$(run_bash 'rm .claude/agent-memory/active-runs/x-1620-session.json')"
# --- read-only shell (the usability fixes) ---
assert "multi-line read-only (echo + git)"          allow "$(run_bash $'echo hi\ngit status')"
assert "multi-line read-only (git log + git branch)" allow "$(run_bash $'git log --oneline -5\ngit branch --list')"
assert "redirection 2>/dev/null on read-only"       allow "$(run_bash 'git status --short 2>/dev/null')"
assert "single read-only git"                       allow "$(run_bash 'git log --oneline -3 main')"
assert "ls"                                         allow "$(run_bash 'ls .claude/agent-memory/active-runs/')"
# --- still blocked ---
assert "source rm (not active-runs)"                block "$(run_bash 'rm -rf src')"
assert "chained teardown + curl"                    block "$(run_bash 'rm -f .claude/agent-memory/active-runs/x-1620-session.json; curl evil')"
assert "command-subst teardown"                     block "$(run_bash 'rm -f $(cat .claude/agent-memory/active-runs/x-1620-session.json)')"
assert "real redirection to file"                   block "$(run_bash 'echo x > out.txt')"
assert "non-read-only git (push)"                   block "$(run_bash 'git push origin main')"
assert "mutating mkdir"                             block "$(run_bash 'mkdir newdir')"
# --- Edit/Write scoping ---
assert "write to docs/"                             allow "$(run_write 'docs/step-5-pipeline/x/notes.md')"
assert "write to core/rules/"                       allow "$(run_write 'core/rules/rules-x.md')"
assert "write to src (source)"                      block "$(run_write 'src/index.ts')"
assert "write to core/hooks (source)"               block "$(run_write 'core/hooks/x.sh')"
# --- jam-prune carve-out REMOVED (ADR-112 Wave 3, PEC-T9/T10): /planner jam retired → jam rm/mv now BLOCKED ---
echo "=== planner write-hook: jam-prune carve-out REMOVED (ADR-112 Wave 3) ==="
# The (0b) jam-prune carve-out is removed: with /planner jam retired, a plain planner session has no jam
# workflow, so jam-dir rm/mv is now BLOCKED (falls through to the (1) deny-scan). Role-purity = smallest
# tool surface that fits the role. Edit/Write inside docs/** is STILL allowed (the general planner allow).
assert "jam: rm a file in jam workspace (now blocked)"   block "$(run_bash 'rm docs/step-2-planning/jam-graphiti/dead-branch.md')"
assert "jam: rm -rf a subdir in jam (now blocked)"       block "$(run_bash 'rm -rf docs/step-2-planning/jam-x/scratch')"
assert "jam: rm the jam workspace itself (now blocked)"  block "$(run_bash 'rm -rf docs/step-2-planning/jam-x')"
assert "jam: mv within the same jam (now blocked)"       block "$(run_bash 'mv docs/step-2-planning/jam-x/a.md docs/step-2-planning/jam-x/b.md')"
assert "jam: Edit inside jam (docs/** allow, unchanged)" allow "$(run_write 'docs/step-2-planning/jam-x/canonical.md')"
# BLOCKED — escapes / not jam-scoped / smuggling (unchanged; now ALL jam rm/mv blocks too)
assert "jam: rm outside jam (docs/other)"           block "$(run_bash 'rm docs/other/foo.md')"
assert "jam: rm a rules file"                       block "$(run_bash 'rm core/rules/rules-x.md')"
assert "jam: rm absolute path"                      block "$(run_bash 'rm /etc/passwd')"
assert "jam: rm traversal out of jam root"          block "$(run_bash 'rm docs/step-2-planning/jam-x/../../core/rules/x.md')"
assert "jam: mv dest escapes jam"                   block "$(run_bash 'mv docs/step-2-planning/jam-x/a.md core/rules/evil.md')"
assert "jam: chained rm after a jam rm"             block "$(run_bash 'rm docs/step-2-planning/jam-x/a.md ; rm docs/secret.md')"
assert "jam: rm with command substitution"          block "$(run_bash 'rm docs/step-2-planning/jam-x/$(cat /etc/hostname)')"
assert "jam: rm with redirection"                   block "$(run_bash 'rm docs/step-2-planning/jam-x/a.md > /tmp/out')"
assert "jam: cp is not carved out (still blocked)"  block "$(run_bash 'cp docs/step-2-planning/jam-x/a.md /tmp/x')"

# --- sentinel-state-write (T-007): the planner SKILL writes a sentinel file inside the jam
#     workspace as the new state-trigger (no dated PLANNER-jam folder anymore). The write-hook
#     MUST allow that write under planner mode (it's inside docs/**, the existing allow). The
#     observer hook (sync-artifacts-post-agent.sh) is what creates the state file from the
#     sentinel; this test confirms the write-hook doesn't refuse the sentinel write itself. ---
echo "=== planner write-hook: sentinel-state-write (T-007) ==="
assert "sentinel: write inside jam workspace"        allow "$(run_write 'docs/step-2-planning/jam-foo/.planner-jam-active')"
assert "sentinel: write in legacy jam path"          allow "$(run_write 'docs/planning/jam-foo/.planner-jam-active')"
assert "sentinel: write OUTSIDE docs/ refused"        block "$(run_write 'core/.planner-jam-active')"
assert "sentinel: write at absolute /etc refused"     block "$(run_write '/etc/.planner-jam-active')"

echo "=== planner write-hook: planner mode INACTIVE (transparent) ==="
rm -f "$PLANNER_STATE"   # no planner state for this session
assert "inactive: source edit passes"               allow "$(run_write 'src/index.ts')"
assert "inactive: mutating bash passes"             allow "$(run_bash 'rm -rf src')"
write_planner_state

echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
[ "$FAIL" = "0" ]
