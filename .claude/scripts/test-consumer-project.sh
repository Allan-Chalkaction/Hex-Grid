#!/usr/bin/env bash
# Consumer-project fixture driver (E1).
#
# Tests claude-infra helpers from a consumer-project-shaped cwd. Catches
# the defect class surfaced in 2026-05-07 MC Wave 1 findings + 2026-05-08
# enhancement plan §3.1: helpers that work from claude-infra cwd but
# fail when invoked from a consumer-project cwd.
#
# Self-contained: copies the fixture to a mktemp scratch dir each run.
#
# Usage: bash core/scripts/test-consumer-project.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(dirname "$REPO_ROOT")"
FIXTURE_SRC="${REPO_ROOT}/core/scripts/fixtures/consumer-project"

if [ ! -d "$FIXTURE_SRC" ]; then
  echo "ERROR: fixture not found at $FIXTURE_SRC" >&2
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
# Helper: copy fixture to a scratch dir and cd in. Sets SCRATCH.
# ---------------------------------------------------------------------------
spin_up_scratch() {
  SCRATCH=$(mktemp -d)
  # Copy fixture content (including dotfiles).
  cp -R "$FIXTURE_SRC"/. "$SCRATCH/"
  # Create the .claude/agent-memory/active-runs/ subdir on the fly. It's
  # NOT staged in the fixture because block-source-edits.sh (active-runs guard) blocks
  # any path matching .claude/agent-memory/active-runs/ (including
  # .gitkeep markers). The test creates state files here at runtime.
  mkdir -p "$SCRATCH/.claude/agent-memory/active-runs"
  cd "$SCRATCH"
}

cleanup_scratch() {
  cd /
  rm -rf "$SCRATCH"
}

# ---------------------------------------------------------------------------
# Test 1 — wave-scaffold-ticket.sh from consumer-project cwd (A1 regression)
# ---------------------------------------------------------------------------
echo "Test 1: wave-scaffold-ticket.sh from consumer-project cwd"
spin_up_scratch

# Sanity: scratch should NOT contain core/
if [ -d "core" ]; then
  ko "Test 1 sanity" "scratch contains core/ unexpectedly"
fi

SLUG="fixture"
SESSION_ID="test-consumer-$(date +%s)"
RUN_DIR="docs/step-5-pipeline/2026-05-08/2200-WAVE-${SLUG}"

# Create a fresh state file (consumer-cwd-relative path)
cat > ".claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json" <<EOF
{
  "ticket_key": null,
  "run_dir": "${RUN_DIR}",
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

if bash "${REPO_ROOT}/core/scripts/wave-scaffold-ticket.sh" \
       "$RUN_DIR" "$SESSION_ID" "$SLUG" "T-001" >/dev/null 2>err1; then
  ok "Test 1: wave-scaffold-ticket succeeds from consumer cwd"
else
  ko "Test 1" "exit non-zero ($(cat err1))"
fi

# Verify ticket scaffolded
TICKET_DIR=$(find "${RUN_DIR}/tickets" -maxdepth 1 -type d -name "*-T-001" | head -1)
if [ -n "$TICKET_DIR" ] && [ -f "${TICKET_DIR}/prompt.md" ]; then
  ok "Test 1: ticket dir + prompt.md created"
else
  ko "Test 1" "ticket dir/prompt.md missing"
fi

# Verify state advanced
PHASE=$(jq -r '.current_phase' ".claude/agent-memory/active-runs/${SESSION_ID}-${SLUG}.json")
if [ "$PHASE" = "t-cto" ]; then
  ok "Test 1: state file advanced to t-cto"
else
  ko "Test 1" "state phase=$PHASE expected t-cto"
fi

cleanup_scratch

# ---------------------------------------------------------------------------
# Test 2 — wave-manifest.py validate from consumer-project cwd
# ---------------------------------------------------------------------------
echo "Test 2: wave-manifest.py validate from consumer-project cwd"
spin_up_scratch

if python3 "${REPO_ROOT}/core/scripts/wave-manifest.py" validate \
     "docs/step-5-pipeline/2026-05-08/2200-WAVE-fixture/wave-manifest.json" 2>err2 >/dev/null; then
  ok "Test 2: fixture manifest validates clean"
else
  ko "Test 2" "manifest validate failed: $(cat err2)"
fi

cleanup_scratch

# ---------------------------------------------------------------------------
# Test 3 — wave-manifest.py next-ready-ticket from consumer-project cwd
# ---------------------------------------------------------------------------
echo "Test 3: wave-manifest.py next-ready-ticket from consumer-project cwd"
spin_up_scratch

NEXT=$(python3 "${REPO_ROOT}/core/scripts/wave-manifest.py" next-ready-ticket \
       "docs/step-5-pipeline/2026-05-08/2200-WAVE-fixture/wave-manifest.json" 2>err3)
if [ "$NEXT" = "T-001" ]; then
  ok "Test 3: next-ready returns T-001 (lowest-key dependency-free ticket)"
else
  ko "Test 3" "expected T-001 got '$NEXT' (stderr: $(cat err3))"
fi

cleanup_scratch

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
