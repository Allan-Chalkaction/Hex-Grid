#!/usr/bin/env bash
# PostToolUse wrapper.
# Matcher: Agent|Write
# Event: PostToolUse
#
# This wrapper survives as the stable hook registration seam (ADR-079 K4):
# the distributed settings.json registers THIS file for PostToolUse, so keeping
# the wrapper lets the v1 phase machine be retired without re-registering hooks
# in every consumer (consumers re-link, not re-register).
#
# Post-ADR-079 it has a single child: sync-artifacts-post-agent.sh (auto-state +
# completed_agents tracking). The v1 advance-workflow-phase.sh child — and its
# exit-code propagation / fail-loud logic — was deleted with the phase state
# machine; there are no surviving track transitions to drive.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Capture stdin once
INPUT=$(cat /dev/stdin 2>/dev/null || echo '{}')

# sync-artifacts (creates state file, tracks agents). Advisory — surface its
# stderr but do not abort on its failure.
echo "$INPUT" | bash "$SCRIPT_DIR/sync-artifacts-post-agent.sh"
SYNC_RC=$?
if [ "$SYNC_RC" -ne 0 ]; then
  echo "post-tool-use-workflow: sync-artifacts exited ${SYNC_RC} (advisory)" >&2
fi

exit 0
