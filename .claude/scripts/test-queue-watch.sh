#!/usr/bin/env bash
# Executable test for queue-watch.sh — the walk-away watcher (ADR-124, Wave 4) — and the CR-002 skip-sink.
# Verifies: (1) an empty queue exits after --max-idle WITHOUT launching a chew; (2) a dep-ready entry LAUNCHES
# the (stubbed) chew and --max-runs bounds it; (3) the QC_SKIP skip-sink excludes a rejected/refused entry so
# qc_pick_entry advances instead of re-picking it (the unattended busy-loop CR-002 closes).
# Portable (macOS BSD): the watcher's sleep fallback is used when inotifywait is absent. Fast bounds.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# Portable timeout safety-net: GNU `timeout` (linux), `gtimeout` (macOS+coreutils), else run direct (the
# watcher self-bounds via --max-idle/--max-runs, so the net is belt-and-suspenders). Avoids the GNU-only
# `timeout` rc-127 trap — the exact portability class this epic exists to fix.
_to() { local secs="$1"; shift; if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; else "$@"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export QUEUE_DIR="$W/docs/step-4-queue"
mkdir -p "$QUEUE_DIR/pending" "$QUEUE_DIR/running" "$QUEUE_DIR/done" "$QUEUE_DIR/failed"

# A stub chew: records that it ran, then "drains" the queue (removes all pending entries) so the watcher
# re-arms to an empty queue. Pointed at via QUEUE_CHEW_CMD (no eval; a program path).
STUB="$W/stub-chew.sh"
cat > "$STUB" <<STUBEOF
#!/usr/bin/env bash
echo "ran" >> "$W/chew-ran.log"
rm -rf "$QUEUE_DIR"/pending/*
STUBEOF
chmod +x "$STUB"

# Helper: write a dep-ready pending entry (folder + sidecar) the watcher's qc_pick_entry will see.
mk_entry() {
  local name="$1" seq="$2"
  mkdir -p "$QUEUE_DIR/pending/$name"
  python3 -c "import json;json.dump({'label':'$name','verb':'nimble','seq':$seq,'target':'.'},open('$QUEUE_DIR/pending/$name/sidecar.json','w'))"
  echo "x" > "$QUEUE_DIR/pending/$name/a.md"
}

# ---------------------------------------------------------------------------------------------------------
# TEST 1 — empty queue: exits after --max-idle WITHOUT launching a chew.
# ---------------------------------------------------------------------------------------------------------
rm -f "$W/chew-ran.log"
QUEUE_CHEW_CMD="$STUB" _to 20 bash "$HERE/queue-watch.sh" --queue "$QUEUE_DIR" --max-idle 1 --interval 1 --max-runs 5 >/dev/null 2>&1
RC=$?
{ [ "$RC" -eq 0 ] && [ ! -f "$W/chew-ran.log" ]; } \
  && ok "empty queue → watcher exits on max-idle WITHOUT launching a chew" \
  || ko "idle-exit" "rc=$RC chew-ran=$([ -f "$W/chew-ran.log" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------------------------------------
# TEST 2 — a dep-ready entry LAUNCHES the chew; --max-runs bounds the watcher.
# ---------------------------------------------------------------------------------------------------------
rm -f "$W/chew-ran.log"
mk_entry "nimble-job" 100
QUEUE_CHEW_CMD="$STUB" _to 20 bash "$HERE/queue-watch.sh" --queue "$QUEUE_DIR" --max-idle 5 --interval 1 --max-runs 1 >/dev/null 2>&1
RC=$?
RUNS=$([ -f "$W/chew-ran.log" ] && wc -l < "$W/chew-ran.log" | tr -d ' ' || echo 0)
{ [ "$RC" -eq 0 ] && [ "$RUNS" -eq 1 ]; } \
  && ok "dep-ready entry → watcher LAUNCHES the chew (run count $RUNS), max-runs bounds it" \
  || ko "launch-on-entry" "rc=$RC runs=$RUNS"
{ [ -z "$(ls -A "$QUEUE_DIR/pending" 2>/dev/null)" ]; } \
  && ok "the stubbed chew drained pending/ (watcher re-armed to empty)" \
  || ko "drain" "pending/ not empty after chew"

# ---------------------------------------------------------------------------------------------------------
# TEST 3 — CR-002 skip-sink: QC_SKIP excludes a rejected/refused entry so qc_pick_entry advances.
# ---------------------------------------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$HERE/queue-chew-lib.sh"
rm -rf "$QUEUE_DIR"/pending/*
mk_entry "nimble-bad" 100      # the entry we'll pretend was rejected/refused
mk_entry "nimble-good" 200     # an independent, later entry
PICK_ALL="$(QC_SKIP='' qc_pick_entry)"
PICK_SKIP="$(QC_SKIP='nimble-bad' qc_pick_entry)"
{ [ "$PICK_ALL" = "nimble-bad" ] && [ "$PICK_SKIP" = "nimble-good" ]; } \
  && ok "skip-sink: QC_SKIP excludes the rejected entry → pick advances to the next (nimble-good), no re-pick spin" \
  || ko "skip-sink" "all=$PICK_ALL skip=$PICK_SKIP"
# When ALL remaining entries are skipped, the pick is empty → the daemon reaches WRAP (no spin).
{ [ -z "$(QC_SKIP='nimble-bad nimble-good' qc_pick_entry)" ]; } \
  && ok "skip-sink: all remaining entries skipped → empty pick (daemon reaches WRAP, never busy-loops)" \
  || ko "skip-sink WRAP" "expected empty pick"

# ---------------------------------------------------------------------------------------------------------
# TEST 4 — CR-001 no-progress guard: a dep-ready entry that NEVER drains must NOT busy-loop. The watcher
# exits after --max-stall launches (bounded), not unbounded.
# ---------------------------------------------------------------------------------------------------------
rm -rf "$QUEUE_DIR"/pending/* "$W/chew-ran.log"
# A stub that RUNS but does NOT drain (leaves the entry dep-ready) — models a refused raw plan un-drained
# back to pending/. The watcher must detect no-progress and exit after --max-stall, capping launches.
STUB_NODRAIN="$W/stub-nodrain.sh"
cat > "$STUB_NODRAIN" <<NDEOF
#!/usr/bin/env bash
echo "ran" >> "$W/chew-ran.log"
NDEOF
chmod +x "$STUB_NODRAIN"
mk_entry "nimble-stuck" 100
QUEUE_CHEW_CMD="$STUB_NODRAIN" _to 20 bash "$HERE/queue-watch.sh" --queue "$QUEUE_DIR" --max-idle 60 --interval 1 --max-stall 2 >/dev/null 2>&1
RC=$?
RUNS=$([ -f "$W/chew-ran.log" ] && wc -l < "$W/chew-ran.log" | tr -d ' ' || echo 0)
{ [ "$RC" -eq 0 ] && [ "$RUNS" -le 2 ] && [ "$RUNS" -ge 1 ]; } \
  && ok "no-progress guard: a never-draining entry exits after max-stall ($RUNS launches, bounded — no hot spin)" \
  || ko "no-progress" "rc=$RC runs=$RUNS (expected 1..2, bounded)"

echo ""
echo "queue-watch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
