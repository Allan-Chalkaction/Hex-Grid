#!/usr/bin/env bash
# PreToolUse hook: block direct Edit/Write to active-runs state files.
# Matcher: Edit|Write
#
# Exit 0 = allow · Exit 2 = block.
#
# Run state under .claude/agent-memory/active-runs/*.json is hook-managed
# (created/updated by sync-artifacts-post-agent.sh and the entry-mode skills).
# The orchestrator MUST NOT mutate these files via Edit/Write — state-file
# changes go through Bash jq + tmp + mv (see rules-orchestrator-behavior.md
# "Orchestrator-permitted paths" caveat, and rules-bypass-mode.md). This hook
# is intentionally NOT short-circuited by bypass mode — the active-runs
# invariant holds regardless of overlay.

set -euo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# Extract the target file path from the tool input.
FILE_PATH=""
if command -v jq &> /dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
else
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Block any path under .claude/agent-memory/active-runs/.
case "$FILE_PATH" in
  */.claude/agent-memory/active-runs/*|*agent-memory/active-runs/*)
    echo "BLOCKED: do not Edit/Write active-runs state files directly. They are hook-managed; mutate via Bash jq + tmp + mv (rules-orchestrator-behavior.md)." >&2
    exit 2
    ;;
esac

# Not an active-runs path — allow.
exit 0
