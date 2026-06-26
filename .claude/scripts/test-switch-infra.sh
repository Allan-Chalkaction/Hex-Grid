#!/usr/bin/env bash
#
# test-switch-infra.sh — hermetic self-test for switch-infra.sh.
#
# Exercises the FULL switch logic (symlink repoint, global settings.json + CLAUDE.md
# swap, settings.local.json preservation, consumer refresh+validate, status,
# idempotency) against a throwaway sandbox HOME + fake v1/v2 repos + fake consumer.
# Touches NO live state (~/.claude and real consumers are never referenced) via the
# SWITCH_INFRA_{CLAUDE_HOME,V1_REPO,V2_REPO,REGISTRY} env overrides.
#
# Run: core/scripts/test-switch-infra.sh   (exit 0 = all asserts pass)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWITCH="$(cd "$SCRIPT_DIR/../.." && pwd)/switch-infra.sh"
[ -f "$SWITCH" ] || { echo "FAIL: switch-infra.sh not found at $SWITCH"; exit 1; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert_eq() { [ "$2" = "$3" ] && ok "$1 ($2)" || no "$1: expected [$3] got [$2]"; }

# --- Build a fake substrate repo: $1=dir $2=tag ------------------------------
make_repo() {
  local dir="$1" tag="$2" d
  for d in agents commands hooks rules skills; do
    mkdir -p "$dir/core/$d"
    echo "$tag" > "$dir/core/$d/marker.txt"
  done
  mkdir -p "$dir/core/config/global"
  printf '{"version":"%s"}\n' "$tag" > "$dir/core/config/global/settings.json"
  printf '# CLAUDE %s\n' "$tag" > "$dir/core/config/global/CLAUDE.md"
  # T6: only the v2 fake repo carries a required-plugins pin (v1 has none -> graceful).
  if [ "$tag" = "v2" ]; then
    printf '{"schema":"required-plugins/1","plugins":[{"id":"ralph-loop","enable_key":"ralph-loop@claude-plugins-official","pinned_version":"1.0.0"}]}\n' \
      > "$dir/core/config/required-plugins.json"
  fi
  # Minimal setup.sh stub mirroring the real --refresh/--validate contract.
  cat > "$dir/setup.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSUMER=""; REFRESH=false; VALIDATE=false
while [ $# -gt 0 ]; do case "$1" in
  --refresh) REFRESH=true; shift;; --validate) VALIDATE=true; shift;;
  *) CONSUMER="$1"; shift;; esac; done
if $VALIDATE; then
  total=0; broken=0
  while IFS= read -r l; do total=$((total+1)); [ -e "$l" ] || broken=$((broken+1)); done \
    < <(find "$CONSUMER/.claude" -type l 2>/dev/null)
  echo "Total symlinks: $total"; echo "Broken: $broken"; exit "$broken"
fi
if $REFRESH; then
  for d in agents commands hooks rules skills; do
    mkdir -p "$CONSUMER/.claude/$d"
    ln -sfn "$INFRA_DIR/core/$d/marker.txt" "$CONSUMER/.claude/$d/marker.txt"
  done
fi
STUB
  chmod +x "$dir/setup.sh"
}

V1="$SANDBOX/v1"; V2="$SANDBOX/v2"
make_repo "$V1" v1
make_repo "$V2" v2

# --- Fake consumer + registry ------------------------------------------------
CONSUMER="$SANDBOX/consumer"
mkdir -p "$CONSUMER/.claude"
REG="$SANDBOX/registry.json"
printf '{"consumers":[{"path":"%s","label":"fake"}]}\n' "$CONSUMER" > "$REG"

# --- Fake HOME/.claude initially wired to v1 ---------------------------------
HOMEDIR="$SANDBOX/home"
CH="$HOMEDIR/.claude"
mkdir -p "$CH"
for d in agents commands hooks rules skills; do ln -sfn "$V1/core/$d" "$CH/$d"; done
echo '{"version":"v1"}' > "$CH/settings.json"
echo '# CLAUDE v1' > "$CH/CLAUDE.md"
# settings.local sentinel — must NEVER change (AC-3)
echo '{"local":"DO-NOT-TOUCH"}' > "$CH/settings.local.json"
LOCAL_SHA_BEFORE="$(shasum "$CH/settings.local.json" | awk '{print $1}')"

