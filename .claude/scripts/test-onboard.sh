#!/usr/bin/env bash
# test-onboard.sh — synthetic test for register-consumer.sh (the /onboard registry step).
# Verifies: append, idempotency (re-register = no-op), tilde-folding, label default,
# refusal of the infra repo, and ~/$HOME path-equivalence. Uses a temp registry via
# INFRA_CONSUMERS_FILE so the real registry is never touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REG_SCRIPT="${SCRIPT_DIR}/register-consumer.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v jq &>/dev/null || { echo "test-onboard: jq required"; exit 1; }
[ -f "$REG_SCRIPT" ] || { echo "test-onboard: register-consumer.sh missing"; exit 1; }

# Scratch fixtures under $HOME so tilde-folding is exercised.
TMP_REG="$(mktemp "${TMPDIR:-/tmp}/onboard-reg.XXXXXX")"
TARGET="$(mktemp -d "$HOME/.onboard-test.XXXXXX")"
cleanup() { rm -f "$TMP_REG"; rm -rf "$TARGET"; }
trap cleanup EXIT

printf '{\n  "_comment": "test",\n  "consumers": []\n}\n' > "$TMP_REG"
export INFRA_CONSUMERS_FILE="$TMP_REG"

echo "=== test-onboard (register-consumer.sh) ==="

# 1. First registration appends one entry.
OUT="$(bash "$REG_SCRIPT" "$TARGET" 2>/dev/null | tail -1)"
N="$(jq '.consumers | length' "$TMP_REG")"
case "$OUT" in REGISTER:\ added\ *) [ "$N" = "1" ] && ok "first register adds one entry" || bad "count after add = $N (want 1)";; *) bad "first register output: $OUT";; esac

# 2. Tilde-folding: stored path starts with ~/ and label defaults to basename.
STORED="$(jq -r '.consumers[0].path' "$TMP_REG")"
LABEL="$(jq -r '.consumers[0].label' "$TMP_REG")"
case "$STORED" in "~/"*) ok "path tilde-folded ($STORED)";; *) bad "path not tilde-folded: $STORED";; esac
[ "$LABEL" = "$(basename "$TARGET")" ] && ok "label defaults to basename" || bad "label = $LABEL"

# 3. Idempotency: re-register the same path is a no-op (still one entry).
OUT="$(bash "$REG_SCRIPT" "$TARGET" 2>/dev/null | tail -1)"
N="$(jq '.consumers | length' "$TMP_REG")"
case "$OUT" in REGISTER:\ already-present\ *) [ "$N" = "1" ] && ok "re-register is idempotent" || bad "count after re-register = $N (want 1)";; *) bad "re-register output: $OUT";; esac

# 4. ~/$HOME equivalence: pre-seed a ~/ entry, then register via the $HOME-absolute path → no-op.
printf '{\n  "consumers": [ { "path": "~/.onboard-eqv-test", "label": "eqv" } ]\n}\n' > "$TMP_REG"
mkdir -p "$HOME/.onboard-eqv-test"
OUT="$(bash "$REG_SCRIPT" "$HOME/.onboard-eqv-test" 2>/dev/null | tail -1)"
N="$(jq '.consumers | length' "$TMP_REG")"
case "$OUT" in REGISTER:\ already-present\ *) [ "$N" = "1" ] && ok "~ and \$HOME treated as same repo" || bad "eqv count = $N (want 1)";; *) bad "eqv output: $OUT";; esac
rmdir "$HOME/.onboard-eqv-test" 2>/dev/null || true

# 5. Refuses to register the infra repo itself (against the REAL registry path, default).
OUT="$(INFRA_CONSUMERS_FILE="" bash "$REG_SCRIPT" "$REPO_ROOT" 2>/dev/null | tail -1)"
case "$OUT" in REGISTER:\ error\ *infra-repo*) ok "refuses to register the infra repo itself";; *) bad "infra-repo refusal output: $OUT";; esac

# 6. Nonexistent path errors cleanly.
OUT="$(bash "$REG_SCRIPT" "/no/such/path/xyzzy" 2>/dev/null | tail -1)"
case "$OUT" in REGISTER:\ error\ *) ok "nonexistent path errors cleanly";; *) bad "nonexistent output: $OUT";; esac

echo "=== test-onboard: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
