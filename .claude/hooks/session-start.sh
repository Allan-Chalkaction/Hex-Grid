#!/usr/bin/env bash
# SessionStart hook: Load project context at session start
# Best-effort: any individual command failure (missing dir, not a git repo,
# missing jq) skips that section but never crashes the hook. Always exits 0.

set -uo pipefail

echo "Session Context"
echo "==================="

# Git status
echo ""
echo "Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
echo ""
echo "Recent commits (last 5):"
git log --oneline -5 2>/dev/null || echo "  No commits yet"
echo ""

# Uncommitted changes
CHANGES=$(git status --short 2>/dev/null)
if [ -n "$CHANGES" ]; then
  echo "Uncommitted changes:"
  echo "$CHANGES" | head -20
  COUNT=$(echo "$CHANGES" | wc -l | tr -d ' ')
  if [ "$COUNT" -gt 20 ]; then
    echo "  ... and $((COUNT - 20)) more"
  fi
else
  echo "Working tree clean"
fi
echo ""
echo "==================="
exit 0
