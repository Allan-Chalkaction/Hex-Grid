#!/usr/bin/env bash
# Wave-manifest helper synthetic test harness (V2-W1-T01).
# Self-contained, runs in a temp scratch dir so no real artifacts are touched.
# Mirrors the test-protocol-hook.sh / test-worktree-staleness.sh pattern.
#
# Coverage:
#   - All 11 acceptance criteria from v2 plan §3 V2-W1-T01 (parse, validate,
#     find-next-ready, atomicity, defaults, base-ref capture, setup.md
#     advancement, SKILL.md invocation, malformed-plan rejection).
#   - CR-001 regression: description block followed by lower-indent content.
#   - CR-002 regression: docs/step-3-specs/_wave-template.md round-trips correctly.
#   - CR-004 regression: validate() rejects empty description.
#   - SA-001 regression: parse_wave_plan rejects path-traversal slugs.
#   - SA-002 regression: next-ready-ticket exits 2 (not 1) on bad input.
#   - SA-003 regression: update-wave-field rejects non-allowlisted fields.
#
# Usage: bash core/scripts/test-wave-manifest.sh
# Exit 0 = all PASS; exit 1 = at least one FAIL.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(dirname "$REPO_ROOT")"
SCRIPT="${REPO_ROOT}/core/scripts/wave-manifest.py"
TEMPLATE="${REPO_ROOT}/docs/step-3-specs/_wave-template.md"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: wave-manifest.py not found at $SCRIPT" >&2
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

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT
cd "$SCRATCH"

# ---------------------------------------------------------------- AC #1
echo "AC #1: parse_wave_plan emits manifest dict for 3-ticket synthetic input"
mkdir -p run-ac1
cat > plan-ac1.md <<'EOF'
# Wave: ac1-synthetic
**Theme:** acceptance test
**Goal:** verify three-ticket parse

## Tickets

### T-001: First
- depends_on: []
- planned_files: [a.ts]
- gate_recommendations: [code-reviewer]
- description: |
    First ticket.

