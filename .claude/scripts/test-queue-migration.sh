#!/usr/bin/env bash
# test-queue-migration.sh — Wave E (SHR3-T8) migration safety assertions (ADR-127 / F-006; AC-025 + AC-026).
#
# This test proves the THREE load-bearing properties of the pipeline-global renumber:
#
#   (a) AC-025 — the F-006 pre-flight is a HARD GATE, not advisory. Seed a REAL in-flight queue entry
#       (an <entry>/sidecar.json folder — the entry-as-folder shape, ADR-124) and assert
#       queue-migrate-preflight.py REFUSES (exits NON-ZERO). A bare `.gitkeep` is NOT an entry — assert the
#       gate PASSES on a clean queue (no false refusal).
#
#   (b) AC-026 — the migration is REVERSIBLE by inverse `git mv` (no `git rm`, no backfill). Set up the OLD
#       three-dir layout in a temp repo, perform the forward `git mv` set, then the inverse, and assert the
#       tree is byte-identical to the original (git status clean, every path restored).
#
#   AC-MIG-1 (ADR-127's binding AC — the crash-consistency invariant survives the renumber). The post-renumber
#       chew drain still moves the entry FOLDER (`running/ → done/`) BEFORE the manifest `set`. We assert this
#       structurally: qc_apply_outcome (the lib's drain) performs the `git mv` and the lib NEVER calls
#       `launch-manifest.py set` (the manifest write is the SESSION's job, AFTER the lib returns) — so the
#       move-first/manifest-second ordering (ADR-123 D-3 invariant #2 / F-004) is preserved by construction.
#
# CITES: ADR-127 (the migration contract + four preserved invariants), ADR-127 F-006 (the pre-flight gate),
# ADR-124 (entry-as-folder), ADR-123 D-3 (crash-consistency ordering / done-success-only terminal).
set -uo pipefail

PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
PREFLIGHT="$REPO_ROOT/core/scripts/queue-migrate-preflight.py"
LIB="$REPO_ROOT/core/scripts/queue-chew-lib.sh"

[ -f "$PREFLIGHT" ] || { echo "FATAL: preflight not found: $PREFLIGHT"; exit 1; }
[ -f "$LIB" ] || { echo "FATAL: chew lib not found: $LIB"; exit 1; }

echo "== test-queue-migration.sh (ADR-127 / F-006; AC-025, AC-026, AC-MIG-1) =="

# -----------------------------------------------------------------------------------------------------------
# Helper: a self-contained temp git repo with the preflight script in place + an OLD-layout queue tree.
# -----------------------------------------------------------------------------------------------------------
new_temp_repo() {
  local w; w="$(mktemp -d)"
  git -C "$w" init -q
  git -C "$w" config user.email t@t.t
  git -C "$w" config user.name t
  mkdir -p "$w/core/scripts"
  cp "$PREFLIGHT" "$w/core/scripts/queue-migrate-preflight.py"
  # OLD three-dir layout the renumber moves (only the queue lifecycle skeleton is needed for the gate).
  mkdir -p "$w/docs/queue/pending" "$w/docs/queue/running" "$w/docs/queue/done" "$w/docs/queue/failed"
  : > "$w/docs/queue/pending/.gitkeep"
  : > "$w/docs/queue/running/.gitkeep"
  : > "$w/docs/queue/done/.gitkeep"
  : > "$w/docs/queue/failed/.gitkeep"
  mkdir -p "$w/docs/step-4-pipeline" "$w/docs/step-5-done"
  : > "$w/docs/step-4-pipeline/.gitkeep"
  : > "$w/docs/step-5-done/.gitkeep"
  git -C "$w" add -A >/dev/null
  git -C "$w" commit -qm init
  printf '%s' "$w"
}

# ===========================================================================================================
# (a) AC-025 — the pre-flight is a HARD GATE.
# ===========================================================================================================
echo "-- (a) AC-025: pre-flight refuses an in-flight entry; passes a clean queue --"

# a1. CLEAN queue (only .gitkeep) → the gate PASSES (exit 0). No false refusal.
W1="$(new_temp_repo)"
if ( cd "$W1" && python3 core/scripts/queue-migrate-preflight.py >/dev/null 2>&1 ); then
  ok "clean queue (only .gitkeep) PASSES the gate (exit 0) — no false refusal"
else
  ko "clean queue PASSES" "the gate refused a CLEAN queue (.gitkeep is not an entry; should pass)"
fi
rm -rf "$W1"

