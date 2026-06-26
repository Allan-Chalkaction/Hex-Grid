#!/usr/bin/env bash
# Synthetic test harness for ADR-105 — default autonomous disposition.
# This is a CONTRACT-DRIFT guard: the behavior is BEHAVIORAL (the orchestrator reasons from the rule, no
# hook enforces it), so the test asserts the binding rule text + the ADR encode the contract — and that the
# retired halt-gating language is gone, so the rule cannot silently revert to halt-on-judgment.
# Exit 0 = all PASS; exit 1 = at least one FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RULES="${REPO_ROOT}/core/rules/rules-orchestrated-mode.md"
ADR="${REPO_ROOT}/docs/decisions/ADR-105-default-autonomous-disposition.md"
CONV="${REPO_ROOT}/docs/conventions/halt-fires-criteria.md"
NIMBLE_RULES="${REPO_ROOT}/core/rules/rules-nimble-routing.md"
for f in "$RULES" "$ADR" "$CONV" "$NIMBLE_RULES"; do
  [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }
done

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

# has <file> <label> <regex...> : PASS iff every regex matches the file
has() { local f="$1" label="$2"; shift 2; local r; for r in "$@"; do
  grep -qiE "$r" "$f" || { ko "$label" "missing /$r/ in $(basename "$f")"; return; }; done; ok "$label"; }
# absent <file> <label> <regex> : PASS iff regex does NOT match (drift guard)
absent() { grep -qiE "$3" "$1" && ko "$2" "stale text /$3/ still present in $(basename "$1")" || ok "$2"; }

echo "ADR-105 default-autonomous-disposition contract:"

# --- AC1: judgment-class auto-disposes + logs + continues (the new default) ---
has "$RULES" "AC1 judgment-class -> auto-dispose + log + continue" \
  "judgment-class" "auto-dispose" "continue"

# --- AC2: execution-class block is the SOLE engine halt ---
has "$RULES" "AC2 execution-class block is the one hard stop" \
  "execution-class" "one hard stop|sole|only mid-run halt" "implementer-blocked"

# --- AC3: planner is the inverse (collaborative) default, by NOT routing the flipped branch ---
has "$RULES" "AC3 planner inverse / collaborative default" \
  "planner is the inverse" "collaborative" "collaboration is the planner default" "does NOT route through"

# --- AC4: shared-state floor preserved but does NOT halt (queue + continue) ---
has "$RULES" "AC4 shared-state floor: queued, not a halt" \
  "shared-state floor" "queue" "does NOT halt|not a halt"

# --- AC5: the decision log + non-blocking end-of-run summary convention ---
has "$RULES" "AC5 decision-log convention + end-of-run summary" \
  "autonomous-decisions-log\.md" "non-blocking consolidated summary" "remediate-if-wrong"

# --- AC6: the ADR-036 escalation-set branch is explicitly flipped (not surfaced-and-halted) ---
has "$RULES" "AC6 ADR-036 escalation branch flipped to disposition" \
  "escalation-set branch is flipped|escalation set is .*disposed" "NOT[[:space:]]+surfaced-and-halted|no longer gates"

# --- AC7: DRIFT GUARD — the retired halt-gating language must be gone ---
absent "$RULES" "AC7a drift: 'halts iff one of the five criteria' removed" \
  "halts iff one of the five criteria above is met"
absent "$RULES" "AC7b drift: 'perform exactly ONE batched surface, END THE TURN' removed" \
  "perform exactly ONE batched surface\*\*, END THE TURN"
absent "$RULES" "AC7c drift: 'crit-1/2/3 .* manual-review halt' removed" \
  "crit-1/2/3.*manual-review halt"

# --- AC8: ADR-105 exists, Accepted, and records the four amendments ---
has "$ADR" "AC8 ADR-105 Accepted + amends 018/029/014/036" \
  "Status:\*\*[[:space:]]*Accepted" "Amends:" "ADR-018" "ADR-029" "ADR-014" "ADR-036"

# --- AC9: ADR-105 names the judgment-vs-execution seam + the two backstops ---
has "$ADR" "AC9 ADR-105 seam + backstops (shared-state floor + decision log)" \
  "judgment-class" "execution-class" "shared-state floor" "decision log"

# --- AC10: the source-of-truth convention doc is IN SYNC (CR-001 — drift is a declared CI failure) ---
has "$CONV" "AC10 halt-fires-criteria.md amended for ADR-105 (rule<->doc sync)" \
  "AMENDED by ADR-105" "execution-class block" "no longer halt"
absent "$CONV" "AC10b drift: convention doc 'halts .* if and only if one of the five' removed" \
  "halts to the operator if and only if one of the five named criteria"

# --- AC11: nimble/chain inherit the disposition default (CR-001 — scope reach to ALL named paths) ---
has "$NIMBLE_RULES" "AC11 nimble routing encodes the ADR-105 disposition default" \
  "ADR-105" "autonomous-decisions-log\.md" "execution-class block"
# the engine scripts' surface comment must reflect dispose-not-halt for judgment-class
has "${REPO_ROOT}/core/scripts/workflows/nimble.js" "AC11b nimble.js surface comment cites ADR-105 disposition" \
  "ADR-105"
has "${REPO_ROOT}/core/scripts/workflows/chain.js" "AC11c chain.js surface comment cites ADR-105 disposition" \
  "ADR-105"

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "test-default-autonomous-disposition: ${PASS}/${PASS} PASS"
  exit 0
else
  echo "test-default-autonomous-disposition: ${PASS} PASS, ${FAIL} FAIL"
  echo -e "FAILURES:${FAIL_DETAIL}"
  exit 1
fi