### T-002: Second
- depends_on: [T-001]
- planned_files: [b.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Second ticket depends on first.

### T-003: Third
- depends_on: [T-001]
- planned_files: [c.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Third ticket also depends on first.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac1.md run-ac1/wave-manifest.json 2>err1; then
  if jq -e '.tickets | length == 3' run-ac1/wave-manifest.json > /dev/null \
     && jq -e '.tickets[0].key == "T-001" and .tickets[1].depends_on == ["T-001"] and .tickets[2].depends_on == ["T-001"]' run-ac1/wave-manifest.json > /dev/null; then
    ok "3-ticket synthetic parses with correct schema"
  else
    ko "3-ticket synthetic parse" "schema fields incorrect"
  fi
else
  ko "3-ticket synthetic parse" "exit non-zero: $(cat err1)"
fi

# ---------------------------------------------------------------- AC #2
echo "AC #2: cyclic depends_on raises clear error"
cat > plan-ac2.md <<'EOF'
# Wave: ac2-cycle
## Tickets
### T-001: A
- depends_on: [T-002]
- planned_files: [a.ts]
- description: |
    cycle a.
### T-002: B
- depends_on: [T-001]
- planned_files: [b.ts]
- description: |
    cycle b.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac2.md /tmp/ac2.json 2>err2; then
  ko "cycle rejection" "exit zero on cyclic input"
else
  if grep -qiE "cycle|cyclic" err2; then ok "cycle rejected with clear error"
  else ko "cycle rejection" "stderr did not mention cycle: $(cat err2)"; fi
fi

# ---------------------------------------------------------------- AC #3
echo "AC #3: self-reference raises clear error"
cat > plan-ac3.md <<'EOF'
# Wave: ac3-self
## Tickets
### T-001: A
- depends_on: [T-001]
- planned_files: [a.ts]
- description: |
    self-ref test.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac3.md /tmp/ac3.json 2>err3; then
  ko "self-reference rejection" "exit zero on self-ref"
else
  if grep -qiE "self-reference|own key" err3; then ok "self-reference rejected with clear error"
  else ko "self-reference rejection" "stderr: $(cat err3)"; fi
fi

# ---------------------------------------------------------------- AC #4
echo "AC #4: orphan reference raises clear error"
cat > plan-ac4.md <<'EOF'
# Wave: ac4-orphan
## Tickets
### T-001: A
- depends_on: [T-999]
- planned_files: [a.ts]
- description: |
    orphan dep.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac4.md /tmp/ac4.json 2>err4; then
  ko "orphan rejection" "exit zero on orphan"
else
  if grep -qiE "unknown ticket|orphan|T-999" err4; then ok "orphan reference rejected with clear error"
  else ko "orphan rejection" "stderr: $(cat err4)"; fi
fi

# ---------------------------------------------------------------- AC #5
echo "AC #5: find_next_ready_ticket cascade"
NEXT=$(python3 "$SCRIPT" next-ready-ticket run-ac1/wave-manifest.json)
if [ "$NEXT" = "T-001" ]; then ok "next-ready returns T-001 when all pending"; else ko "next-ready#a" "expected T-001 got '$NEXT'"; fi
python3 "$SCRIPT" update-ticket-status run-ac1/wave-manifest.json T-001 complete >/dev/null 2>err5a
NEXT=$(python3 "$SCRIPT" next-ready-ticket run-ac1/wave-manifest.json)
if [ "$NEXT" = "T-002" ]; then ok "next-ready returns T-002 (sorted) after T-001 complete"; else ko "next-ready#b" "expected T-002 got '$NEXT'"; fi
python3 "$SCRIPT" update-ticket-status run-ac1/wave-manifest.json T-002 complete >/dev/null 2>err5b
python3 "$SCRIPT" update-ticket-status run-ac1/wave-manifest.json T-003 complete >/dev/null 2>err5c
NEXT=$(python3 "$SCRIPT" next-ready-ticket run-ac1/wave-manifest.json)
if [ -z "$NEXT" ]; then ok "next-ready returns empty when all complete"; else ko "next-ready#c" "expected empty got '$NEXT'"; fi

# ---------------------------------------------------------------- AC #6
echo "AC #6: update-ticket-status atomicity"
mkdir -p run-ac6
cp plan-ac1.md run-ac6/plan.md
python3 "$SCRIPT" write-from-plan run-ac6/plan.md run-ac6/wave-manifest.json
(
  for i in $(seq 1 50); do
    ( jq '.tickets[0].status' run-ac6/wave-manifest.json >> run-ac6/reads.log 2>>run-ac6/read-errors.log ) &
  done
  wait
) &
READERS_PID=$!
for i in $(seq 1 30); do
  STATUS=$([ $((i % 2)) -eq 0 ] && echo "in-progress" || echo "pending")
  python3 "$SCRIPT" update-ticket-status run-ac6/wave-manifest.json T-001 "$STATUS" 2>>run-ac6/write-errors.log
done
wait $READERS_PID 2>/dev/null

if [ -s run-ac6/read-errors.log ]; then
  ko "atomicity" "$(wc -l < run-ac6/read-errors.log) parse errors during concurrent reads"
elif [ ! -s run-ac6/reads.log ]; then
  ko "atomicity" "no reads recorded (test setup bug)"
elif awk '!/"pending"|"in-progress"|"complete"/' run-ac6/reads.log | grep -q .; then
  ko "atomicity" "saw unexpected values"
else
  ok "atomic writes — no partial reads observed across $(wc -l < run-ac6/reads.log) reads"
fi

# ---------------------------------------------------------------- AC #7
echo "AC #7: manual_review_required defaults to true if absent"
cat > plan-ac7.md <<'EOF'
# Wave: ac7-default
## Tickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    No manual_review_required field — should default to true.
EOF
mkdir -p run-ac7
python3 "$SCRIPT" write-from-plan plan-ac7.md run-ac7/wave-manifest.json 2>err7
if jq -e '.tickets[0].manual_review_required == true' run-ac7/wave-manifest.json > /dev/null; then
  ok "manual_review_required defaults to true when absent"
else
  ko "default mrr" "value: $(jq '.tickets[0].manual_review_required' run-ac7/wave-manifest.json)"
fi

cat > plan-ac7b.md <<'EOF'
# Wave: ac7b-explicit
## Tickets
### T-001: A
- depends_on: []
- planned_files: [docs/a.md]
- manual_review_required: false
- description: |
    Explicit false should be preserved.
    (Uses docs/ path so the C7 carve-out validator accepts mrr=false.)
EOF
mkdir -p run-ac7b
python3 "$SCRIPT" write-from-plan plan-ac7b.md run-ac7b/wave-manifest.json 2>err7b
if jq -e '.tickets[0].manual_review_required == false' run-ac7b/wave-manifest.json > /dev/null; then
  ok "manual_review_required: false is preserved"
else
  ko "explicit mrr false" "value: $(jq '.tickets[0].manual_review_required' run-ac7b/wave-manifest.json)"
fi

# ---------------------------------------------------------------- AC #8
echo "AC #8: wave_base_ref capture (setup-phase emulation)"
HEAD_SHA=$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || echo "NO_GIT_HEAD")
if [ "$HEAD_SHA" != "NO_GIT_HEAD" ]; then
  python3 "$SCRIPT" update-wave-field run-ac6/wave-manifest.json wave_base_ref "\"${HEAD_SHA}\""
  GOT=$(jq -r '.wave_base_ref' run-ac6/wave-manifest.json)
  if [ "$GOT" = "$HEAD_SHA" ]; then ok "wave_base_ref captured matches git rev-parse HEAD"
  else ko "wave_base_ref capture" "expected $HEAD_SHA got $GOT"; fi
else
  echo "  SKIP: no git HEAD available"
fi

# ---------------------------------------------------------------- AC #9
# AC #9 RETIRED (T5b / ADR-040): the orchestrated `setup.md` phase doc was deleted with the rest of
# the orchestrated phase machine (orchestrated now runs on the Workflow engine). wave-manifest.py
# itself survives (roadmap-shared) and its functional coverage continues below.

# ---------------------------------------------------------------- AC #10
echo "AC #10: wave-manifest.py write-from-plan succeeds against hand-written plan"
# RETIRED (T5b / ADR-040): the "SKILL.md invokes write-from-plan" assertion checked the v1
# phase-machine orchestrated SKILL.md. The v2 orchestrated track runs on the Workflow engine
# and uses the thin manifest (run-manifest.py), not wave-manifest.py write-from-plan. The
# wave-manifest.py helper itself remains (pipeline-shared) and is still functionally asserted below.
mkdir -p run-ac10
cat > plan-ac10.md <<'EOF'
# Wave: ac10-real

## Tickets

### T-001: First
- depends_on: []
- planned_files: [src/foo.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Real-shaped plan body.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac10.md run-ac10/wave-manifest.json 2>err10; then
  if jq -e '.wave_slug == "ac10-real" and .wave_branch == "feature/wave-ac10-real" and .tickets[0].status == "pending"' run-ac10/wave-manifest.json > /dev/null; then
    ok "helper produces valid manifest from a real plan"
  else
    ko "helper manifest fields" "wrong"
  fi
else
  ko "helper invocation" "exit non-zero: $(cat err10)"
fi

# ---------------------------------------------------------------- AC #11
echo "AC #11: malformed plan fails loud"
cat > plan-ac11a.md <<'EOF'
this file has no Wave header
EOF
if python3 "$SCRIPT" write-from-plan plan-ac11a.md /tmp/ac11a.json 2>err11a; then
  ko "malformed: no header" "should have failed"
else
  if [ -s err11a ]; then ok "missing header → fails with stderr"; else ko "no header" "no stderr"; fi
fi

cat > plan-ac11b.md <<'EOF'
# Wave: ac11b
## NotTickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    no '## Tickets' section.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac11b.md /tmp/ac11b.json 2>err11b; then
  ko "malformed: no Tickets section" "should have failed"
else
  if grep -qi "Tickets" err11b; then ok "missing '## Tickets' → clear error"
  else ko "no Tickets" "stderr: $(cat err11b)"; fi
fi

cat > plan-ac11c.md <<'EOF'
# Wave: ac11c
## Tickets
### bad-key-shape: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    bad key.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac11c.md /tmp/ac11c.json 2>err11c; then
  ko "malformed: bad key shape" "should have failed"
else
  ok "bad ticket key shape → rejected"
fi

cat > plan-ac11d.md <<'EOF'
# Wave: ac11d
## Tickets
### T-001: Empty planned_files
- depends_on: []
- planned_files: []
- description: |
    planned_files empty should reject.
EOF
if python3 "$SCRIPT" write-from-plan plan-ac11d.md /tmp/ac11d.json 2>err11d; then
  ko "malformed: empty planned_files" "should have failed"
else
  if grep -qi "planned_files" err11d; then ok "empty planned_files → clear error"
  else ko "empty planned_files" "stderr: $(cat err11d)"; fi
fi

# ---------------------------------------------------------------- CR-001 regression
echo "CR-001 regression: description block followed by lower-indent content"

# Pattern 1: description block followed by HTML comment at col 0
cat > plan-cr001a.md <<'EOF'
# Wave: cr001a
## Tickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    Description body line one.
    Description body line two.

<!-- HTML comment at col 0 — used to silently truncate description -->
EOF
mkdir -p run-cr001a
python3 "$SCRIPT" write-from-plan plan-cr001a.md run-cr001a/wave-manifest.json 2>err_cr001a
DESC=$(jq -r '.tickets[0].description' run-cr001a/wave-manifest.json 2>/dev/null)
if [ -n "$DESC" ] && [ "$DESC" != "null" ] && echo "$DESC" | grep -q "Description body line one"; then
  ok "description preserved when followed by <!-- comment"
else
  ko "CR-001 HTML comment" "description was '$DESC'; stderr: $(cat err_cr001a)"
fi

# Pattern 2: description block followed by ## section
cat > plan-cr001b.md <<'EOF'
# Wave: cr001b
## Tickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    Description preserved across ## boundary.

## Notes
Some prose at col 0 — used to silently truncate.
EOF
mkdir -p run-cr001b
python3 "$SCRIPT" write-from-plan plan-cr001b.md run-cr001b/wave-manifest.json 2>err_cr001b
DESC=$(jq -r '.tickets[0].description' run-cr001b/wave-manifest.json 2>/dev/null)
if [ -n "$DESC" ] && [ "$DESC" != "null" ] && echo "$DESC" | grep -q "Description preserved across"; then
  ok "description preserved when followed by ## section"
else
  ko "CR-001 ## section" "description was '$DESC'; stderr: $(cat err_cr001b)"
fi

# Pattern 3: description block followed by next field at lower indent
# (This shape is unusual but possible when authors interleave fields after description.)
cat > plan-cr001c.md <<'EOF'
# Wave: cr001c
## Tickets
### T-001: A
- planned_files: [a.ts]
- description: |
    Description survives even when followed by a sibling field.
- gate_recommendations: [code-reviewer]
EOF
mkdir -p run-cr001c
python3 "$SCRIPT" write-from-plan plan-cr001c.md run-cr001c/wave-manifest.json 2>err_cr001c
DESC=$(jq -r '.tickets[0].description' run-cr001c/wave-manifest.json 2>/dev/null)
if [ -n "$DESC" ] && [ "$DESC" != "null" ] && echo "$DESC" | grep -q "Description survives"; then
  ok "description preserved when followed by sibling field at col 0"
else
  ko "CR-001 sibling field" "description was '$DESC'; stderr: $(cat err_cr001c)"
fi

# ---------------------------------------------------------------- CR-002 regression
echo "CR-002 regression: canonical _template.md round-trips with non-empty descriptions"
if [ -f "$TEMPLATE" ]; then
  mkdir -p run-cr002
  if python3 "$SCRIPT" write-from-plan "$TEMPLATE" run-cr002/wave-manifest.json 2>err_cr002; then
    T1_DESC=$(jq -r '.tickets[0].description' run-cr002/wave-manifest.json)
    T2_DESC=$(jq -r '.tickets[1].description' run-cr002/wave-manifest.json)
    if [ -n "$T1_DESC" ] && [ "$T1_DESC" != "null" ] \
       && [ -n "$T2_DESC" ] && [ "$T2_DESC" != "null" ]; then
      ok "_template.md parses with both T-001 and T-002 descriptions present"
    else
      ko "CR-002 template" "T1 desc='$T1_DESC' T2 desc='$T2_DESC'"
    fi
  else
    ko "CR-002 template" "_template.md failed to parse: $(cat err_cr002)"
  fi
else
  echo "  SKIP: $TEMPLATE not present"
fi

# ---------------------------------------------------------------- CR-004 regression
echo "CR-004 regression: validate() rejects empty description"
mkdir -p run-cr004
cp run-ac6/wave-manifest.json run-cr004/wave-manifest.json
jq '.tickets[0].description = ""' run-cr004/wave-manifest.json > run-cr004/empty-desc.json
if python3 "$SCRIPT" validate run-cr004/empty-desc.json 2>err_cr004; then
  ko "CR-004 empty desc" "validate accepted empty description"
else
  if grep -qi "description must be non-empty" err_cr004; then
    ok "validate rejects empty description"
  else
    ko "CR-004 message" "stderr: $(cat err_cr004)"
  fi
fi

# ---------------------------------------------------------------- SA-001 regression
echo "SA-001 regression: parse_wave_plan rejects path-traversal slugs"
for BAD_SLUG in "../../escape" "foo/bar" "foo.bar" "Foo" ".hidden" "-leading-hyphen" "with space"; do
  cat > plan-sa001.md <<EOF
# Wave: ${BAD_SLUG}
## Tickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    Bad slug test for: ${BAD_SLUG}
EOF
  if python3 "$SCRIPT" write-from-plan plan-sa001.md /tmp/sa001.json 2>err_sa001; then
    ko "SA-001 bad slug" "accepted slug '${BAD_SLUG}'"
  else
    if grep -qi "slug" err_sa001 || grep -qE "^wave plan slug" err_sa001; then
      ok "rejected bad slug '${BAD_SLUG}'"
    else
      ko "SA-001 message" "rejected '${BAD_SLUG}' but message wrong: $(cat err_sa001)"
    fi
  fi
done

# Positive control: well-formed slug accepted
cat > plan-sa001-good.md <<'EOF'
# Wave: good-slug-123
## Tickets
### T-001: A
- depends_on: []
- planned_files: [a.ts]
- description: |
    Good slug control.
EOF
mkdir -p run-sa001-good
if python3 "$SCRIPT" write-from-plan plan-sa001-good.md run-sa001-good/wave-manifest.json 2>err_sa001g; then
  ok "well-formed slug 'good-slug-123' accepted (positive control)"
else
  ko "SA-001 positive control" "rejected legit slug: $(cat err_sa001g)"
fi

# ---------------------------------------------------------------- SA-002 regression
echo "SA-002 regression: next-ready-ticket exits 2 + clean message on bad input"
python3 "$SCRIPT" next-ready-ticket /nonexistent/path/manifest.json >/dev/null 2>err_sa002
EXIT=$?
if [ "$EXIT" = "2" ]; then
  if grep -qE "^wave-manifest: read error" err_sa002; then
    ok "next-ready-ticket on missing file: exit 2 + clean error message"
  else
    ko "SA-002 message" "exit 2 but message wrong: $(cat err_sa002)"
  fi
else
  ko "SA-002 exit code" "expected exit 2 got $EXIT — $(cat err_sa002)"
fi

# Malformed JSON
echo "{ this is not json" > run-sa001-good/garbage.json
python3 "$SCRIPT" next-ready-ticket run-sa001-good/garbage.json >/dev/null 2>err_sa002b
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qE "^wave-manifest: read error" err_sa002b; then
  ok "next-ready-ticket on malformed JSON: exit 2 + clean error message"
else
  ko "SA-002 malformed JSON" "exit=$EXIT stderr=$(cat err_sa002b)"
fi

# ---------------------------------------------------------------- SA-003 regression
echo "SA-003 regression: update-wave-field rejects non-allowlisted fields"
# wave_base_ref (allowed) — should succeed
python3 "$SCRIPT" update-wave-field run-sa001-good/wave-manifest.json wave_base_ref "\"deadbeef\"" 2>err_sa003a
if [ $? -eq 0 ]; then ok "update-wave-field accepts allowlisted field 'wave_base_ref'"
else ko "SA-003 allowed" "rejected wave_base_ref: $(cat err_sa003a)"; fi

# tickets (NOT allowed) — should fail
python3 "$SCRIPT" update-wave-field run-sa001-good/wave-manifest.json tickets "[]" 2>err_sa003b
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qi "allowlist" err_sa003b; then
  ok "update-wave-field rejects non-allowlisted field 'tickets'"
else
  ko "SA-003 disallowed tickets" "exit=$EXIT stderr=$(cat err_sa003b)"
fi

# wave_branch (NOT allowed; could mislead operations) — should fail
python3 "$SCRIPT" update-wave-field run-sa001-good/wave-manifest.json wave_branch "\"hijacked\"" 2>err_sa003c
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qi "allowlist" err_sa003c; then
  ok "update-wave-field rejects non-allowlisted field 'wave_branch'"
else
  ko "SA-003 disallowed wave_branch" "exit=$EXIT stderr=$(cat err_sa003c)"
fi

# ---------------------------------------------------------------- iter-2 residual fixes
echo "iter-2 residual: SA-002 UnicodeDecodeError handled in next-ready-ticket + validate"
# Binary file input — UnicodeDecodeError is a ValueError subclass; widened tuple.
printf '\xff\xfe\x00\x00 not utf8' > run-sa001-good/binary.bin
python3 "$SCRIPT" next-ready-ticket run-sa001-good/binary.bin >/dev/null 2>err_sa002_resid_a
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qE "^wave-manifest: read error" err_sa002_resid_a; then
  ok "next-ready-ticket on binary file: exit 2 + clean message (UnicodeDecodeError caught)"
else
  ko "SA-002 residual next-ready" "exit=$EXIT stderr=$(cat err_sa002_resid_a)"
fi

python3 "$SCRIPT" validate run-sa001-good/binary.bin >/dev/null 2>err_sa002_resid_b
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qE "^wave-manifest: read error" err_sa002_resid_b; then
  ok "validate on binary file: exit 2 + clean message (UnicodeDecodeError caught)"
else
  ko "SA-002 residual validate" "exit=$EXIT stderr=$(cat err_sa002_resid_b)"
fi

# RETIRED (T5b / ADR-040): the "SA-001 SKILL.md slug guard before mkdir" assertion checked the v1
# phase-machine orchestrated SKILL.md (which created `${RUN_DIR}/tickets` subfolders via Bash). The
# v2 orchestrated engine door does not create ticket subfolders (the workflow + thin manifest own the
# layout), so the guarded mkdir no longer exists. The SA-001 path-traversal protection itself is still
# asserted at the parse_wave_plan level (the "SA-001 regression" block above tests wave-manifest.py).

# ---------------------------------------------------------------- Bonus: validate subcommand
echo "Bonus: validate subcommand"
python3 "$SCRIPT" validate run-ac1/wave-manifest.json 2>val_err
if [ $? -eq 0 ]; then ok "validate exits 0 on clean manifest"
else ko "validate clean" "$(cat val_err)"; fi

jq '.tickets[0].depends_on = ["T-002"] | .tickets[1].depends_on = ["T-001"]' run-ac1/wave-manifest.json > run-ac1/cycled.json
if python3 "$SCRIPT" validate run-ac1/cycled.json 2>cycled_err; then
  ko "validate cycle" "exit zero on cycled manifest"
else
  if grep -qiE "cycle" cycled_err; then ok "validate detects injected cycle"
  else ko "validate cycle msg" "$(cat cycled_err)"; fi
fi

# ---------------------------------------------------------------- V2-W4-T01 regression
# end-of-wave-gates additions: find-tickets-for-file helper + "reverted" status.

echo "V2-W4-T01: find-tickets-for-file basic single-owner lookup"
mkdir -p run-w4t01
cat > plan-w4t01.md <<'EOF'
# Wave: w4-t01-synthetic
**Theme:** end-of-wave-gates lookup
**Goal:** verify file→ticket mapping

## Tickets

### T-001: Owner of foo
- depends_on: []
- planned_files: [src/foo.ts, src/bar.ts]
- gate_recommendations: [code-reviewer]
- description: |
    First ticket owns foo and bar.

### T-002: Owner of bar (overlap) and baz
- depends_on: [T-001]
- planned_files: [src/bar.ts, src/baz.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Second ticket co-owns bar and uniquely owns baz.

### T-003: Owner of qux
- depends_on: [T-001]
- planned_files: [src/qux.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Third ticket owns qux only.
EOF
python3 "$SCRIPT" write-from-plan plan-w4t01.md run-w4t01/wave-manifest.json 2>err_w4t01_setup
if [ $? -ne 0 ]; then
  ko "V2-W4-T01 setup" "write-from-plan failed: $(cat err_w4t01_setup)"
else
  # AC: file in exactly one ticket's planned_files returns that key.
  RESULT=$(python3 "$SCRIPT" find-tickets-for-file run-w4t01/wave-manifest.json src/foo.ts 2>err_w4t01_a)
  if [ "$RESULT" = "T-001" ]; then
    ok "find-tickets-for-file: src/foo.ts → T-001"
  else
    ko "find-tickets-for-file single owner" "expected 'T-001' got '$RESULT' (stderr: $(cat err_w4t01_a))"
  fi
fi

echo "V2-W4-T01: find-tickets-for-file multi-owner lookup (sorted ascending)"
RESULT=$(python3 "$SCRIPT" find-tickets-for-file run-w4t01/wave-manifest.json src/bar.ts 2>err_w4t01_b | tr '\n' ',' | sed 's/,$//')
if [ "$RESULT" = "T-001,T-002" ]; then
  ok "find-tickets-for-file: src/bar.ts → T-001,T-002 (sorted)"
else
  ko "find-tickets-for-file multi-owner" "expected 'T-001,T-002' got '$RESULT'"
fi

echo "V2-W4-T01: find-tickets-for-file unattributed file (not in any planned_files)"
RESULT=$(python3 "$SCRIPT" find-tickets-for-file run-w4t01/wave-manifest.json src/unknown.ts 2>err_w4t01_c)
EXIT=$?
if [ "$EXIT" = "0" ] && [ -z "$RESULT" ]; then
  ok "find-tickets-for-file: src/unknown.ts → empty (exit 0)"
else
  ko "find-tickets-for-file unattributed" "exit=$EXIT result='$RESULT' stderr=$(cat err_w4t01_c)"
fi

echo "V2-W4-T01: find-tickets-for-file on missing manifest exits 2 + clean error"
python3 "$SCRIPT" find-tickets-for-file /nonexistent/manifest.json src/foo.ts >out_w4t01_d 2>err_w4t01_d
EXIT=$?
if [ "$EXIT" = "2" ] && grep -qE "wave-manifest:.*read error" err_w4t01_d; then
  ok "find-tickets-for-file: missing manifest → exit 2 + clean error"
else
  ko "find-tickets-for-file missing manifest" "exit=$EXIT stderr=$(cat err_w4t01_d)"
fi

echo "V2-W4-T01: update-ticket-status accepts 'reverted' status"
python3 "$SCRIPT" update-ticket-status run-w4t01/wave-manifest.json T-001 reverted 2>err_w4t01_e
if [ $? -eq 0 ]; then
  STATUS=$(jq -r '.tickets[] | select(.key == "T-001") | .status' run-w4t01/wave-manifest.json)
  if [ "$STATUS" = "reverted" ]; then
    ok "update-ticket-status T-001 reverted: status persisted"
  else
    ko "reverted status persistence" "manifest still says status=$STATUS"
  fi
else
  ko "update-ticket-status reverted" "exit non-zero: $(cat err_w4t01_e)"
fi

echo "V2-W4-T01: update-ticket-status reverted with --field reverted_in_commit pass-through"
# Reset T-001 to complete first so we can re-revert it with the field
python3 "$SCRIPT" update-ticket-status run-w4t01/wave-manifest.json T-001 complete 2>/dev/null
python3 "$SCRIPT" update-ticket-status run-w4t01/wave-manifest.json T-001 reverted \
    --field reverted_in_commit='"abc123def456"' 2>err_w4t01_f
if [ $? -eq 0 ]; then
  REVSHA=$(jq -r '.tickets[] | select(.key == "T-001") | .reverted_in_commit' run-w4t01/wave-manifest.json)
  if [ "$REVSHA" = "abc123def456" ]; then
    ok "update-ticket-status reverted_in_commit field pass-through"
  else
    ko "reverted_in_commit field" "expected 'abc123def456' got '$REVSHA'"
  fi
else
  ko "update-ticket-status with --field" "exit non-zero: $(cat err_w4t01_f)"
fi

echo "V2-W4-T01 CR-002 iter-2: scan_downstream_impact excludes 'reverted' tickets"
# Build a manifest where T-001 is reverted and T-002 depends on the amended ticket T-003.
# scan_downstream_impact(T-003) should NOT include T-001 (reverted) but SHOULD include T-002.
mkdir -p run-w4t01-cr002
cat > plan-w4t01-cr002.md <<'EOF'
# Wave: w4-t01-cr002
**Theme:** scan_downstream_impact reverted exclusion
**Goal:** assert reverted tickets are not amendment-propagation candidates

## Tickets

### T-001: Revertee
- depends_on: []
- planned_files: [shared/file.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Will be reverted. Should NOT be a downstream candidate for any amendment.

### T-002: Pending downstream
- depends_on: [T-003]
- planned_files: [shared/file.ts]
- gate_recommendations: [code-reviewer]
- description: |
    Pending. Depends on T-003 (the amended source). SHOULD be a downstream candidate.

### T-003: Amendment source
- depends_on: []
- planned_files: [shared/file.ts]
- gate_recommendations: [code-reviewer]
- description: |
    The ticket whose scope shifts and triggers downstream-impact scan.
EOF
python3 "$SCRIPT" write-from-plan plan-w4t01-cr002.md run-w4t01-cr002/wave-manifest.json 2>err_cr002_setup
if [ $? -ne 0 ]; then
  ko "CR-002 setup" "write-from-plan failed: $(cat err_cr002_setup)"
else
  # Mark T-001 as reverted with a fake reverted_in_commit for realism.
  python3 "$SCRIPT" update-ticket-status run-w4t01-cr002/wave-manifest.json T-001 reverted \
      --field reverted_in_commit='"fake-revert-sha"' 2>/dev/null
  RESULT=$(python3 "$SCRIPT" scan-downstream-impact run-w4t01-cr002/wave-manifest.json T-003 2>err_cr002_a | tr '\n' ',' | sed 's/,$//')
  if [ "$RESULT" = "T-002" ]; then
    ok "scan_downstream_impact excludes reverted T-001; includes pending T-002"
  else
    ko "scan_downstream_impact reverted exclusion" "expected 'T-002' got '$RESULT' (stderr: $(cat err_cr002_a))"
  fi
fi

# Confirm original commit_sha is preserved (audit-trail invariant from B.1 #6).
# wave-manifest schema starts commit_sha at null; if a real wave had set it
# before revert, the orchestrator MUST NOT overwrite it. Set commit_sha first,
# then revert with reverted_in_commit, and assert both fields coexist.
python3 "$SCRIPT" update-ticket-status run-w4t01/wave-manifest.json T-002 complete \
    --field commit_sha='"original-sha-9999"' 2>/dev/null
python3 "$SCRIPT" update-ticket-status run-w4t01/wave-manifest.json T-002 reverted \
    --field reverted_in_commit='"revert-sha-1111"' 2>err_w4t01_g
ORIG=$(jq -r '.tickets[] | select(.key == "T-002") | .commit_sha' run-w4t01/wave-manifest.json)
REVT=$(jq -r '.tickets[] | select(.key == "T-002") | .reverted_in_commit' run-w4t01/wave-manifest.json)
if [ "$ORIG" = "original-sha-9999" ] && [ "$REVT" = "revert-sha-1111" ]; then
  ok "reverted ticket preserves original commit_sha + adds reverted_in_commit (B.1 #6)"
else
  ko "audit-trail preservation" "commit_sha=$ORIG reverted_in_commit=$REVT"
fi

# ---------------------------------------------------------------- A3: find-stuck-tickets
echo ""
echo "A3 #1: find-stuck-tickets — detects in-progress with null run-dir"
mkdir -p run-a3
cat > run-a3/wave-manifest.json <<'EOF'
{
  "wave_slug": "a3-test",
  "wave_branch": "feature/wave-a3-test",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "stuck null run-dir", "description": "x", "planned_files": [], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-a3-test--T-001", "status": "in-progress", "ticket_run_dir": null}
  ]
}
EOF
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3/wave-manifest.json 2>err_a3_1 | head -1)
if echo "$RESULT" | grep -q "^T-001	ticket_run_dir empty"; then
  ok "A3 #1: stuck-detection — null ticket_run_dir surfaces"
else
  ko "A3 #1" "expected 'T-001 ticket_run_dir empty', got '$RESULT' (stderr: $(cat err_a3_1))"
fi

echo "A3 #2: find-stuck-tickets — detects in-progress with nonexistent dir"
mkdir -p run-a3-2
cat > run-a3-2/wave-manifest.json <<'EOF'
{
  "wave_slug": "a3-test-2",
  "wave_branch": "feature/wave-a3-test-2",
  "current_ticket": null,
  "tickets": [
    {"key": "T-002", "title": "stuck nonexistent", "description": "x", "planned_files": [], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-a3-test-2--T-002", "status": "in-progress", "ticket_run_dir": "no/such/dir"}
  ]
}
EOF
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3-2/wave-manifest.json 2>err_a3_2 | head -1)
if echo "$RESULT" | grep -q "^T-002	ticket_run_dir does not exist"; then
  ok "A3 #2: stuck-detection — nonexistent dir surfaces"
else
  ko "A3 #2" "expected 'T-002 ticket_run_dir does not exist', got '$RESULT' (stderr: $(cat err_a3_2))"
fi

echo "A3 #3: find-stuck-tickets — does NOT flag tickets with real findings"
mkdir -p run-a3-3
cat > run-a3-3/wave-manifest.json <<'EOF'
{
  "wave_slug": "a3-test-3",
  "wave_branch": "feature/wave-a3-test-3",
  "current_ticket": null,
  "tickets": [
    {"key": "T-003", "title": "real work", "description": "x", "planned_files": [], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-a3-test-3--T-003", "status": "in-progress", "ticket_run_dir": "run-a3-3/ticket-T-003"}
  ]
}
EOF
mkdir -p run-a3-3/ticket-T-003/findings
touch run-a3-3/ticket-T-003/findings/cto-evaluation.md
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3-3/wave-manifest.json 2>err_a3_3)
if [ -z "$RESULT" ]; then
  ok "A3 #3: stuck-detection — ticket with findings is NOT flagged"
else
  ko "A3 #3" "expected empty, got '$RESULT' (stderr: $(cat err_a3_3))"
fi

echo "A3 #4: find-stuck-tickets — does NOT flag pending tickets"
mkdir -p run-a3-4
cat > run-a3-4/wave-manifest.json <<'EOF'
{
  "wave_slug": "a3-test-4",
  "wave_branch": "feature/wave-a3-test-4",
  "current_ticket": null,
  "tickets": [
    {"key": "T-004", "title": "pending", "description": "x", "planned_files": [], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-a3-test-4--T-004", "status": "pending", "ticket_run_dir": null}
  ]
}
EOF
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3-4/wave-manifest.json 2>err_a3_4)
if [ -z "$RESULT" ]; then
  ok "A3 #4: stuck-detection — pending tickets are NOT flagged"
else
  ko "A3 #4" "expected empty, got '$RESULT' (stderr: $(cat err_a3_4))"
fi

echo "A3 #5: find-stuck-tickets — empty findings/ subdir surfaces"
mkdir -p run-a3-5
cat > run-a3-5/wave-manifest.json <<'EOF'
{
  "wave_slug": "a3-test-5",
  "wave_branch": "feature/wave-a3-test-5",
  "current_ticket": null,
  "tickets": [
    {"key": "T-005", "title": "stuck empty findings", "description": "x", "planned_files": [], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-a3-test-5--T-005", "status": "in-progress", "ticket_run_dir": "run-a3-5/ticket-T-005"}
  ]
}
EOF
mkdir -p run-a3-5/ticket-T-005/findings
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3-5/wave-manifest.json 2>err_a3_5 | head -1)
if echo "$RESULT" | grep -q "^T-005	findings/ empty"; then
  ok "A3 #5: stuck-detection — empty findings/ surfaces"
else
  ko "A3 #5" "expected 'T-005 findings/ empty', got '$RESULT' (stderr: $(cat err_a3_5))"
fi

echo "A3 #6: find-stuck-tickets — missing manifest exits 2"
RESULT=$(python3 "$SCRIPT" find-stuck-tickets run-a3-nope/wave-manifest.json 2>err_a3_6)
EXIT=$?
if [ "$EXIT" = "2" ]; then
  ok "A3 #6: stuck-detection — missing manifest exit 2 (defensive)"
else
  ko "A3 #6" "expected exit 2, got $EXIT (stderr: $(cat err_a3_6))"
fi

# ---------------------------------------------------------------- C7: ADR-013 carve-out widening
echo ""
echo "C7 #1: validate accepts manual_review_required=false on docs-only ticket"
mkdir -p run-c7-docs
cat > run-c7-docs/wave-manifest.json <<'EOF'
{
  "wave_slug": "c7-docs",
  "wave_branch": "feature/wave-c7-docs",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "docs", "description": "x", "planned_files": ["docs/foo.md", "README.md"], "gate_recommendations": [], "manual_review_required": false, "depends_on": [], "ticket_branch": "feature/wave-c7-docs--T-001", "status": "pending"}
  ]
}
EOF
if python3 "$SCRIPT" validate run-c7-docs/wave-manifest.json 2>err_c7_1 >/dev/null; then
  ok "C7 #1: docs-only ticket with mrr=false validates"
else
  ko "C7 #1" "validate failed: $(cat err_c7_1)"
fi

echo "C7 #2: validate accepts manual_review_required=false on test-only ticket"
mkdir -p run-c7-tests
cat > run-c7-tests/wave-manifest.json <<'EOF'
{
  "wave_slug": "c7-tests",
  "wave_branch": "feature/wave-c7-tests",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "tests", "description": "x", "planned_files": ["tests/foo.test.ts", "src/__tests__/bar.test.js"], "gate_recommendations": [], "manual_review_required": false, "depends_on": [], "ticket_branch": "feature/wave-c7-tests--T-001", "status": "pending"}
  ]
}
EOF
if python3 "$SCRIPT" validate run-c7-tests/wave-manifest.json 2>err_c7_2 >/dev/null; then
  ok "C7 #2: test-only ticket with mrr=false validates"
