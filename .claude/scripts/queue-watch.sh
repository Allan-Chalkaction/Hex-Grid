#!/usr/bin/env bash
# queue-watch.sh — the WALK-AWAY watcher for the autonomous work queue (ADR-124, Wave 4).
#
# THE LIVENESS HALF of "feed work and walk away". `/queue-chew` exits when nothing is dep-ready (so a Claude
# session never spins). But that means a producer append AFTER a drain strands in pending/ until someone
# manually re-invokes the chew. This watcher closes that gap: it re-launches a one-shot chew when pending/
# gains a dep-ready entry.
#
# THE ARCHITECTURAL CATCH (from the dogfood finding): a Claude session cannot cheaply busy-wait — idling an
# LLM chew session burns context/tokens just to re-poll. So the EXPENSIVE LLM chew is EVENT-DRIVEN, not
# poll-driven: this is a THIN SHELL watcher that waits cheaply (inotifywait if available, else sleep) and
# launches a fresh chew session ONLY when a new dep-ready entry appears. The LLM does real work, exits, and
# this cheap watcher re-arms.
#
# BOUNDED (anti-limbo, ADR-087 spirit): exits after --max-idle seconds with no dep-ready entry, or after
# --max-runs chew launches. A heartbeat is logged each idle tick so a forgotten watch is visible.
#
# ADR-093 reconciliation: this adds NO survival state. Each launched chew re-derives lifecycle from the
# folder (location-is-status); the watcher only decides WHEN to launch. ADR-093 handles restart across the
# usage window; this handles drained-then-new-work — different problems, composable.
#
# SHARED-STATE FLOOR (ADR-105 / rules-git.md): the watcher NEVER merges/pushes. It only launches chews, and a
# chew only STACKS branches + queues the merge lever. No `git push origin main` / `gh pr merge` / `--force`
# exists in this script.
#
# Usage: queue-watch.sh [--max-idle SECS] [--max-runs N] [--interval SECS] [--queue DIR]
#   Defaults: --max-idle 300, --max-runs 0 (unbounded), --interval 5, --queue ${QUEUE_DIR:-docs/step-4-queue}.
#   The chew command is ${QUEUE_CHEW_CMD:-claude -p "/queue-chew"} (override via QUEUE_CHEW_CMD; tests point it
#   at a stub). QUEUE_CHEW_CMD is run as a single program path (no eval) — it is operator/test-supplied.
set -uo pipefail

MAX_IDLE=300; MAX_RUNS=0; INTERVAL=5; MAX_STALL=3; QDIR="${QUEUE_DIR:-docs/step-4-queue}"
while [ $# -gt 0 ]; do
  case "$1" in
    --max-idle)  MAX_IDLE="$2"; shift 2 ;;
    --max-runs)  MAX_RUNS="$2"; shift 2 ;;
    --max-stall) MAX_STALL="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --queue)     QDIR="$2"; shift 2 ;;
    *) echo "queue-watch: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
export QUEUE_DIR="$QDIR"

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
. "$HERE/queue-chew-lib.sh"        # reuse qc_pick_entry for dep-ready detection (ONE selection contract).

# qw_dep_ready — print non-empty iff a dep-ready BUILD entry is waiting in pending/ (reuses the lib's pick).
qw_dep_ready() { QC_SKIP='' qc_pick_entry; }

# qw_launch_chew — the pluggable launcher. Default: a headless one-shot chew via the claude CLI. Override with
# QUEUE_CHEW_CMD (a program path) — tests point it at a stub that simulates a drain. NO eval (injection-safe).
qw_launch_chew() {
  if [ -n "${QUEUE_CHEW_CMD:-}" ]; then
    "${QUEUE_CHEW_CMD}"
  else
    claude -p "/queue-chew"
  fi
}

# qw_wait SECS — cheap inter-poll wait. Event-driven (inotifywait, linux) if present; else a plain sleep
# (macOS/portable). Either way bounded by SECS so the idle accounting stays accurate.
qw_wait() {
  local secs="$1"
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -q -t "$secs" -e create -e moved_to "$QDIR/pending" >/dev/null 2>&1 || true
  else
    sleep "$secs"
  fi
}

runs=0; idle=0; stall=0
echo "queue-watch: watching $QDIR/pending (max-idle=${MAX_IDLE}s, max-runs=$([ "$MAX_RUNS" -gt 0 ] && echo "$MAX_RUNS" || echo '∞'), max-stall=${MAX_STALL}, interval=${INTERVAL}s)"
while : ; do
  pick="$(qw_dep_ready)"
  if [ -n "$pick" ]; then
    runs=$((runs + 1))
    echo "queue-watch: dep-ready entry '$pick' → launching chew (run $runs)"
    qw_launch_chew
    idle=0
    if [ "$MAX_RUNS" -gt 0 ] && [ "$runs" -ge "$MAX_RUNS" ]; then
      echo "queue-watch: max-runs ($MAX_RUNS) reached — exiting."
      break
    fi
    # NO-PROGRESS guard (CR-001): if the SAME entry is still the dep-ready pick after the chew ran, the launch
    # made NO progress — the canonical case is a REFUSED raw plan (the chew un-drains it back to pending/, so it
    # stays dep-ready). Without this the loop would `continue` and re-launch IMMEDIATELY → an unbounded hot spin
    # of Claude sessions (the exact resource-burn this watcher exists to prevent). Rate-limit with qw_wait and
    # exit after MAX_STALL consecutive no-progress launches; a launch that DID drain resets the counter.
    if [ "$(qw_dep_ready)" = "$pick" ]; then
      stall=$((stall + 1))
      echo "queue-watch: no progress on '$pick' ($stall/$MAX_STALL) — it did not drain (refused raw plan? a stuck build?)."
      qw_wait "$INTERVAL"
      if [ "$stall" -ge "$MAX_STALL" ]; then
        echo "queue-watch: max-stall ($MAX_STALL) on '$pick' — dep-ready but not draining; exiting. /roadmap it, or QUEUE_ALLOW_RAW_PLAN=1, then re-invoke."
        break
      fi
    else
      stall=0
    fi
    continue
  fi
  qw_wait "$INTERVAL"
  idle=$((idle + INTERVAL))
  echo "queue-watch: idle ${idle}s (no dep-ready entry — heartbeat)"
  if [ "$idle" -ge "$MAX_IDLE" ]; then
    echo "queue-watch: max-idle (${MAX_IDLE}s) reached, queue empty/blocked — exiting. Re-invoke to resume (ADR-093; state is the folder)."
    break
  fi
done
