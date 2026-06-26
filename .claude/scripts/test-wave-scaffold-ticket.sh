#!/usr/bin/env bash
# Synthetic test for core/scripts/wave-scaffold-ticket.sh portability fix (A1).
#
# Verifies the helper:
#   - Self-locates claude-infra root from its own path (not cwd).
#   - Succeeds when invoked from a consumer-project-shaped cwd that does NOT
#     contain core/scripts/wave-manifest.py.
#   - Still works from claude-infra's own cwd (regression).
#   - Errors with a clear diagnostic when wave-manifest.py is unreachable
#     (e.g., script copied out of repo).
#
# Self-contained: runs in mktemp scratch dirs.
#
# Usage: bash core/scripts/test-wave-scaffold-ticket.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(dirname "$REPO_ROOT")"
SCAFFOLD="${REPO_ROOT}/core/scripts/wave-scaffold-ticket.sh"
WAVE_MANIFEST_PY="${REPO_ROOT}/core/scripts/wave-manifest.py"

if [ ! -f "$SCAFFOLD" ]; then
  echo "ERROR: wave-scaffold-ticket.sh not found at $SCAFFOLD" >&2
  exit 1
fi
if [ ! -f "$WAVE_MANIFEST_PY" ]; then
  echo "ERROR: wave-manifest.py not found at $WAVE_MANIFEST_PY" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 1
fi

PASS=0
FAIL=0
FAIL_DETAIL=""

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

# ---------------------------------------------------------------------------
# Helper: build a synthetic consumer-project-shape scratch dir + manifest +
# state file. Returns via exported vars: SCRATCH, RUN_DIR, MANIFEST, STATE_FILE,
# SESSION_ID, SLUG, TICKET_KEY.
# ---------------------------------------------------------------------------
build_scratch_consumer() {
  SCRATCH=$(mktemp -d)
  SLUG="fake"
  SESSION_ID="test-session"
  TICKET_KEY="T-001"
  RUN_DIR="${SCRATCH}/docs/step-5-pipeline/2026-05-08/2200-WAVE-${SLUG}"
  MANIFEST="${RUN_DIR}/wave-manifest.json"
  STATE_FILE="${SCRATCH}/.claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json"

  mkdir -p "${RUN_DIR}/tickets"
  mkdir -p "${SCRATCH}/.claude/agent-memory/active-runs"

  cat > "$MANIFEST" <<EOF
{
  "wave_slug": "${SLUG}",
  "wave_branch": "feature/wave-${SLUG}",
  "current_ticket": null,
  "tickets": [
    {
      "key": "${TICKET_KEY}",
      "title": "Test ticket one",
      "description": "Synthetic ticket for fixture testing.",
      "planned_files": ["src/foo.ts", "tests/foo.test.ts"],
      "gate_recommendations": [],
      "manual_review_required": true,
      "depends_on": [],
      "ticket_branch": "feature/wave-${SLUG}--${TICKET_KEY}",
      "status": "pending"
    }
  ]
}
EOF

  cat > "$STATE_FILE" <<EOF
{
  "ticket_key": null,
  "run_dir": "docs/step-5-pipeline/2026-05-08/2200-WAVE-${SLUG}",
  "slug": "${SLUG}",
  "track": "orchestrated",
  "mode": null,
  "session_id": "${SESSION_ID}",
  "current_phase": "w-setup",
  "current_ticket": null,
  "completed_agents": [],
  "phase_history": []
}
EOF
}

# ---------------------------------------------------------------------------
# AC #1 + #2 + #4 + #6: invoke from consumer-project cwd
# ---------------------------------------------------------------------------
echo "AC #1+#2+#4+#6: invoke from consumer-project cwd (no core/ dir)"

build_scratch_consumer
SCRATCH_1="$SCRATCH"

cd "$SCRATCH_1"

# Sanity: cwd does NOT contain core/
if [ -d "core" ]; then
  ko "scratch cwd cleanliness" "scratch dir contains core/ unexpectedly"
