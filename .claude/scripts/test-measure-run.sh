#!/usr/bin/env bash
# test-measure-run.sh — unit test for the T4.2 subagent token roll-up in
# measure-run.sh (subagent_* fields, --per-agent, --run-log).
#
# Hermetic: builds a synthetic session transcript + a sibling subagents/ journal
# fixture in a mktemp scratch dir, runs measure-run.sh against it with
# --transcript (no dependence on ~/.claude/projects or any live session), and
# asserts on the emitted JSON record. Mirrors the real on-disk layout discovered
# in T4.1/T4.2: journals live at <transcript-without-.jsonl>/subagents/agent-*.jsonl
# and carry sessionId + attributionAgent + message.usage token fields.
#
# Exit 0: all assertions passed. Exit 1: at least one failed. Exit 2: setup error.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/core/scripts/measure-run.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: measure-run.sh not found at $SCRIPT" >&2
  exit 2
fi
for tool in jq python3; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: $tool unavailable" >&2
    exit 2
  fi
done

echo "=== test-measure-run.sh ==="
echo "SCRIPT: $SCRIPT"
echo

total=0
failures=0

pass() { echo "PASS: $1"; }
fail() { failures=$((failures + 1)); echo "FAIL: $1"; }

# assert_eq <name> <expected> <actual>
assert_eq() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Build a synthetic session transcript with a subagents/ fixture ----------
SID="testsess-0000-0000-0000-000000000001"
TRANSCRIPT="$WORK/${SID}.jsonl"
SUBDIR="$WORK/${SID}/subagents"
mkdir -p "$SUBDIR"

# Minimal parent transcript: one human kickoff + one assistant turn (output 1000).
# Each event carries a top-level ISO-8601 `timestamp` (as real transcripts do) so
# the W5.0 duration_seconds amend can compute last-minus-first (here: 90s).
{
  printf '%s\n' '{"type":"user","timestamp":"2026-06-15T10:00:00.000Z","message":{"content":[{"type":"text","text":"do the thing"}]}}'
  printf '%s\n' '{"type":"assistant","timestamp":"2026-06-15T10:01:30.000Z","message":{"usage":{"output_tokens":1000},"content":[{"type":"text","text":"ok"}]}}'
} > "$TRANSCRIPT"

# Two subagent journals. Each entry stamps sessionId + attributionAgent; usage
# carries the four token fields the roll-up sums.
make_journal() {
  # make_journal <file> <agent> <in> <out> <cc> <cr>
  local f="$1" agent="$2" in="$3" out="$4" cc="$5" cr="$6"
  {
    printf '{"type":"user","sessionId":"%s","attributionAgent":"%s","isSidechain":true,"message":{"content":"prompt"}}\n' "$SID" "$agent"
    printf '{"type":"assistant","sessionId":"%s","attributionAgent":"%s","message":{"usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$SID" "$agent" "$in" "$out" "$cc" "$cr"
  } > "$f"
}
make_journal "$SUBDIR/agent-aaaa1111.jsonl" "implementer"     100 200 300 400
make_journal "$SUBDIR/agent-bbbb2222.jsonl" "code-reviewer"    10  20  30  40
# A stray journal stamped with a DIFFERENT session — must be skipped by the
# sessionId field-verification (defends the structural directory join).
make_journal "$SUBDIR/agent-cccc3333.jsonl" "intruder"        999 999 999 999
# Patch the intruder's sessionId to a foreign session.
python3 - "$SUBDIR/agent-cccc3333.jsonl" "$SID" <<'PY'
import json, sys
p, sid = sys.argv[1], sys.argv[2]
lines = []
for l in open(p):
    o = json.loads(l)
    o["sessionId"] = "foreign-session-9999"
    lines.append(json.dumps(o))
open(p, "w").write("\n".join(lines) + "\n")
PY

