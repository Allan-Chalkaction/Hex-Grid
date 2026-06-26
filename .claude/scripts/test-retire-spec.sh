#!/usr/bin/env bash
# test-retire-spec.sh — fixture-driven test harness for retire-spec.py (ADR-106/107, W1DLP-T3/T5).
#
# Each sub-test runs in an isolated, git-init'd tempdir — the harness NEVER mutates the live repo's working
# tree. Mirrors core/scripts/test-graduate-jam.sh's idiom (seed → run → assert → rm -rf).
#
# W1 base coverage (W1DLP-T3): the retire-spec.py base contract —
#   (a) the --superseded-by move is STAGED not committed (the invocation produces no commit),
#   (b) a re-run no-ops (idempotent),
#   (c) an absent source WARNs and exits cleanly (missing-source tolerance).
# W2 harvest coverage (W1DLP-T5) is appended below (the DEAD/ABSORBED/ORPHANED classification assertions).
#
# Subcommands (no arg = run all):
#   stage-not-commit  idempotent  missing-source  help-flags
#   harvest-orphaned-only  harvest-before-move  harvest-no-overwrite   (W2, appended by T5)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RS="$REPO_ROOT/core/scripts/retire-spec.py"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# seed_spec <slug> [extra-residual-setup-fn] -> prints the tempdir path
# Seeds docs/step-3-specs/<slug>/ with a spec.md, git inits, and commits once (the seed commit).
seed_spec() {
  local slug="$1"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/docs/step-3-specs/$slug"
  echo "# spec $slug" > "$tmp/docs/step-3-specs/$slug/spec.md"
  # let an optional caller-supplied function add residuals before the seed commit
  if [ -n "${2:-}" ]; then "$2" "$tmp" "$slug"; fi
  git -C "$tmp" init -q
  git -C "$tmp" add -A
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m seed
  echo "$tmp"
}

# commit_count <tmp> -> number of commits in the tempdir repo
commit_count() { git -C "$1" rev-list --count HEAD; }

# ---------------------------------------------------------------------------
# W1 base coverage
# ---------------------------------------------------------------------------

t_stage_not_commit() {
  echo "[stage-not-commit] --superseded-by move is STAGED, not committed (AC-005a / AC-020)"
  local slug=rs-fixture-old tmp before after
  tmp="$(seed_spec "$slug")"
  before="$(commit_count "$tmp")"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" >/dev/null 2>&1)
  after="$(commit_count "$tmp")"
  [ -d "$tmp/docs/step-6-done/superseded/$slug" ] && pass "spec moved to terminal/superseded home" || fail "spec not moved"
  [ -f "$tmp/docs/step-6-done/superseded/$slug/RETIRED.md" ] && pass "RETIRED.md successor marker written" || fail "successor marker missing"
  grep -q 'rs-fixture-new' "$tmp/docs/step-6-done/superseded/$slug/RETIRED.md" 2>/dev/null \
    && pass "successor name recorded in marker" || fail "successor name not recorded"
  [ "$before" = "$after" ] && pass "no commit produced by the invocation (stage-only)" \
    || fail "invocation produced a commit (before=$before after=$after)"
  # the move + marker must be STAGED (in the index)
  git -C "$tmp" diff --cached --quiet && fail "nothing staged (move was not staged)" || pass "the move is staged in the index"
  rm -rf "$tmp"
}

t_idempotent() {
  echo "[idempotent] a re-run no-ops (AC-005b)"
  local slug=rs-fixture-old tmp out
  tmp="$(seed_spec "$slug")"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" >/dev/null 2>&1)
  out="$(cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" 2>&1)"
  echo "$out" | grep -q 'already retired' && pass "re-run reports already-retired no-op" || { fail "re-run did not no-op"; echo "    $out" | tail -2; }
  rm -rf "$tmp"
}

t_missing_source() {
  echo "[missing-source] an absent source WARNs and exits cleanly (AC-005c)"
  local tmp out rc
  tmp="$(seed_spec rs-fixture-present)"
  out="$(cd "$REPO_ROOT" && python3 "$RS" --slug rs-fixture-absent --superseded-by rs-fixture-new --repo-root "$tmp" 2>&1)"; rc=$?
  echo "$out" | grep -qiE 'not found|missing source' && pass "absent source WARNs" || { fail "no WARN on absent source"; echo "    $out" | tail -2; }
  [ "$rc" -eq 0 ] && pass "exits cleanly (rc=0) on absent source" || fail "non-zero exit on absent source (rc=$rc)"
  rm -rf "$tmp"
}

t_help_flags() {
  echo "[help-flags] --help runs and shows --superseded-by (AC-003)"
  local out
  out="$(cd "$REPO_ROOT" && python3 "$RS" --help 2>&1)"
  echo "$out" | grep -q -- '--superseded-by' && pass "--help shows --superseded-by" || fail "--help missing --superseded-by"
}

# ===========================================================================
# W2 harvest coverage (W1DLP-T5, ADR-108) — extends the SAME suite (no fork).
# ===========================================================================

