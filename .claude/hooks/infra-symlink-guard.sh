#!/usr/bin/env bash
# PreToolUse hook: Warn (but don't block) when editing symlinked infra files
# Matches: Edit, Write
#
# Exit code 0 = allow (with warning via stdout)
# Exit code 2 = block the action
#
# This hook warns by default. To hard-block, change BLOCK_MODE to "true".

set -euo pipefail

BLOCK_MODE="${INFRA_SYMLINK_GUARD_BLOCK:-true}"

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# Extract file path from tool input
FILE_PATH=""
if command -v jq &> /dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
else
  FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
  if [ -z "$FILE_PATH" ]; then
    FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null || true)
  fi
fi

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only check files under .claude/
case "$FILE_PATH" in
  */.claude/*) ;;
  *) exit 0 ;;
esac

# Skip known project-local files
case "$FILE_PATH" in
  *settings.local.json|*settings.json|*project-paths.sh)
    exit 0
    ;;
  */agent-memory/*|*/agent-memory)
    exit 0
    ;;
esac

# Check if the file is a symlink
if [ -L "$FILE_PATH" ]; then
  LINK_TARGET=$(readlink "$FILE_PATH" 2>/dev/null || true)

  # Check if it points to claude-infra
  case "$LINK_TARGET" in
    *claude-infra*)
      if [ "$BLOCK_MODE" = "true" ]; then
        echo "BLOCKED: $FILE_PATH is symlinked from claude-infra ($LINK_TARGET). Edit the source in claude-infra instead, then re-run setup.sh. Reply 'override' to force a local edit." >&2
        exit 2
      else
        # Warn but allow — output goes to stderr for Claude to see
        echo "WARNING: $FILE_PATH is symlinked from claude-infra ($LINK_TARGET). Changes here will modify the shared infrastructure source. If you intend to make a project-local override, break the symlink first." >&2
        exit 0
      fi
      ;;
  esac
fi

exit 0
