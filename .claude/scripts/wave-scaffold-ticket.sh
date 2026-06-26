#!/usr/bin/env bash
# wave-scaffold-ticket.sh — orchestrated mode shared ticket-scaffolding helper.
#
# Both w-setup (first ticket of a wave) and t-commit (looping to next ticket
# after a squash-merge) need to perform the same sequence of operations to
# enter a ticket. Pre-extraction, the sequence was duplicated inline in both
# phase files; t-commit's loop-back was missing the scaffolding (mkdir +
# prompt.md + ticket_run_dir update) entirely, surfaced as a Wave 1 finding
# during the orchestrated-mode rollout.
#
# Operations, in the order w-setup originally performed them:
#
#   1. Update the wave-level `current_ticket` field on the manifest.
#   2. Create ${TICKET_RUN_DIR} and write prompt.md from the manifest entry
#      (skipped if a matching dir + prompt.md already exists — resume case).
#   3. Persist ticket_run_dir + status="in-progress" on the ticket atomically
#      (single-call jq+tmp+mv via wave-manifest.py update-ticket-status).
#   4. Mutate the orchestrated state file to a per-ticket entry phase + new
#      current_ticket; append phase_history; update last_activity_at.
#
# Per-ticket entry phase (D7 / CARRY-FORWARD §2 Option b):
#   - wave_protocol_version == 3 → "t-implement" (ADR-028: every ticket enters
#     at t-implement; the wave-implement marker dispatches one wave-implementer
#     on the first ticket and passes through on the rest. Pre-impl review is
#     wave-level at w-setup (ADR-015); post-impl review is wave-level at
#     w-finalize (ADR-026); so there are no per-ticket pre/post phases.)
#   - wave_protocol_version == 2 → "t-drift-check" (Layer 1 drift surface
#     fires BEFORE t-implement; legacy t-cto/t-spec/t-consensus collapse
#     into the wave-level review trio at w-setup per ADR-015)
#   - wave_protocol_version == 1 (or absent) → "t-cto" (legacy per-ticket
#     pre-implementation review chain)
#
# Wave-spec location convention (D7 / Q-D8, forward-only):
#   - wave_protocol_version == 2 or 3 → ${run_dir}/spec.md (canonical; the
#     pre-build spec at docs/step-3-specs/{slug}/waves/{wave-slug}/ MOVES into
#     ${run_dir} as the build's first act — ADR-051 move-on-advance).
#   - wave_protocol_version == 1 → docs/step-3-specs/waves/{slug}.md (legacy, pre-ADR-051)
# This helper does NOT read the wave-spec directly (the manifest is the
# operative source). The convention is documented here for downstream
# phase docs and is enforced by the orchestrated SKILL at wave creation.
#
# Idempotence: re-invoking with the same ticket_key is safe. mkdir is -p,
# prompt.md is rewritten only if missing, manifest updates set deterministic
# values, and state-file mutation appends a fresh phase_history entry (the
# log of re-invocation is intentional — diagnostic, not bug).
#
# Usage:
#   bash core/scripts/wave-scaffold-ticket.sh <run_dir> <session_id> <slug> <ticket_key>
#
# All four args are required. Exits non-zero with a diagnostic on any error;
# does NOT swallow failures from update-ticket-status, update-wave-field, or
# the state-file mutation.

set -euo pipefail

# Locate the co-located wave-manifest.py. It is ALWAYS a sibling of this script
# in both layouts: claude-infra's core/scripts/, and a consumer's .claude/scripts/
# (setup.sh symlinks both files side by side). Resolving this script's own
# directory works whether the helper is invoked via its infra path OR a consumer
# symlink — `cd -P` follows a symlinked scripts/ dir, and a per-file symlink
# leaves dirname at the real .claude/scripts which holds the co-located
# wave-manifest.py symlink.
#
# Prior bug (Option-A fix): the old up-walk used $0 literally without
# dereferencing the symlink, so a consumer invocation
# (.claude/scripts/wave-scaffold-ticket.sh) resolved to the CONSUMER root and
# looked for a nonexistent <consumer>/core/scripts/wave-manifest.py. Sibling
# lookup needs no INFRA_ROOT and no symlink-chain walk.
SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd)"
WAVE_MANIFEST_PY="${SCRIPT_DIR}/wave-manifest.py"

if [ ! -f "$WAVE_MANIFEST_PY" ]; then
  echo "wave-scaffold-ticket: wave-manifest.py not found at $WAVE_MANIFEST_PY" >&2
  echo "  (resolved SCRIPT_DIR=$SCRIPT_DIR from \$0=$0)" >&2
  exit 2
fi

