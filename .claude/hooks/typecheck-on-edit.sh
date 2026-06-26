#!/usr/bin/env bash
# PostToolUse hook: Run type checking after file edits to catch errors early
# Fires after Edit or Write tool calls on source files
# Advisory only (exit 0) — shows errors but does not block
#
# Requires TYPECHECK_CMD to be set in .claude/project-paths.sh
# Example: export TYPECHECK_CMD="npx tsc --noEmit --pretty"
#
# This hook prevents multi-round debugging loops by catching type errors
# immediately after edits, before they compound into harder-to-diagnose issues.

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)

# Only trigger on Edit or Write
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only trigger on source files (not markdown, json config, etc.)
case "$FILE_PATH" in
  *.ts|*.tsx|*.py|*.go|*.rs) ;;
  *) exit 0 ;;
esac

# Source project paths if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATHS="${SCRIPT_DIR}/../project-paths.sh"
if [ -f "$PROJECT_PATHS" ]; then
  # shellcheck disable=SC1090
  source "$PROJECT_PATHS"
fi

# Fall back to common type checkers if TYPECHECK_CMD not set
if [ -z "$TYPECHECK_CMD" ]; then
  case "$FILE_PATH" in
    *.ts|*.tsx)
      if [ -f "node_modules/.bin/tsc" ]; then
        TYPECHECK_CMD="npx tsc --noEmit --pretty"
      else
        exit 0
      fi
      ;;
    *.py)
      if command -v mypy &>/dev/null; then
        TYPECHECK_CMD="mypy --no-error-summary"
      elif command -v pyright &>/dev/null; then
        TYPECHECK_CMD="pyright"
      else
        exit 0
      fi
      ;;
    *.go)
      if command -v go &>/dev/null; then
        TYPECHECK_CMD="go vet ./..."
      else
        exit 0
      fi
      ;;
    *.rs)
      if command -v cargo &>/dev/null; then
        TYPECHECK_CMD="cargo check --message-format short"
      else
        exit 0
      fi
      ;;
    *) exit 0 ;;
  esac
fi

# Run type check, capture output, limit to first 20 lines to avoid noise
OUTPUT=$($TYPECHECK_CMD 2>&1 | head -20)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ] && [ -n "$OUTPUT" ]; then
  echo ""
  echo "--- TYPE CHECK ERRORS ---"
  echo "$OUTPUT"
  echo "---"
  echo "Fix these type errors before continuing. They will compound if left unresolved."
fi

exit 0
