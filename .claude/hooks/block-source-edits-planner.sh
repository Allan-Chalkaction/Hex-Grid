#!/usr/bin/env bash
# PreToolUse hook: planner-mode write-scoping (ADR-032)
# Matches: Edit|Write|Bash
#
# Exit code 0 = allow, Exit code 2 = block.
#
# Fires ONLY when planner mode is active — i.e. a session-scoped active-run state
# file with track="planner". Transparent (exit 0) in every other session/track.
#
# ROLE-PURITY INVARIANT (ADR-032): this hook has NO bypass short-circuit, by design.
# Bypass governs *gating*; planner-mode governs *role-scoped tool surface*. They are
# orthogonal primitives. To write source, exit planner mode — do NOT bypass through it.
# (Contrast block-source-edits.sh, which DOES honor bypass because it guards
# operator-override authority. Do not "fix" the missing short-circuit here — its
# absence is the contract. See docs/decisions/ADR-032-planner-track.md.)
#
# Disposition: default-DENY + planner-allow-list (the inverse of block-source-edits.sh):
#   Edit/Write → allow ONLY docs/** and core/rules/** (the planner run folder lives under docs/).
#   Bash       → read-only only: a filesystem-mutation deny-scan + a read-only first-token
#                allowlist + a read-only git-subcommand gate. Conservative/best-effort by
#                design (shell parsing is not exhaustive); over-blocks rather than under-blocks.
#                Relaxable as real read-only needs surface. ONE carve-out (step 0): `rm` of
#                THIS session's own active-run state file (the /planner off teardown) — else
#                planner mode blocks the command that exits it. Session-scoped, not a bypass.

set -uo pipefail

INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