# === Assertion 1: subagent fields populate (2 valid journals; intruder skipped) ===
REC="$(bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --task fixture --no-append 2>/dev/null)"
assert_eq "record is valid JSON (kind=measurement)" "measurement" "$(printf '%s' "$REC" | jq -r '.kind')"
assert_eq "subagent_count = 2 (intruder skipped)" "2" "$(printf '%s' "$REC" | jq -r '.subagent_count')"
assert_eq "subagent_input_tokens = 110"  "110" "$(printf '%s' "$REC" | jq -r '.subagent_input_tokens')"
assert_eq "subagent_output_tokens = 220" "220" "$(printf '%s' "$REC" | jq -r '.subagent_output_tokens')"
assert_eq "subagent_cache_creation_tokens = 330" "330" "$(printf '%s' "$REC" | jq -r '.subagent_cache_creation_tokens')"
assert_eq "subagent_cache_read_tokens = 440" "440" "$(printf '%s' "$REC" | jq -r '.subagent_cache_read_tokens')"
assert_eq "subagent_link_method labelled" "subagents-dir+sessionId" "$(printf '%s' "$REC" | jq -r '.subagent_link_method')"
assert_eq "intruder counted as skipped" "1" "$(printf '%s' "$REC" | jq -r '.subagent_session_mismatch_skipped')"
assert_eq "existing output_tokens field intact" "1000" "$(printf '%s' "$REC" | jq -r '.output_tokens')"

# === Assertion 1d: duration_seconds present + numeric in transcript mode (W5.0 / AC-001,003) ===
# Fixture events are 90s apart (10:00:00 -> 10:01:30); last-minus-first = 90.
assert_eq "duration_seconds = 90 (last-minus-first event timestamp)" "90" \
  "$(printf '%s' "$REC" | jq -r '.duration_seconds')"
total=$((total + 1))
if printf '%s' "$REC" | jq -e '.duration_seconds | type == "number"' >/dev/null 2>&1; then
  pass "duration_seconds is numeric in transcript mode (AC-003)"
else
  fail "duration_seconds is not numeric (got: $(printf '%s' "$REC" | jq -r '.duration_seconds'))"
fi
# duration is a scalar only — never an object/array (token-counts-only invariant 5).
total=$((total + 1))
DTYPE="$(printf '%s' "$REC" | jq -r '.duration_seconds | type')"
if [ "$DTYPE" = "number" ] || [ "$DTYPE" = "null" ]; then
  pass "duration_seconds is a numeric/null scalar (invariant 5 preserved)"
else
  fail "duration_seconds is not a scalar (type=$DTYPE)"
fi

# === Assertion 2: --per-agent renders the array with recovered labels ===
RECP="$(bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --task fixture --per-agent --no-append 2>/dev/null)"
assert_eq "--per-agent array length = 2" "2" "$(printf '%s' "$RECP" | jq -r '.subagents | length')"
assert_eq "--per-agent recovers implementer label" "implementer" \
  "$(printf '%s' "$RECP" | jq -r '.subagents[] | select(.journal_id=="agent-aaaa1111") | .agent')"
assert_eq "--per-agent per-entry output token" "200" \
  "$(printf '%s' "$RECP" | jq -r '.subagents[] | select(.journal_id=="agent-aaaa1111") | .output_tokens')"
# Default (no --per-agent) record must NOT carry the array.
assert_eq "subagents array absent by default" "null" "$(printf '%s' "$REC" | jq -r '.subagents')"

# === Assertion 3: null-graceful when there is NO subagents dir ===
SID2="testsess-no-subagents-0000-000000000002"
T2="$WORK/${SID2}.jsonl"
printf '%s\n' '{"type":"assistant","message":{"usage":{"output_tokens":500},"content":[]}}' > "$T2"
RECN="$(bash "$SCRIPT" --transcript "$T2" --version v2 --task nosub --no-append 2>/dev/null)"
assert_eq "null-graceful: still valid JSON" "measurement" "$(printf '%s' "$RECN" | jq -r '.kind')"
assert_eq "null-graceful: subagent_count null" "null" "$(printf '%s' "$RECN" | jq -r '.subagent_count')"
assert_eq "null-graceful: subagent_input null" "null" "$(printf '%s' "$RECN" | jq -r '.subagent_input_tokens')"
assert_eq "null-graceful: link_method null" "null" "$(printf '%s' "$RECN" | jq -r '.subagent_link_method')"
# The T2 fixture carries NO timestamps -> duration_seconds must be null (W5.0 null-grace, AC-003).
assert_eq "null-graceful: duration_seconds null (no recoverable timestamps)" "null" \
  "$(printf '%s' "$RECN" | jq -r '.duration_seconds')"