else
  ko "C7 #2" "validate failed: $(cat err_c7_2)"
fi

echo "C7 #3: validate accepts manual_review_required=false on config-only ticket"
mkdir -p run-c7-config
cat > run-c7-config/wave-manifest.json <<'EOF'
{
  "wave_slug": "c7-config",
  "wave_branch": "feature/wave-c7-config",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "config", "description": "x", "planned_files": ["tsconfig.json", ".prettierrc.json"], "gate_recommendations": [], "manual_review_required": false, "depends_on": [], "ticket_branch": "feature/wave-c7-config--T-001", "status": "pending"}
  ]
}
EOF
if python3 "$SCRIPT" validate run-c7-config/wave-manifest.json 2>err_c7_3 >/dev/null; then
  ok "C7 #3: config-only ticket with mrr=false validates"
else
  ko "C7 #3" "validate failed: $(cat err_c7_3)"
fi

echo "C7 #4: validate REJECTS manual_review_required=false with source file"
mkdir -p run-c7-mixed
cat > run-c7-mixed/wave-manifest.json <<'EOF'
{
  "wave_slug": "c7-mixed",
  "wave_branch": "feature/wave-c7-mixed",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "mixed", "description": "x", "planned_files": ["src/handler.ts", "tests/handler.test.ts"], "gate_recommendations": [], "manual_review_required": false, "depends_on": [], "ticket_branch": "feature/wave-c7-mixed--T-001", "status": "pending"}
  ]
}
EOF
if python3 "$SCRIPT" validate run-c7-mixed/wave-manifest.json 2>err_c7_4 >/dev/null; then
  ko "C7 #4" "validate accepted mixed ticket with mrr=false (should reject)"