if [ $# -ne 4 ]; then
  cat >&2 <<'EOF'
Usage: wave-scaffold-ticket.sh <run_dir> <session_id> <slug> <ticket_key>

Scaffolds the ticket run dir, writes prompt.md from the manifest entry,
sets the ticket to in-progress with ticket_run_dir, updates the manifest's
current_ticket, and advances the orchestrated state file to the per-ticket
entry phase (t-drift-check for wave_protocol_version == 2; t-cto for v1).
EOF
  exit 2
fi

RUN_DIR="$1"
SESSION_ID="$2"
SLUG="$3"
TICKET_KEY="$4"

MANIFEST="${RUN_DIR}/wave-manifest.json"
STATE_FILE=".claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json"

if [ ! -f "$MANIFEST" ]; then
  echo "wave-scaffold-ticket: manifest not found at $MANIFEST" >&2
  exit 2
fi
if [ ! -f "$STATE_FILE" ]; then
  echo "wave-scaffold-ticket: state file not found at $STATE_FILE" >&2
  exit 2
fi

# Determine TICKET_RUN_DIR. Prefer an existing ${RUN_DIR}/tickets/*-${TICKET_KEY}
# directory if present (resume / idempotent re-invocation); otherwise mint one
# with the current HHmm timestamp. The glob is bounded by the ticket-key
# suffix, so it cannot match a sibling ticket.
shopt -s nullglob
EXISTING_DIRS=( "${RUN_DIR}/tickets/"*"-${TICKET_KEY}" )
shopt -u nullglob

if [ "${#EXISTING_DIRS[@]}" -ge 1 ] && [ -d "${EXISTING_DIRS[0]}" ]; then
  TICKET_RUN_DIR="${EXISTING_DIRS[0]}"
else
  TICKET_RUN_DIR="${RUN_DIR}/tickets/$(date +%H%M)-${TICKET_KEY}"
fi

# Step 1: update the wave-level current_ticket field.
python3 "$WAVE_MANIFEST_PY" update-wave-field \
    "$MANIFEST" current_ticket "\"${TICKET_KEY}\""

# Step 2: scaffold (mkdir + prompt.md). Only writes prompt.md if absent so a
# resume entry preserves any orchestrator-edited prompt.md.
mkdir -p "$TICKET_RUN_DIR"
if [ ! -f "${TICKET_RUN_DIR}/prompt.md" ]; then
  jq -r --arg key "${TICKET_KEY}" '
    .tickets[] | select(.key == $key) |
    "# Ticket: " + .key + "\n\n## Title\n" + .title +
    "\n\n## Description\n" + .description +
    "\n\n## Planned files\n" + ([.planned_files[] | "- " + .] | join("\n")) +
    "\n\n## Gate recommendations\n" + ([.gate_recommendations[] | "- " + .] | join("\n")) +
    "\n\n## Manual review required\n" + (.manual_review_required | tostring)
  ' "$MANIFEST" > "${TICKET_RUN_DIR}/prompt.md"
fi

# Step 3: persist ticket_run_dir + status="in-progress" atomically (CR-004).
python3 "$WAVE_MANIFEST_PY" update-ticket-status \
    "$MANIFEST" "$TICKET_KEY" in-progress \
    --field ticket_run_dir="\"${TICKET_RUN_DIR}\""

# Step 4: mutate the orchestrated state file to per-ticket entry phase
# + new current_ticket. Per D7 / CARRY-FORWARD §2 Option (b), the entry
# phase branches on wave_protocol_version:
#   - v3 → "t-implement" (ADR-028 one-implementer-per-wave: every ticket
#     enters at t-implement, where the wave-implement marker dispatches the
#     single wave-implementer on the first ticket and passes through on the
#     rest. Pre-impl review is wave-level (w-setup, ADR-015); post-impl review
#     is wave-level (w-finalize, ADR-026); so no per-ticket pre/post phases.)
#   - v2 → "t-drift-check" (Layer 1 drift surface; legacy pre-impl chain
#     collapsed into the wave-level review trio at w-setup per ADR-015)
#   - v1 (or absent) → "t-cto" (legacy per-ticket pre-impl chain)
WAVE_PROTOCOL_VERSION=$(jq -r '.wave_protocol_version // 1' "$MANIFEST")
if [ "$WAVE_PROTOCOL_VERSION" = "3" ]; then
  ENTRY_PHASE="t-implement"
elif [ "$WAVE_PROTOCOL_VERSION" = "2" ]; then
  ENTRY_PHASE="t-drift-check"
else
  ENTRY_PHASE="t-cto"
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg phase "$ENTRY_PHASE" --arg ticket "${TICKET_KEY}" --arg ts "$NOW" '
  .current_phase = $phase |
  .current_ticket = $ticket |
  .last_activity_at = $ts |
  .phase_history = (.phase_history // []) + [{"phase": $phase, "entered_at": $ts, "ticket": $ticket}]
' "$STATE_FILE" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

echo "wave-scaffold-ticket: ${TICKET_KEY} entered at ${TICKET_RUN_DIR} (phase=${ENTRY_PHASE}, v${WAVE_PROTOCOL_VERSION})"
