#!/usr/bin/env bash
# core/scripts/lib/native-transcript-path.sh
#
# Shared path-resolution helper for the native Claude Code (CC) per-agent
# transcript journal — `agent-*.jsonl`. Used by BOTH:
#
#   - core/scripts/persist-run-artifacts.py (journal-read fallback when the
#     Workflow return drops — ADR-068)
#   - core/scripts/watch-run-artifacts.sh   (Wave 2's live-mirror watcher —
#     CONDITIONAL on the SPIKE outcome; AC-035 DRY).
#
# READ-ONLY. The native CC runtime is the only writer of `agent-*.jsonl`
# (ADR-068 binding invariant: the journal is the RUNTIME's; persist READS,
# the Workflow script NEVER writes one). This helper resolves paths; it
# does not open, write, or modify a journal file.
#
# Path shape observed on CC 2.1.168 (macOS, 2026-06-08 SPIKE):
#
#   $HOME/.claude/projects/<repo-slug>/<session-id>/subagents/agent-<agent-id>.jsonl
#                              │              │                   │
#                              │              │                   └─ 17-char hex (rendered as `agent-<id>`)
#                              │              └─ UUID; the orchestrator CC session id
#                              └─ repo path with '/' -> '-' and a leading '-'
#
#   Sibling: agent-<agent-id>.meta.json (worktreePath, agentType, toolUseId)
#
# When the cwd is a git WORKTREE (e.g. /repo/.claude/worktrees/agent-<id>),
# the journal still lives under the MAIN repo's slug — derive the main repo
# path via `git rev-parse --git-common-dir → dirname`.
#
# This is a Bash file meant to be SOURCED. The Python persist also calls
# the same resolution logic, but does so by re-implementing the algorithm
# in Python (the algorithm is short and stable enough that a Python-Bash
# bridge would be more fragile than the duplicate); the helper here is the
# CANONICAL spec — Python's resolution must stay byte-identical. The
# DRY contract (AC-035) is: same algorithm, two thin implementations.

# Usage:
#   source core/scripts/lib/native-transcript-path.sh
#   native_transcript_dir            # echoes $HOME/.claude/projects/<repo-slug>/<session-id>/subagents
#   native_transcript_for_agent ID   # echoes the agent-<ID>.jsonl path if it exists
#   native_transcript_resolve_main   # echoes the main-repo path for the current cwd

# Resolve the main-repo path from any cwd inside the repo or one of its worktrees.
# Exit 1 if not in a git repo. Writes only to stdout/stderr; touches no files.
native_transcript_resolve_main() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *)  common="$(pwd)/$common" ;;
  esac
  # common-dir is .git (a file or directory). Its parent is the main repo root.
  (cd "$(dirname "$common")" && pwd)
}

# Turn an absolute repo path into the CC project-slug under ~/.claude/projects/.
# Algorithm: replace '/' with '-' (keeps the leading '-' from the absolute path).
native_transcript_repo_slug() {
  local repo_path="${1:-}"
  [ -n "$repo_path" ] || return 2
  echo "$repo_path" | sed 's|/|-|g'
}

# Echo the directory holding the current session's per-agent journals.
# Args (optional): SESSION_ID (defaults to $CLAUDE_CODE_SESSION_ID).
# Exits 1 if the dir cannot be resolved or does not exist; touches no files.
native_transcript_dir() {
  local session="${1:-${CLAUDE_CODE_SESSION_ID:-}}"
  [ -n "$session" ] || { echo "native_transcript_dir: no session id (pass arg or set CLAUDE_CODE_SESSION_ID)" >&2; return 1; }
  local main slug dir
  main=$(native_transcript_resolve_main) || { echo "native_transcript_dir: not in a git repo" >&2; return 1; }
  slug=$(native_transcript_repo_slug "$main")
  dir="${HOME}/.claude/projects/${slug}/${session}/subagents"
  [ -d "$dir" ] || { echo "native_transcript_dir: dir not found: $dir" >&2; return 1; }
  echo "$dir"
}

# Echo a path to a specific agent's journal file, given the 17-char agent id.
# Returns the path even if the file does not (yet) exist — the caller decides
# whether to wait or fail. Touches no files.
native_transcript_for_agent() {
  local agent_id="${1:-}"
  [ -n "$agent_id" ] || { echo "native_transcript_for_agent: missing agent id" >&2; return 2; }
  local dir
  dir=$(native_transcript_dir) || return 1
  echo "${dir}/agent-${agent_id}.jsonl"
}

# Echo all current-session journals (newest mtime first). Useful for the
# watcher's "what changed?" loop and the SPIKE probe's enumeration.
native_transcript_list() {
  local dir
  dir=$(native_transcript_dir) || return 1
  # -t = sort by mtime, -1 = one per line; suppress error if no matches.
  (cd "$dir" && ls -1t agent-*.jsonl 2>/dev/null | awk -v d="$dir" '{print d"/"$0}')
}
