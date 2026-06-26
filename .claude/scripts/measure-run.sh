#!/usr/bin/env bash
#
# measure-run.sh — derive the three substrate-rebuild success metrics from a
# Claude Code session and append a measurement record to docs/step-3-specs/_metrics.jsonl.
#
# The three metrics (build-plan-v2 "Success criteria"):
#   output_tokens       — sum of message.usage.output_tokens over assistant turns.
#   operator_interrupts — genuine human text turns AFTER the first (the first is
#                         the kickoff prompt, not an interrupt). tool_result
#                         deliveries (also user-role) are excluded.
#   agent_dispatches    — count of `Agent`/`Task` tool_use blocks (orchestrator-
#                         visible direct dispatches).
#   workflow_dispatches — count of `Workflow` tool_use blocks (the v2 ENGINE
#                         dispatch primitive). The engine spawns its agents INSIDE
#                         the Workflow call, so they don't appear as Agent/Task
#                         blocks — for a v2 engine run, agent_dispatches alone
#                         undercounts the work; the real per-agent count is inside
#                         the Workflow (see `/workflows`). One Workflow call
#                         collapsing ~16 wave agents out of the orchestrator's
#                         context is the headline v2 win this row makes visible.
#
# Subagent token roll-up (T4.2 — closes the v2 attribution gap):
#   For transcript/session/latest modes, the script also locates this session's
#   native subagent journals and aggregates their token usage. This makes the
#   agents that run INSIDE a Workflow call (invisible to the dispatch counts above)
#   visible in the token record. The new additive fields are:
#     subagent_count                 — number of journals aggregated.
#     subagent_input_tokens          — sum of message.usage.input_tokens.
#     subagent_output_tokens         — sum of message.usage.output_tokens.
#     subagent_cache_creation_tokens — sum of message.usage.cache_creation_input_tokens.
#     subagent_cache_read_tokens     — sum of message.usage.cache_read_input_tokens.
#     subagent_link_method           — how journals were joined to the session.
#   When no journals are found, all five token/count fields are null (the
#   measurement never fails on a missing subagents dir).
#
#   Linkage method: subagent journals are `agent-*.jsonl` files in the session's
#   `subagents/` subdir — i.e. `<transcript-without-.jsonl>/subagents/agent-*.jsonl`,
#   a directory that sits beside the session transcript in the same project dir.
#   Each journal entry ALSO carries a `sessionId` field equal to the parent session
#   and an `attributionAgent` field naming the agent type — so the join is
#   structural (directory) AND field-verified (sessionId), not a guess. Journals
#   whose in-file sessionId disagrees with the session being measured are skipped.
#   Labelled "subagents-dir+sessionId" in subagent_link_method.
#
# Authoritative source is the session transcript JSONL under
# ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl. A --run-folder fallback
# derives only agent_dispatches (from findings/ + state completed_agents); tokens
# and interrupts are reported null because they are not recoverable from artifacts.
#
# Usage:
#   measure-run.sh --transcript <file.jsonl> [opts]
#   measure-run.sh --session <session-id>    [opts]      # resolves under ~/.claude/projects
#   measure-run.sh --latest [project-substr] [opts]      # newest transcript (substr is CASE-INSENSITIVE)
#   measure-run.sh --run-folder <dir>        [opts]      # fallback: dispatches only
#
# Options:
#   --version v1|v2     label which substrate produced the run (default: auto from cwd/transcript path)
#   --task <slug>       a human label for what was run (default: "unspecified")
#   --label <text>      free-form note stored on the record
#   --metrics <path>    target _metrics.jsonl (default: <repo>/docs/step-3-specs/_metrics.jsonl)
#   --no-append         print the record to stdout only; do not write
#   --per-agent         add a `subagents` array to the record: one entry per journal
#                       carrying {agent, journal_id, input/output/cache_creation/cache_read
#                       tokens}. Default OFF to keep records small.
#   --run-log <dir>     after computing, append one TOKENS: line to <dir>/run-log.md
#                       summarising orchestrator output + the subagent roll-up. Creates
#                       the file if missing; a write error never fails the measurement.
#   --by-mtime          (--latest mode only) sort transcript candidates by file mtime (newest
#                       first) instead of the default `ls -t` time ordering. Catches transcripts
#                       that were edited/touched after a more-recent file was created.
#
# Records are tagged {"kind":"measurement"} and carry the legacy {slug,status,
# timestamp} keys so existing readers (pipeline-metrics, retrospective) skip them
# cleanly while remaining valid JSONL.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODE=""; ARG=""
VERSION=""; TASK="unspecified"; LABEL=""
METRICS="$REPO_DIR/docs/step-3-specs/_metrics.jsonl"
APPEND=true
BY_MTIME=false
PER_AGENT=false
RUN_LOG_DIR=""

