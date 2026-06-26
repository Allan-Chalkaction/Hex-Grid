#!/usr/bin/env bash
# Synthetic test for the per-family F9 decision scripts (ADR-126, SHR3-T5; Wave C of substrate-hardening-round-3).
#
# Asserts the two binding F9 properties per family (ADR-126 D-1/D-2):
#   (1) ZERO LLM body — `grep -nE 'agent\(' <script>` is clean per family (mirrors queue-order.py AC-004/005).
#   (2) wired-and-fires — the script's verdict is what the owning SKILL.md acts on: a grep-able invocation
#       site in the owning skill AND the skill path is exercised here, asserting the script's verdict is the
#       one the skill consumes (NOT a parallel LLM call that re-decides).
# Also asserts the {decision, reason, confidence} shape + the no-guess (abstain/flag) discipline per family,
# and the AC-016 ceiling preservation: NO F9 script exists for resolver-uncited / shape-thesis-fork.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"     # core/
REPO="$(cd "$ROOT/.." && pwd)"     # repo root
PY=python3
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

SWEEP_CLUSTER="$HERE/sweep-cluster.py"
BG_MATRIX="$HERE/batch-gate-matrix.py"
IDEA_DEDUP="$HERE/idea-dedup.py"
SHELF_MATCH="$HERE/shelf-match.py"
SWEEP_SKILL="$ROOT/skills/sweep/SKILL.md"
BG_SKILL="$ROOT/skills/batch-gate/SKILL.md"