else
  ok "scratch cwd has no core/ dir (consumer-project shape)"
fi

# Use cwd-relative paths for run_dir; helper consumes them as-is
RUN_DIR_REL="docs/step-5-pipeline/2026-05-08/2200-WAVE-fake"

if bash "$SCAFFOLD" "$RUN_DIR_REL" "test-session" "fake" "T-001" >/dev/null 2>&1; then
  ok "AC-1: scaffold-ticket succeeds from consumer-project cwd"
else
  ko "AC-1: scaffold-ticket from consumer-project cwd" "exit non-zero"
fi

# AC-2: ticket dir + prompt.md created
TICKET_DIR=$(find "${RUN_DIR_REL}/tickets" -maxdepth 1 -type d -name "*-T-001" | head -1)
if [ -n "$TICKET_DIR" ] && [ -f "${TICKET_DIR}/prompt.md" ]; then
  ok "AC-2: ticket dir + prompt.md created"
  if grep -q "Test ticket one" "${TICKET_DIR}/prompt.md"; then
    ok "AC-2: prompt.md has manifest title"
  else
    ko "AC-2: prompt.md content" "title 'Test ticket one' not found in prompt.md"
  fi
else
  ko "AC-2: ticket dir / prompt.md" "missing"
fi

# AC-4: state-file path correctly resolved (consumer-cwd-relative)
PHASE=$(jq -r '.current_phase' ".claude/agent-memory/active-runs/test-session-fake.json")
CURRENT_TICKET=$(jq -r '.current_ticket' ".claude/agent-memory/active-runs/test-session-fake.json")
if [ "$PHASE" = "t-cto" ] && [ "$CURRENT_TICKET" = "T-001" ]; then
  ok "AC-4: state file advanced to t-cto with current_ticket=T-001"
else
  ko "AC-4: state file advance" "phase=$PHASE current_ticket=$CURRENT_TICKET"
fi

# AC-6: manifest path correctly resolved (cwd-relative through arg)
TICKET_STATUS=$(jq -r '.tickets[0].status' "${RUN_DIR_REL}/wave-manifest.json")
TICKET_RUN_DIR=$(jq -r '.tickets[0].ticket_run_dir' "${RUN_DIR_REL}/wave-manifest.json")
if [ "$TICKET_STATUS" = "in-progress" ] && [ -n "$TICKET_RUN_DIR" ]; then
  ok "AC-6: manifest ticket updated (status=in-progress, ticket_run_dir set)"
else
  ko "AC-6: manifest update" "status=$TICKET_STATUS ticket_run_dir=$TICKET_RUN_DIR"
fi

# Cleanup scratch 1
cd /
rm -rf "$SCRATCH_1"

# ---------------------------------------------------------------------------
# AC #3: regression — invoke from claude-infra cwd
# ---------------------------------------------------------------------------
echo "AC #3: regression — invoke from claude-infra cwd"

build_scratch_consumer
SCRATCH_2="$SCRATCH"

# Stage manifest + state-file paths to be reachable when cwd is REPO_ROOT.
# Easiest: copy the scratch consumer-project skeleton to a temp subdir under
# REPO_ROOT and cd there; OR run from REPO_ROOT with absolute paths.
# We use the latter (absolute paths through args) since that's a real use
# case (claude-infra-internal invocations from REPO_ROOT).
cd "$REPO_ROOT"

# Move scratch state file to REPO_ROOT-relative path that the helper expects
# (.claude/agent-memory/active-runs/...). REPO_ROOT itself has its own
# .claude/ — do NOT clobber it. Use a different SLUG/SESSION_ID combo.
ALT_SLUG="fake-regression"
ALT_SESSION="test-regression"
ALT_TICKET="T-100"
ALT_RUN_DIR="${SCRATCH_2}/docs/step-5-pipeline/2026-05-08/2201-WAVE-${ALT_SLUG}"
ALT_STATE_FILE=".claude/agent-memory/active-runs/${ALT_SESSION}-${ALT_SLUG}.json"