die() { printf 'measure-run: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --transcript) MODE=transcript; ARG="${2:-}"; shift 2 ;;
    --session)    MODE=session;    ARG="${2:-}"; shift 2 ;;
    --latest)     MODE=latest;     ARG="${2:-}"; [ "${ARG#--}" != "$ARG" ] && { ARG=""; shift 1; } || shift 2 ;;
    --run-folder) MODE=runfolder;  ARG="${2:-}"; shift 2 ;;
    --version)    VERSION="${2:-}"; shift 2 ;;
    --task)       TASK="${2:-}"; shift 2 ;;
    --label)      LABEL="${2:-}"; shift 2 ;;
    --metrics)    METRICS="${2:-}"; shift 2 ;;
    --no-append)  APPEND=false; shift 1 ;;
    --per-agent)  PER_AGENT=true; shift 1 ;;
    --run-log)    RUN_LOG_DIR="${2:-}"; shift 2 ;;
    --by-mtime)   BY_MTIME=true; shift 1 ;;
    -h|--help)    awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;  # dynamic: header comment block (no hardcoded line range)
    *) die "unknown arg: $1" ;;
  esac
done

[ -n "$MODE" ] || die "specify one of --transcript | --session | --latest | --run-folder (see --help)"

PROJECTS_ROOT="${HOME}/.claude/projects"

# --- Resolve the transcript file (for transcript/session/latest modes) -------
TRANSCRIPT=""
case "$MODE" in
  transcript)
    TRANSCRIPT="$ARG"; [ -f "$TRANSCRIPT" ] || die "transcript not found: $TRANSCRIPT" ;;
  session)
    [ -n "$ARG" ] || die "--session needs a session id"
    TRANSCRIPT="$(find "$PROJECTS_ROOT" -name "${ARG}.jsonl" -type f 2>/dev/null | head -1)"
    [ -n "$TRANSCRIPT" ] || die "no transcript for session id: $ARG" ;;
  latest)
    # CASE-INSENSITIVE substring match on the encoded project-dir path. Claude
    # Code records the dir with the case you cd'd into (~/Desktop/Test2 ->
    # ...-Desktop-Test2), but macOS shell globbing is case-sensitive — so a
    # lowercase `--latest test2` would silently miss `...-Test2`. `find -ipath`
    # matches case-insensitively; capture candidates first, then pick newest via
    # `ls -t` (guarded so an empty match never makes `ls` list the cwd).
    if [ -n "$ARG" ]; then
      _cand="$(find "$PROJECTS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -ipath "*${ARG}*" 2>/dev/null)"
    else
      _cand="$(find "$PROJECTS_ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null)"
    fi
    if [ "$BY_MTIME" = true ] && [ -n "$_cand" ]; then
      # --by-mtime: sort by file mtime (newest first) instead of the default ls-time order.
      # `ls -t` keys off ctime/mtime via Darwin's default but the canonical "newest by mtime"
      # is `stat`-driven sort. macOS uses `stat -f %m`; GNU uses `stat -c %Y`. Detect once.
      if stat -f %m "$0" &>/dev/null; then
        _stat_fmt='-f %m'
      else
        _stat_fmt='-c %Y'
      fi
      # Emit "<mtime>\t<path>", numeric-sort descending, take the first path.
      TRANSCRIPT="$(printf '%s\n' "$_cand" | while IFS= read -r _p; do
        [ -f "$_p" ] || continue
        _m="$(stat $_stat_fmt "$_p" 2>/dev/null || echo 0)"
        printf '%s\t%s\n' "$_m" "$_p"
      done | sort -t "$(printf '\t')" -k1,1 -nr | head -1 | cut -f2-)"
    elif [ -n "$_cand" ]; then
      TRANSCRIPT="$(printf '%s\n' "$_cand" | xargs ls -t 2>/dev/null | head -1)"
    fi
    [ -n "$TRANSCRIPT" ] || die "no transcript found under $PROJECTS_ROOT (filter: '${ARG:-none}')" ;;
esac

# --- Auto-detect version from the RUN's path if not given -------------------
# Key off the transcript/run-folder path (the run's origin), never the harness's
# own repo dir — the harness lives in v2 but routinely measures v1 runs.
if [ -z "$VERSION" ]; then
  case "${TRANSCRIPT}${ARG}" in
    *claude-infra-v2*) VERSION=v2 ;;
    *new-claude-infra*) VERSION=v1 ;;
    *) VERSION=unknown ;;
  esac
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "$MODE" = runfolder ]; then
  # Fallback: count agent dispatches from run artifacts; tokens/interrupts unknown.
  [ -d "$ARG" ] || die "run folder not found: $ARG"
  RECORD="$(python3 - "$ARG" "$VERSION" "$TASK" "$LABEL" "$TS" <<'PY'