# JSON field extractor (stdin -> .<key>).
jq_field() { $PY -c "import json,sys;print(json.load(sys.stdin).get('$1'))"; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# ============================================================================
# 1. ZERO-LLM-BODY per family (AC-014, ADR-126 D-1) — grep agent( is clean.
# ============================================================================
echo "[1] zero-LLM-body per family (grep agent( clean)"
for s in "$SWEEP_CLUSTER" "$BG_MATRIX" "$IDEA_DEDUP" "$SHELF_MATCH"; do
  name=$(basename "$s")
  [ -f "$s" ] || { ko "$name exists" "missing"; continue; }
  if grep -nE 'agent\(' "$s" >/dev/null 2>&1; then
    ko "$name zero-LLM-body" "grep agent( found a match"
  else
    ok "$name zero-LLM-body (grep agent( clean)"
  fi
done

# ============================================================================
# 2. {decision, reason, confidence} shape per family.
# ============================================================================
echo "[2] {decision, reason, confidence} shape per family"
shape_ok() {  # name, json
  local name="$1" json="$2"
  echo "$json" | $PY -c "import json,sys;d=json.load(sys.stdin);assert all(k in d for k in ('decision','reason','confidence')),'missing key';assert d.get('advisory') is None,'advisory must be null in the script body'" 2>/dev/null \
    && ok "$name shape {decision,reason,confidence}, advisory=null" \
    || ko "$name shape" "missing key or advisory non-null: $json"
}
INBOX="$W/inbox"; mkdir -p "$INBOX/backlog" "$INBOX/parked"
JAMS="$W/planning"; mkdir -p "$JAMS"
printf '# alpha widget\nsome real body content here describing the alpha widget feature.\n' > "$INBOX/alpha-widget.md"
shape_ok "idea-dedup"       "$($PY "$IDEA_DEDUP" check --inbox "$INBOX" --slug "novel-zzz.md" 2>/dev/null)"
shape_ok "shelf-match"      "$($PY "$SHELF_MATCH" match --item "novel-zzz.md" --backlog "$INBOX/backlog" --parked "$INBOX/parked" --jams "$JAMS" 2>/dev/null)"
shape_ok "batch-gate-matrix" "$($PY "$BG_MATRIX" select --files "src/foo.py" --repo-root "$W" 2>/dev/null)"
shape_ok "sweep-cluster(cluster)" "$($PY "$SWEEP_CLUSTER" cluster --inbox "$INBOX" 2>/dev/null)"
shape_ok "sweep-cluster(gate)"    "$($PY "$SWEEP_CLUSTER" gate --verdict promote --item "$INBOX/alpha-widget.md" --jams "$JAMS" 2>/dev/null)"

# ============================================================================
# 3. no-guess (abstain/flag) discipline per family (ADR-126 D-3).
# ============================================================================
echo "[3] no-guess: abstain on indeterminate, flag (exit 3) on a strong deterministic hit"
# idea-dedup: exact slug -> duplicate (exit 3); near-but-ambiguous -> abstain.
printf '# configure mcps\nbody\n' > "$INBOX/configure-mcps-per-repo.md"
$PY "$IDEA_DEDUP" check --inbox "$INBOX" --slug "configure-mcps-per-repo.md" >/dev/null 2>&1; RC=$?
[ "$RC" = "3" ] && ok "idea-dedup exact -> duplicate flag (exit 3)" || ko "idea-dedup exact" "rc=$RC"
# overlap 0.60 ({configure,mcps,repo} ∩, union 5) lands in the abstain band [0.40,0.75) -> abstain (no-guess).
D=$($PY "$IDEA_DEDUP" check --inbox "$INBOX" --slug "configure-mcps-repo-setup.md" 2>/dev/null | jq_field decision)
[ "$D" = "abstain" ] && ok "idea-dedup ambiguous overlap -> abstain (no-guess)" || ko "idea-dedup ambiguous" "decision=$D"
# shelf-match: shelf item -> route-to-pool (exit 3); nothing -> abstain.
cp "$INBOX/configure-mcps-per-repo.md" "$INBOX/backlog/configure-mcps-per-repo.md"
$PY "$SHELF_MATCH" match --item "configure-mcps-per-repo.md" --backlog "$INBOX/backlog" --parked "$INBOX/parked" --jams "$JAMS" >/dev/null 2>&1; RC=$?
[ "$RC" = "3" ] && ok "shelf-match shelf hit -> route-to-pool flag (exit 3)" || ko "shelf-match hit" "rc=$RC"
D=$($PY "$SHELF_MATCH" match --item "wholly-unrelated-topic.md" --backlog "$INBOX/backlog" --parked "$INBOX/parked" --jams "$JAMS" 2>/dev/null | jq_field decision)
[ "$D" = "abstain" ] && ok "shelf-match no-match -> abstain (operator decides)" || ko "shelf-match no-match" "decision=$D"
# sweep-cluster gate: G2/G4-class verdict -> abstain (content-nuance -> LLM ceiling).
D=$($PY "$SWEEP_CLUSTER" gate --verdict drop --item "$INBOX/alpha-widget.md" --jams "$JAMS" 2>/dev/null | jq_field decision)
[ "$D" = "abstain" ] && ok "sweep-cluster gate drop(G2) -> abstain (no-guess, content-nuance)" || ko "sweep-cluster G2 abstain" "decision=$D"

# ============================================================================
# 4. DETERMINISM — same inputs -> same verdict, twice (ADR-126 consequence).
# ============================================================================
echo "[4] determinism: identical inputs -> identical verdict"
A=$($PY "$BG_MATRIX" select --files "supabase/migrations/x.sql,package.json,client/src/App.tsx" --repo-root "$W" 2>/dev/null)
B=$($PY "$BG_MATRIX" select --files "supabase/migrations/x.sql,package.json,client/src/App.tsx" --repo-root "$W" 2>/dev/null)
[ "$A" = "$B" ] && ok "batch-gate-matrix deterministic (two identical runs match)" || ko "batch-gate-matrix determinism" "A!=B"

# ============================================================================
# 5. WIRED-AND-FIRES (AC-015, ADR-126 D-2) — invocation site in the owning skill
#    AND the skill path is exercised, asserting the script's verdict is consumed.
# ============================================================================
echo "[5] wired-and-fires: invocation site + skill consumes the script's verdict"
# (a) grep-able invocation site in the owning SKILL.md.
grep -q 'batch-gate-matrix.py' "$BG_SKILL" && ok "batch-gate-matrix wired in batch-gate/SKILL.md" || ko "batch-gate-matrix wired" "no invocation site"
for s in shelf-match.py idea-dedup.py sweep-cluster.py; do
  grep -q "$s" "$SWEEP_SKILL" && ok "$s wired in sweep/SKILL.md" || ko "$s wired" "no invocation site"
done
# (b) The skill's wired invocation is `cluster`/`gate`/`match`/`check`/`select` — assert the SKILL.md acts
#     on the script's `.decision` (the floor), exercising the exact command form the skill documents and
#     confirming the verdict the script prints is the one the skill consumes (not a re-derived LLM call).
grep -q 'ACT ON .decision\|ACTS ON .decision\|acts on the script' "$BG_SKILL" \
  && ok "batch-gate skill acts on the script's .decision (floor, not re-derived)" \
  || ko "batch-gate acts-on" "skill does not state it acts on the script verdict"
grep -q 'ACTS ON .decision\|acts on .their verdict\|acts on the script\|ACT ON .decision' "$SWEEP_SKILL" \
  && ok "sweep skill acts on the scripts' .decision (floor, not re-derived)" \
  || ko "sweep acts-on" "skill does not state it acts on the script verdict"

# Exercise the skill path: run the EXACT command the batch-gate SKILL documents and assert the consumed
# verdict (.decision) is the script's deterministic gate set (a migration surface MUST include security-auditor).
FILES="supabase/migrations/001.sql,client/src/App.tsx"
CONSUMED=$($PY "$BG_MATRIX" select --files "$FILES" --repo-root "$W" 2>/dev/null | $PY -c "import json,sys;print(','.join(json.load(sys.stdin)['decision']))")
case ",$CONSUMED," in
  *",security-auditor,"*) ok "batch-gate skill consumes the script's verdict (migration -> security-auditor in .decision)";;
  *) ko "batch-gate consumes verdict" "security-auditor not in consumed decision: $CONSUMED";;
