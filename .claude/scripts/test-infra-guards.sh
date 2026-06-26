#!/usr/bin/env bash
# test-infra-guards.sh — hermetic regression for the ADR-085 D3/D4 infra guards.
#
# Covers:
#   (a) D3 — setup.sh refuses an infra-marker PROJECT_DIR (a dir carrying
#       core/config/infra-consumers.json): exit 1, error names BOTH dirs.
#   (b) D3 — setup.sh proceeds past the guard for a normal (no-marker) consumer
#       dir: the guard refusal is NOT emitted and the framework dirs get created.
#   (c) D4 — register-consumer.sh (the sole infra-consumers.json mutator) writes
#       atomically (tmp + mv): the post-state is the correctly-mutated registry,
#       no *.tmp / register-consumer.* residue is left in the target dir, and the
#       infra-repo self-register case is refused.
#
# NEVER mutates the real repo: every PROJECT_DIR / registry fixture is mktemp'd.
# INFRA_DIR points at the real repo READ-ONLY (setup.sh only reads its core/).
#
# Exit 0: all assertions passed. Exit 1: at least one failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SETUP="${REPO_ROOT}/setup.sh"
REGISTER="${REPO_ROOT}/core/scripts/register-consumer.sh"

for f in "$SETUP" "$REGISTER"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required script not found: $f" >&2
    exit 2
  fi
done

echo "=== test-infra-guards.sh ==="
echo "SETUP:    $SETUP"
echo "REGISTER: $REGISTER"
echo

total=0
failures=0