import json, sys, os, glob
runf, version, task, label, ts = sys.argv[1:6]
dispatches = 0
fdir = os.path.join(runf, "findings")
if os.path.isdir(fdir):
    dispatches = len([f for f in glob.glob(os.path.join(fdir, "*.md"))])
rec = {
    "kind": "measurement", "slug": os.path.basename(runf.rstrip("/")),
    "status": "MEASURED", "timestamp": ts, "version": version, "task": task,
    "source": "run-folder", "source_path": runf,
    "output_tokens": None, "operator_interrupts": None,
    "duration_seconds": None,
    "agent_dispatches": dispatches,
    "note": "run-folder fallback: tokens/interrupts/duration unavailable; dispatches = findings/*.md count",
}
if label: rec["label"] = label
print(json.dumps(rec))
PY
)"
else
  RECORD="$(python3 - "$TRANSCRIPT" "$VERSION" "$TASK" "$LABEL" "$TS" "$PER_AGENT" <<'PY'
import json, sys, os, glob
path, version, task, label, ts, per_agent_s = sys.argv[1:7]
per_agent = (per_agent_s == "true")
out_tokens = 0
agent_dispatches = 0
workflow_dispatches = 0
human_text_turns = 0
assistant_turns = 0
# --- Wall-clock duration (W5.0 / ADR-100 amend) ----------------------------
# duration_seconds = last-event minus first-event timestamp, derived from the
# top-level ISO-8601 `timestamp` field each transcript event carries
# (e.g. "2026-05-23T18:20:31.669Z"). It is a numeric/null SCALAR only — NO
# message/content/text field is added (token-counts-only invariant 5). null
# when no recoverable timestamps (mirrors the output_tokens null-grace template).
import datetime as _dt
def _parse_ts(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        # ISO-8601 with trailing Z (UTC). Python <3.11 chokes on 'Z', so swap it.
        return _dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None
_first_ts = None
_last_ts = None
for line in open(path, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    _ev_ts = _parse_ts(o.get("timestamp"))
    if _ev_ts is not None:
        if _first_ts is None or _ev_ts < _first_ts:
            _first_ts = _ev_ts
        if _last_ts is None or _ev_ts > _last_ts:
            _last_ts = _ev_ts
    t = o.get("type")
    msg = o.get("message") or {}
    if t == "assistant":
        assistant_turns += 1
        u = msg.get("usage") or {}
        out_tokens += int(u.get("output_tokens") or 0)
        cont = msg.get("content")
        if isinstance(cont, list):
            for b in cont:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    name = b.get("name")
                    if name in ("Agent", "Task"):
                        agent_dispatches += 1
                    elif name == "Workflow":
                        workflow_dispatches += 1
    elif t == "user":
        # Genuine human turn = user message whose content has a text block and
        # no tool_result block. tool_result deliveries are user-role but machine.
        cont = msg.get("content")
        if o.get("isMeta"):
            continue
        is_tool_result = False
        has_text = False
        if isinstance(cont, str):
            has_text = bool(cont.strip())
        elif isinstance(cont, list):
            for b in cont:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_result":
                    is_tool_result = True
                elif b.get("type") == "text" and b.get("text", "").strip():
                    has_text = True
        if has_text and not is_tool_result:
            human_text_turns += 1
operator_interrupts = max(0, human_text_turns - 1)  # first human turn = kickoff

# Wall-clock duration: last-event minus first-event. null when unrecoverable.
duration_seconds = None
if _first_ts is not None and _last_ts is not None and _last_ts >= _first_ts:
    _secs = (_last_ts - _first_ts).total_seconds()
    # Render a whole-second delta as int, sub-second as float — numeric scalar either way.
    duration_seconds = int(_secs) if _secs == int(_secs) else _secs

# --- Subagent token roll-up (T4.2) -----------------------------------------
# Journals live at <transcript-without-.jsonl>/subagents/agent-*.jsonl, a dir
# beside the session transcript. The directory IS the structural join; each
# journal also stamps `sessionId` (parent) + `attributionAgent` (agent type),
# so we field-verify the join and recover labels without prompt-prefix matching.
# Null-graceful: no subagents dir -> all five fields stay None, no failure.
session_id = os.path.splitext(os.path.basename(path))[0]
subagents_dir = os.path.splitext(path)[0] + os.sep + "subagents"
sub_count = None
sub_in = sub_out = sub_cc = sub_cr = None
sub_link_method = None
sub_detail = []
sub_skipped = 0
if os.path.isdir(subagents_dir):
    journals = sorted(glob.glob(os.path.join(subagents_dir, "agent-*.jsonl")))
    if journals:
        sub_count = 0
        sub_in = sub_out = sub_cc = sub_cr = 0
        sub_link_method = "subagents-dir+sessionId"
        for jp in journals:
            j_in = j_out = j_cc = j_cr = 0
            j_agent = None
            j_session = None
            j_id = os.path.splitext(os.path.basename(jp))[0]  # e.g. agent-<hash>
            try:
                jf = open(jp, encoding="utf-8")
            except Exception:
                continue
            with jf:
                for jl in jf:
                    jl = jl.strip()
                    if not jl:
                        continue
                    try:
                        jo = json.loads(jl)
                    except Exception:
                        continue
                    if j_session is None and jo.get("sessionId"):
                        j_session = jo.get("sessionId")
                    if j_agent is None and jo.get("attributionAgent"):
                        j_agent = jo.get("attributionAgent")
                    if jo.get("type") == "assistant":
                        ju = (jo.get("message") or {}).get("usage") or {}
                        j_in += int(ju.get("input_tokens") or 0)
                        j_out += int(ju.get("output_tokens") or 0)
                        j_cc += int(ju.get("cache_creation_input_tokens") or 0)
                        j_cr += int(ju.get("cache_read_input_tokens") or 0)
            # Field-verify the structural join: skip journals stamped with a
            # different parent session (defends against stray files in the dir).
            if j_session is not None and j_session != session_id:
                sub_skipped += 1
                continue
            sub_count += 1
            sub_in += j_in; sub_out += j_out; sub_cc += j_cc; sub_cr += j_cr
            if per_agent:
                sub_detail.append({
                    "agent": j_agent or j_id,
                    "journal_id": j_id,
                    "input_tokens": j_in,
                    "output_tokens": j_out,
                    "cache_creation_tokens": j_cc,
                    "cache_read_tokens": j_cr,
                })

rec = {
    "kind": "measurement", "slug": os.path.splitext(os.path.basename(path))[0],
    "status": "MEASURED", "timestamp": ts, "version": version, "task": task,
    "source": "transcript", "source_path": path,
    "output_tokens": out_tokens, "operator_interrupts": operator_interrupts,
    "duration_seconds": duration_seconds,
    "human_text_turns": human_text_turns, "assistant_turns": assistant_turns,
    "agent_dispatches": agent_dispatches,
    "workflow_dispatches": workflow_dispatches,
    "subagent_count": sub_count,
    "subagent_input_tokens": sub_in,
    "subagent_output_tokens": sub_out,
    "subagent_cache_creation_tokens": sub_cc,
    "subagent_cache_read_tokens": sub_cr,
    "subagent_link_method": sub_link_method,
}
if sub_skipped:
    rec["subagent_session_mismatch_skipped"] = sub_skipped
if per_agent:
    rec["subagents"] = sub_detail
if workflow_dispatches:
    rec["note"] = ("v2 engine run: agent_dispatches counts only orchestrator-visible "
                   "Agent/Task blocks; the wave's agents run INSIDE the %d Workflow call(s) "
                   "(see /workflows for the internal count)." % workflow_dispatches)
if label:
    rec["label"] = label
print(json.dumps(rec))
PY
)"
fi

echo "$RECORD"

if [ "$APPEND" = true ]; then
  mkdir -p "$(dirname "$METRICS")"
  printf '%s\n' "$RECORD" >> "$METRICS"
  printf 'measure-run: appended to %s\n' "$METRICS" >&2
fi

# --- Run-log token line (T4.2 --run-log) -----------------------------------
# Append ONE TOKENS: line to <dir>/run-log.md summarising orchestrator output +
# the subagent roll-up. Best-effort: a write failure (missing parent, perms)
# logs a warning and never fails the measurement (it has already been emitted).
if [ -n "$RUN_LOG_DIR" ]; then
  # Pass the record as argv (not stdin) so the heredoc remains python's program.
  TOKEN_LINE="$(python3 - "$TS" "$RECORD" <<'PY'
import json, sys
ts, record = sys.argv[1], sys.argv[2]
rec = json.loads(record)
def fmt(v):
    return "null" if v is None else str(v)
orch = fmt(rec.get("output_tokens"))
n = fmt(rec.get("subagent_count"))
si = fmt(rec.get("subagent_input_tokens"))
so = fmt(rec.get("subagent_output_tokens"))
print("TOKENS: orchestrator_out=%s subagents=%s in/%s out (%s journals) "
      "[measured by measure-run.sh at %s]" % (orch, si, so, n, ts))
PY
)"
  if [ -n "$TOKEN_LINE" ]; then
    if { mkdir -p "$RUN_LOG_DIR" && printf '%s\n' "$TOKEN_LINE" >> "$RUN_LOG_DIR/run-log.md"; } 2>/dev/null; then
      printf 'measure-run: appended TOKENS line to %s/run-log.md\n' "$RUN_LOG_DIR" >&2
    else
      printf 'measure-run: WARNING could not write run-log to %s (measurement unaffected)\n' "$RUN_LOG_DIR" >&2
    fi
  fi
fi