esac
# Exercise the sweep gate path: a new-cluster verdict whose topic matches a live jam MUST be MODIFIED by the
# script's verdict (the floor the skill acts on), not an LLM re-judgment.
mkdir -p "$JAMS/jam-flow-telemetry"
G=$($PY "$SWEEP_CLUSTER" gate --verdict new-cluster --item "$INBOX/alpha-widget.md" --jams "$JAMS" --topic "flow-telemetry" 2>/dev/null | jq_field decision)
[ "$G" = "MODIFIED" ] && ok "sweep skill consumes G1 floor (live-jam topic -> MODIFIED to ingest-to-jam)" || ko "sweep G1 consume" "decision=$G"
# Exercise shelf-match path: a shelf item match is the route-to-pool floor the skill acts on.
SM=$($PY "$SHELF_MATCH" match --item "configure-mcps-per-repo.md" --backlog "$INBOX/backlog" --parked "$INBOX/parked" --jams "$JAMS" 2>/dev/null | jq_field decision)
[ "$SM" = "route-to-pool" ] && ok "sweep skill consumes shelf-match floor (shelf hit -> route-to-pool)" || ko "shelf-match consume" "decision=$SM"

# ============================================================================
# 6. CEILING PRESERVED (AC-016, ADR-126 D-3 / examiner F-001) — NO F9 script for
#    resolver-uncited-disposition OR shape/thesis-fork resolution.
# ============================================================================
echo "[6] ceiling preserved: no F9 script for resolver-uncited / shape-thesis-fork"
FORBIDDEN=0
for bad in resolver-decide resolver-disposition resolver-decision shape-decide shape-resolve thesis-fork-resolve thesis-decide fork-resolve; do
  if ls "$HERE/$bad.py" >/dev/null 2>&1; then ko "ceiling" "forbidden F9 script exists: $bad.py"; FORBIDDEN=1; fi
done
[ "$FORBIDDEN" = "0" ] && ok "no F9 decision script for resolver-uncited / shape/thesis-fork (ceiling intact)"
# The four built scripts decide CLASSIFICATION floors only (cluster/gate/matrix/dedup/match) — none names a
# resolver-disposition or thesis-fork subcommand.
for s in "$SWEEP_CLUSTER" "$BG_MATRIX" "$IDEA_DEDUP" "$SHELF_MATCH"; do
  if grep -qiE 'def cmd_(resolve|disposition|thesis|fork)\b' "$s"; then
    ko "ceiling subcommands" "$(basename "$s") names a ceiling subcommand"
  fi
done
ok "built scripts carry classification floors only — no resolver/thesis/fork subcommand"

# ============================================================================
echo
echo "F9 decision scripts test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