else
  if grep -qiE "manual_review_required=false but planned_files contains|carve-out|ADR-013" err_c7_4; then
    ok "C7 #4: mixed ticket with mrr=false REJECTED with carve-out error"
  else
    ko "C7 #4" "validate failed but error didn't mention carve-out: $(cat err_c7_4)"
  fi
fi

echo "C7 #5: default mrr=true preserved (existing behavior)"
mkdir -p run-c7-default
cat > run-c7-default/wave-manifest.json <<'EOF'
{
  "wave_slug": "c7-default",
  "wave_branch": "feature/wave-c7-default",
  "current_ticket": null,
  "tickets": [
    {"key": "T-001", "title": "default", "description": "x", "planned_files": ["src/handler.ts"], "gate_recommendations": [], "manual_review_required": true, "depends_on": [], "ticket_branch": "feature/wave-c7-default--T-001", "status": "pending"}
  ]
}
EOF
if python3 "$SCRIPT" validate run-c7-default/wave-manifest.json 2>err_c7_5 >/dev/null; then
  ok "C7 #5: source-touching ticket with mrr=true validates (default preserved)"
else
  ko "C7 #5" "validate failed: $(cat err_c7_5)"
fi

# ---------------------------------------------------------------- A2: F-005a partition-files
echo ""
echo "A2 #1: partition-files separates lockfile cascade from chosen files"
mkdir -p run-a2-1
cat > run-a2-1/wave-manifest.json <<'EOF'
{
  "wave_slug": "a2-cascade-test",
  "wave_base_ref": null,
  "tickets": [
    {
      "key": "T-001",
      "summary": "ticket with lockfile cascade",
      "depends_on": [],
      "planned_files": ["packages/foo/package.json", "packages/foo/src/index.ts"],
      "ticket_run_dir": null,
      "ticket_branch": null,
      "status": "pending",
      "commit_sha": null
    }
  ]
}
EOF
# Files modified: planned files + lockfile cascade
RESULT=$(python3 "$SCRIPT" partition-files \
  --manifest-path run-a2-1/wave-manifest.json \
  --ticket-key T-001 \
  --file packages/foo/package.json \
  --file packages/foo/src/index.ts \
  --file pnpm-lock.yaml 2>err_a2_1)
