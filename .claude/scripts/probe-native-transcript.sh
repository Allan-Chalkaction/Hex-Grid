#!/usr/bin/env bash
# core/scripts/probe-native-transcript.sh
#
# OBS-W1-SPIKE: read-only discoverability probe for the native Claude Code
# (CC) per-agent transcript journal (`agent-*.jsonl`). Invoked inside an
# active CC session, it prints:
#
#   (a) the resolved path to the current run's `agent-*.jsonl` DIRECTORY
#       (the {session}/subagents/ folder)
#   (b) one matching file path (the current agent's own journal if we can
#       identify it, else the newest journal by mtime)
#   (c) the first JSONL record parsed (via jq)
#   (d) the native CC version detected (from `claude --version` and/or the
#       `version` field on the journal records themselves)
#
# STRICTLY READ-ONLY (AC-007):
#   - No filesystem writes. Output goes to stdout/stderr ONLY; the caller
#     redirects to capture (e.g. `probe-native-transcript.sh > findings/probe-output-nimble.txt`).
#     The probe never creates a directory, never opens a file for write,
#     never touches the runtime's journal source.
#   - No network calls.
#   - No process spawns beyond `ls`/`cat`/`jq`/`stat`/`wc`/`git`/`claude --version`
#     equivalents.
#
# Binding invariant (ADR-068): the journal is the RUNTIME's. This probe
# READS the journal. The Workflow script NEVER writes one.
#
# Usage:
#   probe-native-transcript.sh [--agent-id ID] [--session ID] [--max-records N]
#
#   --agent-id ID       Optional. If supplied, probe THIS agent's journal
#                       (17-char hex matching the agent-<ID>.jsonl filename).
#   --session ID        Optional. Defaults to $CLAUDE_CODE_SESSION_ID.
#   --max-records N     Optional. Limit JSONL parsing to first N records
#                       (default 1; AC-008 = first record parsed).
#
# Exit codes:
#   0  success — at least (a)+(b)+(c)+(d) printed
#   1  journal not discoverable (no main repo / no session / dir missing)
#   2  invalid arguments
#   3  no journal file found in the resolved directory
#   4  JSONL parse failed (malformed / empty)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/native-transcript-path.sh"

AGENT_ID=""
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
MAX_RECORDS=1

while [ $# -gt 0 ]; do
  case "$1" in
    --agent-id)     AGENT_ID="${2:-}"; shift 2 ;;
    --session)      SESSION_ID="${2:-}"; shift 2 ;;
    --max-records)  MAX_RECORDS="${2:-1}"; shift 2 ;;
    -h|--help)
      sed -n '3,40p' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *)
      echo "probe-native-transcript: unknown arg: $1" >&2
      exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "probe-native-transcript: jq required (read-only JSONL parse)" >&2
  exit 2
fi

# (d) native CC version. Best-effort: both the CLI report AND the .version
# field in the journal records (the journal's version is the authoritative
# capture for that journal, which can lag a fresh `claude --version`).
CC_VERSION_CLI=$(claude --version 2>/dev/null || echo "(claude CLI not on PATH)")

# (a) resolve the {session}/subagents/ dir for the current session.
if [ -z "$SESSION_ID" ]; then
  echo "probe-native-transcript: no session id (set CLAUDE_CODE_SESSION_ID or pass --session)" >&2
  exit 1
fi

JOURNAL_DIR=$(native_transcript_dir "$SESSION_ID") || exit 1

# (b) pick one journal file. Prefer --agent-id; else the newest by mtime.
# Build the agent-path relative to the resolved JOURNAL_DIR so an explicit
# --session is honored (the helper's default for native_transcript_dir uses
# $CLAUDE_CODE_SESSION_ID).
JOURNAL_FILE=""
if [ -n "$AGENT_ID" ]; then
  cand="${JOURNAL_DIR}/agent-${AGENT_ID}.jsonl"
  if [ -f "$cand" ]; then JOURNAL_FILE="$cand"; fi
fi
if [ -z "$JOURNAL_FILE" ]; then
  JOURNAL_FILE=$(cd "$JOURNAL_DIR" && ls -1t agent-*.jsonl 2>/dev/null | awk -v d="$JOURNAL_DIR" 'NR==1{print d"/"$0}')
fi
if [ -z "$JOURNAL_FILE" ] || [ ! -f "$JOURNAL_FILE" ]; then
  echo "probe-native-transcript: no agent-*.jsonl found under $JOURNAL_DIR" >&2
  exit 3
fi

# (c) parse the first N records via jq. Read-only; jq does not modify the file.
PARSED=""
if ! PARSED=$(head -n "$MAX_RECORDS" "$JOURNAL_FILE" | jq -c '.' 2>/dev/null); then
  echo "probe-native-transcript: JSONL parse failed on $JOURNAL_FILE" >&2
  exit 4
fi
if [ -z "$PARSED" ]; then
  echo "probe-native-transcript: empty JSONL parse from $JOURNAL_FILE" >&2
  exit 4
fi

CC_VERSION_JOURNAL=$(head -n 1 "$JOURNAL_FILE" | jq -r '.version // "unknown"')

# All output to stdout (read-only — caller redirects to capture; AC-007).
# A "track" hint can be passed via env (PROBE_TRACK=nimble|orchestrated|chain|adhoc).
TRACK="${PROBE_TRACK:-adhoc}"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

emit() { printf '%s\n' "$1"; }

emit "=== probe-native-transcript.sh @ $TS ==="
emit "track-hint:        $TRACK"
emit "session_id:        $SESSION_ID"
emit "cwd:               $(pwd)"
emit "main_repo:         $(native_transcript_resolve_main 2>/dev/null || echo '(not in git repo)')"
emit ""
emit "--- (d) native CC version ---"
emit "cli:               $CC_VERSION_CLI"
emit "journal.version:   $CC_VERSION_JOURNAL"
emit ""
emit "--- (a) resolved journal directory ---"
emit "dir:               $JOURNAL_DIR"
emit "dir_listing_count: $(ls -1 "$JOURNAL_DIR" 2>/dev/null | wc -l | tr -d ' ')"
emit ""
emit "--- (b) one matching agent-*.jsonl file ---"
emit "file:              $JOURNAL_FILE"
emit "size_bytes:        $(stat -f '%z' "$JOURNAL_FILE" 2>/dev/null || stat -c '%s' "$JOURNAL_FILE" 2>/dev/null || echo '?')"
emit "lines:             $(wc -l < "$JOURNAL_FILE" | tr -d ' ')"
if [ -f "${JOURNAL_FILE%.jsonl}.meta.json" ]; then
  emit "meta_sibling:      ${JOURNAL_FILE%.jsonl}.meta.json (present)"
else
  emit "meta_sibling:      (none)"
fi
emit ""
emit "--- (c) first $MAX_RECORDS JSONL record(s) parsed ---"
# Emit each parsed line on its own line. We intentionally don't pretty-print
# (keeps output deterministic + grep-friendly).
while IFS= read -r line; do
  emit "$line"
done <<<"$PARSED"
emit ""
emit "=== probe-native-transcript: ok ==="
