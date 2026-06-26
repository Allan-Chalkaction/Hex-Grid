#!/usr/bin/env bash
# PreToolUse hook: Nudge toward /project:pipeline for new feature files
# Advisory only (exit 0) — does NOT block execution
#
# Fires when a new source file is being created (not editing existing).
# Checks for feature-like paths and reminds about the pipeline skill.

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Only trigger for NEW files (file does not yet exist)
if [ -f "$FILE_PATH" ]; then
  exit 0
fi

# Suppress if a pipeline run is already active
QUEUE_FILE="docs/step-3-specs/_queue.json"
if [ -f "$QUEUE_FILE" ] && command -v jq &>/dev/null; then
  ACTIVE=$(jq -r 'to_entries[] | select(.value.status != "DONE" and .value.status != "CANCELLED") | .key' "$QUEUE_FILE" 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    exit 0
  fi
fi

# Check if this looks like new feature work
case "$FILE_PATH" in
  */client/src/pages/*|client/src/pages/*)
    ;;
  */client/src/components/*/[A-Z]*.tsx|client/src/components/*/[A-Z]*.tsx)
    ;;
  */client/src/hooks/use-*.ts|client/src/hooks/use-*.ts)
    ;;
  *)
    exit 0
    ;;
esac

echo ""
echo "--- PIPELINE REMINDER ---"
echo "Creating new source file: $FILE_PATH"
echo "If this is a new feature, consider using /project:pipeline instead of direct implementation."
echo "The pipeline routes through CTO evaluation, spec writing, architecture review, and quality gates."
echo "Skip this reminder by saying \"Execute directly\" in your prompt."
echo "---"

exit 0
