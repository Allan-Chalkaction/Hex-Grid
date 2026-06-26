#!/usr/bin/env bash
# core/scripts/watch-run-artifacts.sh — OBS-W2-WATCH (W2 watcher).
#
# Read-only LIVE-MIRROR watcher: tails the native Claude Code per-agent
# transcript journal (`agent-*.jsonl`) for the current orchestrator session and
# writes `findings/<NN>-<agent>.md` under `--run-dir D/findings/` as each
# completed agent's terminal text lands. Operator-facing in-flight visibility
# under the v2 engine — the authoritative end-of-run persist
# (`persist-run-artifacts.py`) still wins and is the source of truth.
#
# Binding invariant (ADR-068, preserved verbatim from PERSIST):
#
#     The journal is the RUNTIME's. The watcher READS, NEVER writes one.
#     Writes are confined strictly to <run-dir>/findings/.
#
# Properties (AC-029..AC-037):
#   - AC-030: invoked `--run-dir D` it tails the native runtime journal and
#     writes `findings/<NN>-<agent>.md` for each completed agent.
#   - AC-031: read-only against the journal; the only file writes are inside
#     `--run-dir` (specifically `<run-dir>/findings/`).
#   - AC-032: no race with persist — running it alongside `persist-run-artifacts.py`
#     against the same run-dir produces a result indistinguishable from persist
#     alone (no orphans outside findings/, no conflicting content; the watcher's
#     incremental files are either overwritten by persist or are an additive
#     in-flight snapshot persist's end-of-run output does not disagree with).
#   - AC-033: no manifest writes — the thin manifest is exclusively the
#     orchestrator's via `persist-run-artifacts.py`.
#   - AC-034: additive + disposable — killing the watcher mid-run leaves a valid
#     (possibly partial) state the end-of-run persist overwrites cleanly.
#   - AC-035: imports / sources THE SAME path-resolution helper as the PERSIST
#     fallback (`core/scripts/lib/native-transcript-path.sh`). DRY — one
#     canonical resolver across the two consumers.
#   - AC-036: end-to-end fixture test reuses
#     `core/scripts/tests/fixtures/journal-fallback/agent-sample.jsonl`.
#   - AC-037: ADR-068 cross-links this watcher as the secondary consumer of
#     the discoverability mechanism (grep finds `watch-run-artifacts` /
#     `OBS-W2-WATCH` / `W2 watcher` in the ADR).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# AC-035 DRY: source the SAME helper Wave 1's PERSIST fallback uses. The
# transcript-discoverability mechanism (SPIKE outcome positive — see
# `docs/step-3-specs/engine-observability/transcript-discoverability.md`) lives in
# `core/scripts/lib/native-transcript-path.sh`. Re-implementing it here would
# silently drift; sourcing it keeps one source of truth.
# shellcheck source=core/scripts/lib/native-transcript-path.sh
. "${SCRIPT_DIR}/lib/native-transcript-path.sh"

usage() {
  cat <<'EOF'
usage: watch-run-artifacts.sh --run-dir D [--interval N] [--once] [--session SESS]

Read-only live-mirror watcher (OBS-W2-WATCH / W2 watcher). Tails the native
Claude Code per-agent transcript journal for the current orchestrator session
and writes `findings/<NN>-<agent>.md` under D/findings/ as each completed agent
result lands. Reads the journal via the same discoverability mechanism as the
PERSIST fallback (ADR-068; sources core/scripts/lib/native-transcript-path.sh).

Required:
  --run-dir D        Run folder; only writes go under D/findings/ (no journal
                     writes, no manifest writes).

Optional:
  --interval N       Polling interval in seconds (default: 2). Ignored with --once.
  --once             Single pass over the current journal dir, then exit. Used
                     by tests and one-shot snapshots; default behavior loops.
  --session SESS     Override CLAUDE_CODE_SESSION_ID (test/debugging hook).
  --help, -h         This help.

Binding invariant: the journal is the RUNTIME's; this script READS, NEVER
writes one. Writes are confined strictly to <run-dir>/findings/. The watcher
NEVER writes manifest.json. End-of-run `persist-run-artifacts.py` remains
authoritative; the live mirror is additive + disposable (kill it any time;
persist overwrites cleanly).
EOF
}

# -------------------------------------------------------------------- args ---

RUN_DIR=""
INTERVAL="2"
ONCE="0"
SESSION_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir)   RUN_DIR="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --once)      ONCE="1"; shift ;;
    --session)   SESSION_OVERRIDE="$2"; shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *) echo "watch-run-artifacts: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$RUN_DIR" ]; then
  echo "watch-run-artifacts: --run-dir is required" >&2
  usage >&2
  exit 2
fi
if [ ! -d "$RUN_DIR" ]; then
  echo "watch-run-artifacts: run-dir not found: $RUN_DIR" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "watch-run-artifacts: jq is required (parses the native CC JSONL journal)" >&2
  exit 2
fi

# Convert to an absolute path so AC-031's "writes confined to <run-dir>"
# assertion is unambiguous regardless of the operator's cwd.
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
FINDINGS_DIR="${RUN_DIR}/findings"
mkdir -p "$FINDINGS_DIR"

# Session id: --session > env. The helper bounds journal discovery to ONE
# session — never globs broadly, never reads other sessions' journals (mirrors
# AC-024 in PERSIST). Without a session id we cannot locate the journal dir.
SESSION_ID="${SESSION_OVERRIDE:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$SESSION_ID" ]; then
  echo "watch-run-artifacts: no session id (pass --session or set CLAUDE_CODE_SESSION_ID)" >&2
  exit 2