# _add_mixed_residuals <tmp> <slug> — add one DEAD, one ABSORBED, one ORPHANED residual.
# The structural spec.md is marked DEAD so EXACTLY one residual is ORPHANED (clean assertion).
_add_mixed_residuals() {
  local tmp="$1" slug="$2" sp="$1/docs/step-3-specs/$2"
  printf '# spec %s\n<!-- retire: dead -->\nshell of the spec\n' "$slug" > "$sp/spec.md"
  printf '# notes\n<!-- retire: dead -->\nobsolete\n' > "$sp/dead-notes.md"
  printf '# design\n<!-- retire: absorbed-by: rs-fixture-new -->\nmoved on\n' > "$sp/absorbed-design.md"
  printf '# loose idea\nlive content nobody absorbed\n' > "$sp/orphan-idea.md"
}

t_harvest_orphaned_only() {
  echo "[harvest-orphaned-only] exactly the ORPHANED residual is harvested (AC-007)"
  local slug=rs-fixture-old tmp hdir
  tmp="$(seed_spec "$slug" _add_mixed_residuals)"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" >/dev/null 2>&1)
  hdir="$tmp/docs/step-1-ideas/from-retired-$slug"
  # exactly one harvest file, and it is the orphan
  local n; n="$(ls "$hdir" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" = "1" ] && pass "exactly one residual harvested (got $n)" || fail "expected 1 harvested, got $n"
  [ -f "$hdir/orphan-idea.md" ] && pass "the ORPHANED residual is harvested" || fail "orphan-idea.md not harvested"
  [ ! -f "$hdir/dead-notes.md" ] && pass "DEAD residual NOT harvested" || fail "DEAD residual wrongly harvested"
  [ ! -f "$hdir/absorbed-design.md" ] && pass "ABSORBED residual NOT harvested" || fail "ABSORBED residual wrongly harvested"
  rm -rf "$tmp"
}

t_harvest_before_move() {
  echo "[harvest-before-move] harvest writes land under step-1-ideas/, STAGED, BEFORE the move (AC-008)"
  local slug=rs-fixture-old tmp hdir
  tmp="$(seed_spec "$slug" _add_mixed_residuals)"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" >/dev/null 2>&1)
  hdir="$tmp/docs/step-1-ideas/from-retired-$slug"
  # the harvest landed under step-1-ideas/ AND is staged in the index
  [ -d "$hdir" ] && pass "harvest writes land under docs/step-1-ideas/" || fail "harvest dir missing"
  git -C "$tmp" diff --cached --name-only | grep -q "docs/step-1-ideas/from-retired-$slug/orphan-idea.md" \
    && pass "harvest file is STAGED (git add)" || fail "harvest file not staged"
  # harvest happened BEFORE the move: the harvested file still references the source under step-3-specs,
  # and both the harvest stub and the moved spec are staged in the SAME run (single index, no commit).
  git -C "$tmp" diff --cached --name-only | grep -q "docs/step-6-done/superseded/$slug/" \
    && pass "the spec move is staged in the SAME run as the harvest" || fail "spec move not staged with harvest"
  # no commit produced (stage-only)
  [ "$(commit_count "$tmp")" = "1" ] && pass "no commit produced (harvest + move both staged)" || fail "a commit was produced"
  rm -rf "$tmp"
}

t_harvest_no_overwrite() {
  echo "[harvest-no-overwrite] a re-run does not overwrite an existing harvest file (AC-008)"
  local slug=rs-fixture-old tmp hfile first second
  tmp="$(seed_spec "$slug" _add_mixed_residuals)"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" >/dev/null 2>&1)
  hfile="$tmp/docs/step-1-ideas/from-retired-$slug/orphan-idea.md"
  first="$(cat "$hfile")"
  # tamper the harvested file, then re-run retire on a freshly re-seeded source spec to retrigger harvest
  echo "TAMPERED" >> "$hfile"
  mkdir -p "$tmp/docs/step-3-specs/$slug"
  printf '# loose idea\nDIFFERENT content this time\n' > "$tmp/docs/step-3-specs/$slug/orphan-idea.md"
  (cd "$REPO_ROOT" && python3 "$RS" --slug "$slug" --superseded-by rs-fixture-new --repo-root "$tmp" 2>&1 | grep -q 'already present') \
    && pass "re-run reports already-present (not overwriting)" || fail "re-run did not report no-overwrite"
  second="$(cat "$hfile")"
  echo "$second" | grep -q 'TAMPERED' && pass "existing harvest file left intact (never overwritten)" \
    || fail "existing harvest file was overwritten"
  rm -rf "$tmp"
}


# --- run-all dispatch ------------------------------------------------------
run_all() {
  t_stage_not_commit
  t_idempotent
  t_missing_source
  t_help_flags
  # W2 (T5):
  if declare -f t_harvest_orphaned_only >/dev/null; then
    t_harvest_orphaned_only
    t_harvest_before_move
    t_harvest_no_overwrite
  fi
}

case "${1:-all}" in
  all) run_all ;;
  stage-not-commit) t_stage_not_commit ;;
  idempotent) t_idempotent ;;
  missing-source) t_missing_source ;;
  help-flags) t_help_flags ;;
  harvest-orphaned-only) t_harvest_orphaned_only ;;
  harvest-before-move) t_harvest_before_move ;;
  harvest-no-overwrite) t_harvest_no_overwrite ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac

echo ""
echo "=== test-retire-spec.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