# === Assertion 4: --run-log appends one TOKENS line (creates file if missing) ===
RLDIR="$WORK/runlog"
bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --task fixture --no-append --run-log "$RLDIR" >/dev/null 2>&1
total=$((total + 1))
if [ -f "$RLDIR/run-log.md" ]; then pass "--run-log created run-log.md"; else fail "--run-log did not create run-log.md"; fi
assert_eq "--run-log wrote exactly one TOKENS line" "1" "$(grep -c '^TOKENS:' "$RLDIR/run-log.md" 2>/dev/null || echo 0)"
total=$((total + 1))
if grep -q 'orchestrator_out=1000 subagents=110 in/220 out (2 journals)' "$RLDIR/run-log.md" 2>/dev/null; then
  pass "--run-log TOKENS line carries roll-up figures"
else
  fail "--run-log TOKENS line content (got: $(cat "$RLDIR/run-log.md" 2>/dev/null))"
fi

# === Assertion 5: --run-log write failure never fails the measurement ===
OUT="$(bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --task fixture --no-append --run-log /dev/null/cannot 2>/dev/null)"
RC=$?
assert_eq "bad --run-log dir: exit 0 (measurement unaffected)" "0" "$RC"
assert_eq "bad --run-log dir: record still emitted" "measurement" "$(printf '%s' "$OUT" | jq -r '.kind')"

# === Assertion 6: the append/cache-field behaviour of the close-out form (W1M-T2 / AC-003,004,012) =
# Drives measure-run.sh DIRECTLY in the corrected `--metrics <path> --task <slug>` form (NO --per-agent)
# against the hermetic fixture transcript, into a scratch _metrics.jsonl — verifying the append delta,
# the real cache fields, and no per-agent array. NOTE: this does NOT exercise closeout-run.py's argument
# CONSTRUCTION (that is Assertion 6b's job — the CR-001 regression guard); it checks the emitted record.
CLOSEOUT_METRICS="$WORK/closeout_metrics.jsonl"
: > "$CLOSEOUT_METRICS"
BEFORE_N="$(wc -l < "$CLOSEOUT_METRICS" | tr -d ' ')"
# The CORRECTED close-out form (--metrics <path> --task <slug>), driven via --transcript for
# hermeticity. (closeout-run.py's actual construction of this form is guarded by Assertion 6b.):
bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --metrics "$CLOSEOUT_METRICS" --task closeout-fixture >/dev/null 2>&1
AFTER_N="$(wc -l < "$CLOSEOUT_METRICS" | tr -d ' ')"
assert_eq "close-out fires: exactly +1 measurement line (delta==1, AC-004/012)" "1" "$((AFTER_N - BEFORE_N))"
CLINE="$(tail -1 "$CLOSEOUT_METRICS")"
assert_eq "close-out line is kind=measurement (seam reached, AC-002)" "measurement" "$(printf '%s' "$CLINE" | jq -r '.kind')"
# Non-NULL cache fields prove the REAL keys (cache_creation_input_tokens /
# cache_read_input_tokens) flowed through to the aggregates (AC-003).
assert_eq "close-out line: subagent_cache_creation_tokens non-null (AC-003)" "330" "$(printf '%s' "$CLINE" | jq -r '.subagent_cache_creation_tokens')"
assert_eq "close-out line: subagent_cache_read_tokens non-null (AC-003)" "440" "$(printf '%s' "$CLINE" | jq -r '.subagent_cache_read_tokens')"
total=$((total + 1))
if printf '%s' "$CLINE" | jq -e '.subagent_cache_creation_tokens | type == "number"' >/dev/null 2>&1; then
  pass "close-out line: cache_creation is an integer (AC-003)"
else
  fail "close-out line: cache_creation is not an integer"