mkdir -p "${ALT_RUN_DIR}/tickets"
cat > "${ALT_RUN_DIR}/wave-manifest.json" <<EOF
{
  "wave_slug": "${ALT_SLUG}",
  "wave_branch": "feature/wave-${ALT_SLUG}",
  "current_ticket": null,
  "tickets": [
    {
      "key": "${ALT_TICKET}",
      "title": "Regression ticket",
      "description": "Regression test from claude-infra cwd.",
      "planned_files": ["docs/foo.md"],
      "gate_recommendations": [],
      "manual_review_required": true,
      "depends_on": [],
      "ticket_branch": "feature/wave-${ALT_SLUG}--${ALT_TICKET}",
      "status": "pending"
    }
  ]
}
EOF

# Write the state file under REPO_ROOT's .claude/ (we'll clean it up after).
# The active-runs/ directory is gitignored — on a fresh clone (CI) it
# does not exist. Ensure the parent dir exists before redirecting.
mkdir -p "$(dirname "$ALT_STATE_FILE")"
cat > "$ALT_STATE_FILE" <<EOF
{
  "ticket_key": null,
  "run_dir": "${ALT_RUN_DIR}",
  "slug": "${ALT_SLUG}",
  "track": "orchestrated",
  "mode": null,
  "session_id": "${ALT_SESSION}",
  "current_phase": "w-setup",
  "current_ticket": null,
  "completed_agents": [],
  "phase_history": []
}
EOF

if bash "$SCAFFOLD" "$ALT_RUN_DIR" "$ALT_SESSION" "$ALT_SLUG" "$ALT_TICKET" >/dev/null 2>&1; then
  ok "AC-3: scaffold-ticket succeeds from claude-infra cwd (regression)"
else
  ko "AC-3: scaffold-ticket from claude-infra cwd" "exit non-zero"
fi

# Verify the regression case advanced state correctly
ALT_PHASE=$(jq -r '.current_phase' "$ALT_STATE_FILE")
if [ "$ALT_PHASE" = "t-cto" ]; then
  ok "AC-3: regression state file advanced"
else
  ko "AC-3: regression state advance" "phase=$ALT_PHASE"
fi

# Clean up REPO_ROOT-side state file
rm -f "$ALT_STATE_FILE"
rm -rf "$SCRATCH_2"

# ---------------------------------------------------------------------------
# AC #5 (auxiliary): existing test-orchestrated-mode.sh / test-wave-manifest.sh
# pass green. Caller verifies manually; this test focuses on portability.
# ---------------------------------------------------------------------------
echo "Note: existing tests (test-orchestrated-mode.sh, test-wave-manifest.sh) verified separately."

# ---------------------------------------------------------------------------
# Negative case: missing manifest exits 2 with clear diagnostic
# ---------------------------------------------------------------------------
echo "Negative: missing manifest -> exit 2"

NEG_SCRATCH=$(mktemp -d)
cd "$NEG_SCRATCH"
mkdir -p .claude/agent-memory/active-runs
cat > .claude/agent-memory/active-runs/neg-session-neg-slug.json <<EOF
{"session_id": "neg-session", "slug": "neg-slug", "current_phase": "w-setup"}
EOF

NEG_OUT=$(bash "$SCAFFOLD" "docs/step-5-pipeline/no-such" "neg-session" "neg-slug" "T-NEG" 2>&1)
NEG_EXIT=$?
if [ "$NEG_EXIT" = "2" ] && echo "$NEG_OUT" | grep -q "manifest not found"; then
  ok "Negative: missing manifest -> exit 2 with clear diagnostic"
else
  ko "Negative: missing manifest" "exit=$NEG_EXIT output=$NEG_OUT"
fi

cd /
rm -rf "$NEG_SCRATCH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================="
echo "Total: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  echo -e "$FAIL_DETAIL"
  exit 1
fi
exit 0
