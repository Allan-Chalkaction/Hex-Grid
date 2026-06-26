#!/usr/bin/env bash
# SessionStart hook — inject salient durable facts for this project from the Graphiti memory.
#
# OFF BY DEFAULT and NOT registered in settings (Wave 3 ships the machinery opt-in; nothing
# changes your sessions until you turn it on). To enable:
#   1) touch .claude/agent-memory/graphiti-read-enabled
#   2) register this hook under SessionStart in your settings (see docs/graphiti/graphiti-read-hook.md)
#
# Composes alongside the other SessionStart hooks — it never replaces them. Fail-open at every
# step: any miss emits no context and exits 0, so it can never block or break a session.
#
# COHERENCE GUARD (load-bearing): this re-adds per-turn context to the very repo v2 thinned to
# cut it. Measured latency of the v1 docker-exec read path is ~1.2s — over the 200ms target — so
# this is SessionStart-only (one read per session), relevance is recency+per-group, and the size
# is hard-capped. A faster (persistent-bolt) path is required before any per-prompt read.
set -euo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
ENABLE_FLAG="${REPO_ROOT}/.claude/agent-memory/graphiti-read-enabled"
# Locate the graphiti repo: explicit env wins, else probe common $HOME locations.
# Absent everywhere -> the read below fails open and the session continues untouched.
if [ -z "${GRAPHITI_REPO:-}" ]; then
  for _cand in "$HOME/graphiti" "$HOME/Desktop/Dev/graphiti" "$HOME/Desktop/Development/graphiti"; do
    [ -d "$_cand" ] && { GRAPHITI_REPO="$_cand"; break; }
  done
fi
GRAPHITI_REPO="${GRAPHITI_REPO:-$HOME/graphiti}"
READ_SCRIPT="${REPO_ROOT}/core/scripts/graphiti-read.py"
METER_LOG="${REPO_ROOT}/.claude/agent-memory/graphiti-read.log"
BUDGET_MS=1500            # hard wall (timeout); the *target* is far lower — see coherence note
TOP_K=5
MAX_BYTES=1200

# 0. Disabled unless the operator opted in. (Default path: silent exit.)
[ -f "$ENABLE_FLAG" ] || exit 0

# Read stdin (SessionStart payload) but never depend on it; fall back to PWD.
STDIN="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "$STDIN" | python3 -c 'import sys,json;
try:
    print(json.load(sys.stdin).get("cwd",""))
except Exception:
    print("")' 2>/dev/null || true)"
[ -n "$CWD" ] || CWD="$REPO_ROOT"

# Derive the fail-closed group_id via the registry loader; bail silently on any error.
GID="$(python3 -c "import sys; sys.path.insert(0, '$GRAPHITI_REPO'); import graphiti_groups as g; print(g.derive_group_id('$CWD'))" 2>/dev/null || true)"
[ -n "$GID" ] || exit 0
# Nothing salient to inject for an unknown/quarantined project.
[ "$GID" = "unsorted:NEEDS_TRIAGE" ] && exit 0
[ -x "$(command -v python3)" ] && [ -f "$READ_SCRIPT" ] || exit 0

# Run the read under a hard wall-clock cap; capture facts (stdout) + meter (stderr).
# `timeout` is GNU-only (absent on stock macOS); use `gtimeout` if present, else run without the
# outer cap — the read script has its own internal cypher timeout, so it still can't hang.
TMP_ERR="$(mktemp)"; trap 'rm -f "$TMP_ERR"' EXIT
SECS="$(awk "BEGIN{print $BUDGET_MS/1000}")"
TIMEOUT_BIN=""
command -v timeout  >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
[ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"
if [ -n "$TIMEOUT_BIN" ]; then
  FACTS="$("$TIMEOUT_BIN" "$SECS" python3 "$READ_SCRIPT" --group-id "$GID" --top-k "$TOP_K" --max-bytes "$MAX_BYTES" --meter 2>"$TMP_ERR" || true)"
else
  FACTS="$(python3 "$READ_SCRIPT" --group-id "$GID" --top-k "$TOP_K" --max-bytes "$MAX_BYTES" --meter 2>"$TMP_ERR" || true)"
fi

# Always record the meter line (operator-visible observability), even on empty/zero injection.
mkdir -p "$(dirname "$METER_LOG")"
{ grep -m1 '^Graphiti-read:' "$TMP_ERR" 2>/dev/null || echo "Graphiti-read: injected=0 bytes, facts=0, latency=NA, group_id=$GID"; } >> "$METER_LOG"

# No facts -> inject nothing, silently (graceful empty-graph; no banner, no apology).
[ -n "$FACTS" ] || exit 0

# Emit as plain stdout — SessionStart stdout is BOTH shown to the operator (a visible banner, like
# the other SessionStart hooks) AND added to the session context. The JSON additionalContext form
# injects silently with no banner, which reads as "nothing happened" to the operator.
printf '## Recalled long-term memory (Graphiti) — group: %s\n' "$GID"
printf 'Durable facts recalled for this project. They MAY be stale — verify load-bearing facts against the source.\n\n'
printf '%s\n' "$FACTS"
exit 0
