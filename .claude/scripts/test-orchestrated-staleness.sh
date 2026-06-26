#!/usr/bin/env bash
# V2-W1-T03 synthetic test — verifies the per-ticket pre-dispatch staleness
# check refuses a ticket branch whose base is behind the wave branch.
#
# This test mirrors core/scripts/test-worktree-staleness.sh (INFRA-019 for
# pipeline-mode wave merges) but adapted to orchestrated mode's per-ticket
# branching model:
#
#   - Wave branch is the running integration branch for a /orchestrated run.
#   - Ticket branches are created off the wave branch in t-implement. They are
#     git-ref PEERS of the wave branch, separated by `--` (double dash) — the
#     intuitive nested form `feature/wave-{slug}/T-NNN` cannot be used because
#     git-refs cannot have a leaf and a directory at the same path. See ADR-008
#     branching subsection for the rationale.
#   - During implementation (or between t-implement and t-commit) the wave
#     branch may advance via concurrent runs or in-session squash-merges.
#   - If the ticket branch is then merged to the wave branch without rebase,
#     intervening wave-branch commits are silently reverse-deltaed.
#
# The check runs in TWO places in t-implement.md:
#   - Pre-dispatch (Step 3): refuse if the ticket branch is already stale
#     relative to the wave branch (e.g., resume scenario with stale base).
#   - Post-merge (Step 7): refuse if the wave branch advanced WHILE the
#     implementer was running.
#
# This test exercises the same logic at both gates. It runs in a disposable
# temp git repo to avoid touching the real repo's branches or worktrees.
#
# Usage:
#   bash core/scripts/test-orchestrated-staleness.sh
#
# Exit codes:
#   0 — all assertions PASS (staleness refused on stale base; permitted on fresh)
#   1 — at least one assertion FAILED

set -euo pipefail

# ----------------------------------------------------------------------------
# Setup: disposable temp repo
# ----------------------------------------------------------------------------

TEMP_DIR=$(mktemp -d -t orchestrated-staleness-test-XXXXXX)
trap 'rm -rf "${TEMP_DIR}"' EXIT

cd "${TEMP_DIR}"
git init --quiet -b main
git config user.email "test@orchestrated-staleness.local"
git config user.name "V2-W1-T03 Test"

# Initial commit on main
echo "main initial" > main-file.txt
git add main-file.txt
git commit --quiet -m "initial: main bootstrap"
MAIN_BASE=$(git rev-parse HEAD)

# ----------------------------------------------------------------------------
# Create the wave branch (analogous to /orchestrated's feature/wave-{slug})
# and a wave-base commit on top.
# ----------------------------------------------------------------------------

WAVE_BRANCH="feature/wave-test-slug"
git checkout --quiet -b "${WAVE_BRANCH}" "${MAIN_BASE}"
echo "wave preflight artifact" > wave-preflight.txt
git add wave-preflight.txt
git commit --quiet -m "wave: w-setup artifact (commit W0)"
WAVE_W0=$(git rev-parse HEAD)

# ----------------------------------------------------------------------------
# POSITIVE CONTROL: stale ticket branch
# ----------------------------------------------------------------------------
# Create T-001's ticket branch off W0. Then advance the wave branch via a
# squash-merge of a hypothetical T-000 ticket. T-001's branch is now 1 commit
# behind the wave branch.
# ----------------------------------------------------------------------------

TICKET_001_BRANCH="${WAVE_BRANCH}--T-001-stale"
git checkout --quiet -b "${TICKET_001_BRANCH}" "${WAVE_W0}"
echo "T-001 implementer change" > t-001-output.txt
git add t-001-output.txt
git commit --quiet -m "T-001: implementer work on stale base"

# Wave branch advances (simulate T-000 squash-merge, or concurrent activity).
git checkout --quiet "${WAVE_BRANCH}"
echo "T-000 squash-merged content" > t-000-output.txt
git add t-000-output.txt
git commit --quiet -m "wave: T-000 squash-merge (commit W1)"
WAVE_W1=$(git rev-parse HEAD)

