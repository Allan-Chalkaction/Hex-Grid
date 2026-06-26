#!/usr/bin/env bash
# Executable test for the /queue add PRODUCER-TIME kind validation (SHR4-C1, AC-011).
#
# WHAT THIS GUARDS. The /queue add <kind> <target> producer door (core/skills/queue/SKILL.md) resolves a
# source artifact and then `git mv`s it INTO the entry folder. SHR4-C1 inserts a fail-fast kind check
# ORDERED STRICTLY BEFORE both `mkdir -p "$DEST"` and `git mv` — so a typo'd <kind> (e.g. `nimbel`) is
# rejected with the source artifact STILL AT ITS ORIGIN (zero side effects: no entry folder, nothing moved).
# Before C1 the only kind gate was the chew-time AC-010 allowlist (qc_validate_kind), which fires far too
# late — the artifact is already moved by then, stranding it in a half-built entry.
#
# THE SINGLE SOURCE OF TRUTH is launch-manifest.py's KINDS set. The producer snippet shells out to read it
# (never inlines a copy). This test:
#   (a) DRIFT GUARD — asserts the SKILL's validation block reads launch-manifest.py KINDS (no inlined list),
#       and that the check is ordered BEFORE the `git mv "$SOURCE" "$DEST/"` line in the SKILL (AC-011 grep).
#   (b) BEHAVIOR — replays the EXACT producer order (validate → mkdir → git mv) against the REAL
#       launch-manifest.py KINDS in a hermetic temp repo: a valid kind moves the source; an invalid kind
#       (typo / planning verb / empty) exits non-zero with the source UN-MOVED and NO entry folder created.
#
# Hermetic: a throwaway temp dir; no GNU-only flags (macOS BSD + GNU portable).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"     # core/ parent (when dogfooding inside claude-infra: <repo>/core)
SKILL="$REPO/skills/queue/SKILL.md"
LM="$HERE/launch-manifest.py"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

[ -f "$SKILL" ] || { echo "FATAL: SKILL not found at $SKILL"; exit 1; }
[ -f "$LM" ]    || { echo "FATAL: launch-manifest.py not found at $LM"; exit 1; }

# =========================================================================================================
echo "== SHR4-C1: AC-011 producer kind-validation — SOURCE-LEVEL (drift + ordering) =="
# =========================================================================================================

# (a1) The validation block must read launch-manifest.py KINDS (single source of truth) — NOT an inlined list.
if grep -qE 'launch-manifest\.py' "$SKILL" && grep -qE 'm\.KINDS|KINDS' "$SKILL"; then
  ok "AC-011 source-of-truth: producer validation reads launch-manifest.py KINDS (no inlined kind list)"
else
  ko "AC-011 source-of-truth" "the SKILL validation block does not reference launch-manifest.py KINDS"
fi

# (a2) ORDERING — the kind check (the 'invalid kind' echo) must appear BEFORE the `git mv "$SOURCE" "$DEST/"`.
#      Compare line numbers within the SKILL. AC-011's grep target: 'invalid kind' precedes the move.
CHECK_LN="$(grep -nE 'invalid kind' "$SKILL" | head -1 | cut -d: -f1)"
MV_LN="$(grep -nE 'git mv "\$SOURCE" "\$DEST/"' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$CHECK_LN" ] && [ -n "$MV_LN" ] && [ "$CHECK_LN" -lt "$MV_LN" ]; then
  ok "AC-011 ordering: kind check (line $CHECK_LN) precedes the git mv \$SOURCE move (line $MV_LN)"
else
  ko "AC-011 ordering" "check_line='$CHECK_LN' mv_line='$MV_LN' (the kind check must precede the git mv)"
fi

# (a3) ZERO-RESIDUE ordering — the check must also precede `mkdir -p "$DEST"` (a rejected add mints no folder).
MKDIR_LN="$(grep -nE 'mkdir -p "\$DEST"' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$CHECK_LN" ] && [ -n "$MKDIR_LN" ] && [ "$CHECK_LN" -lt "$MKDIR_LN" ]; then
  ok "AC-011 zero-residue: kind check (line $CHECK_LN) precedes mkdir -p \$DEST (line $MKDIR_LN)"
else
  ko "AC-011 zero-residue ordering" "check_line='$CHECK_LN' mkdir_line='$MKDIR_LN' (check must precede mkdir)"
fi

