#!/usr/bin/env bash
# PreToolUse hook: Block access to sensitive file patterns
# Exit code 2 = block the action
#
# This hook OWNS the secrets verdict (.env, secrets/, .pem, .key, .ssh, .aws).
# block-source-edits.sh no longer carries a .env allow (SH-1 #4) so the two hooks
# agree: secrets are blocked, period.

set -uo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# jq guard — FAIL CLOSED for secrets (SH-1 #4). Previously a missing jq produced
# an empty FILE_PATH -> exit 0, leaving secrets readable/writable. Without jq we
# cannot reliably parse the path, so we crudely scan the raw payload for a
# secret-ish token and block if one appears; otherwise allow (non-secret traffic
# must not be globally blocked just because jq is absent).
if ! command -v jq &>/dev/null; then
  if printf '%s' "$INPUT" | grep -Eq '\.env|/secrets/|"secrets/|\.pem|\.key|/\.ssh/|/\.aws/'; then
    echo "🚫 BLOCKED: jq unavailable — cannot parse the file path, and the request references a secret pattern. Failing closed." >&2
    exit 2
  fi
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Blocked patterns
case "$FILE_PATH" in
  *.env|*.env.*|.env*)
    echo "🚫 BLOCKED: Access to .env files is restricted. Use environment variables instead."
    exit 2
    ;;
  */secrets/*|secrets/*)
    echo "🚫 BLOCKED: Access to secrets/ directory is restricted."
    exit 2
    ;;
  *.pem)
    echo "🚫 BLOCKED: Access to .pem certificate files is restricted."
    exit 2
    ;;
  *.key)
    echo "🚫 BLOCKED: Access to .key files is restricted."
    exit 2
    ;;
  */.ssh/*|~/.ssh/*)
    echo "🚫 BLOCKED: Access to .ssh directory is restricted."
    exit 2
    ;;
  */.aws/*|~/.aws/*)
    echo "🚫 BLOCKED: Access to .aws directory is restricted."
    exit 2
    ;;
esac

exit 0