# a2. SEED a REAL in-flight pending entry (<entry>/sidecar.json) → the gate REFUSES (exit non-zero).
W2="$(new_temp_repo)"
mkdir -p "$W2/docs/queue/pending/some-entry"
printf '{"verb":"orchestrated","label":"some-entry","seq":1,"target":"."}' > "$W2/docs/queue/pending/some-entry/sidecar.json"
: > "$W2/docs/queue/pending/some-entry/some-entry.md"
git -C "$W2" add -A >/dev/null && git -C "$W2" commit -qm seed-inflight
if ( cd "$W2" && python3 core/scripts/queue-migrate-preflight.py >/dev/null 2>&1 ); then
  ko "in-flight PENDING entry REFUSES" "the gate PASSED with a real pending/<entry>/sidecar.json (should refuse, non-zero)"
else
  ok "in-flight PENDING entry REFUSES (exit non-zero) — gate is hard, not advisory"
fi
rm -rf "$W2"

# a3. SEED a REAL in-flight RUNNING entry → the gate REFUSES too (both stages are in-flight).
W3="$(new_temp_repo)"
mkdir -p "$W3/docs/queue/running/run-entry"
printf '{"verb":"nimble","label":"run-entry","seq":1,"target":"."}' > "$W3/docs/queue/running/run-entry/sidecar.json"
git -C "$W3" add -A >/dev/null && git -C "$W3" commit -qm seed-running
if ( cd "$W3" && python3 core/scripts/queue-migrate-preflight.py >/dev/null 2>&1 ); then
  ko "in-flight RUNNING entry REFUSES" "the gate PASSED with a real running/<entry>/sidecar.json (should refuse)"
else
  ok "in-flight RUNNING entry REFUSES (exit non-zero)"
fi
rm -rf "$W3"

# ===========================================================================================================
# (b) AC-026 — the renumber is REVERSIBLE by inverse `git mv` (no git rm, no backfill).
# ===========================================================================================================
echo "-- (b) AC-026: forward git-mv set is reversible by inverse git-mv --"

WR="$(new_temp_repo)"
# Capture the original tracked-tree signature.
ORIG_SIG="$(git -C "$WR" ls-files | sort | sha1sum | cut -d' ' -f1)"

# Forward: the three atomic renames (queue→step-4-queue, step-4-pipeline→step-5-pipeline, step-5-done→step-6-done).
(
  cd "$WR"
  git mv docs/queue docs/step-4-queue
  git mv docs/step-4-pipeline docs/step-5-pipeline
  git mv docs/step-5-done docs/step-6-done
) >/dev/null 2>&1
FWD_OK=0
[ -d "$WR/docs/step-4-queue" ] && [ -d "$WR/docs/step-5-pipeline" ] && [ -d "$WR/docs/step-6-done" ] \
  && [ ! -e "$WR/docs/queue" ] && [ ! -e "$WR/docs/step-4-pipeline" ] && [ ! -e "$WR/docs/step-5-done" ] && FWD_OK=1
if [ "$FWD_OK" -eq 1 ]; then ok "forward git mv set lands new names; old names gone"; else ko "forward git mv set" "new/old layout not as expected"; fi

# Inverse: restore the prior layout.
(
  cd "$WR"
  git mv docs/step-4-queue docs/queue
  git mv docs/step-5-pipeline docs/step-4-pipeline
  git mv docs/step-6-done docs/step-5-done
) >/dev/null 2>&1
REV_SIG="$(git -C "$WR" ls-files | sort | sha1sum | cut -d' ' -f1)"
if [ "$REV_SIG" = "$ORIG_SIG" ]; then
  ok "inverse git mv restores the EXACT prior layout (tracked-tree signature identical)"
else
  ko "inverse git mv reversibility" "tracked-tree signature differs after round-trip (orig=$ORIG_SIG rev=$REV_SIG)"
fi
# No git rm: every original path is still tracked (round-trip preserved file count).
ORIG_N="$(git -C "$WR" ls-files | wc -l | tr -d ' ')"
if [ "$ORIG_N" -ge 6 ]; then ok "no git rm — all tracked queue/pipeline paths survive the round-trip ($ORIG_N tracked)"; else ko "no git rm" "tracked file count dropped ($ORIG_N)"; fi
rm -rf "$WR"

# ===========================================================================================================
# AC-MIG-1 — crash-consistency ordering survives the renumber (folder mv FIRST, manifest set SECOND).
# ===========================================================================================================
echo "-- AC-MIG-1 (ADR-127): post-renumber drain moves the folder BEFORE the manifest set --"