command -v jq >/dev/null 2>&1 || exit 0  # fail-open if jq missing (mirrors sibling hooks)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# --- Detect planner mode: a session-scoped active-run with track="planner" ---
RUNS_DIR=".claude/agent-memory/active-runs"
PLANNER_ACTIVE=false
if [ -d "$RUNS_DIR" ]; then
  for candidate in "$RUNS_DIR"/*.json; do
    [[ "$candidate" == *.tmp ]] && continue
    [ -f "$candidate" ] || continue
    if [ -n "$SESSION_ID" ]; then
      fname=$(basename "$candidate")
      case "$fname" in "${SESSION_ID}-"*) ;; *) continue ;; esac
    fi
    tk=$(jq -r '.track // empty' "$candidate" 2>/dev/null)
    ph=$(jq -r '.current_phase // empty' "$candidate" 2>/dev/null)
    if [ "$tk" = "planner" ] && [ "$ph" != "done" ]; then
      PLANNER_ACTIVE=true
      break
    fi
  done
fi

[ "$PLANNER_ACTIVE" = true ] || exit 0  # transparent outside planner mode

# --- NO bypass short-circuit here (ADR-032). Its absence is intentional. ---

# --- Bash: read-only enforcement ---
if [ "$TOOL_NAME" = "Bash" ]; then
  [ -z "$COMMAND" ] && exit 0

  # (0) lifecycle carve-out: the /planner off teardown — a single, un-chained `rm` of
  #     this session's planner state file under active-runs/. The one mutating command
  #     planner mode MUST permit, else it blocks the very command that exits it
  #     (chicken-and-egg — the recurring "/planner off is stuck" bug).
  #
  #     Scoping: the hook only reaches this point when planner mode is active for THIS
  #     session (see detection above), and core/skills/planner/SKILL.md emits a
  #     slug-scoped glob (active-runs/*-<run-slug>.json) — the run slug is session-unique.
  #     We deliberately do NOT require the literal ${SESSION_ID} in the command:
  #     ${SESSION_ID} does NOT expand in the model's Bash-tool subshell (INFRA-012), so
  #     requiring it made the teardown structurally unmatchable. Guards: first token is
  #     rm (first LINE only — NR==1; a bare awk '{print $1}' concatenates every line's
  #     first token and breaks on multi-line commands), targets active-runs/*.json, and
  #     no chaining / substitution metacharacters. NOT a bypass short-circuit (role-purity
  #     intact). (ADR-032; see SKILL.md "End (/planner off)".)
  co_first=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*//' | awk 'NR==1{print $1}')
  if [ "$co_first" = "rm" ] \
     && printf '%s' "$COMMAND" | grep -qF ".claude/agent-memory/active-runs/" \
     && printf '%s' "$COMMAND" | grep -qE '\.json([[:space:]"'"'"']|$)' \
     && ! printf '%s' "$COMMAND" | grep -qE '[;&|`]|\$\(' ; then
    exit 0
  fi

  # (0b) jam-prune carve-out — REMOVED (ADR-112 Wave 3, PEC-T9/T10).
  #      The `/planner jam` sub-mode that this carve-out served is RETIRED — jam clustering +
  #      convergence moved to `/sweep` (which runs OUTSIDE planner mode and does its `git mv`/`git rm`
  #      as the orchestrator/operator, not through this hook). With `/planner jam` gone, this carve-out
  #      would grant `rm`/`mv` mutation authority inside a PLAIN `/planner` session for no live workflow
  #      — a dead privilege. Role-purity (ADR-032) is about the SMALLEST tool surface that fits the role;
  #      a plain planner session has no jam workflow, so it gets no jam-dir mutation authority. Removing
  #      the carve-out makes the hook strictly MORE restrictive (a jam `rm`/`mv` now falls through to the
  #      (1) deny-scan and is blocked) and preserves the default-deny + no-bypass-short-circuit contract.
  #      (The (0) teardown-rm carve-out below is unrelated and retained.)

  # (1) filesystem-mutation deny-scan: any (real) redirection or mutating command → block.
  #     Known-harmless redirections (to /dev/null, and stderr->stdout merge) are stripped
  #     first so read-only commands can silence noise — e.g. `git status 2>/dev/null`.
  deny=false
  scan=$(printf '%s' "$COMMAND" | sed -E 's/(2>&1|&>[[:space:]]*\/dev\/null|2?>[[:space:]]*\/dev\/null)//g')
  case "$scan" in *">"*) deny=true ;; esac
  printf '%s' "$COMMAND" | grep -qE '(^|[|&;[:space:]])(tee|rm|mv|cp|mkdir|touch|truncate|dd|install|ln|chmod|chown|chgrp)([[:space:]]|$)' && deny=true
  printf '%s' "$COMMAND" | grep -qE 'sed[[:space:]].*(-i|--in-place)' && deny=true
  if [ "$deny" = true ]; then
    echo "BLOCKED (planner mode): mutating shell command. The planner is read-only on the shell — use Read/Glob/Grep, or draft the change as an artifact. (ADR-032 role-scope; not lifted by /bypass.)" >&2
    exit 2
  fi

  # (2) read-only first-token allowlist. NR==1 → first token of the FIRST line only
  #     (bare awk '{print $1}' concatenates every line's first token → multi-line
  #     read-only commands like a `git log` / `ls` sequence would never match).
  first=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*//' | awk 'NR==1{print $1}')
  case "$first" in
    git)
      # (3) read-only git-subcommand gate.
      sub=$(printf '%s' "$COMMAND" | sed -E 's/^[[:space:]]*git[[:space:]]+//' | awk 'NR==1{print $1}')
      case "$sub" in
        log|show|diff|status|branch|ls-files|ls-tree|rev-parse|blame|grep|describe|shortlog|reflog|cat-file|whatchanged|name-rev|merge-base)
          exit 0 ;;
        *)
          echo "BLOCKED (planner mode): 'git ${sub}' is not a read-only git subcommand. Commits/pushes/checkouts are operator-authority, not planner actions. (ADR-032.)" >&2
          exit 2 ;;
      esac
      ;;
    grep|rg|find|ls|cat|head|tail|wc|jq|awk|diff|tree|pwd|echo|which|file|stat|sort|uniq|cut|basename|dirname|realpath|date|env|sed|column|nl|comm|test|true|printf)
      exit 0 ;;
    *)
      echo "BLOCKED (planner mode): '${first}' is not on the planner read-only Bash allowlist. Use a read-only command (git log/grep/find/cat/…), or draft the action as an artifact. (ADR-032; not lifted by /bypass.)" >&2
      exit 2 ;;
  esac
fi

# --- Edit/Write: planner-allow-list (default-deny) ---
[ -z "$FILE_PATH" ] && exit 0
case "$FILE_PATH" in
  */docs/*|docs/*|*/core/rules/*|core/rules/*)
    exit 0 ;;
esac
echo "BLOCKED (planner mode): the planner writes planning artifacts to docs/** and core/rules/** only — not '${FILE_PATH}'. To change source, draft it as text for the operator to paste, or route to /nimble or /bypass. (ADR-032 role-scope; not lifted by /bypass.)" >&2
exit 2