export SWITCH_INFRA_CLAUDE_HOME="$CH"
export SWITCH_INFRA_V1_REPO="$V1"
export SWITCH_INFRA_V2_REPO="$V2"
export SWITCH_INFRA_REGISTRY="$REG"

run() { bash "$SWITCH" "$@"; }

echo "== switch -> v2 =="
run v2 >/dev/null
assert_eq "agents symlink -> v2"  "$(readlink "$CH/agents")" "$V2/core/agents"
assert_eq "hooks symlink -> v2"   "$(readlink "$CH/hooks")"  "$V2/core/hooks"
assert_eq "global settings.json = v2" "$(cat "$CH/settings.json")" '{"version":"v2"}'
assert_eq "global CLAUDE.md = v2"     "$(cat "$CH/CLAUDE.md")"     '# CLAUDE v2'
assert_eq "status reports v2"     "$(run status | head -1)" "ACTIVE: v2"
assert_eq "consumer refreshed -> v2" "$(readlink "$CONSUMER/.claude/agents/marker.txt")" "$V2/core/agents/marker.txt"
assert_eq "settings.local untouched (AC-3)" "$(shasum "$CH/settings.local.json" | awk '{print $1}')" "$LOCAL_SHA_BEFORE"
[ -f "$CH/settings.json.switch-bak" ] && ok "settings.json.switch-bak created" || no "no settings.json.switch-bak"
# T6: plugin-pin status reports the v2 manifest's ralph-loop as NOT-ENABLED (no enabledPlugins in $CH/settings.json)
run status | grep -Eq '^  ralph-loop .*pin=1.0.0 .*NOT-ENABLED' && ok "status reports ralph-loop pin NOT-ENABLED" || no "plugin-pin status (NOT-ENABLED) missing"
# now enable it in the sandbox global settings and re-check -> enabled
printf '{"version":"v2","enabledPlugins":{"ralph-loop@claude-plugins-official":true}}\n' > "$CH/settings.json"
run status | grep -Eq '^  ralph-loop .*pin=1.0.0 .*enabled' && ok "status reports ralph-loop enabled when present in enabledPlugins" || no "plugin-pin status (enabled) missing"

echo "== switch -> v1 (round-trip) =="
run v1 >/dev/null
assert_eq "agents symlink -> v1"  "$(readlink "$CH/agents")" "$V1/core/agents"
assert_eq "global settings.json = v1" "$(cat "$CH/settings.json")" '{"version":"v1"}'
assert_eq "global CLAUDE.md = v1"     "$(cat "$CH/CLAUDE.md")"     '# CLAUDE v1'
assert_eq "status reports v1"     "$(run status | head -1)" "ACTIVE: v1"
assert_eq "consumer refreshed -> v1" "$(readlink "$CONSUMER/.claude/agents/marker.txt")" "$V1/core/agents/marker.txt"
assert_eq "settings.local STILL untouched (AC-3)" "$(shasum "$CH/settings.local.json" | awk '{print $1}')" "$LOCAL_SHA_BEFORE"
# T6 (CR-006): v1 has no required-plugins manifest -> plugin section prints the graceful line, exit 0
run status | grep -q '(no required-plugins manifest for the active substrate)' \
  && ok "v1 (no manifest) -> plugin section prints graceful line" || no "v1 graceful plugin-status missing"

echo "== idempotency: v1 again =="
run v1 >/dev/null
assert_eq "still v1 after repeat" "$(run status | head -1)" "ACTIVE: v1"
assert_eq "settings.local untouched after repeat" "$(shasum "$CH/settings.local.json" | awk '{print $1}')" "$LOCAL_SHA_BEFORE"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
