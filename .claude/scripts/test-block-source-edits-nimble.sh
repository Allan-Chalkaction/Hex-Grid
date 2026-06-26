#!/usr/bin/env bash
# OQ-2 Part 2 — synthetic test for block-source-edits.sh against the
# post-mode-aware-refactor Nimble shape.
#
# What's under test:
#   The hook MUST block source-file edits in the main repo when:
#     - bypass-active.json is absent, AND
#     - the active nimble run has NO plan-steps.json (the post-Step-4
#       Nimble shape — no decompose phase, no plan-steps emission), AND
#     - the file path is not in any allow-list / worktree-equivalent path.
#
# Why this matters: stripping plan-steps.json from Nimble removes the
# "active plan step" fallback that previously authorized implementer
# edits. The structural guarantee that source files don't get written
# directly in the main repo collapses to (a) bypass mode short-circuit,
# and (b) worktree isolation. This test verifies (a) is the only opener
# when no worktree is in play.
#
# Cases:
#   1. bypass off + nimble execute + no plan-steps + main-repo *.ts edit
#      → expect exit 2 + BLOCKED stderr (the post-Step-4 nimble guard).
#   2. bypass on + same setup → expect exit 0 (positive control).
#   3. bypass off + plan-steps.json with active step → expect exit 0
#      (legacy fallback regression check; unreachable in post-Step-4
#      nimble flow, but the hook still implements it).
#   4. bypass off + no plan-steps + /tmp/* path → expect exit 0
#      (the hook treats /tmp as worktree-equivalent).
#
# Run from anywhere in the repo:
#   bash core/scripts/test-block-source-edits-nimble.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="${REPO_ROOT}/hooks/block-source-edits.sh"

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

cd "$WORK" || { echo "FAIL: could not cd to $WORK"; exit 1; }

mkdir -p .claude/agent-memory/active-runs
RUN_DIR="docs/step-5-pipeline/2026-05-04/2100-NIMBLE-bse-test"
mkdir -p "${RUN_DIR}/findings"

SESSION_ID="bse-test-sess-1"
STATE_FILE=".claude/agent-memory/active-runs/${SESSION_ID}-bse-test.json"

cat > "$STATE_FILE" <<JSON
{
  "session_id": "${SESSION_ID}",
  "ticket_key": "TEST-001",
  "slug": "bse-test",
  "run_dir": "${RUN_DIR}",
  "track": "nimble",
  "mode": "nimble",
  "current_phase": "execute",
  "initiated_by": "nimble",
  "completed_agents": [
    {"type": "Explore", "at": "2026-05-04T21:00:00Z"},
    {"type": "pm-spec",  "at": "2026-05-04T21:01:00Z"}
  ],
  "phase_history": [{"phase": "execute", "entered_at": "2026-05-04T21:02:00Z"}]
}
JSON

# Precondition: no plan-steps.json in run_dir (post-Step-4 invariant).
if [ -f "${RUN_DIR}/plan-steps.json" ]; then
  echo "FAIL: precondition — plan-steps.json must not exist"; exit 1
fi
# Precondition: no bypass file in $WORK (session-scoped — ADR-052).
if [ -f ".claude/agent-memory/bypass-active-${SESSION_ID}.json" ]; then
  echo "FAIL: precondition — bypass-active-${SESSION_ID}.json must not exist in WORK"; exit 1
fi

# Synthetic stdin emulating an Edit on an absolute *.ts path that is NOT
# inside the hook's allow-list and NOT inside any worktree-equivalent
# directory. Use a synthetic absolute path under /Users/... that contains
# none of the special substrings (no /tmp/, no /var/folders/, no /docs/,
# no /.claude/, no /worktrees/).
TARGET="/Users/synthetic-tester/some-project/src/foo.ts"
INPUT=$(/usr/bin/jq -n \
  --arg fp "$TARGET" \
  --arg sid "$SESSION_ID" \
  '{tool_name: "Edit", session_id: $sid, tool_input: {file_path: $fp}}')

PASS=0
FAIL=0

# ---- Case 1: bypass off, no plan-steps → BLOCK ----
ACTUAL_STDERR=$(echo "$INPUT" | bash "$HOOK" 2>&1 >/dev/null)
ACTUAL_EXIT=$?

if [ "$ACTUAL_EXIT" -eq 2 ]; then
  echo "PASS: case-1 (bypass off, no plan-steps, main-repo *.ts) → exit 2"
  PASS=$((PASS+1))
else
  echo "FAIL: case-1 expected exit 2, got $ACTUAL_EXIT"
  FAIL=$((FAIL+1))
fi

if echo "$ACTUAL_STDERR" | /usr/bin/grep -q '^BLOCKED:'; then
  echo "PASS: case-1 stderr starts with 'BLOCKED:'"
  PASS=$((PASS+1))
else
  echo "FAIL: case-1 stderr did not start with 'BLOCKED:'"
  echo "  first line: $(echo "$ACTUAL_STDERR" | /usr/bin/head -1)"
  FAIL=$((FAIL+1))
fi

# ---- Case 2: bypass on → ALLOW (positive control) ----
# ADR-052: session-scoped flag keyed to the stdin session_id ($SESSION_ID).
cat > ".claude/agent-memory/bypass-active-${SESSION_ID}.json" <<EOF
{"enabled": true, "activated_at": "2026-05-04T21:00:00Z", "session_id": "${SESSION_ID}", "reason": "test"}
EOF

echo "$INPUT" | bash "$HOOK" 2>/dev/null
ACTUAL_EXIT=$?

if [ "$ACTUAL_EXIT" -eq 0 ]; then
  echo "PASS: case-2 (bypass on) → exit 0"
  PASS=$((PASS+1))
else
  echo "FAIL: case-2 expected exit 0, got $ACTUAL_EXIT"
  FAIL=$((FAIL+1))
fi

rm ".claude/agent-memory/bypass-active-${SESSION_ID}.json"

# ---- Case 3: bypass off, plan-steps.json with active step → ALLOW
#       (legacy fallback regression check) ----
cat > "${RUN_DIR}/plan-steps.json" <<JSON
{"steps": [{"step_number": 1, "status": "active"}]}
JSON

echo "$INPUT" | bash "$HOOK" 2>/dev/null
ACTUAL_EXIT=$?

if [ "$ACTUAL_EXIT" -eq 0 ]; then
  echo "PASS: case-3 (bypass off, plan-steps active) → exit 0 (legacy fallback intact)"
  PASS=$((PASS+1))
else
  echo "FAIL: case-3 expected exit 0, got $ACTUAL_EXIT"
  FAIL=$((FAIL+1))
fi

rm "${RUN_DIR}/plan-steps.json"

# ---- Case 4: bypass off, no plan-steps, /tmp/ path → ALLOW
#       (worktree-equivalent path) ----
TARGET_TMP="/tmp/scratch-test/src/foo.ts"
INPUT_TMP=$(/usr/bin/jq -n \
  --arg fp "$TARGET_TMP" \
  --arg sid "$SESSION_ID" \
  '{tool_name: "Edit", session_id: $sid, tool_input: {file_path: $fp}}')

echo "$INPUT_TMP" | bash "$HOOK" 2>/dev/null
ACTUAL_EXIT=$?

if [ "$ACTUAL_EXIT" -eq 0 ]; then
  echo "PASS: case-4 (/tmp path) → exit 0 (worktree-equivalent)"
  PASS=$((PASS+1))
else
  echo "FAIL: case-4 expected exit 0, got $ACTUAL_EXIT"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
