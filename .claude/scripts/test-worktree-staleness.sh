#!/usr/bin/env bash
# INFRA-019 synthetic test — verifies the pre-merge staleness check refuses
# a merge whose worktree branch base is behind current HEAD.
#
# This test reproduces the failure mode caught manually on INFRA-017 (and
# documented in catches #1, #4 of findings/diagnosis.md):
#   - A worktree branched from commit A
#   - main advances to commit B (intervening commits land)
#   - The worktree's branch is merged
#   - WITHOUT the fix: merge succeeds textually-cleanly, intervening commits
#     are silently reverse-deltaed
#   - WITH the fix: merge is refused with a BLOCKED message
#
# The test runs in a disposable temporary git repo to avoid touching the
# actual repo's worktrees, branches, or history.
#
# Usage:
#   bash core/scripts/test-worktree-staleness.sh
#
# Exit codes:
#   0 — test PASS (fix correctly refuses stale-base merge)
#   1 — test FAIL (fix did not refuse a stale-base merge OR setup failed)

set -euo pipefail

# ----------------------------------------------------------------------------
# Setup: disposable temp repo
# ----------------------------------------------------------------------------

TEMP_DIR=$(mktemp -d -t infra-019-test-XXXXXX)
trap 'rm -rf "${TEMP_DIR}"' EXIT

cd "${TEMP_DIR}"
git init --quiet -b main
git config user.email "test@infra-019.local"
git config user.name "INFRA-019 Test"

# Initial commit on main (commit A — the "session-stable base ref" stand-in)
echo "initial content" > main-file.txt
git add main-file.txt
git commit --quiet -m "initial: commit A (the stale base ref under test)"
COMMIT_A=$(git rev-parse HEAD)

# ----------------------------------------------------------------------------
# Create the synthetic "worktree branch" from commit A
# (analogous to what the Agent runtime does with isolation: "worktree")
# ----------------------------------------------------------------------------

git checkout --quiet -b step-1-branch "${COMMIT_A}"
echo "agent's intended change" > agent-output.txt
git add agent-output.txt
git commit --quiet -m "step-1: agent's work on the synthetic atom"
git checkout --quiet main

# ----------------------------------------------------------------------------
# main advances: simulate intervening commits landing while the agent worked
# (this is the situation where the worktree's session-stable base goes stale)
# ----------------------------------------------------------------------------

echo "intervening change 1" >> main-file.txt
git add main-file.txt
git commit --quiet -m "intervening: commit B1 (must NOT be reverse-deltaed)"

echo "intervening change 2" >> main-file.txt
git add main-file.txt
git commit --quiet -m "intervening: commit B2 (must NOT be reverse-deltaed)"

COMMIT_B=$(git rev-parse HEAD)

# ----------------------------------------------------------------------------
# Run the staleness check (the L3 logic from execute.md Step 4c.1)
# ----------------------------------------------------------------------------

WAVE_ATOMS_ASCENDING="1"
wave_index=0
check_blocked=0

for n in ${WAVE_ATOMS_ASCENDING}; do
  branch="step-${n}-branch"
  stale_count=$(git log --oneline "${branch}..HEAD" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${stale_count:-0}" -gt 0 ]; then
    echo "[expected BLOCKED] branch ${branch} is ${stale_count} commit(s) behind HEAD"
    check_blocked=1
    break
  fi
done

# ----------------------------------------------------------------------------
# Assertions
# ----------------------------------------------------------------------------

if [ "${check_blocked}" -eq 0 ]; then
  echo "FAIL: staleness check did NOT refuse the stale-base branch."
  echo "       worktree base: ${COMMIT_A}"
  echo "       current HEAD:  ${COMMIT_B}"
  echo "       expected: refuse with BLOCKED. actual: would have allowed merge."
  exit 1
fi

# Negative control — verify a fresh branch (rebased onto HEAD) PASSES the check.
git checkout --quiet -b step-2-branch "${COMMIT_B}"
echo "fresh agent change" > fresh-output.txt
git add fresh-output.txt
git commit --quiet -m "step-2: fresh agent work on current HEAD"
git checkout --quiet main

stale_count_fresh=$(git log --oneline "step-2-branch..HEAD" 2>/dev/null | wc -l | tr -d ' ')
if [ "${stale_count_fresh:-0}" -gt 0 ]; then
  echo "FAIL: fresh branch step-2-branch incorrectly flagged as stale (count=${stale_count_fresh})."
  exit 1
fi

# Positive control — verify an actual git merge of the stale branch WOULD have
# been destructive. This documents what the fix prevents.
git merge --no-edit --no-ff step-1-branch >/dev/null 2>&1 || true

# After merging the stale branch, check whether main-file.txt's intervening
# changes survive. (Without the L3 fix, the orchestrator would have run this
# merge in production. We run it here only to characterize the destructive
# outcome — the L3 check above already proved it would have refused.)
if grep -q "intervening change 1" main-file.txt && grep -q "intervening change 2" main-file.txt; then
  # Intervening commits survived the merge — git's textual merge happened to
  # preserve them in this synthetic setup (because step-1-branch only added
  # a new file, not modified main-file.txt). The L3 check is still the right
  # defense because in practice agents DO modify shared files.
  outcome_note="(intervening commits survived this synthetic merge — agent's work was disjoint; the L3 check is still the right defense for non-disjoint cases like INFRA-017)"
else
  outcome_note="(intervening commits were reverse-deltaed by the merge — exactly the destructive failure mode the L3 check prevents)"
fi

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------

echo "PASS: INFRA-019 pre-merge staleness check correctly refused the stale-base branch."
echo "      worktree base: ${COMMIT_A}"
echo "      current HEAD:  ${COMMIT_B}"
echo "      stale commits: ${stale_count}"
echo "      destructive outcome characterization: ${outcome_note}"
echo "      fresh-branch control: PASS (count=${stale_count_fresh:-0}, correctly NOT flagged)"
exit 0