fi
# AC-012: the close-out path does NOT request the per-agent breakdown array.
assert_eq "close-out line carries NO per-agent breakdown array (AC-012)" "null" "$(printf '%s' "$CLINE" | jq -r '.subagents')"
# Belt-and-braces: the actual call site in closeout-run.py never passes the flag.
total=$((total + 1))
if ! git -C "$REPO_ROOT" grep -nq "per-agent" -- core/scripts/closeout-run.py 2>/dev/null; then
  pass "closeout-run.py source passes no per-agent flag (AC-012)"
else
  fail "closeout-run.py source references per-agent flag"
fi

# === Assertion 6b: closeout-run.py BUILDS the correct --metrics <path> form (CR-001 regression) ====
# Assertion 6 above drives measure-run.sh DIRECTLY (good for append/cache-field behaviour) but cannot
# catch a bug in how closeout-run.py CONSTRUCTS the invocation. Drive closeout-run.py --dry-run (which
# prints the MEASURE command it builds) and assert the shape is `--metrics <path> --task <slug>`, NOT
# the broken `--metrics --task <slug>` form that made --metrics swallow --task → the slug hit
# "unknown arg" → exit 1 → the per-run line was silently NEVER appended (CR-001).
CO_FIX="$WORK/co/docs/step-5-pipeline/2026-06-14/0900-NIMBLE-x"
mkdir -p "$CO_FIX"
CO_OUT="$(python3 "$REPO_ROOT/core/scripts/closeout-run.py" "$CO_FIX" --session testsess --dry-run 2>&1 | grep -i 'MEASURE' | head -1)"
total=$((total + 1))
if printf '%s' "$CO_OUT" | grep -qE -- '--metrics +[^ ]+ +--task'; then
  pass "closeout-run.py builds --metrics <path> --task (CR-001 regression guard)"
else
  fail "closeout-run.py MEASURE command shape wrong (CR-001): $CO_OUT"
fi

# === Assertion 7: concurrent-append integrity (W1M-T2 / AC-005) ================
# Two backgrounded >> writers against a shared scratch _metrics.jsonl. Each appends
# one ≤PIPE_BUF line, so a single write() is atomic on POSIX — final line count must
# equal the writer count with NO mid-line interleave (every line valid JSON).
CONC_METRICS="$WORK/concurrent_metrics.jsonl"
: > "$CONC_METRICS"
WRITERS=2
for i in $(seq 1 "$WRITERS"); do
  bash "$SCRIPT" --transcript "$TRANSCRIPT" --version v2 --metrics "$CONC_METRICS" --task "conc-$i" >/dev/null 2>&1 &
done
wait
CONC_N="$(wc -l < "$CONC_METRICS" | tr -d ' ')"
assert_eq "concurrent append: final line count == writer count (AC-005)" "$WRITERS" "$CONC_N"
# Every line must be valid JSON (proves no mid-line interleave / torn write).
total=$((total + 1))
BADLINES=0
while IFS= read -r _ln; do
  [ -z "$_ln" ] && continue
  if ! printf '%s' "$_ln" | jq -e . >/dev/null 2>&1; then BADLINES=$((BADLINES + 1)); fi
done < "$CONC_METRICS"
if [ "$BADLINES" -eq 0 ]; then
  pass "concurrent append: every line is valid JSON (no mid-line interleave, AC-005)"
else
  fail "concurrent append: $BADLINES torn/invalid line(s)"
fi

# === Assertion 8: wrong-primitive guard (W1M-T2 / AC-011) ======================
# measure-run.sh (and the append path) must use single-line O_APPEND only — never
# a read-modify-write (_w()) or os.replace whole-file swap.
total=$((total + 1))
if ! git -C "$REPO_ROOT" grep -nqE "_w\(|os\.replace" -- core/scripts/measure-run.sh 2>/dev/null; then
  pass "no _w()/os.replace in measure-run.sh (single-line O_APPEND only, AC-011)"
else
  fail "measure-run.sh uses a read-modify-write primitive (_w()/os.replace)"
fi

echo
echo "=== test-measure-run.sh: $((total - failures))/$total assertions passed ==="
if [ "$failures" -gt 0 ]; then
  echo "RESULT: FAIL ($failures failures)"
  exit 1
fi
echo "RESULT: PASS"
exit 0
