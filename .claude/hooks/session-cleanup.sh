#!/usr/bin/env bash
# SessionStart hook: Archive stale run state files
# Archives:
#   1. Completed runs (current_phase: "done")
#   2. Stale runs (last_activity_at older than 60 minutes)
# This prevents previous sessions' state from bleeding into new runs.
#
# Exit 0 always — advisory, never blocks.

set -uo pipefail

if ! command -v jq &>/dev/null; then
  exit 0
fi

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

RUNS_DIR=".claude/agent-memory/active-runs"
ARCHIVE_DIR=".claude/agent-memory/archived-runs"

if [ ! -d "$RUNS_DIR" ]; then
  exit 0
fi

# Stale threshold: 60 minutes ago (own-session clean-start hygiene).
# Orphan threshold: 24 hours ago (cross-session GC — see ADR-052). The 60-min
# rule applies ONLY to the current session's own files; another session's run is
# only GC'd once it is older than ORPHAN_THRESHOLD, well beyond any plausible
# live-but-idle session parked at a halt.
if date -v-60M +%s &>/dev/null 2>&1; then
  # macOS
  STALE_THRESHOLD=$(date -v-60M +%s)
  ORPHAN_THRESHOLD=$(date -v-24H +%s)
else
  # Linux
  STALE_THRESHOLD=$(date -d '60 minutes ago' +%s)
  ORPHAN_THRESHOLD=$(date -d '24 hours ago' +%s)
fi

for state_file in "$RUNS_DIR"/*.json; do
  [[ "$state_file" == *.tmp ]] && continue
  [ -f "$state_file" ] || continue
  # Skip non-state files
  jq -e '.slug' "$state_file" >/dev/null 2>&1 || continue

  fname=$(basename "$state_file")
  PHASE=$(jq -r '.current_phase // empty' "$state_file" 2>/dev/null)
  LAST_ACTIVITY=$(jq -r '.last_activity_at // empty' "$state_file" 2>/dev/null)
  SLUG=$(jq -r '.slug // empty' "$state_file" 2>/dev/null)

  # Compute staleness (>60m) and orphan-age (>24h) from last_activity_at.
  IS_STALE=false
  IS_ORPHAN=false
  if [ -n "$LAST_ACTIVITY" ]; then
    if date -jf "%Y-%m-%dT%H:%M:%SZ" "$LAST_ACTIVITY" +%s &>/dev/null 2>&1; then
      # macOS
      ACTIVITY_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$LAST_ACTIVITY" +%s 2>/dev/null || echo "0")
    else
      # Linux
      ACTIVITY_EPOCH=$(date -d "$LAST_ACTIVITY" +%s 2>/dev/null || echo "0")
    fi
    if [ "$ACTIVITY_EPOCH" -lt "$STALE_THRESHOLD" ] 2>/dev/null; then
      IS_STALE=true
    fi
    if [ "$ACTIVITY_EPOCH" -lt "$ORPHAN_THRESHOLD" ] 2>/dev/null; then
      IS_ORPHAN=true
    fi
  else
    # No activity timestamp — malformed/legacy; treat as both stale and orphan.
    IS_STALE=true
    IS_ORPHAN=true
  fi

  # Ownership: does this state file belong to the CURRENT (starting) session?
  IS_CURRENT=false
  if [ -n "$SESSION_ID" ]; then
    case "$fname" in "${SESSION_ID}-"*) IS_CURRENT=true ;; esac
  fi

  # Session-aware cleanup policy (ADR-052). A SessionStart cleanup MUTATES ONLY
  # its own session's files. Another session's in-progress run is LEFT ALONE — it
  # may be a live session merely parked at a halt (e.g. roadmap between rounds, a
  # planner session), and last_activity_at staleness cannot distinguish
  # idle-but-alive from dead. The ONLY cross-session sweep is the age-based orphan
  # GC (> 24h), far beyond any plausible live idle session.
  #
  # Cross-session RE-HOMING IS REMOVED. The reconnect case (user /exit'd and came
  # back with a new session_id) is served by the explicit, manifest-driven
  # /resume (ADR-039) — re-writing prompt.md auto-creates a fresh current-session
  # state file. Silently stealing another session's run (the v1 behavior) is the
  # concurrency bug this fixes: two live sessions in one repo no longer clobber
  # each other's gating state.
  if [ "$PHASE" = "done" ]; then
    # Finished run — archive regardless of session (it is complete).
    mkdir -p "$ARCHIVE_DIR"; mv "$state_file" "$ARCHIVE_DIR/"; continue
  fi
  if [ "$IS_CURRENT" = "true" ] && [ "$IS_STALE" = "true" ]; then
    # Our OWN stale run — archive for a clean start.
    mkdir -p "$ARCHIVE_DIR"; mv "$state_file" "$ARCHIVE_DIR/"; continue
  fi
  if [ "$IS_ORPHAN" = "true" ]; then
    # Truly ancient (> 24h) — GC regardless of session; no live session idles
    # this long. This is the only path that touches another session's file.
    mkdir -p "$ARCHIVE_DIR"; mv "$state_file" "$ARCHIVE_DIR/"; continue
  fi
  # Otherwise — our own in-progress run, or another session's recent run — leave
  # it exactly as-is. No re-home, no archive.
done

# Delete any leftover legacy singleton (no longer used)
rm -f ".claude/agent-memory/nimble-run-state.json"

# Clear bypass mode at session start — bypass is per-session (ADR-052). Clear ONLY
# THIS session's own scoped flag (a fresh session always starts un-bypassed);
# OTHER sessions' bypass flags are left intact so starting a new session no longer
# disables bypass in a concurrently-running one (the bug this fixes). Also remove
# the legacy repo-global bypass-active.json (no longer honored), and GC orphan
# scoped flags older than 24h so the dir doesn't grow unbounded.
# Anchor to the project dir so the cleanup hits the right file regardless of cwd.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
AGENT_MEM="$PROJECT_DIR/.claude/agent-memory"
if [ -n "$SESSION_ID" ]; then
  rm -f "$AGENT_MEM/bypass-active-${SESSION_ID}.json"
fi
rm -f "$AGENT_MEM/bypass-active.json"   # legacy repo-global flag (migration)
# Orphan GC: scoped bypass flags untouched for >24h (mtime). -mtime +0 = >1 day.
find "$AGENT_MEM" -maxdepth 1 -type f -name 'bypass-active-*.json' -mtime +0 -delete 2>/dev/null || true

# Clean synced-artifacts manifest so new runs start fresh
MANIFEST=".claude/agent-memory/synced-artifacts.json"
if [ -f "$MANIFEST" ]; then
  # Only clear if all runs were archived (no active state files remain).
  # SH-1 #6: the prior `ls ... | grep -cv '\.tmp$' || echo "0"` yielded "0\n0" on
  # an empty dir — grep prints "0" AND exits 1 (no match), so the `|| echo "0"`
  # appended a second "0", and the `[ "$REMAINING" = "0" ]` test then failed,
  # skipping the manifest reset. Use find|wc for a clean integer that is "0" when
  # the dir is empty.
  REMAINING=$(find "$RUNS_DIR" -maxdepth 1 -type f -name '*.json' ! -name '*.tmp' 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "${REMAINING:-0}" = "0" ]; then
    echo '{}' > "$MANIFEST"
  fi
fi

exit 0
