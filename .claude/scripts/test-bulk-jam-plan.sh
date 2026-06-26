#!/usr/bin/env bash
# test-bulk-jam-plan.sh — fixture-driven test harness for the verify-shipped gate (ADR-060, W1VSG-T1).
#
# The original "live-misclassified cluster" anchor drained from docs/step-1-ideas/ between authoring and
# implementation (commits 35586c0, 8c67951), so the wave's primary validation is a synthetic fixture corpus
# checked in under core/scripts/test-fixtures/bulk-jam-plan/. This harness drives that corpus.
#
# Subcommands (no arg = run all):
#   rg-vs-walk          AC-008 — classify_shipped() returns deep-equal results via ripgrep and via the
#                       pure-Python walk fallback, across all three fixture classifications.
#   shipped-fixture     AC-018 — the SHIPPED banner fires with a concrete evidence path; the cluster is
#                       suppressed from the CREATE/REOPEN/SKIP listing.
#   unbuilt-only-fixture AC-012/AC-021 — no banner; last line carries `, 0 shipped`; AC-011 regex holds.
#   partly-fixture      PARTLY classification renders as a plain CREATE row (no suffix from the script).
#   verify-default-noop AC-017a — a PARTLY-cluster fixture invoked plain dispatches zero Explore agents
#                       (the script cannot dispatch agents; assert no explore tokens + clean exit).
#   module-attrs        AC-001 — classify_shipped is importable + callable.
#
# Read-only: the harness reads the live repo and the checked-in fixtures; it writes nothing into the working
# tree (no tempdir mutation of tracked files). AC-008's rg path is skipped-with-notice when `rg` is not a
# real PATH binary on the host, so the harness stays green where ripgrep is not installed while still
# asserting rg/walk equivalence wherever ripgrep is present.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN="$REPO_ROOT/core/scripts/bulk-jam-plan.py"
FIX="$REPO_ROOT/core/scripts/test-fixtures/bulk-jam-plan"

