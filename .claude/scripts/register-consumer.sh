#!/usr/bin/env bash
# register-consumer.sh — idempotently add a repo to the consumer registry
# (core/config/infra-consumers.json) so /doctor tracks it for drift, /upgrade refreshes it,
# and T17 harvest can see it. Safe to re-run: a repo already present is a no-op.
#
# Usage:   bash core/scripts/register-consumer.sh <repo-path> [label]
# Output:  last line is machine-parseable — one of:
#            REGISTER: added <label> (<tilde-path>)
#            REGISTER: already-present <label>
#            REGISTER: error <reason>
#
# Env override (for tests): INFRA_CONSUMERS_FILE=/path/to/registry.json
#
# Storage convention: paths are stored with a leading ~ for $HOME (matching the existing registry).
# Idempotency is by RESOLVED absolute path (~ expanded on both sides), not string equality, so
# `~/x` and `$HOME/x` are treated as the same repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REG="${INFRA_CONSUMERS_FILE:-${REPO_ROOT}/core/config/infra-consumers.json}"

fail() { echo "register-consumer: $1" >&2; echo "REGISTER: error $1"; exit 1; }

command -v jq &>/dev/null || fail "jq-required"
[ "$#" -ge 1 ] || fail "usage:-register-consumer.sh-<repo-path>-[label]"
[ -f "$REG" ] || fail "no-registry-at-$REG"

# Resolve target to an absolute, existing directory.
TARGET_ABS="$(cd "$1" 2>/dev/null && pwd)" || fail "path-does-not-exist:-$1"

# Never register the infra repo itself as a consumer of itself.
if [ "$TARGET_ABS" = "$REPO_ROOT" ]; then
  fail "refusing-to-register-the-infra-repo-itself"
fi

LABEL="${2:-$(basename "$TARGET_ABS")}"

# Tilde-fold for storage (only if under $HOME).
case "$TARGET_ABS" in
  "$HOME"/*) TILDE_PATH="~${TARGET_ABS#"$HOME"}" ;;
  *)         TILDE_PATH="$TARGET_ABS" ;;
esac

# Idempotency: compare RESOLVED paths (expand a stored leading ~ to $HOME).
already=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    "~/"*) exp="${HOME}/${p#\~/}" ;;
    "~")   exp="$HOME" ;;
    *)     exp="$p" ;;
  esac
  if [ "$exp" = "$TARGET_ABS" ]; then already=1; break; fi
done < <(jq -r '.consumers[]?.path // empty' "$REG" 2>/dev/null)

if [ "$already" = "1" ]; then
  echo "Already registered: $TARGET_ABS"
  echo "REGISTER: already-present $LABEL"
  exit 0
fi

# Append { path, label } to .consumers, preserving _comment/_schema. Atomic write.
TMP="$(mktemp "${TMPDIR:-/tmp}/register-consumer.XXXXXX")" || fail "mktemp-failed"
if jq --arg p "$TILDE_PATH" --arg l "$LABEL" \
      '.consumers += [{"path": $p, "label": $l}]' "$REG" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$REG"
  echo "Registered $LABEL → $TILDE_PATH in $REG"
  echo "REGISTER: added $LABEL ($TILDE_PATH)"
else
  rm -f "$TMP"
  fail "jq-append-failed"
fi
