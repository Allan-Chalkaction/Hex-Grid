#!/usr/bin/env bash
# block-fable-dispatch.sh — PreToolUse:Agent hook: ban Fable-class dispatch + floor at sonnet.
#
# Exit code 0 = allow the dispatch.
# Exit code 2 = block the dispatch.
#
# Converts the model-tier-selection convention into a fail-closed enforcement
# primitive (hook-over-behavioral — ADR-079/080). The behavioral floor already
# failed once (an expensive-tier dispatch slipped through); the fix is an exit
# code, not another rule clause.
#
# Governing decision: ADR-099 (fable dispatch ban + sonnet floor). The narrow
# examiner Fable seat is ADR-088; ADR-095 temporarily repins examiner to Opus —
# the allowlist is TYPE-KEYED (literal {examiner}), never pin-detected, so the
# seat survives the runtime pin flip (ADR-095) and a future ADR-088 Fable revert.
#
# Resolution order (load-bearing):
#   Rule 1  explicit .tool_input.model contains 'fable' (case-insensitive) ->
#           BLOCK unconditionally, for ANY type, INCLUDING examiner. The allowlist
#           governs ONLY the frontmatter-pin path, NEVER the explicit-param path.
#   Rule 2  explicit non-fable .tool_input.model (sonnet/haiku/...) -> ALLOW.
#   Rule 3  .tool_input.model ABSENT -> resolve the child frontmatter pin (from
#           .claude/agents/<type>.md OR core/agents/<type>.md). A FABLE pin blocks
#           every type except examiner (ADR-088 seat); a non-fable pin allows; an
#           UNRESOLVABLE / PINLESS dispatch ALLOWS — the hook cannot see the parent
#           session model, so blocking every unpinned dispatch would brick the
#           substrate. Pin-existence is enforced as a separate lint, not here.
#   Genuine-error fail CLOSED: parse failure / no jq / empty stdin -> exit 2.
#
# Trust-no-input: there is no parent-session model field on tool_input; the hook
# gates only the DETECTABLE Fable cases (explicit fable param, or a fable frontmatter
# pin on a non-examiner). Agent pins resolve from .claude/agents/ (consumer symlink
# target) or core/agents/ (claude-infra's own un-symlinked source).
#
# All checks are LOCAL FILE READS — no remote services involved.

set -uo pipefail

# Read stdin defensively. Empty/unreadable -> fail closed below.
INPUT=$(cat /dev/stdin 2>/dev/null || echo '')

# Fail closed: empty stdin (no payload to reason about -> over-block visibly).
if [ -z "$INPUT" ]; then
  echo "BLOCKED: empty stdin — cannot determine dispatch model. Failing closed (ADR-099)." >&2
  exit 2
fi

# jq is required to parse the dispatch payload. Absent -> fail closed.
if ! command -v jq &> /dev/null; then
  echo "BLOCKED: jq is required to evaluate the Fable-dispatch gate. Failing closed (ADR-099)." >&2
  exit 2
fi

# Fail closed: malformed JSON -> jq cannot parse -> over-block.
if ! echo "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo "BLOCKED: tool_input is not valid JSON — cannot evaluate the dispatch model. Failing closed (ADR-099)." >&2
  exit 2
fi

# Fail closed: a non-object top-level JSON (array/string/number) is a structurally invalid
# dispatch payload — jq -e . treats [] / "x" / 123 as truthy, so assert object shape (SA-002).
if ! echo "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "BLOCKED: tool_input is not a JSON object — cannot evaluate the dispatch. Failing closed (ADR-099)." >&2
  exit 2
fi

SUBAGENT_TYPE=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)
MODEL=$(echo "$INPUT" | jq -r '.tool_input.model // empty' 2>/dev/null)

