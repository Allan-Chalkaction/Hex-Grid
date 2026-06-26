#!/usr/bin/env bash
# Synthetic harness for activation-check.py (ADR-103 W4 — BUILT_NOT_ACTIVATED surfacing).
# Regression fixture: an unwired seam (a script with zero live-path callers under core/)
# is flagged at wrap; a wired one is not. Each case runs in a throwaway git repo.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/core/scripts/activation-check.py"
[ -f "$SCRIPT" ] || { echo "ERROR: $SCRIPT not found" >&2; exit 1; }

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

# mk_repo → echoes a fresh temp git repo dir with a core/ tree + a run folder.
mk_repo() {
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p core/scripts core/hooks core/skills/foo "docs/step-5-pipeline/2026-06-14/RUN" )
  echo "$d"
}

mk_manifest() {  # mk_manifest <repo> <planned_files-json>
  printf '{"schema":"thin-manifest/1","track":"orchestrated","tickets":[{"key":"T-001","status":"complete","planned_files":%s}]}' \
    "$2" > "$1/docs/step-5-pipeline/2026-06-14/RUN/manifest.json"
}

run() { ( cd "$1" && python3 "$SCRIPT" check "docs/step-5-pipeline/2026-06-14/RUN" ); }

# ---- T1: a NEW script with NO caller anywhere → flagged (no references at all) ----
D=$(mk_repo)
printf '#!/usr/bin/env python3\nprint("hi")\n' > "$D/core/scripts/orphan.py"
mk_manifest "$D" '["core/scripts/orphan.py"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "BUILT_NOT_ACTIVATED" && echo "$out" | grep -q "orphan.py" \
   && echo "$out" | grep -q "no references at all"; then
  ok "an uncalled new script is flagged BUILT_NOT_ACTIVATED (no references at all)"
else
  ko "orphan flagged" "rc=$rc out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$D"

# ---- T2: a script referenced ONLY by a test → flagged (test-only; built+tested, not wired) ----
D=$(mk_repo)
printf 'print("x")\n' > "$D/core/scripts/tested-only.py"
printf 'python3 core/scripts/tested-only.py\n' > "$D/core/scripts/test-tested-only.sh"
mk_manifest "$D" '["core/scripts/tested-only.py"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "tested-only.py" && echo "$out" | grep -qi "only test references"; then
  ok "a test-only-referenced script is flagged (built + tested but not wired)"
else
  ko "test-only flagged" "rc=$rc out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$D"

# ---- T3: a script wired by a LIVE caller (a skill) → NOT flagged ----
D=$(mk_repo)
printf 'print("x")\n' > "$D/core/scripts/wired.py"
printf 'Run: python3 core/scripts/wired.py at lock.\n' > "$D/core/skills/foo/SKILL.md"
mk_manifest "$D" '["core/scripts/wired.py"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ACTIVATION OK" && ! echo "$out" | grep -q "BUILT_NOT_ACTIVATED"; then
  ok "a script wired by a live caller (skill) is NOT flagged"
else
  ko "wired not flagged" "rc=$rc out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$D"

# ---- T4: a NEW hook not registered in settings → flagged; registering it clears the flag ----
D=$(mk_repo)
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/core/hooks/new-guard.sh"
mk_manifest "$D" '["core/hooks/new-guard.sh"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1)
flagged_before=$(echo "$out" | grep -q "new-guard.sh" && echo yes || echo no)
mkdir -p "$D/core/config/global"
printf '{"hooks":{"PreToolUse":[{"command":"core/hooks/new-guard.sh"}]}}\n' > "$D/core/config/global/settings.json"
( cd "$D" && git add -A >/dev/null && git commit -qm reg )
out2=$(run "$D" 2>&1)
flagged_after=$(echo "$out2" | grep -q "new-guard.sh" && echo yes || echo no)
if [ "$flagged_before" = "yes" ] && [ "$flagged_after" = "no" ]; then
  ok "an unregistered hook is flagged; a settings.json registration clears it"
else
  ko "hook registration" "before=$flagged_before after=$flagged_after"
fi
rm -rf "$D"

# ---- T5: a wireable file is its OWN reference only → still flagged (self-ref doesn't activate) ----
D=$(mk_repo)
printf '# core/scripts/selfref.py mentions itself\nprint("x")\n' > "$D/core/scripts/selfref.py"
mk_manifest "$D" '["core/scripts/selfref.py"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1)
if echo "$out" | grep -q "selfref.py"; then ok "a file referencing only itself is still flagged (self-ref ≠ activation)"; else ko "self-ref" "not flagged"; fi
rm -rf "$D"

# ---- T6: non-wireable planned files (docs/rules/agents) → not applicable, never flagged ----
D=$(mk_repo)
printf 'a rule\n' > "$D/core/scripts/note.md"   # .md is not wireable
mk_manifest "$D" '["core/rules/rules-x.md","docs/decisions/ADR-200-x.md","core/scripts/note.md"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qi "no wireable"; then
  ok "non-wireable planned files (docs/rules/.md) → not applicable, nothing flagged"
else
  ko "non-wireable skip" "rc=$rc out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$D"

# ---- T8: a JS module wired via EXTENSIONLESS require() → NOT flagged (CR-001) ----
# Node resolves require("./_lib/click") without ".js"; the basename "click.js" never appears in the
# caller, so a naive basename grep would false-positive. The extensionless-stem term fixes it.
D=$(mk_repo)
mkdir -p "$D/core/hooks/_lib"
printf 'module.exports = {};\n' > "$D/core/hooks/_lib/click.js"
printf 'const click = require("./_lib/click");\nclick;\n' > "$D/core/hooks/notify.js"
mk_manifest "$D" '["core/hooks/_lib/click.js"]'
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ACTIVATION OK" && ! echo "$out" | grep -q "click.js"; then
  ok "a JS module wired via extensionless require() is NOT flagged (stem match — CR-001 fix)"
else
  ko "extensionless require" "rc=$rc out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$D"

# ---- T7: nimble run (manifest without tickets[]) → not applicable, exit 0 ----
D=$(mk_repo)
printf '{"schema":"thin-manifest/1","track":"nimble","steps":[{"phase":"implement","status":"complete"}]}' \
  > "$D/docs/step-5-pipeline/2026-06-14/RUN/manifest.json"
( cd "$D" && git add -A >/dev/null && git commit -qm init )
out=$(run "$D" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -qi "not applicable"; then
  ok "nimble run (no tickets[]) → not applicable (exit 0)"
else
  ko "nimble skip" "rc=$rc"
fi
rm -rf "$D"

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
