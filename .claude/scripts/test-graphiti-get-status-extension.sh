#!/usr/bin/env bash
# test-graphiti-get-status-extension.sh — get_status queue_size + worker_state (W3IO-T4, AC-027).
#
# Static verification (no docker): the additive fields are wired in the mounted get_status body
# (graphiti_mcp_server.py) and declared on the StatusResponse TypedDict (response_types.py).
#
# ACTIVATION NOTE (build-time correction): the mounted graphiti_mcp_server.py is ':ro' but the
# running MCP server loaded the module at PROCESS START — editing the file does NOT hot-reload it
# (Python caches modules in sys.modules; FastMCP does not re-exec tool modules per call). So the
# live behavior (enqueue -> get_status shows queue_size/worker_state) activates only after an
# OPERATOR restart of the mcp server (ADR-018 crit-4 — not done autonomously). The functional
# enqueue->get_status assertion is therefore an operator post-restart verification, recorded in the
# run-log; this test verifies the code is correctly in place.
set -uo pipefail
# Locate the graphiti repo: explicit env wins, else probe common $HOME locations.
# Absent everywhere -> the read below fails open and the session continues untouched.
if [ -z "${GRAPHITI_REPO:-}" ]; then
  for _cand in "$HOME/graphiti" "$HOME/Desktop/Dev/graphiti" "$HOME/Desktop/Development/graphiti"; do
    [ -d "$_cand" ] && { GRAPHITI_REPO="$_cand"; break; }
  done
fi
GRAPHITI_REPO="${GRAPHITI_REPO:-$HOME/graphiti}"
SERVER="$GRAPHITI_REPO/mcp_server/custom/graphiti_mcp_server.py"
TYPES="$GRAPHITI_REPO/mcp_server/src/models/response_types.py"

fail() { echo "FAIL: $1" >&2; exit 1; }

# get_status body: both field names populated from the live queue_service.
grep -qE 'resp\[.queue_size.\]|queue_size\[' "$SERVER" || fail "queue_size not populated in get_status ($SERVER)"
grep -qE 'resp\[.worker_state.\]|worker_state\[' "$SERVER" || fail "worker_state not populated in get_status ($SERVER)"
grep -q 'is_worker_running' "$SERVER" || fail "get_status must read is_worker_running"
grep -q 'get_queue_size' "$SERVER" || fail "get_status must read get_queue_size"
# Backward-compat guard: the fields are conditional on queue_service availability (no error sentinels).
grep -q 'if queue_service is not None' "$SERVER" || fail "get_status must omit fields when queue_service is None"

# StatusResponse TypedDict declares the additive (NotRequired) fields.
grep -qE 'queue_size: *NotRequired' "$TYPES" || fail "StatusResponse missing NotRequired queue_size ($TYPES)"
grep -qE 'worker_state: *NotRequired' "$TYPES" || fail "StatusResponse missing NotRequired worker_state ($TYPES)"

# AC-027 verification grep (both field names live in graphiti_mcp_server.py).
n="$(grep -cE 'queue_size|worker_state' "$SERVER")"
[ "${n:-0}" -ge 2 ] || fail "expected >=2 queue_size/worker_state references in get_status, got $n"

echo "test-graphiti-get-status-extension: OK (code in place; live activation pending OPERATOR mcp-server restart)"
