#!/usr/bin/env bash
# PreCompact hook: write a deterministic continuation anchor before compaction.
# Event: PreCompact   Matcher: "" (fires on manual + auto compaction)
#
# ADR-087 D3 (the document router), rows 1-2 + the captured idea
# (RAW-2026-06-12-scripted-precompact-anchor-and-compaction.md). The harness fires
# this hook just before it compacts the transcript; we capture the repo-side state
# that compaction would otherwise lose, so resume is a file read, not a memory.
#
# Where the anchor lands (D3 router):
#   - active run for this session  -> <run_dir>/session-log.md  (append; moves to done with the run)
#   - no active run                -> docs/step-6-done/sessions/anchor-<date>-<session8>.md (born done)
#
# Content is ENTIRELY deterministic — a hook cannot ask the model for prose. We record
# what git + the state file already know: branch, HEAD sha, dirty-file list, active run
# slug/phase, last 3 commits. That is exactly the state a post-compaction resume needs.
#
# Contract: FAIL-OPEN. Exit 0 ALWAYS — never block compaction. Timestamped/idempotent-ish:
# the session-log append is dated; the no-active-run file is timestamped so re-fires append-stack.
#
# REGISTRATION (PreCompact, repo .claude/settings.json OR the operator's global settings):
#   "PreCompact": [
#     { "matcher": "",
#       "hooks": [ { "type": "command",
#                    "command": "bash $HOME/.claude/hooks/precompact-anchor.sh",
#                    "timeout": 5 } ] }
#   ]
# (setup.sh symlinks core/hooks/precompact-anchor.sh -> .claude/hooks/. The PreCompact
#  event IS registered in core/config/global/settings.json — installed to the operator's
#  live ~/.claude/settings.json via switch-infra.sh.)

set -uo pipefail
# NOTE: set -e intentionally omitted — advisory hook, must always exit 0.

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

SESSION_ID=""
if command -v jq &>/dev/null; then
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

# Anchor to the repo (a hook can fire with a drifted cwd).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TODAY="$(date -u +%Y-%m-%d 2>/dev/null || echo unknown)"

# ---- gather deterministic git state (all best-effort, never fatal) ----
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
DIRTY="$(git status --short 2>/dev/null | head -40)"
LAST3="$(git log --oneline -3 2>/dev/null)"

