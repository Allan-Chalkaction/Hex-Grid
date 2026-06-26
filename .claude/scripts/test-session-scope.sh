#!/usr/bin/env bash
# test-session-scope.sh — ADR-052: session-scoped bypass + concurrency-safe
# run-state cleanup. Proves two concurrent sessions in one repo don't clobber
# each other's bypass flag or run-state.
#
# Read-only against the repo: builds a throwaway temp "project" and runs the
# real hooks against it. Never touches the live .claude/agent-memory.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # core/
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"                        # repo root
HOOKS="$REPO_ROOT/core/hooks"

PASS=0; FAIL=0
ok()   { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- isolated temp project ---------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && git init -q && git config user.email t@t && git config user.name t )
AM="$TMP/.claude/agent-memory"
RUNS="$AM/active-runs"
mkdir -p "$RUNS"

SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"

iso_ago() { # minutes-ago -> ISO8601 Z
  if date -v-"$1"M +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -v-"$1"M +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ
  fi
}
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkstate() { # path session_id phase last_activity
  printf '{"slug":"s","run_dir":"docs/step-5-pipeline/x","track":"nimble","session_id":"%s","current_phase":"%s","last_activity_at":"%s"}\n' \
    "$2" "$3" "$4" > "$1"
}

run_hook() { # hookname stdin_json  -> sets RC and OUT (stdout)
  local hook="$1" payload="$2"
  OUT=$( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" printf '%s' "$payload" | bash "$HOOKS/$hook" 2>/dev/null )
  RC=$?
}

# === A. Bypass reader scoping (require-protocol.sh) ==========================
# Session A has bypass on; an implementer dispatch from A must be ALLOWED (0).
echo '{"enabled":true,"session_id":"'"$SID_A"'"}' > "$AM/bypass-active-$SID_A.json"
run_hook require-protocol.sh '{"session_id":"'"$SID_A"'","tool_input":{"subagent_type":"implementer"}}'
[ "$RC" -eq 0 ] && ok "bypass: session A (flag present) -> implementer allowed" \
                || bad "bypass: session A should be allowed (rc=$RC)"

# Session B has NO bypass flag and no run state -> implementer BLOCKED (2).
run_hook require-protocol.sh '{"session_id":"'"$SID_B"'","tool_input":{"subagent_type":"implementer"}}'
[ "$RC" -eq 2 ] && ok "bypass: session B (no flag) -> implementer blocked (no leak from A)" \
                || bad "bypass: session B should be blocked (rc=$RC) — A's flag LEAKED"

# === B. Bypass reader scoping (require-track-selection.sh) ===================
# UserPromptSubmit signals a block via {decision:"block"} on stdout (exit 0),
# NOT via exit code — so assert on OUT, not RC.
run_hook require-track-selection.sh '{"session_id":"'"$SID_A"'","prompt":"hello bare prompt"}'
case "$OUT" in *'"decision":"block"'*|*'"decision": "block"'*) bad "track-gate: session A bypass should allow (got block)" ;; *) ok "track-gate: session A bypass -> bare prompt allowed" ;; esac
run_hook require-track-selection.sh '{"session_id":"'"$SID_B"'","prompt":"hello bare prompt"}'
case "$OUT" in *'"decision":"block"'*|*'"decision": "block"'*) ok "track-gate: session B (no flag) -> bare prompt blocked (no leak from A)" ;; *) bad "track-gate: session B should be blocked — A's flag LEAKED" ;; esac

# === C. session-cleanup concurrency (run as session A) ======================
mkstate "$RUNS/$SID_A-own-stale.json"   "$SID_A" "explore"  "$(iso_ago 90)"     # own + stale  -> archive
mkstate "$RUNS/$SID_B-other-recent.json" "$SID_B" "explore" "$NOW_ISO"           # other + recent -> LEAVE
mkstate "$RUNS/$SID_B-other-old.json"   "$SID_B" "explore"  "$(iso_ago 1500)"   # other + >24h -> orphan GC
mkstate "$RUNS/$SID_B-other-done.json"  "$SID_B" "done"     "$NOW_ISO"           # done -> archive
# bypass flags: A own (cleared), B (intact), legacy (removed)
echo '{"enabled":true}' > "$AM/bypass-active-$SID_A.json"
echo '{"enabled":true}' > "$AM/bypass-active-$SID_B.json"
echo '{"enabled":true}' > "$AM/bypass-active.json"

run_hook session-cleanup.sh '{"session_id":"'"$SID_A"'"}'

[ ! -f "$RUNS/$SID_A-own-stale.json" ]    && ok "cleanup: own stale run archived" \
                                          || bad "cleanup: own stale run should be archived"
[ -f "$RUNS/$SID_B-other-recent.json" ]   && ok "cleanup: other session's RECENT run LEFT ALONE (no steal)" \
                                          || bad "cleanup: other session's recent run was stolen/archived — BUG"
[ ! -f "$RUNS/$SID_B-other-old.json" ]     && ok "cleanup: other session's >24h run orphan-GC'd" \
                                          || bad "cleanup: >24h orphan should be archived"
[ ! -f "$RUNS/$SID_B-other-done.json" ]    && ok "cleanup: done run archived (any session)" \
                                          || bad "cleanup: done run should be archived"
# no re-homing: there must be NO new A-prefixed copy of B's recent run
[ ! -f "$RUNS/$SID_A-other-recent.json" ] && ok "cleanup: no cross-session re-home of recent run" \
                                          || bad "cleanup: recent run was re-homed to session A — BUG"

[ ! -f "$AM/bypass-active-$SID_A.json" ]  && ok "cleanup: own bypass flag cleared" \
                                          || bad "cleanup: own bypass flag should be cleared"
[ -f "$AM/bypass-active-$SID_B.json" ]    && ok "cleanup: OTHER session's bypass flag intact (no wipe)" \
                                          || bad "cleanup: other session's bypass flag was wiped — BUG"
[ ! -f "$AM/bypass-active.json" ]         && ok "cleanup: legacy repo-global bypass file removed" \
                                          || bad "cleanup: legacy bypass file should be removed"

echo ""
echo "----------------------------------------"
echo "session-scope tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "All session-scope tests PASSED — ADR-052 wiring correct."; exit 0; } || exit 1