EXPECTED_CHOSEN="packages/foo/package.json
packages/foo/src/index.ts"
EXPECTED_CASCADE="pnpm-lock.yaml"
ACTUAL_CHOSEN=$(echo "$RESULT" | sed -n '1,/^--$/{/^--$/!p;}')
ACTUAL_CASCADE=$(echo "$RESULT" | sed -n '/^--$/,$p' | sed '1d')
if [ "$ACTUAL_CHOSEN" = "$EXPECTED_CHOSEN" ] && [ "$ACTUAL_CASCADE" = "$EXPECTED_CASCADE" ]; then
  ok "A2 #1: lockfile cascade auto-classified when package.json is in planned_files"
else
  ko "A2 #1" "chosen=[$ACTUAL_CHOSEN] cascade=[$ACTUAL_CASCADE] (stderr: $(cat err_a2_1))"
fi

echo "A2 #2: lockfile NOT cascade when no corresponding manifest in planned_files"
mkdir -p run-a2-2
cat > run-a2-2/wave-manifest.json <<'EOF'
{
  "wave_slug": "a2-no-manifest",
  "wave_base_ref": null,
  "tickets": [
    {
      "key": "T-001",
      "summary": "ticket without package.json",
      "depends_on": [],
      "planned_files": ["src/foo.ts"],
      "ticket_run_dir": null,
      "ticket_branch": null,
      "status": "pending",
      "commit_sha": null
    }
  ]
}
EOF
# Files modified: planned + lockfile (but no package.json in planned).
# pnpm-lock.yaml should NOT be classified cascade — it goes to chosen.
RESULT=$(python3 "$SCRIPT" partition-files \
  --manifest-path run-a2-2/wave-manifest.json \
  --ticket-key T-001 \
  --file src/foo.ts \
  --file pnpm-lock.yaml 2>err_a2_2)
ACTUAL_CHOSEN=$(echo "$RESULT" | sed -n '1,/^--$/{/^--$/!p;}')
ACTUAL_CASCADE=$(echo "$RESULT" | sed -n '/^--$/,$p' | sed '1d')
EXPECTED_CHOSEN="pnpm-lock.yaml
src/foo.ts"
if [ "$ACTUAL_CHOSEN" = "$EXPECTED_CHOSEN" ] && [ -z "$ACTUAL_CASCADE" ]; then
  ok "A2 #2: lockfile NOT cascade without corresponding manifest"
else
  ko "A2 #2" "chosen=[$ACTUAL_CHOSEN] cascade=[$ACTUAL_CASCADE]"
fi