# --- Rule 1: explicit-param Fable ban (UNCONDITIONAL, checked FIRST) ---
# Case-insensitive substring on the model token. The allowlist (Rule 3) cannot be
# reached via the explicit-param path — even examiner with an explicit fable param
# is blocked.
if [ -n "$MODEL" ]; then
  MODEL_LC=$(printf '%s' "$MODEL" | tr '[:upper:]' '[:lower:]')
  case "$MODEL_LC" in
    *fable*)
      echo "BLOCKED: Fable may not be dispatched (explicit model param '${MODEL}'). ADR-099." >&2
      exit 2
      ;;
    *)
      # --- Rule 2: explicit non-fable model -> allow ---
      exit 0
      ;;
  esac
fi

# --- Rule 3: .tool_input.model ABSENT -> resolve the child frontmatter pin ---
# The hook CANNOT see the parent session's model (there is no such field on tool_input),
# so it cannot detect "unpinned dispatch inheriting Fable". It therefore gates only what is
# DETECTABLE: an explicit fable param (Rule 1) and a fable frontmatter pin on a non-examiner
# (below). An unresolvable / pinless dispatch is ALLOWED — over-blocking every unpinned
# dispatch bricks the substrate (all real agents carry pins; pin-existence is a lint concern,
# not a per-dispatch gate). ADR-099.
TYPE="$SUBAGENT_TYPE"
if [ -z "$TYPE" ]; then
  TYPE="general-purpose"
fi

# Reject a path-bearing subagent_type (SA-003 defense-in-depth): a real agent type is a bare
# slug, never a path. A type containing '/' or '..' would interpolate into the agent-file path
# and read outside the agents dirs. Treat it as unresolvable -> ALLOW (consistent with the
# no-agent-file arm; the hook only ever blocks DETECTABLE Fable, never reads attacker paths).
case "$TYPE" in
  */*|*..*)
    exit 0 ;;
esac

# Anchor agent-file reads to the project dir (hooks can fire with a drifted cwd).
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"

# Resolve the agent file from EITHER the distributed consumer location (.claude/agents/, the
# setup.sh symlink target) OR the canonical source location (core/agents/, where claude-infra
# itself keeps its agents un-symlinked). Whichever exists wins. (The original single-path
# assumption blocked EVERY dispatch in the infra repo — agents live in core/agents/ there.)
AGENT_FILE=""
for cand in "$PROJECT_DIR/.claude/agents/${TYPE}.md" "$PROJECT_DIR/core/agents/${TYPE}.md"; do
  if [ -f "$cand" ]; then AGENT_FILE="$cand"; break; fi
done

# No committed agent file (a built-in like Explore/general-purpose, or an unknown type) ->
# the model is undeterminable and there is no detectable Fable -> ALLOW (do not over-block).
if [ -z "$AGENT_FILE" ]; then
  exit 0
fi

# Extract the frontmatter `model:` pin (grep the model: line; do not full-parse YAML —
# mirrors how the substrate reads core/agents/*.md model fields).
PIN=$(grep -m1 -E '^[[:space:]]*model:[[:space:]]*' "$AGENT_FILE" 2>/dev/null \
        | sed -E 's/^[[:space:]]*model:[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')

# File present but no model: pin -> undeterminable model, no detectable Fable -> ALLOW.
# (Pin-existence is enforced separately as a lint, not by over-blocking this dispatch.)
if [ -z "$PIN" ]; then
  exit 0
fi

# Frontmatter pins Fable: type-keyed allowlist — ONLY agent TYPE literally 'examiner'
# is allowed (in-source literal set {examiner}). Keyed on type, NEVER on detecting a
# Fable pin, so the ADR-088 examiner seat survives examiner's ADR-095 temp Opus pin
# and any future Fable revert.
PIN_LC=$(printf '%s' "$PIN" | tr '[:upper:]' '[:lower:]')
case "$PIN_LC" in
  *fable*)
    case "$TYPE" in
      examiner)
        # ADR-088 narrow seat — allowed.
        exit 0
        ;;
      *)
        echo "BLOCKED: Fable frontmatter pin is allowlisted for only 'examiner' (got type '${TYPE}'). ADR-099 / ADR-088." >&2
        exit 2
        ;;
    esac
    ;;
  *)
    # Frontmatter pins a non-fable model (opus/sonnet/haiku) -> allow.
    exit 0
    ;;
esac