assert_rc() {
  local name="$1" got="$2" want="$3"
  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    echo "PASS: $name (rc=$got)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name — rc=$got, expected $want"
  fi
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
  else
    failures=$((failures + 1))
    echo "FAIL: $name — expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local name="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    failures=$((failures + 1))
    echo "FAIL: $name — output unexpectedly contained: $needle"
  else
    echo "PASS: $name"
  fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
# (a) D3 — infra-marker PROJECT_DIR is refused, names both dirs, exits 1.
# ---------------------------------------------------------------------------
FAKE_INFRA="$SCRATCH/fake-infra"
mkdir -p "$FAKE_INFRA/core/config"
echo '{"consumers": []}' > "$FAKE_INFRA/core/config/infra-consumers.json"

A_OUT="$(bash "$SETUP" "$FAKE_INFRA" 2>&1)"; A_RC=$?
assert_rc "infra-marker PROJECT_DIR refused" "$A_RC" "1"
assert_contains "refusal names PROJECT_DIR"            "$A_OUT" "$FAKE_INFRA"
assert_contains "refusal names INFRA_DIR"              "$A_OUT" "INFRA_DIR is ${REPO_ROOT}"
assert_contains "refusal explains it is an infra repo" "$A_OUT" "is an infra repo, not a consumer"
# The guard must fire BEFORE any linking — no .claude/ symlinks should be created.
total=$((total + 1))
if [ ! -d "$FAKE_INFRA/.claude/agents" ]; then
  echo "PASS: no symlinks created against the refused infra dir"
else
  failures=$((failures + 1))
  echo "FAIL: symlinks were created against the refused infra dir"
fi

# ---------------------------------------------------------------------------
# (b) D3 — a normal consumer dir (no infra marker) proceeds PAST the guard.
#     Run setup.sh fully against the mktemp dir (safe: it only creates dirs +
#     symlinks under PROJECT_DIR). Assert the guard refusal is absent and the
#     framework dirs got created (proof we advanced past the guard).
# ---------------------------------------------------------------------------
FAKE_CONSUMER="$SCRATCH/fake-consumer"
mkdir -p "$FAKE_CONSUMER"

B_OUT="$(bash "$SETUP" "$FAKE_CONSUMER" 2>&1)"; B_RC=$?
assert_rc "normal consumer dir setup exits 0" "$B_RC" "0"
assert_not_contains "guard does NOT fire on normal consumer" "$B_OUT" "is an infra repo, not a consumer"
total=$((total + 1))
if [ -d "$FAKE_CONSUMER/docs/step-3-specs" ] && [ -d "$FAKE_CONSUMER/.claude/agents" ]; then
  echo "PASS: framework + .claude dirs created (advanced past guard)"
else
  failures=$((failures + 1))
  echo "FAIL: framework/.claude dirs not created — guard may have blocked a valid consumer"
fi

# ---------------------------------------------------------------------------
# (c) D4 — register-consumer.sh atomic-replace of infra-consumers.json.
#     Drive it via INFRA_CONSUMERS_FILE pointed at a mktemp registry. Assert the
#     post-state is correctly mutated, no tmp residue remains in the target dir,
#     and the infra-repo self-register case is refused.
# ---------------------------------------------------------------------------
REG="$SCRATCH/registry.json"
cat > "$REG" <<'EOF'
{
  "_comment": "test fixture",
  "_schema": {"consumers": [{"path": "~/x", "label": "y"}]},
  "consumers": []
}
EOF
CONSUMER_TARGET="$SCRATCH/some-consumer-repo"
mkdir -p "$CONSUMER_TARGET"

C_OUT="$(INFRA_CONSUMERS_FILE="$REG" bash "$REGISTER" "$CONSUMER_TARGET" testlabel 2>&1)"; C_RC=$?
assert_rc "register-consumer adds a new consumer" "$C_RC" "0"
assert_contains "register reports added" "$C_OUT" "REGISTER: added testlabel"

# Post-state: registry is valid JSON, _comment/_schema preserved, consumer present.
total=$((total + 1))
if jq -e '.consumers | length == 1' "$REG" >/dev/null 2>&1 \
   && jq -e '._comment != null and ._schema != null' "$REG" >/dev/null 2>&1 \
   && jq -e --arg l testlabel '.consumers[0].label == $l' "$REG" >/dev/null 2>&1; then
  echo "PASS: registry atomically mutated, metadata preserved, consumer present"
else
  failures=$((failures + 1))
  echo "FAIL: registry post-state incorrect after register-consumer"
  cat "$REG" >&2
fi

# Atomic-replace observable signal: no leftover tmp file in the registry's dir.
# register-consumer mktemp's into $TMPDIR/-/tmp then mv's onto $REG — a partial
# (non-atomic) write would tend to leave residue or a half-written target.
total=$((total + 1))
if [ -z "$(find "$SCRATCH" -maxdepth 1 -name 'register-consumer.*' 2>/dev/null)" ]; then
  echo "PASS: no register-consumer tmp residue beside the registry"
else
  failures=$((failures + 1))
  echo "FAIL: register-consumer tmp residue left behind (non-atomic write)"
fi

# Self-register refusal (CR-001, batch gate): the infra repo itself is refused.
SR_OUT="$(INFRA_CONSUMERS_FILE="$REG" bash "$REGISTER" "$REPO_ROOT" selftest 2>&1)"; SR_RC=$?
total=$((total + 1))
if [ "$SR_RC" -ne 0 ] && printf '%s' "$SR_OUT" | grep -q "refusing-to-register-the-infra-repo-itself"; then
  echo "PASS: register-consumer refuses the infra repo itself"
else
  failures=$((failures + 1))
  echo "FAIL: infra-repo self-register was not refused (rc=$SR_RC): $SR_OUT"
fi

# Idempotency: re-registering the same path is a no-op (does not double-write).
C2_OUT="$(INFRA_CONSUMERS_FILE="$REG" bash "$REGISTER" "$CONSUMER_TARGET" testlabel 2>&1)"; C2_RC=$?
assert_rc "re-register is a no-op" "$C2_RC" "0"
assert_contains "re-register reports already-present" "$C2_OUT" "REGISTER: already-present"
total=$((total + 1))
if jq -e '.consumers | length == 1' "$REG" >/dev/null 2>&1; then
  echo "PASS: idempotent — registry still has exactly one consumer"
else
  failures=$((failures + 1))
  echo "FAIL: re-register changed consumer count (not idempotent)"
fi

echo
echo "=== Summary: $((total - failures))/${total} passed ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0