echo "A2 #3: --planned flag form (no manifest) works"
RESULT=$(python3 "$SCRIPT" partition-files \
  --planned packages/foo/package.json \
  --planned packages/foo/src/index.ts \
  --file packages/foo/package.json \
  --file packages/foo/src/index.ts \
  --file pnpm-lock.yaml 2>err_a2_3)
ACTUAL_CASCADE=$(echo "$RESULT" | sed -n '/^--$/,$p' | sed '1d')
if [ "$ACTUAL_CASCADE" = "pnpm-lock.yaml" ]; then
  ok "A2 #3: --planned flag form recognizes lockfile cascade"
else
  ko "A2 #3" "cascade=[$ACTUAL_CASCADE]"
fi

echo "A2 #4: --deletive-path classifies pre-computed deletive files as cascade"
RESULT=$(python3 "$SCRIPT" partition-files \
  --planned src/main.ts \
  --deletive-path src/legacy/old-symbol.ts \
  --deletive-path test/legacy.test.ts \
  --file src/main.ts \
  --file src/legacy/old-symbol.ts \
  --file test/legacy.test.ts 2>err_a2_4)
ACTUAL_CHOSEN=$(echo "$RESULT" | sed -n '1,/^--$/{/^--$/!p;}')
ACTUAL_CASCADE=$(echo "$RESULT" | sed -n '/^--$/,$p' | sed '1d')
EXPECTED_CASCADE="src/legacy/old-symbol.ts
test/legacy.test.ts"
if [ "$ACTUAL_CHOSEN" = "src/main.ts" ] && [ "$ACTUAL_CASCADE" = "$EXPECTED_CASCADE" ]; then
  ok "A2 #4: --deletive-path entries classified as cascade"
else
  ko "A2 #4" "chosen=[$ACTUAL_CHOSEN] cascade=[$ACTUAL_CASCADE]"
fi

echo "A2 #5: empty input returns empty partitions"
RESULT=$(python3 "$SCRIPT" partition-files \
  --planned src/foo.ts \
  --file "" 2>err_a2_5 || true)
# `--file ""` is a no-op (empty path filtered out); chosen + cascade both empty
if [ -z "$(echo "$RESULT" | sed -n '1,/^--$/{/^--$/!p;}')" ]; then
  ok "A2 #5: empty file list partitions cleanly"
else
  ko "A2 #5" "non-empty result for empty input"
fi

# ============================================================================
# D2 / ADR-015 — wave_protocol_version v1/v2 split + SURFACE_TYPE enum delta.
# ============================================================================

# ---------------------------------------------------------------- D2 #1
echo "D2 T_v2_a: v2 manifest with all required new fields validates"
mkdir -p run-d2-1
cat > plan-d2-1.md <<'EOF'
# Wave: d2-test-v2-clean
**Theme:** v2 happy path
**Goal:** validate accepts a clean v2 manifest
**Protocol version:** 2

## Tickets

### T-001: First ticket
- depends_on: []
- planned_files: [src/a.ts]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    First ticket.

### T-002: Second ticket
- depends_on: [T-001]
- planned_files: [src/b.ts]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Second ticket.
EOF
if python3 "$SCRIPT" write-from-plan plan-d2-1.md run-d2-1/wave-manifest.json 2>err_d2_1; then
  ok "D2 T_v2_a: write-from-plan accepts v2 plan"
  if python3 "$SCRIPT" validate run-d2-1/wave-manifest.json 2>err_d2_1_v; then
    ok "D2 T_v2_a: validate accepts v2 manifest"
  else
    ko "D2 T_v2_a (validate)" "$(cat err_d2_1_v)"
  fi
  PROTO=$(jq -r .wave_protocol_version run-d2-1/wave-manifest.json)
  CTO=$(jq -r .wave_cto_evaluation_path run-d2-1/wave-manifest.json)
  MWS=$(jq -r .max_wave_size run-d2-1/wave-manifest.json)
  T1_REC=$(jq -r '.tickets[0].wave_cto_recommendation' run-d2-1/wave-manifest.json)
  if [ "$PROTO" = "2" ] && [ "$CTO" = "null" ] && [ "$MWS" = "12" ] && [ "$T1_REC" = "null" ]; then
    ok "D2 T_v2_a: v2 fields initialized (proto=2, paths=null, max_wave_size=12, per-ticket=null)"
  else
    ko "D2 T_v2_a (field init)" "proto=$PROTO cto=$CTO mws=$MWS t1_rec=$T1_REC"
  fi
else
  ko "D2 T_v2_a" "$(cat err_d2_1)"
fi

# ---------------------------------------------------------------- D2 #2
echo "D2 T_v2_b: v2 manifest missing required field is rejected"
mkdir -p run-d2-2
cat > run-d2-2/wave-manifest.json <<'EOF'
{
  "wave_slug": "d2-test-missing-field",
  "wave_run_dir": "/tmp/x",
  "wave_branch": "feature/wave-d2-test-missing-field",
  "wave_base_ref": null,
  "ui_addendum_path": null,
  "current_ticket": null,
  "wave_protocol_version": 2,
  "wave_cto_evaluation_path": null,
  "wave_spec_path": null,
  "wave_cto_consensus_path": null,
  "wave_manifest_at_wave_start_snapshot_path": null,
  "tickets": [{
    "key": "T-001", "title": "x", "description": "x",
    "ticket_run_dir": null,
    "ticket_branch": "feature/wave-d2-test-missing-field--T-001",
    "depends_on": [], "planned_files": ["a"], "gate_recommendations": [],
    "manual_review_required": true, "status": "pending",
    "amendment_history": [], "amendment_proposal": null,
    "commit_sha": null, "created_at": "2026-05-10T00:00:00Z", "completed_at": null,
    "wave_cto_recommendation": null, "wave_cto_simplification": null,
    "wave_consensus_status": null
  }],
  "deferrals": [],
  "surface_log": ""
}
EOF
ERR=$(python3 "$SCRIPT" validate run-d2-2/wave-manifest.json 2>&1 || true)
if echo "$ERR" | grep -q "missing required field 'max_wave_size'"; then
  ok "D2 T_v2_b: missing max_wave_size flagged with clear error"
else
  ko "D2 T_v2_b" "expected 'missing required field max_wave_size', got: $ERR"
fi

# ---------------------------------------------------------------- D2 #3
echo "D2 T_v2_c: v2 manifest with len(tickets) > max_wave_size fails preflight"
mkdir -p run-d2-3
cat > plan-d2-3.md <<'EOF'
# Wave: d2-test-cap
**Theme:** Test max_wave_size cap
**Goal:** verify cap halts preflight
**Protocol version:** 2
**Max wave size:** 2

## Tickets

### T-001: A
- depends_on: []
- planned_files: [a]
- gate_recommendations: []
- manual_review_required: true
- description: |
    A.

### T-002: B
- depends_on: []
- planned_files: [b]
- gate_recommendations: []
- manual_review_required: true
- description: |
    B.

### T-003: C
- depends_on: []
- planned_files: [c]
- gate_recommendations: []
- manual_review_required: true
- description: |
    C.
EOF
ERR=$(python3 "$SCRIPT" write-from-plan plan-d2-3.md run-d2-3/wave-manifest.json 2>&1 || true)
if echo "$ERR" | grep -qE "max_wave_size=2|reduce ticket count"; then
  ok "D2 T_v2_c: cap violation rejected at write-from-plan with clear error"
else
  ko "D2 T_v2_c" "expected cap error, got: $ERR"
fi

# ---------------------------------------------------------------- D2 #4
echo "D2 T_v1_a: v1 plan (no Protocol version header) defaults to legacy + validates"
mkdir -p run-d2-4
cat > plan-d2-4.md <<'EOF'
# Wave: d2-test-v1-default
**Theme:** Legacy v1 default
**Goal:** verify v1 fall-through

## Tickets

### T-001: Legacy ticket
- depends_on: []
- planned_files: [src/legacy.ts]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Legacy ticket — no v2 fields expected.
EOF
if python3 "$SCRIPT" write-from-plan plan-d2-4.md run-d2-4/wave-manifest.json 2>err_d2_4; then
  if python3 "$SCRIPT" validate run-d2-4/wave-manifest.json 2>err_d2_4_v; then
    PROTO=$(jq -r '.wave_protocol_version // "<absent>"' run-d2-4/wave-manifest.json)
    HAS_V2=$(jq -r 'has("wave_cto_evaluation_path")' run-d2-4/wave-manifest.json)
    if [ "$PROTO" = "<absent>" ] && [ "$HAS_V2" = "false" ]; then
      ok "D2 T_v1_a: v1 manifest validates + does NOT carry v2 top-level fields"
    else
      ko "D2 T_v1_a (field absence)" "proto=$PROTO has_v2=$HAS_V2"
    fi
  else
    ko "D2 T_v1_a (validate)" "$(cat err_d2_4_v)"
  fi
else
  ko "D2 T_v1_a" "$(cat err_d2_4)"
fi