fi

# ----------------------------------------------------------------- helpers ---

# Sanitize an agent-type string into a safe basename fragment.
_sanitize() {
  local s="${1:-agent}"
  # Lowercase, then keep [a-z0-9._-], collapse anything else to '-'.
  echo "$s" \
    | tr 'A-Z' 'a-z' \
    | sed 's|[^a-z0-9._-]|-|g; s|--*|-|g; s|^-||; s|-$||' \
    | sed 's|^$|agent|'
}

# Extract the LAST assistant record's text content from a journal file.
# Strategy mirrors persist's `_journal_extract_agent_text` (Python) — same
# algorithm, two thin implementations (the DRY contract is for the path
# resolver; the extractor is short enough to mirror cheaply in jq).
#
# CC stores message.content either as a plain string OR as a list of typed
# blocks `[{type:text,text:...}, {type:tool_use,...}, ...]`. We pull the text
# blocks. Returns empty string if no assistant text is present (the caller
# skips writing in that case — the agent hasn't emitted a terminal message yet).
_extract_last_assistant_text() {
  local path="$1"
  # jq script: walk all records, keep only assistant rows, concatenate text
  # blocks per record, keep the LAST non-empty result. Exits 0 even on empty.
  jq -rs '
    map(select(.type == "assistant"))
    | map(
        (.message.content // "") as $c
        | if ($c | type) == "string" then $c
          elif ($c | type) == "array" then
            ($c | map(select(.type == "text") | .text // "") | join("\n\n"))
          else "" end
      )
    | map(select(length > 0))
    | (last // "")
  ' "$path" 2>/dev/null || echo ""
}

# Extract the agentType from the sibling meta.json (best-effort).
_meta_agent_type() {
  local meta="$1"
  [ -f "$meta" ] || { echo "agent"; return 0; }
  jq -r '.agentType // "agent"' "$meta" 2>/dev/null || echo "agent"
}

# Atomic write helper — mirrors PERSIST's `_w()` contract (tmp + rename so a
# crash mid-write never leaves a truncated artifact for a downstream reader).
_atomic_write() {
  local path="$1"; local body="$2"
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir"
  local tmp; tmp="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$body" > "$tmp"
  mv -f "$tmp" "$path"
}

# Render a single agent's findings markdown. Body: the extracted terminal text.
# Header carries provenance so a reader can tell this came from the watcher
# (vs the authoritative persist).
_render_findings_md() {
  local agent_type="$1"; local journal_path="$2"; local text="$3"
  cat <<EOF
# ${agent_type} (live mirror)

_Written by core/scripts/watch-run-artifacts.sh from the native CC per-agent
transcript journal. The journal is the RUNTIME's; this watcher READS it,
NEVER writes one. End-of-run \`persist-run-artifacts.py\` is authoritative
and may overwrite this file with its own rendering (see ADR-068)._

_Source journal:_ \`$(basename "$journal_path")\`

---

${text}
EOF
}

# One pass over the current session's journal dir. Writes one
# findings/<NN>-<agent>.md per completed agent (NN = mtime-ordered index,
# 01-based, oldest first so files appear in dispatch order).
#
# Idempotent: re-running overwrites the same files with the same content.
# AC-033: never writes manifest.json. AC-031: only writes are under FINDINGS_DIR.
_one_pass() {
  local subagents_dir
  if ! subagents_dir="$(native_transcript_dir "$SESSION_ID" 2>/dev/null)"; then
    # Dir not present yet (no subagents dispatched) — no-op. The watcher loops.
    return 0
  fi

  # Enumerate journals OLDEST-first so NN reflects dispatch order. This is
  # mtime-sorted; tied mtimes fall back to lex order. Bounded strictly to the
  # current session's subagents dir (the helper enforces this).
  local journals=()
  # `ls -tr` is "sort by mtime, reverse" = oldest first. Filter to agent-*.jsonl.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    journals+=("$f")
  done < <(cd "$subagents_dir" && ls -1tr agent-*.jsonl 2>/dev/null | awk -v d="$subagents_dir" '{print d"/"$0}')

  local idx=0
  local jpath base meta agent_type text safe_at out_name out_path body
  for jpath in "${journals[@]}"; do
    idx=$((idx + 1))
    base="$(basename "$jpath" .jsonl)"
    meta="${jpath%.jsonl}.meta.json"
    agent_type="$(_meta_agent_type "$meta")"
    text="$(_extract_last_assistant_text "$jpath")"
    # No terminal text yet = agent is still running / hasn't emitted assistant
    # content. Skip — we'll catch it on a later cycle. AC-034 (additive + disposable):
    # this leaves a partial state that persist overwrites cleanly.
    if [ -z "$text" ]; then
      continue
    fi
    safe_at="$(_sanitize "$agent_type")"
    out_name="$(printf '%02d-%s.md' "$idx" "$safe_at")"
    out_path="${FINDINGS_DIR}/${out_name}"
    body="$(_render_findings_md "$agent_type" "$jpath" "$text")"
    _atomic_write "$out_path" "$body"
  done
}

# -------------------------------------------------------------------- main ---

if [ "$ONCE" = "1" ]; then
  _one_pass
  exit 0
fi

# Loop forever (or until killed). The watcher is disposable — SIGINT/SIGTERM
# just stop the loop; any partially-written files are left for end-of-run
# persist to overwrite cleanly (AC-034). No teardown ceremony needed.
trap 'exit 0' INT TERM
while :; do
  _one_pass
  sleep "$INTERVAL"
done
