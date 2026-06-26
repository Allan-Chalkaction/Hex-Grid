#!/usr/bin/env bash
# Synthetic test for the merged source-protection hook (claude-infra v2 T2).
#
# block-source-edits.sh absorbed the former block-active-runs-edits.sh. The
# merge has one load-bearing invariant: the active-runs guard runs BEFORE the
# bypass short-circuit, so editing a state file is blocked EVEN under /bypass
# (the orchestrator must mutate state via Bash + jq + tmp + mv, never Edit/Write).
# The source-edit guard, by contrast, IS lifted by bypass.
#
# Cases:
#   1. Edit active-runs/*.json, bypass OFF        → block (exit 2)  [active-runs guard]
#   2. Edit active-runs/*.json, bypass ON         → block (exit 2)  [guard precedes bypass — the merge invariant]
#   3. Edit src/foo.ts, bypass OFF, no run        → block (exit 2)  [source guard]
#   4. Edit src/foo.ts, bypass ON                 → allow (exit 0)  [bypass lifts source guard]
#   5. Edit docs/x.md, bypass OFF                 → allow (exit 0)  [non-source allow-list]
#
# Run: bash core/scripts/test-source-protection-merge.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/block-source-edits.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/.claude/agent-memory/active-runs"
mkdir -p "$WORK/src" "$WORK/docs"

PASS=0; FAIL=0
# run_hook <bypass:on|off> <file_path> → echoes exit code
run_hook() {
  local bypass="$1" fpath="$2"
  # ADR-052: session-scoped flag keyed to the stdin session_id ("S").
  if [ "$bypass" = "on" ]; then
    printf '{"enabled":true,"session_id":"S"}' > "$WORK/.claude/agent-memory/bypass-active-S.json"
  else
    rm -f "$WORK/.claude/agent-memory/bypass-active-S.json"
  fi
  ( cd "$WORK" && printf '{"tool_input":{"file_path":"%s"},"session_id":"S"}' "$fpath" \
      | bash "$HOOK" >/dev/null 2>&1; echo $? )
}
assert() { # <name> <expect:0|2> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok  — $1"; else FAIL=$((FAIL+1)); echo "  XX  — $1 (expected $2, got $3)"; fi
}

# Synthetic path strings (the hook inspects the file_path STRING; the file need
# not exist). Deliberately NOT under the temp dir — mktemp paths live in
# /var/folders, which the hook treats as worktree-equivalent (allow).
echo "=== source-protection merge ==="
assert "active-runs edit, bypass OFF → block"          2 "$(run_hook off "/proj/.claude/agent-memory/active-runs/x.json")"
assert "active-runs edit, bypass ON  → block (invariant)" 2 "$(run_hook on  "/proj/.claude/agent-memory/active-runs/x.json")"
assert "source edit, bypass OFF, no run → block"       2 "$(run_hook off "/proj/src/foo.ts")"
assert "source edit, bypass ON → allow"                0 "$(run_hook on  "/proj/src/foo.ts")"
assert "docs edit, bypass OFF → allow"                 0 "$(run_hook off "/proj/docs/x.md")"

echo ""
echo "RESULT: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