# ---------------------------------------------------------------- D2 #5
echo "D2 T_v1_b: v1 manifest with extra v2 field is tolerated (no error)"
mkdir -p run-d2-5
cat > run-d2-5/wave-manifest.json <<'EOF'
{
  "wave_slug": "d2-test-v1-extra",
  "wave_run_dir": "/tmp/x",
  "wave_branch": "feature/wave-d2-test-v1-extra",
  "wave_base_ref": null,
  "ui_addendum_path": null,
  "current_ticket": null,
  "wave_cto_evaluation_path": "/tmp/extra-v2-field-tolerated",
  "tickets": [{
    "key": "T-001", "title": "x", "description": "x",
    "ticket_run_dir": null,
    "ticket_branch": "feature/wave-d2-test-v1-extra--T-001",
    "depends_on": [], "planned_files": ["a"], "gate_recommendations": [],
    "manual_review_required": true, "status": "pending",
    "amendment_history": [], "amendment_proposal": null,
    "commit_sha": null, "created_at": "2026-05-10T00:00:00Z", "completed_at": null
  }],
  "deferrals": [],
  "surface_log": ""
}
EOF
if python3 "$SCRIPT" validate run-d2-5/wave-manifest.json 2>err_d2_5; then
  ok "D2 T_v1_b: v1 manifest with extra v2 field is tolerated"
else
  ko "D2 T_v1_b" "$(cat err_d2_5)"
fi

# ---------------------------------------------------------------- D2 #6
echo "D2 T_per_ticket_a: v2 ticket with wave_cto_recommendation=SIMPLIFY validates"
mkdir -p run-d2-6
cp run-d2-1/wave-manifest.json run-d2-6/wave-manifest.json
python3 -c '
import json, pathlib
p = pathlib.Path("run-d2-6/wave-manifest.json")
m = json.loads(p.read_text())
m["tickets"][0]["wave_cto_recommendation"] = "SIMPLIFY"
m["tickets"][0]["wave_cto_simplification"] = "Drop AC-005 (synchronous handler stub); not needed in v1."
p.write_text(json.dumps(m, indent=2))
'
if python3 "$SCRIPT" validate run-d2-6/wave-manifest.json 2>err_d2_6; then
  ok "D2 T_per_ticket_a: SIMPLIFY recommendation + simplification text validates"
else
  ko "D2 T_per_ticket_a" "$(cat err_d2_6)"
fi

# ---------------------------------------------------------------- D2 #7
echo "D2 T_per_ticket_b: v2 ticket with wave_cto_recommendation=INVALID is rejected"
mkdir -p run-d2-7
cp run-d2-1/wave-manifest.json run-d2-7/wave-manifest.json
python3 -c '
import json, pathlib
p = pathlib.Path("run-d2-7/wave-manifest.json")
m = json.loads(p.read_text())
m["tickets"][0]["wave_cto_recommendation"] = "INVALID-VERDICT"
p.write_text(json.dumps(m, indent=2))
'
ERR=$(python3 "$SCRIPT" validate run-d2-7/wave-manifest.json 2>&1 || true)
if echo "$ERR" | grep -qE "wave_cto_recommendation must be one of"; then
  ok "D2 T_per_ticket_b: invalid recommendation enum rejected"
else
  ko "D2 T_per_ticket_b" "expected enum-rejection, got: $ERR"
fi

# ---------------------------------------------------------------- D2 #8
# RETIRED (T5b / ADR-040): the SURFACE_TYPE enum lived in the orchestrated phase doc
# `wave-resume-context.md`, deleted with the rest of the orchestrated phase machine. The v2
# orchestrated engine computes the surface in orchestrated.js (criterionFindings + surfaceRequired)
# and is covered by test-orchestrated-engine.sh. wave-manifest.py coverage continues below.

# ---------------------------------------------------------------- ADR-017 #1
echo "ADR-017 T_nf_absent: new_files absent — parses + field absent on manifest"
mkdir -p run-adr017-1
cat > plan-adr017-1.md <<'EOF'
# Wave: adr017-absent
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts]
- description: |
    no new_files field.
EOF
if python3 "$SCRIPT" write-from-plan plan-adr017-1.md run-adr017-1/wave-manifest.json 2>err_adr017_1; then
  HAS_NF=$(jq -r '.tickets[0] | has("new_files")' run-adr017-1/wave-manifest.json)
  if [ "$HAS_NF" = "false" ]; then
    ok "ADR-017 T_nf_absent: manifest omits new_files when plan omits the field"
  else
    ko "ADR-017 T_nf_absent" "manifest has new_files=$(jq '.tickets[0].new_files' run-adr017-1/wave-manifest.json); expected absent"
  fi
else
  ko "ADR-017 T_nf_absent" "parse failed: $(cat err_adr017_1)"
fi

# ---------------------------------------------------------------- ADR-017 #2
echo "ADR-017 T_nf_empty: new_files: [] — parses + field is [] (distinct from absent)"
mkdir -p run-adr017-2
cat > plan-adr017-2.md <<'EOF'
# Wave: adr017-empty
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts]
- new_files: []
- description: |
    explicit empty new_files.
EOF
if python3 "$SCRIPT" write-from-plan plan-adr017-2.md run-adr017-2/wave-manifest.json 2>err_adr017_2; then
  HAS_NF=$(jq -r '.tickets[0] | has("new_files")' run-adr017-2/wave-manifest.json)
  LEN_NF=$(jq -r '.tickets[0].new_files | length' run-adr017-2/wave-manifest.json)
  if [ "$HAS_NF" = "true" ] && [ "$LEN_NF" = "0" ]; then
    ok "ADR-017 T_nf_empty: explicit empty distinct from absent"
  else
    ko "ADR-017 T_nf_empty" "has=$HAS_NF len=$LEN_NF; expected has=true len=0"
  fi
else
  ko "ADR-017 T_nf_empty" "parse failed: $(cat err_adr017_2)"
fi

# ---------------------------------------------------------------- ADR-017 #3
echo "ADR-017 T_nf_subset: valid subset — parses + manifest carries sorted array"
mkdir -p run-adr017-3
cat > plan-adr017-3.md <<'EOF'
# Wave: adr017-subset
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts, b.ts, c.ts]
- new_files: [a.ts, b.ts]
- description: |
    subset of planned_files.
EOF
if python3 "$SCRIPT" write-from-plan plan-adr017-3.md run-adr017-3/wave-manifest.json 2>err_adr017_3; then
  if jq -e '.tickets[0].new_files == ["a.ts", "b.ts"]' run-adr017-3/wave-manifest.json > /dev/null; then
    ok "ADR-017 T_nf_subset: subset declaration round-trips"
  else
    ko "ADR-017 T_nf_subset" "manifest new_files=$(jq '.tickets[0].new_files' run-adr017-3/wave-manifest.json)"
  fi
else
  ko "ADR-017 T_nf_subset" "parse failed: $(cat err_adr017_3)"
fi

# ---------------------------------------------------------------- ADR-017 #4
echo "ADR-017 T_nf_not_subset: validate rejects new_files entry not in planned_files"
mkdir -p run-adr017-4
cat > plan-adr017-4.md <<'EOF'
# Wave: adr017-not-subset
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts]
- new_files: [b.ts]
- description: |
    b.ts not in planned_files.
EOF
ERR_4=$(python3 "$SCRIPT" write-from-plan plan-adr017-4.md /tmp/adr017_4.json 2>&1 || true)
if echo "$ERR_4" | grep -qE "new_files must be a subset of planned_files"; then
  ok "ADR-017 T_nf_not_subset: subset violation rejected with clear error"
else
  ko "ADR-017 T_nf_not_subset" "expected subset-violation error, got: $ERR_4"
fi

# ---------------------------------------------------------------- ADR-017 #5
echo "ADR-017 T_nf_duplicates: validate rejects duplicate entries in new_files"
mkdir -p run-adr017-5
cat > plan-adr017-5.md <<'EOF'
# Wave: adr017-dup
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts, b.ts]
- new_files: [a.ts, a.ts]
- description: |
    duplicate a.ts.
EOF
ERR_5=$(python3 "$SCRIPT" write-from-plan plan-adr017-5.md /tmp/adr017_5.json 2>&1 || true)
if echo "$ERR_5" | grep -qE "new_files contains duplicates"; then
  ok "ADR-017 T_nf_duplicates: duplicate entries rejected"
else
  ko "ADR-017 T_nf_duplicates" "expected duplicate-rejection error, got: $ERR_5"
fi

# ---------------------------------------------------------------- ADR-017 #6
echo "ADR-017 T_nf_unsorted: validate rejects unsorted new_files"
mkdir -p run-adr017-6
cat > plan-adr017-6.md <<'EOF'
# Wave: adr017-unsorted
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts, b.ts]
- new_files: [b.ts, a.ts]
- description: |
    descending order.
EOF
ERR_6=$(python3 "$SCRIPT" write-from-plan plan-adr017-6.md /tmp/adr017_6.json 2>&1 || true)
if echo "$ERR_6" | grep -qE "new_files must be sorted ascending"; then
  ok "ADR-017 T_nf_unsorted: unsorted new_files rejected"
else
  ko "ADR-017 T_nf_unsorted" "expected sort-rejection error, got: $ERR_6"
fi

# ---------------------------------------------------------------- ADR-017 #7
echo "ADR-017 T_nf_collision: wave-level NEW-NEW collision rejected by validator"
mkdir -p run-adr017-7
cat > plan-adr017-7.md <<'EOF'
# Wave: adr017-collision
## Tickets
### T-001: First
- depends_on: []
- planned_files: [shared.ts]
- new_files: [shared.ts]
- description: |
    First claim.
