#!/usr/bin/env bash
# SessionEnd hook — automatically distill the session into durable facts and (optionally) capture them.
#
# DOUBLE-GATED, because this is the only auto-WRITE path:
#   - OFF entirely unless   .claude/agent-memory/graphiti-capture-enabled   exists (off-by-default).
#   - When enabled, capture is LIVE by default (real distillates written via graphiti-distill.py
#     --write → write_fact()), UNLESS an explicit opt-out flag
#       .claude/agent-memory/graphiti-capture-dry-run
#     is present, which forces dry-run (logs what it WOULD capture, writes nothing).
#
# AMS-T3 (wave-1-writes, AC-004) flipped the default from dry-run to live PER THE FLAG MECHANISM —
# NOT by hardcoding WRITE_ARG="--write" and ripping out the branch. The reversibility envelope is
# preserved two ways: (1) drop the enable flag → fully off; (2) drop a dry-run flag → observe-only.
# The legacy   graphiti-capture-live   flag is still honored as an explicit live request (so an
# existing enable→dry-run→live dogfood setup keeps working), but live is now the enabled default.
#
# Fail-open: any error logs and exits 0. Never blocks session end. Writes go through graphiti_write
# (scrub + fail-closed group_id + idempotent + provenance), so even live mode can't write secrets or
# to main.
set -euo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENABLE_FLAG="${REPO_ROOT}/.claude/agent-memory/graphiti-capture-enabled"
LIVE_FLAG="${REPO_ROOT}/.claude/agent-memory/graphiti-capture-live"
DRY_RUN_FLAG="${REPO_ROOT}/.claude/agent-memory/graphiti-capture-dry-run"
DISTILL="${REPO_ROOT}/core/scripts/graphiti-distill.py"
LOG="${REPO_ROOT}/.claude/agent-memory/graphiti-capture.log"

[ -f "$ENABLE_FLAG" ] || exit 0            # disabled -> silent
[ -f "$DISTILL" ] || exit 0

STDIN="$(cat 2>/dev/null || true)"
TRANSCRIPT="$(printf '%s' "$STDIN" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("transcript_path",""))
except Exception: print("")' 2>/dev/null || true)"
CWD="$(printf '%s' "$STDIN" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("cwd",""))
except Exception: print("")' 2>/dev/null || true)"
[ -n "$CWD" ] || CWD="$REPO_ROOT"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0   # no transcript -> nothing to distill

# AMS-T3 (AC-004): live is the enabled DEFAULT, flag-driven (NOT a hardcoded WRITE_ARG).
#   - default (enabled, no flags)      -> live  (--write)
#   - explicit opt-out (dry-run flag)  -> dry-run (no --write) — the observe-only escape hatch
#   - legacy live flag                 -> live  (explicit, still honored)
# WRITE_ARG/MODE stay derived from the flag state; the $LIVE_FLAG/$ENABLE_FLAG mechanism is preserved.
WRITE_ARG="--write"
MODE="live"
if [ -f "$DRY_RUN_FLAG" ] && [ ! -f "$LIVE_FLAG" ]; then WRITE_ARG=""; MODE="dry-run"; fi

mkdir -p "$(dirname "$LOG")"
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) capture [$MODE] cwd=$CWD ==="
  python3 "$DISTILL" --transcript "$TRANSCRIPT" --cwd "$CWD" $WRITE_ARG 2>&1 || echo "(distill failed — fail-open)"
} >> "$LOG" 2>&1

exit 0