# Now run the staleness check (the same logic in t-implement.md Step 3 and
# Step 7).
STALE_COUNT_001=$(git log --oneline "${TICKET_001_BRANCH}..${WAVE_BRANCH}" 2>/dev/null | wc -l | tr -d ' ')

if [ "${STALE_COUNT_001:-0}" -le 0 ]; then
  echo "FAIL: positive control — staleness check did NOT refuse stale ticket branch."
  echo "       ticket branch: ${TICKET_001_BRANCH} (rooted at ${WAVE_W0})"
  echo "       wave branch:   ${WAVE_BRANCH} (now at ${WAVE_W1})"
  echo "       expected stale_count >= 1; actual: ${STALE_COUNT_001}"
  exit 1
fi

# ----------------------------------------------------------------------------
# NEGATIVE CONTROL: fresh ticket branch
# ----------------------------------------------------------------------------
# Create T-002's ticket branch off the CURRENT wave branch HEAD (W1). This is
# the in-session-fresh case — no concurrent wave activity has occurred since
# branch creation. Staleness check must NOT flag this.
# ----------------------------------------------------------------------------

TICKET_002_BRANCH="${WAVE_BRANCH}--T-002-fresh"
git checkout --quiet -b "${TICKET_002_BRANCH}" "${WAVE_W1}"
echo "T-002 implementer change" > t-002-output.txt
git add t-002-output.txt
git commit --quiet -m "T-002: implementer work on fresh base"
git checkout --quiet "${WAVE_BRANCH}"

STALE_COUNT_002=$(git log --oneline "${TICKET_002_BRANCH}..${WAVE_BRANCH}" 2>/dev/null | wc -l | tr -d ' ')

if [ "${STALE_COUNT_002:-0}" -gt 0 ]; then
  echo "FAIL: negative control — staleness check incorrectly flagged fresh ticket branch."
  echo "       ticket branch: ${TICKET_002_BRANCH} (rooted at ${WAVE_W1})"
  echo "       wave branch:   ${WAVE_BRANCH} (also at ${WAVE_W1})"
  echo "       expected stale_count == 0; actual: ${STALE_COUNT_002}"
  exit 1
fi

# ----------------------------------------------------------------------------
# DESTRUCTIVE-OUTCOME CHARACTERIZATION
# ----------------------------------------------------------------------------
# Document what the check prevents — actually merge the stale T-001 branch
# into the wave branch without rebase, and observe whether the intervening
# T-000 content survives. (This run only happens for documentation; the
# staleness check would have refused this merge in production.)
# ----------------------------------------------------------------------------

git checkout --quiet "${WAVE_BRANCH}"
git merge --no-edit --no-ff "${TICKET_001_BRANCH}" >/dev/null 2>&1 || true

if [ -f t-000-output.txt ]; then
  destructive_outcome="(intervening T-000 file survived this synthetic merge — the work was disjoint; the staleness check is still the right defense for non-disjoint cases)"
else
  destructive_outcome="(intervening T-000 work was reverse-deltaed by the merge — exactly the destructive failure mode the staleness check prevents)"
fi

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------

echo "PASS: V2-W1-T03 orchestrated-mode staleness check correctly distinguishes"
echo "      stale vs fresh ticket branches."
echo "      positive control (stale ticket branch): refused"
echo "        ticket: ${TICKET_001_BRANCH} (base: ${WAVE_W0})"
echo "        wave:   ${WAVE_BRANCH} (head: ${WAVE_W1})"
echo "        stale_count: ${STALE_COUNT_001} (expected >= 1)"
echo "      negative control (fresh ticket branch): permitted"
echo "        ticket: ${TICKET_002_BRANCH} (base: ${WAVE_W1})"
echo "        wave:   ${WAVE_BRANCH} (head: ${WAVE_W1})"
echo "        stale_count: ${STALE_COUNT_002} (expected == 0)"
echo "      destructive-outcome characterization: ${destructive_outcome}"
exit 0