### T-002: Second
- depends_on: []
- planned_files: [shared.ts]
- new_files: [shared.ts]
- description: |
    Collides with T-001.
EOF
ERR_7=$(python3 "$SCRIPT" write-from-plan plan-adr017-7.md /tmp/adr017_7.json 2>&1 || true)
if echo "$ERR_7" | grep -qE "new_files collision:.*shared\.ts"; then
  ok "ADR-017 T_nf_collision: NEW-NEW collision caught at wave-level validation"
else
  ko "ADR-017 T_nf_collision" "expected new_files collision error, got: $ERR_7"
fi

# ---------------------------------------------------------------- ADR-017 #8
echo "ADR-017 T_amend_nf_happy: amend-new-files appends and sorts"
mkdir -p run-adr017-8
cat > plan-adr017-8.md <<'EOF'
# Wave: adr017-amend
## Tickets
### T-001: First
- depends_on: []
- planned_files: [a.ts, b.ts, c.ts]
- new_files: [a.ts]
- description: |
    Start with a.ts NEW.
EOF
if ! python3 "$SCRIPT" write-from-plan plan-adr017-8.md run-adr017-8/wave-manifest.json 2>err_adr017_8; then
  ko "ADR-017 T_amend_nf_happy (setup)" "parse failed: $(cat err_adr017_8)"
else
  python3 "$SCRIPT" amend-new-files run-adr017-8/wave-manifest.json T-001 --file c.ts --file b.ts > /dev/null 2>err_adr017_8b
  if jq -e '.tickets[0].new_files == ["a.ts", "b.ts", "c.ts"]' run-adr017-8/wave-manifest.json > /dev/null; then
    ok "ADR-017 T_amend_nf_happy: amend-new-files appends + sorts (no duplicates)"
  else
    ko "ADR-017 T_amend_nf_happy" "result=$(jq '.tickets[0].new_files' run-adr017-8/wave-manifest.json); err=$(cat err_adr017_8b)"
  fi
fi

# ---------------------------------------------------------------- ADR-017 #9
echo "ADR-017 T_amend_nf_idempotent: re-invoking with same files is a no-op"
if [ -f run-adr017-8/wave-manifest.json ]; then
  BEFORE=$(jq -c '.tickets[0].new_files' run-adr017-8/wave-manifest.json)
  python3 "$SCRIPT" amend-new-files run-adr017-8/wave-manifest.json T-001 --file a.ts --file b.ts --file c.ts > /dev/null 2>err_adr017_9
  AFTER=$(jq -c '.tickets[0].new_files' run-adr017-8/wave-manifest.json)
  if [ "$BEFORE" = "$AFTER" ]; then
    ok "ADR-017 T_amend_nf_idempotent: re-invoking with same files is a no-op"
  else
    ko "ADR-017 T_amend_nf_idempotent" "before=$BEFORE after=$AFTER"
  fi
else
  ko "ADR-017 T_amend_nf_idempotent" "setup manifest missing"
fi

# ---------------------------------------------------------------- v3 (ADR-026 + ADR-028)
echo "INFRA-028/029: wave_protocol_version == 3 validation + sizing tripwire"
# A v3 plan parses, validates, and stores version 3 (v3 reuses v2 wave-level fields).
cat > "${SCRATCH}/v3-plan.md" <<'EOF'
# Wave: v3-accept
**Theme:** t
**Goal:** g
**Protocol version:** 3

## Tickets

### INFRA-028: cadence collapse
- depends_on: []
- planned_files: [core/config/phases/orchestrated/w-finalize.md]
- manual_review_required: true
- description: |
    test
EOF
if python3 "$SCRIPT" write-from-plan "${SCRATCH}/v3-plan.md" "${SCRATCH}/v3-manifest.json" 2>"${SCRATCH}/v3.err"; then
  V3PV=$(jq -r '.wave_protocol_version' "${SCRATCH}/v3-manifest.json")
  [ "$V3PV" = "3" ] && ok "v3 plan validates + stores wave_protocol_version=3" \
    || ko "v3 accept" "expected version 3, got '$V3PV'"
else
  ko "v3 accept" "v3 plan failed validation: $(cat "${SCRATCH}/v3.err")"
fi

# An unknown protocol version (4) is rejected at parse time.
sed 's/\*\*Protocol version:\*\* 3/\*\*Protocol version:\*\* 4/' "${SCRATCH}/v3-plan.md" > "${SCRATCH}/v4-plan.md"
if python3 "$SCRIPT" write-from-plan "${SCRATCH}/v4-plan.md" "${SCRATCH}/v4-manifest.json" 2>"${SCRATCH}/v4.err"; then
  ko "unknown version rejected" "expected exit!=0 for version 4"
else
  grep -qiE "must be 1, 2, or 3" "${SCRATCH}/v4.err" && ok "unknown protocol version (4) rejected with clear error" \
    || ko "unknown version rejected" "rejected but wrong message: $(cat "${SCRATCH}/v4.err")"
fi

# Sizing tripwire: an 8-ticket v3 wave emits the decompose-not-fragment warning (non-blocking).
{
  echo "# Wave: v3-big"; echo "**Theme:** t"; echo "**Goal:** g"; echo "**Protocol version:** 3"; echo ""; echo "## Tickets"; echo ""
  for n in 1 2 3 4 5 6 7 8; do
    echo "### INFRA-10${n}: t${n}"; echo "- depends_on: []"; echo "- planned_files: [a${n}.md]"; echo "- manual_review_required: false"; echo "- description: |"; echo "    d"; echo ""
  done
} > "${SCRATCH}/v3-big-plan.md"
python3 "$SCRIPT" write-from-plan "${SCRATCH}/v3-big-plan.md" "${SCRATCH}/v3-big-manifest.json" 2>"${SCRATCH}/v3big.err"
if grep -qiE "Wave-sizing tripwire|decompose" "${SCRATCH}/v3big.err"; then
  ok "v3 8-ticket wave emits decompose-not-fragment sizing warning (ADR-028)"
else
  ko "v3 sizing tripwire" "expected sizing warning on stderr, got: $(cat "${SCRATCH}/v3big.err")"
fi

# ------------------------------------------- ADR-103 W1: acceptance atom-chain carry (re-arm AC-COVERAGE)
echo "ADR-103 W1: acceptance atoms render->parse->manifest"
cat > "${SCRATCH}/atom-chain.md" <<'EOF'
# Wave: atom-chain-w1

**Protocol version:** 3

## Tickets

### TC-001: render+parse acceptance
- depends_on: []
- planned_files: [core/scripts/workflows/roadmap.js]
- acceptance: [AC-001, AC-002]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    carry the atom chain

### TC-002: second claim
- depends_on: [TC-001]
- planned_files: [core/scripts/wave-manifest.py]
- acceptance: [AC-003]
- manual_review_required: true
- description: |
    claim AC-003
EOF
if python3 "$SCRIPT" write-from-plan "${SCRATCH}/atom-chain.md" "${SCRATCH}/atom-chain.json" 2>"${SCRATCH}/atomchain.err"; then
  a1=$(jq -c '.tickets[0].acceptance' "${SCRATCH}/atom-chain.json")
  a2=$(jq -c '.tickets[1].acceptance' "${SCRATCH}/atom-chain.json")
  if [ "$a1" = '["AC-001","AC-002"]' ] && [ "$a2" = '["AC-003"]' ]; then
    ok "acceptance parses as a list and survives into the manifest (atom-chain carry)"
  else
    ko "atom-chain carry" "expected [AC-001,AC-002]/[AC-003], got $a1 / $a2"
  fi
  claimed=$(jq -r '[.tickets[].acceptance[]] | unique | join(",")' "${SCRATCH}/atom-chain.json")
  if [ "$claimed" = "AC-001,AC-002,AC-003" ]; then
    ok "AC-COVERAGE set-diff intact: all 3 spec atoms claimed (defang fixed)"
  else
    ko "AC-COVERAGE carry" "claimed set = $claimed"
  fi
else
  ko "atom-chain carry" "write-from-plan failed: $(cat "${SCRATCH}/atomchain.err")"
fi

# Back-compat: a legacy plan with NO acceptance field defaults to [] (not null, not a crash).
cat > "${SCRATCH}/legacy.md" <<'EOF'
# Wave: legacy-no-accept

**Protocol version:** 3

## Tickets

### T-001: legacy
- depends_on: []
- planned_files: [a.md]
- manual_review_required: false
- description: |
    no acceptance field
EOF
if python3 "$SCRIPT" write-from-plan "${SCRATCH}/legacy.md" "${SCRATCH}/legacy.json" 2>/dev/null; then
  la=$(jq -c '.tickets[0].acceptance' "${SCRATCH}/legacy.json")
  if [ "$la" = '[]' ]; then ok "legacy plan without acceptance defaults to [] (back-compat)"; else ko "legacy acceptance default" "got $la"; fi
else
  ko "legacy acceptance default" "write-from-plan failed"
fi

# ---------------------------------------------------------------- Summary
echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "FAILURES:$FAIL_DETAIL"
  exit 1
fi
echo "ALL GREEN"
exit 0