# AC-MIG-1.1 (structural): the lib NEVER calls `launch-manifest.py set` — the manifest write is the SESSION's
# job, performed AFTER qc_settle returns. So the lib's drain (qc_apply_outcome's `git mv`) is ALWAYS before
# any manifest set, on the new path exactly as on the old (re-point did not touch the ordering).
if grep -qE 'launch-manifest\.py[[:space:]]+set' "$LIB"; then
  ko "lib does no manifest set" "queue-chew-lib.sh calls 'launch-manifest.py set' — manifest write must stay session-level (would break mv-first ordering)"
else
  ok "lib does NO manifest 'set' — manifest write stays session-level (move-first/manifest-second preserved)"
fi

# AC-MIG-1.2 (behavioral): qc_apply_outcome performs the folder `git mv` (running→done) on the RENUMBERED
# root, and the entry is in done/ when the function returns — proving the move is the lib's deterministic act
# that precedes any session-level manifest write. Run against QUEUE_DIR=docs/step-4-queue (the NEW root).
WM="$(mktemp -d)"
git -C "$WM" init -q; git -C "$WM" config user.email t@t.t; git -C "$WM" config user.name t
mkdir -p "$WM/docs/step-4-queue/pending" "$WM/docs/step-4-queue/running" "$WM/docs/step-4-queue/done" "$WM/docs/step-4-queue/failed"
mkdir -p "$WM/docs/step-4-queue/running/drain-me"
printf '{"verb":"nimble","label":"drain-me","seq":1,"target":"."}' > "$WM/docs/step-4-queue/running/drain-me/sidecar.json"
: > "$WM/docs/step-4-queue/running/drain-me/drain-me.md"
git -C "$WM" add -A >/dev/null && git -C "$WM" commit -qm seed
(
  cd "$WM"
  # shellcheck disable=SC1090
  . "$LIB"
  export QUEUE_DIR="docs/step-4-queue"
  out="$(qc_apply_outcome "drain-me" 0 "")"   # launch_rc=0, clean tree → SUCCESS → running/→done/
  [ "$out" = "done" ] || { echo "OUTCOME=$out"; exit 21; }
  [ -d "docs/step-4-queue/done/drain-me" ] || exit 22       # moved INTO done/ on the new root
  [ ! -e "docs/step-4-queue/running/drain-me" ] || exit 23  # left running/
)
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "qc_apply_outcome drains running→done on the RENUMBERED root (docs/step-4-queue) — folder move is the lib's act, BEFORE any manifest set"
else
  ko "qc_apply_outcome on renumbered root" "drain failed on docs/step-4-queue (rc=$RC)"
fi
rm -rf "$WM"

# AC-MIG-1.3 (terminal split survives): a FAILURE drains running→FAILED (never done/) on the new root —
# ADR-123 D-3 invariant #4 (done/=success-only) preserved through the renumber.
WF="$(mktemp -d)"
git -C "$WF" init -q; git -C "$WF" config user.email t@t.t; git -C "$WF" config user.name t
mkdir -p "$WF/docs/step-4-queue/running/fail-me" "$WF/docs/step-4-queue/done" "$WF/docs/step-4-queue/failed"
printf '{"verb":"nimble","label":"fail-me","seq":1,"target":"."}' > "$WF/docs/step-4-queue/running/fail-me/sidecar.json"
git -C "$WF" add -A >/dev/null && git -C "$WF" commit -qm seed
(
  cd "$WF"
  # shellcheck disable=SC1090
  . "$LIB"
  export QUEUE_DIR="docs/step-4-queue"
  out="$(qc_apply_outcome "fail-me" 1 "")"   # launch_rc=1 → FAILURE → running/→failed/
  [ "$out" = "failed" ] || exit 31
  [ -d "docs/step-4-queue/failed/fail-me" ] || exit 32
  [ ! -e "docs/step-4-queue/done/fail-me" ] || exit 33   # NEVER done/
)
RC=$?
if [ "$RC" -eq 0 ]; then
  ok "failure drains running→FAILED (never done/) on the renumbered root — done/=success-only invariant preserved (ADR-123 D-3 #4)"
else
  ko "terminal split on renumbered root" "failure did not land in failed/ cleanly (rc=$RC)"
fi
rm -rf "$WF"

# -----------------------------------------------------------------------------------------------------------
echo
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
