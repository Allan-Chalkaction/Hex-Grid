#!/usr/bin/env bash
# PostToolUse hook: Remind about required agent reviews based on file patterns
# Maps to CLAUDE.md "Contextual Agent Triggers" section
# Advisory only (exit 0) — blocking enforcement is in CLAUDE.md rules

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

case "$FILE_PATH" in
  */supabase/migrations/*|supabase/migrations/*)
    echo "AGENT REQUIRED: This migration requires db-migration-reviewer + security-auditor before task completion. Invoke both agents now if you haven't already."
    ;;
  */policies/*|*RLS*|*auth.uid*)
    echo "AGENT REQUIRED: RLS/auth changes require security-auditor review before task completion."
    ;;
  */client/src/components/ui/*|client/src/components/ui/*)
    echo "AGENT REQUIRED: Design system changes require ui-review before task completion."
    ;;
  */package.json|package.json)
    echo "AGENT REQUIRED: Dependency changes require dependency-auditor review. Run audit before task completion."
    ;;
  */supabase/functions/*|supabase/functions/*)
    echo "AGENT REQUIRED: Edge Function changes require security-auditor review (auth token verification)."
    ;;
  */client/src/hooks/use-*.ts|*/client/src/hooks/use-*.tsx|client/src/hooks/use-*.ts|client/src/hooks/use-*.tsx)
    echo "AGENT REQUIRED: New React Query hook detected. performance-reviewer required before task completion."
    ;;
  */client/src/pages/*.tsx|client/src/pages/*.tsx)
    echo "AGENT REQUIRED: New page component detected. ui-review required before task completion."
    ;;
  */client/src/components/*.tsx|client/src/components/*.tsx)
    # Skip client/src/components/ui/ — handled by the earlier case
    case "$FILE_PATH" in
      */client/src/components/ui/*|client/src/components/ui/*) ;;
      *)
        echo "AGENT REQUIRED: New component with visual output detected. ui-review required before task completion."
        ;;
    esac
    ;;
esac

exit 0
