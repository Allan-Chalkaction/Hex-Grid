#!/usr/bin/env bash
# test-sweep-cluster.sh — SHR4-E3 / AC-019: the ADDITIVE-ONLY `area:`-tag floor in sweep-cluster.py.
#
# sweep-cluster.py's `cluster` command is the DETERMINISTIC clustering floor (ADR-126): a union-find over a
# token-Jaccard graph where an edge exists when slug-token overlap >= CLUSTER_THRESHOLD (0.50), and
# borderline/singleton items ABSTAIN to the LLM convergence ceiling rather than guess. SHR4-E3 adds an
# `<area>-` slug-prefix edge that JOINS two items sharing a matching area — but ONLY as a POSITIVE, additive
# signal.
#
# THE LOAD-BEARING INVARIANT (the whole point of E3): a different/absent area must NEVER block, drop, veto,
# or AND-gate an otherwise-strong token-overlap edge. The token edge must still fire on its own. This test
# asserts that invariant literally — two items with strong token overlap but DIFFERENT area tags STILL land
# in the same cluster — so a regression that turns area into a gate/AND condition (breaking the
# abstain-to-ceiling discipline) is caught.
#
# CITES: ADR-126 (the determinism floor + abstain-to-ceiling discipline), SHR4-E3 / AC-019.
set -uo pipefail

PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
CLUSTER_PY="$REPO_ROOT/core/scripts/sweep-cluster.py"
[ -f "$CLUSTER_PY" ] || { echo "FATAL: sweep-cluster.py not found: $CLUSTER_PY"; exit 1; }

echo "== test-sweep-cluster.sh (SHR4-E3 / AC-019 — additive-only area floor) =="

# Are two named files in the SAME cluster group in the cluster JSON? (decision is [[file,...], ...])
same_cluster() {
  # args: <cluster-json> <fileA> <fileB>
  printf '%s' "$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
a, b = sys.argv[1], sys.argv[2]
for grp in d['decision']:
    if a in grp and b in grp:
        sys.exit(0)
sys.exit(1)
" "$2" "$3"
}

# -----------------------------------------------------------------------------------------------------------
# Assertion 1 (THE invariant — AC-019): a strong token-overlap edge SURVIVES an area-tag mismatch.
# Two items share most slug tokens (login-redirect-session-fix -> jaccard >= 0.50) but carry DIFFERENT area
# prefixes (auth- vs ui-). They MUST still land in the same cluster: the token edge fires on its own and the
# area mismatch does NOT drop/gate it. A regression that ANDs area into the edge condition would split them.
# -----------------------------------------------------------------------------------------------------------
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/inbox"
: > "$W/inbox/auth-login-redirect-session-fix.md"
: > "$W/inbox/ui-login-redirect-session-fix.md"
R=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
if same_cluster "$R" "auth-login-redirect-session-fix.md" "ui-login-redirect-session-fix.md"; then
  ok "strong token edge (jaccard >= 0.50) SURVIVES an area-tag mismatch (auth- vs ui-) — area never gates the token edge"
else
  ko "additive-only invariant" "different-area items with strong token overlap were split — area is acting as a gate/AND, not additive. JSON=$R"
fi

# -----------------------------------------------------------------------------------------------------------
# Assertion 2 (the additive DIRECTION): a SHARED area edge JOINS two items the token floor would abstain on.
# Same area prefix (auth-) but weak token overlap (jaccard < 0.50). The additive area edge must pull them
# into one cluster (proving area ADDS edges, the positive half of "additive-only").
# -----------------------------------------------------------------------------------------------------------
rm -f "$W/inbox/"*.md
: > "$W/inbox/auth-totally-different-thing.md"
: > "$W/inbox/auth-some-other-unrelated-matter.md"
R=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
if same_cluster "$R" "auth-totally-different-thing.md" "auth-some-other-unrelated-matter.md"; then
  ok "shared area edge JOINS two weak-token-overlap items (additive: area can ADD an edge the token floor abstained on)"
else
  ko "additive area edge" "same-area items were not joined — the area edge did not fire. JSON=$R"
fi

# -----------------------------------------------------------------------------------------------------------
# Assertion 3 (abstain-to-ceiling preserved): two UNRELATED items with DIFFERENT areas and weak token overlap
# still abstain (each stays its own singleton group) — area is not a blanket joiner; untagged/mismatched
# items behave exactly as before E3.
# -----------------------------------------------------------------------------------------------------------
rm -f "$W/inbox/"*.md
: > "$W/inbox/auth-token-refresh.md"
: > "$W/inbox/billing-invoice-export.md"
R=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
if same_cluster "$R" "auth-token-refresh.md" "billing-invoice-export.md"; then
  ko "abstain-to-ceiling preserved" "unrelated different-area items were wrongly joined. JSON=$R"
else
  ok "unrelated different-area items still abstain (each its own group) — abstain-to-ceiling discipline intact (ADR-126)"
fi

# -----------------------------------------------------------------------------------------------------------
# Assertion 4 (determinism): identical inputs -> identical groups (no randomness, no LLM in the floor).
# -----------------------------------------------------------------------------------------------------------
rm -f "$W/inbox/"*.md
: > "$W/inbox/auth-login-a.md"
: > "$W/inbox/auth-login-b.md"
: > "$W/inbox/ui-modal-c.md"
R1=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
R2=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
if [ "$R1" = "$R2" ]; then
  ok "area-augmented cluster floor is deterministic (identical inputs -> identical groups; no randomness/LLM)"
else
  ko "determinism" "R1=$R1 R2=$R2"
fi

echo
echo "=== Summary ==="
echo "sweep-cluster: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