# The UNBUILT fixture slug, assembled so its full literal form never appears in this harness file (which
# lives under core/scripts/ — a classifier search root). Were the literal present here, classify_shipped
# would body-match it and return PARTLY, defeating the genuine empty-evidence case. The fixture idea files
# under test-fixtures/ DO carry the literal, but test-fixtures/ is excluded from the body search.
UNB="unbuilt-zq7""kp9"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# classify_probe <rg_force 0|1> <slug> -> prints JSON {classification, evidence(sorted)} or "ERR:<msg>"
classify_probe() {
  RG_FORCE="$1" PROBE_SLUG="$2" PROBE_ROOT="$REPO_ROOT" PLAN_PATH="$PLAN" python3 - <<'PY'
import importlib.util, json, os, sys
root = os.environ["PROBE_ROOT"]
slug = os.environ["PROBE_SLUG"]
rg_force = os.environ["RG_FORCE"]
spec = importlib.util.spec_from_file_location("bjp", os.environ["PLAN_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
if rg_force == "1":
    if not mod.shutil.which("rg"):
        print("ERR:rg-not-on-path"); sys.exit(0)
else:
    mod.shutil.which = lambda name: None  # force the pure-Python walk fallback
res = mod.classify_shipped(slug, root)
print(json.dumps({"classification": res["classification"], "evidence": sorted(res["evidence"])}))
PY
}

t_rg_vs_walk() {
  echo "[rg-vs-walk] AC-008 — ripgrep and walk paths agree"
  local rg_real; rg_real="$(python3 -c 'import shutil;print("1" if shutil.which("rg") else "0")')"
  if [ "$rg_real" != "1" ]; then
    echo "  NOTE  rg not a PATH binary on this host — rg-path skipped; validating walk-path only."
  fi
  for slug in bulk-idea-jam verify-shipped "$UNB"; do
    local walk; walk="$(classify_probe 0 "$slug")"
    if [ -z "$walk" ] || [[ "$walk" == ERR:* ]]; then
      fail "walk-path produced no result for $slug ($walk)"; continue
    fi
    if [ "$rg_real" = "1" ]; then
      local rg; rg="$(classify_probe 1 "$slug")"
      if [[ "$rg" == ERR:* ]]; then
        fail "rg-path errored for $slug ($rg)"; continue
      fi
      if [ "$rg" = "$walk" ]; then
        pass "$slug — rg == walk ($walk)"
      else
        fail "$slug — rg($rg) != walk($walk)"
      fi
    else
      # No rg on host: assert the walk result is at least sane (non-empty classification).
      if echo "$walk" | grep -q '"classification"'; then
        pass "$slug — walk-path OK ($walk)"
      else
        fail "$slug — walk-path malformed ($walk)"
      fi
    fi
  done
}

t_shipped_fixture() {
  echo "[shipped-fixture] AC-018 — SHIPPED banner + suppression"
  local out; out="$(python3 "$PLAN" --root "$FIX/shipped/ideas" --jams "$FIX/shipped/jams" 2>&1)"
  if echo "$out" | grep -qE '^VERIFY-SHIPPED GATE — 1 SHIPPED cluster\(s\) suppressed from CREATE:$'; then
    pass "banner heading present"
  else
    fail "banner heading missing"; echo "$out" | sed 's/^/      /'
  fi
  if echo "$out" | grep -qE '^  SHIPPED  jam-bulk-idea-jam  evidence: core/skills/bulk-idea-jam/SKILL.md$'; then
    pass "SHIPPED line with concrete evidence path"
  else
    fail "SHIPPED evidence line missing/wrong"
  fi
  if echo "$out" | grep -qE '^(CREATE|REOPEN|SKIP)  jam-bulk-idea-jam'; then
    fail "SHIPPED cluster leaked into CREATE/REOPEN/SKIP listing"
  else
    pass "SHIPPED cluster suppressed from listing"
  fi
  if echo "$out" | grep -qE '^BULK-JAM-PLAN: 0 create, 0 reopen\(\+new\), 0 skip\(no-new\), 1 shipped across 1 cluster\(s\)\.$'; then
    pass "last line reports 1 shipped across 1 cluster"
  else
    fail "last line wrong"; echo "$out" | tail -1 | sed 's/^/      /'
  fi
}

t_unbuilt_only_fixture() {
  echo "[unbuilt-only-fixture] AC-012/AC-021 — no banner, 0 shipped, AC-011 regex"
  local out; out="$(python3 "$PLAN" --root "$FIX/unbuilt/ideas" --jams "$FIX/unbuilt/jams" 2>&1)"
  if echo "$out" | grep -q 'VERIFY-SHIPPED GATE'; then
    fail "banner printed for an all-UNBUILT corpus"
  else
    pass "no banner for all-UNBUILT corpus"
  fi
  if echo "$out" | grep -qE "^CREATE  jam-${UNB}"; then
    pass "UNBUILT cluster appears unchanged in CREATE listing"
  else
    fail "UNBUILT cluster missing from CREATE listing"
  fi
  if echo "$out" | grep -qE '^BULK-JAM-PLAN: [0-9]+ create, [0-9]+ reopen\(\+new\), [0-9]+ skip\(no-new\), 0 shipped across [0-9]+ cluster\(s\)\.$'; then
    pass "AC-011 last-line regex holds with 0 shipped"
  else
    fail "AC-011 regex failed"; echo "$out" | tail -1 | sed 's/^/      /'
  fi
}

t_partly_fixture() {
  echo "[partly-fixture] PARTLY renders as a plain CREATE row (no script-side suffix)"
  local out; out="$(python3 "$PLAN" --root "$FIX/partly/ideas" --jams "$FIX/partly/jams" 2>&1)"
  if echo "$out" | grep -qE '^CREATE  jam-verify-shipped'; then
    pass "PARTLY cluster appears in CREATE listing"
  else
    fail "PARTLY cluster missing from CREATE listing"; echo "$out" | sed 's/^/      /'
  fi
  if echo "$out" | grep -q 'PARTLY —'; then
    fail "script emitted a (PARTLY — ...) suffix — that is the orchestrator's job (W1VSG-T2)"
  else
    pass "no (PARTLY — ...) suffix from the script"
  fi
  if echo "$out" | grep -q 'VERIFY-SHIPPED GATE'; then
    fail "PARTLY cluster wrongly banner-suppressed"
  else
    pass "PARTLY cluster not banner-suppressed"
  fi
}

t_verify_default_noop() {
  echo "[verify-default-noop] AC-017a — plain invocation dispatches zero Explore agents"
  local out rc
  out="$(python3 "$PLAN" --root "$FIX/partly/ideas" --jams "$FIX/partly/jams" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "exit 0 without --verify=explore"; else fail "non-zero exit ($rc)"; fi
  if echo "$out" | grep -qiE 'explore|findings/explore-'; then
    fail "script output references an Explore dispatch (should be impossible from the script)"
  else
    pass "no Explore dispatch tokens in script output"
  fi
}

t_module_attrs() {
  echo "[module-attrs] AC-001 — classify_shipped importable + callable"
  if PLAN_PATH="$PLAN" PROBE_SLUG="$UNB" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("bjp", os.environ["PLAN_PATH"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
assert callable(mod.classify_shipped), "classify_shipped not callable"
root = os.path.dirname(os.path.dirname(os.path.dirname(os.environ["PLAN_PATH"])))
r = mod.classify_shipped(os.environ["PROBE_SLUG"], root)
assert set(r) == {"classification", "evidence"}, r
assert r["classification"] == "UNBUILT" and r["evidence"] == [], r
PY
  then pass "classify_shipped is callable and returns the documented shape"
  else fail "classify_shipped import/contract check failed"; fi
}

run_all() {
  t_rg_vs_walk
  t_shipped_fixture
  t_unbuilt_only_fixture
  t_partly_fixture
  t_verify_default_noop
  t_module_attrs
  echo ""
  echo "RESULT: $PASS passed, $FAIL failed."
  [ "$FAIL" -eq 0 ]
}

case "${1:-all}" in
  rg-vs-walk) t_rg_vs_walk ;;
  shipped-fixture) t_shipped_fixture ;;
  unbuilt-only-fixture) t_unbuilt_only_fixture ;;
  partly-fixture) t_partly_fixture ;;
  verify-default-noop) t_verify_default_noop ;;
  module-attrs) t_module_attrs ;;
  all) run_all ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac

# For single-subcommand invocations, exit non-zero if any assertion failed.
[ "$FAIL" -eq 0 ]