# ---- find an active run state file for THIS session (mirror require-protocol.sh) ----
RUNS_DIR=".claude/agent-memory/active-runs"
RUN_DIR=""
RUN_SLUG=""
RUN_PHASE=""
if [ -d "$RUNS_DIR" ] && command -v jq &>/dev/null; then
  latest_mtime=0
  state_file=""
  for cand in "$RUNS_DIR"/*.json; do
    [[ "$cand" == *.tmp ]] && continue
    [ -f "$cand" ] || continue
    if [ -n "$SESSION_ID" ]; then
      case "$(basename "$cand")" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    jq -e '.slug' "$cand" >/dev/null 2>&1 || continue
    if stat -f %m "$cand" &>/dev/null; then m=$(stat -f %m "$cand"); else m=$(stat -c %Y "$cand" 2>/dev/null || echo 0); fi
    if [ "$m" -gt "$latest_mtime" ] 2>/dev/null; then latest_mtime="$m"; state_file="$cand"; fi
  done
  if [ -n "$state_file" ]; then
    RUN_DIR=$(jq -r '.run_dir // empty' "$state_file" 2>/dev/null)
    RUN_SLUG=$(jq -r '.slug // empty' "$state_file" 2>/dev/null)
    RUN_PHASE=$(jq -r '.current_phase // empty' "$state_file" 2>/dev/null)
  fi
fi

# ---- compose the anchor body ----
sess8="${SESSION_ID:0:8}"; sess8="${sess8//[^a-zA-Z0-9]/}"; [ -z "$sess8" ] && sess8="nosession"
anchor_body() {
  echo ""
  echo "## Continuation anchor — ${NOW_ISO}"
  echo ""
  echo "- **session:** ${SESSION_ID:-?}"
  echo "- **branch:** ${BRANCH}  **HEAD:** ${HEAD_SHA}"
  if [ -n "$RUN_SLUG" ]; then
    echo "- **active run:** ${RUN_SLUG}  (phase: ${RUN_PHASE:-?}, dir: ${RUN_DIR:-?})"
  else
    echo "- **active run:** none"
  fi
  echo "- **dirty files:**"
  if [ -n "$DIRTY" ]; then printf '%s\n' "$DIRTY" | sed 's/^/    /'; else echo "    (clean tree)"; fi
  echo "- **last 3 commits:**"
  if [ -n "$LAST3" ]; then printf '%s\n' "$LAST3" | sed 's/^/    /'; else echo "    (no commits)"; fi
  echo ""
  echo "_Written by precompact-anchor.sh (ADR-087 D3) — deterministic, pre-compaction._"
}

if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
  # Active run: append to its session-log.md (moves to done with the run).
  anchor_body >> "$RUN_DIR/session-log.md" 2>/dev/null || true
else
  # No active run: born-done anchor under step-6-done/sessions/ (prefer new path).
  SESS_DIR="docs/step-6-done/sessions"
  mkdir -p "$SESS_DIR" 2>/dev/null || true
  ts="$(date -u +%H%M%S 2>/dev/null || echo 000000)"
  out="$SESS_DIR/anchor-${TODAY}-${sess8}-${ts}.md"
  { echo "# Continuation anchor (no active run) — ${TODAY}"; anchor_body; } > "$out" 2>/dev/null || true
fi

# ---- AMS-T10 (wave-4, AC-001..AC-005): opt-in halt-snapshot write to memory ----
# After the anchor body is written to disk, ADDITIONALLY route the SAME deterministic snapshot text
# through write_fact() so the halt moment ("we halted because X, state was Y") is recallable on resume.
#
# Design contract (binding):
#   - OFF BY DEFAULT (AC-003): gated behind GRAPHITI_STOP_WRITE; unset/0 => no write at all.
#   - CONTENT-FREE of LLM prose (AC-001): the body is the deterministic git/state text anchor_body
#     already composed — no model call, no PII solicited.
#   - SOLE WRITE RAIL (AC-022): shells into the existing graphiti_write CLI (-> write_fact()) and
#     NOTHING else. No graph client, no add_episode, no group re-derivation, no scrubber re-impl.
#     group_id is derived fail-closed by the funnel from --cwd (quarantine-on-miss, never main).
#   - FAIL-OPEN + NO DELAY (AC-004): wrapped in `|| true` with a hard timeout well under the ~5s
#     hook budget; engine-down/timeout/non-zero never blocks compaction. This block adds no `set -e`.
#   - NO HOST-SIDE DEDUP (AC-005): idempotency is the funnel's uuid5 alone. The anchor body carries a
#     timestamp, so successive PreCompact fires mint distinct episodes (distinct halt moments) — that
#     is accepted; we add no content-hash/dedup layer here.
#   - REVERSIBLE (AC-021): deleting this whole block leaves the anchor hook byte-identical to its
#     pre-W4 behavior (a clean no-op).
if [ "${GRAPHITI_STOP_WRITE:-0}" = "1" ]; then
  GW="${PROJECT_DIR}/core/scripts/graphiti_write.py"
  if [ -f "$GW" ] && command -v python3 &>/dev/null; then
    # Compose the snapshot text once; pipe it to the write rail via stdin (no LLM, deterministic).
    if command -v timeout &>/dev/null; then TO=(timeout 4); else TO=(); fi
    anchor_body 2>/dev/null | "${TO[@]}" python3 "$GW" \
      --cwd "$PROJECT_DIR" \
      --source "precompact-anchor halt snapshot (deterministic, content-free)" \
      --source-type session \
      --name "halt-anchor ${BRANCH}@${HEAD_SHA} ${NOW_ISO}" \
      >/dev/null 2>&1 || true
  fi
fi

exit 0