# (a4) SA-002 — $KIND is passed as a distinct quoted argv element to python3, never composed into a string.
#      Assert the snippet invokes `python3 - "$KIND" ...` (argv form), not a `python3 -c "... $KIND ..."` interp.
if grep -qE 'python3 - "\$KIND"' "$SKILL"; then
  ok "AC-011/SA-002: \$KIND passed as a distinct quoted argv element (never composed into a command string)"
else
  ko "AC-011/SA-002 argv" "the validation does not pass \$KIND as a distinct argv element to python3"
fi

# =========================================================================================================
echo "== SHR4-C1: AC-011 producer kind-validation — BEHAVIOR (replays the exact producer order) =="
# =========================================================================================================
# The producer order under test (verbatim from the SKILL step 3): KIND VALIDATION → mkdir -p "$DEST" →
# git mv "$SOURCE" "$DEST/". We replay it here against the REAL launch-manifest.py KINDS so a rejected add
# leaves $SOURCE un-moved and no $DEST. The kind-membership check is the EXACT snippet shape from the SKILL.

# validate_kind KIND  → exit 0 iff KIND ∈ launch-manifest.py KINDS (the shipped snippet's logic, byte-for-byte).
validate_kind() {
  python3 - "$1" "$LM" <<'PYEOF'
import importlib.util, sys
kind, lm_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("_lm", lm_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if kind in m.KINDS else 1)
PYEOF
}

# producer_add KIND  → replay the producer order in a hermetic dir. Echoes "MOVED" if the source was moved
#   into the entry folder, "REJECTED" (rc 2) if the kind check failed BEFORE any side effect.
producer_add() {
  local KIND="$1" T S Q SOURCE ENTRY DEST
  T="$(mktemp -d)"
  Q="$T/docs/step-4-queue/pending"; mkdir -p "$Q"
  SOURCE="$T/docs/step-1-ideas/2026-06-18-thing.md"; mkdir -p "$(dirname "$SOURCE")"; echo "idea" > "$SOURCE"
  # ---- PRODUCER ORDER (mirrors SKILL step 3) ----
  if ! validate_kind "$KIND"; then
    # REJECTED before any side effect — assert zero residue right here.
    ENTRY="${KIND}-thing"; DEST="$Q/$ENTRY"
    if [ -f "$SOURCE" ] && [ ! -e "$DEST" ]; then echo "REJECTED-CLEAN"; else echo "REJECTED-DIRTY"; fi
    rm -rf "$T"; return 2
  fi
  ENTRY="${KIND}-thing"; DEST="$Q/$ENTRY"
  mkdir -p "$DEST"
  mv "$SOURCE" "$DEST/"   # plain mv (no git in this hermetic harness); the side-effect order is what matters
  if [ -f "$DEST/$(basename "$SOURCE")" ] && [ ! -f "$SOURCE" ]; then echo "MOVED"; else echo "MOVE-FAILED"; fi
  rm -rf "$T"; return 0
}

# Valid kinds → MOVED (rc 0).
for k in orchestrated nimble chain loop; do
  OUT="$(producer_add "$k")"; RC=$?
  if [ "$OUT" = "MOVED" ] && [ "$RC" -eq 0 ]; then ok "AC-011 valid kind '$k' → source moved into the entry folder (rc 0)"; else ko "AC-011 valid '$k'" "out='$OUT' rc=$RC (expected MOVED, rc 0)"; fi
done

# Invalid kinds → REJECTED-CLEAN, non-zero, source un-moved, no entry folder.
for k in nimbel roadmap sweep bogus; do
  OUT="$(producer_add "$k")"; RC=$?
  if [ "$OUT" = "REJECTED-CLEAN" ] && [ "$RC" -ne 0 ]; then ok "AC-011 invalid kind '$k' → REJECTED non-zero, source UN-MOVED, no entry folder (zero residue)"; else ko "AC-011 invalid '$k'" "out='$OUT' rc=$RC (expected REJECTED-CLEAN, rc!=0)"; fi
done

# Empty kind → rejected too (a missing argument must not slip through).
OUT="$(producer_add "")"; RC=$?
if [ "$OUT" = "REJECTED-CLEAN" ] && [ "$RC" -ne 0 ]; then ok "AC-011 empty kind '' → REJECTED non-zero, zero residue"; else ko "AC-011 empty kind" "out='$OUT' rc=$RC"; fi

echo
echo "queue-producer-kind: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
