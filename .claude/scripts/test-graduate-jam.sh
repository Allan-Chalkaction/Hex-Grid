#!/usr/bin/env bash
# test-graduate-jam.sh — fixture-driven test harness for graduate-jam.py (ADR-061, W2GJ-T2).
#
# Each sub-test runs in an isolated, git-init'd tempdir seeded from a checked-in fixture tree under
# core/scripts/test-fixtures/graduate-jam/. The harness NEVER mutates the live repo's working tree — every
# move/reshape happens inside a mktemp dir. AC-016: `git status --porcelain` on the live repo is identical
# before and after a full run.
#
# Subcommands (no arg = run all):
#   orchestrated-fixture  bypass-fixture  intent-readme-fixture  intent-fallback-fixture
#   intent-absent-fixture  target-exists-fixture  no-waves-fixture  bad-header-fixture
#   out-of-scope-write-detector  merge-first-fixture  merge-delta-fixture  merge-idempotent-fixture
#   merge-refusal-unchanged  slug-validation  module-attrs  help-flags
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GJ="$REPO_ROOT/core/scripts/graduate-jam.py"
FIX="$REPO_ROOT/core/scripts/test-fixtures/graduate-jam"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# seed <fixture-jam-abs-dir> <slug>  -> prints the tempdir path
seed() {
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/docs/step-2-planning"
  cp -R "$1" "$tmp/docs/step-2-planning/jam-$2"
  git -C "$tmp" init -q
  git -C "$tmp" add -A
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m seed
  echo "$tmp"
}

# out_of_bounds <tmp> <slug>  -> prints any changed path NOT under the two allowed prefixes
out_of_bounds() {
  git -C "$1" status --porcelain \
    | sed 's/^...//' | sed 's/ -> /\n/' \
    | grep -vE "^(docs/step-2-planning/jam-$2/|docs/step-3-specs/$2/)" | grep -v '^$' || true
}

t_orchestrated() {
  echo "[orchestrated-fixture] move + reshape two waves"
  local slug=gj-fixture-orch tmp out
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --repo-root "$tmp" 2>&1)"
  [ -f "$tmp/docs/step-3-specs/$slug/waves/foo/foo.md" ] && pass "waves/foo/foo.md" || fail "waves/foo/foo.md missing"
  [ -f "$tmp/docs/step-3-specs/$slug/waves/foo/foo-prompts.md" ] && pass "waves/foo/foo-prompts.md" || fail "waves/foo/foo-prompts.md missing"
  [ -f "$tmp/docs/step-3-specs/$slug/waves/bar-baz/bar-baz.md" ] && pass "waves/bar-baz/bar-baz.md" || fail "waves/bar-baz/bar-baz.md missing"
  [ -f "$tmp/docs/step-3-specs/$slug/waves/bar-baz/bar-baz-prompts.md" ] && pass "waves/bar-baz/bar-baz-prompts.md" || fail "waves/bar-baz/bar-baz-prompts.md missing"
  [ -f "$tmp/docs/step-3-specs/$slug/README.md" ] && pass "README.md retained at spec root" || fail "README.md not retained"
  [ ! -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "source jam removed" || fail "source jam still present"
  if echo "$out" | grep -qE "^GRADUATE-JAM: moved jam-$slug → docs/step-3-specs/$slug/ \(2 waves reshaped, 1 intent artifact, [1-9][0-9]* retained files\)\.$"; then
    pass "summary line W=2 I=1 R>=1"
  else
    fail "summary line wrong"; echo "    $out" | tail -1
  fi
  rm -rf "$tmp"
}

t_bypass() {
  echo "[bypass-fixture] move-only, no reshape"
  local slug=gj-fixture-bypass tmp out
  tmp="$(seed "$FIX/bypass/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target bypass --repo-root "$tmp" 2>&1)"
  [ -f "$tmp/docs/step-3-specs/$slug/decomposition/prompts.md" ] && pass "decomposition/prompts.md present" || fail "prompts.md missing"
  [ ! -d "$tmp/docs/step-3-specs/$slug/waves" ] && pass "waves/ NOT created under bypass" || fail "waves/ wrongly created"
  if echo "$out" | grep -qE "^GRADUATE-JAM: moved jam-$slug → docs/step-3-specs/$slug/ \(0 waves reshaped, 1 intent artifact, [1-9][0-9]* retained files\)\.$"; then
    pass "summary line W=0 I=1 R>=1"
  else
    fail "summary line wrong"; echo "    $out" | tail -1
  fi
  rm -rf "$tmp"
}

t_intent_readme() {
  echo "[intent-readme-fixture] README.md is the intent artifact"
  local slug=gj-fixture-orch tmp
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  (cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --repo-root "$tmp" >/dev/null 2>&1)
  [ -f "$tmp/docs/step-3-specs/$slug/README.md" ] && pass "README.md at spec root" || fail "README.md missing"
  rm -rf "$tmp"
}

t_intent_fallback() {
  echo "[intent-fallback-fixture] index.md fallback when no README"
  local slug=gj-fixture-fallback tmp out
  tmp="$(seed "$FIX/intent-fallback/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target bypass --repo-root "$tmp" 2>&1)"
  [ -f "$tmp/docs/step-3-specs/$slug/index.md" ] && pass "index.md at spec root" || fail "index.md missing"
  echo "$out" | grep -qE "1 intent artifact" && pass "summary reports I=1" || fail "summary I != 1"
  rm -rf "$tmp"
}

t_intent_absent() {
  echo "[intent-absent-fixture] neither README nor index -> I=0, exit 0"
  local slug=gj-fixture-absent tmp out rc
  tmp="$(seed "$FIX/intent-absent/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target bypass --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "exit 0" || fail "non-zero exit ($rc)"
  echo "$out" | grep -qE "0 intent artifact" && pass "summary reports I=0" || fail "summary I != 0"
  rm -rf "$tmp"
}

t_target_exists() {
  echo "[target-exists-fixture] refuse on non-empty target; proceed on empty target"
  local slug=gj-fixture-targetex tmp out rc
  # Non-empty target -> refuse.
  tmp="$(seed "$FIX/target-exists/jam-$slug" "$slug")"
  mkdir -p "$tmp/docs/step-3-specs/$slug"
  echo "sentinel" > "$tmp/docs/step-3-specs/$slug/sentinel.md"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target bypass --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "non-zero exit on non-empty target" || fail "should have refused"
  echo "$out" | grep -qF "graduate-jam: target docs/step-3-specs/$slug/ already exists (non-empty)." && pass "literal refusal message" || fail "refusal message wrong"
  [ -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "source jam left in place" || fail "source jam moved despite refusal"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/sentinel.md")" = "sentinel" ] && pass "sentinel unchanged" || fail "sentinel mutated"
  rm -rf "$tmp"
  # Empty target dir -> proceed.
  tmp="$(seed "$FIX/target-exists/jam-$slug" "$slug")"
  mkdir -p "$tmp/docs/step-3-specs/$slug"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target bypass --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "proceeds on empty target dir" || fail "refused an empty target ($rc): $out"
  rm -rf "$tmp"
}

t_no_waves() {
  echo "[no-waves-fixture] --target orchestrated with 0 headers -> refuse, no partial move"
  local slug=gj-fixture-nowaves tmp out rc
  tmp="$(seed "$FIX/no-waves/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "non-zero exit" || fail "should have refused"
  echo "$out" | grep -qF "graduate-jam: --target orchestrated requires ≥1 # Wave: header; found 0." && pass "literal no-waves message" || fail "no-waves message wrong"
  [ -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "no partial move (source intact)" || fail "partial move occurred"
  [ ! -d "$tmp/docs/step-3-specs/$slug" ] && pass "no spec target created" || fail "spec target created despite refusal"
  rm -rf "$tmp"
}

t_bad_header() {
  echo "[bad-header-fixture] header normalizing to empty -> refuse"
  local slug=gj-fixture-badhdr tmp out rc
  tmp="$(seed "$FIX/bad-header/jam-$slug" "$slug")"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "non-zero exit" || fail "should have refused"
  echo "$out" | grep -qE "^graduate-jam: invalid wave header:" && pass "stderr begins 'graduate-jam: invalid wave header:'" || fail "bad-header message wrong: $out"
  [ -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "no partial move (source intact)" || fail "partial move occurred"
  rm -rf "$tmp"
}

t_merge_first() {
  echo "[merge-first-fixture] --into-existing: target has roadmap.md + waves/ (no source/) -> jam merges in"
  local slug=gj-fixture-orch tmp out rc
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  # Persist-populated target: roadmap.md + waves/, but NO source/ yet (first graduation).
  mkdir -p "$tmp/docs/step-3-specs/$slug/waves/foo"
  echo "engine roadmap" > "$tmp/docs/step-3-specs/$slug/roadmap.md"
  echo "engine wave foo" > "$tmp/docs/step-3-specs/$slug/waves/foo/foo.md"
  # Give the jam a source/ dir so the merge has a non-colliding dir to move in.
  mkdir -p "$tmp/docs/step-2-planning/jam-$slug/source"
  echo "jam atom one" > "$tmp/docs/step-2-planning/jam-$slug/source/atom1.md"
  git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m setup
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --into-existing --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "exit 0" || fail "non-zero exit ($rc): $out"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/roadmap.md")" = "engine roadmap" ] && pass "roadmap.md preserved" || fail "roadmap.md clobbered"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/waves/foo/foo.md")" = "engine wave foo" ] && pass "waves/ preserved" || fail "waves/ clobbered"
  [ -f "$tmp/docs/step-3-specs/$slug/source/atom1.md" ] && pass "jam source/ merged in" || fail "jam source/ not merged"
  [ ! -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "jam emptied + removed" || fail "jam not emptied"
  rm -rf "$tmp"
}

t_merge_delta() {
  echo "[merge-delta-fixture] CR-001: target has source/oldatom.md; delta jam brings NEW source/newatom.md -> BOTH present"
  local slug=gj-fixture-orch tmp out rc
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  # Target already populated AND already has source/oldatom.md (the delta case).
  mkdir -p "$tmp/docs/step-3-specs/$slug/source" "$tmp/docs/step-3-specs/$slug/waves/foo"
  echo "old atom" > "$tmp/docs/step-3-specs/$slug/source/oldatom.md"
  echo "engine roadmap" > "$tmp/docs/step-3-specs/$slug/roadmap.md"
  echo "engine wave foo" > "$tmp/docs/step-3-specs/$slug/waves/foo/foo.md"
  # The delta jam carries a NEW source/newatom.md.
  mkdir -p "$tmp/docs/step-2-planning/jam-$slug/source"
  echo "new delta atom" > "$tmp/docs/step-2-planning/jam-$slug/source/newatom.md"
  git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m setup
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --into-existing --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "exit 0" || fail "non-zero exit ($rc): $out"
  [ -f "$tmp/docs/step-3-specs/$slug/source/oldatom.md" ] && pass "oldatom.md preserved" || fail "oldatom.md dropped"
  [ -f "$tmp/docs/step-3-specs/$slug/source/newatom.md" ] && pass "newatom.md merged in (CR-001 fixed — delta NOT dropped)" || fail "newatom.md DROPPED (CR-001 regression)"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/source/oldatom.md")" = "old atom" ] && pass "oldatom.md content intact" || fail "oldatom.md content mutated"
  rm -rf "$tmp"
}

t_merge_idempotent() {
  echo "[merge-idempotent-fixture] running --into-existing twice doesn't error or lose/duplicate files"
  local slug=gj-fixture-orch tmp out rc cnt
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  mkdir -p "$tmp/docs/step-3-specs/$slug/waves/foo"
  echo "engine roadmap" > "$tmp/docs/step-3-specs/$slug/roadmap.md"
  echo "engine wave foo" > "$tmp/docs/step-3-specs/$slug/waves/foo/foo.md"
  mkdir -p "$tmp/docs/step-2-planning/jam-$slug/source"
  echo "jam atom one" > "$tmp/docs/step-2-planning/jam-$slug/source/atom1.md"
  git -C "$tmp" add -A; git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m setup
  # First merge.
  (cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --into-existing --repo-root "$tmp" >/dev/null 2>&1)
  # Re-create an identical jam (every file already present in target) and re-merge.
  mkdir -p "$tmp/docs/step-2-planning/jam-$slug/source"
  echo "jam atom one" > "$tmp/docs/step-2-planning/jam-$slug/source/atom1.md"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --into-existing --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "re-graduate exits 0 (no error)" || fail "re-graduate non-zero ($rc): $out"
  cnt="$(ls "$tmp/docs/step-3-specs/$slug/source" | grep -c atom1.md)"
  [ "$cnt" -eq 1 ] && pass "atom1.md present exactly once (no duplication)" || fail "atom1.md count=$cnt"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/source/atom1.md")" = "jam atom one" ] && pass "atom1.md content unchanged (no overwrite)" || fail "atom1.md content changed"
  rm -rf "$tmp"
}

t_merge_refusal_unchanged() {
  echo "[merge-refusal-unchanged] --target orchestrated WITHOUT --into-existing on non-empty target still refuses"
  local slug=gj-fixture-orch tmp out rc
  tmp="$(seed "$FIX/orchestrated/jam-$slug" "$slug")"
  mkdir -p "$tmp/docs/step-3-specs/$slug"
  echo "sentinel" > "$tmp/docs/step-3-specs/$slug/sentinel.md"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target orchestrated --repo-root "$tmp" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "non-zero exit on non-empty target (refusal unchanged)" || fail "should have refused"
  echo "$out" | grep -qF "graduate-jam: target docs/step-3-specs/$slug/ already exists (non-empty)." && pass "literal refusal message" || fail "refusal message wrong"
  [ -d "$tmp/docs/step-2-planning/jam-$slug" ] && pass "source jam left in place" || fail "source jam moved despite refusal"
  [ "$(cat "$tmp/docs/step-3-specs/$slug/sentinel.md")" = "sentinel" ] && pass "sentinel unchanged" || fail "sentinel mutated"
  rm -rf "$tmp"
}

t_out_of_scope() {
  echo "[out-of-scope-write-detector] all changed paths within jam-<slug>/ or specs/<slug>/"
  local slug tmp bad
  for spec in "orchestrated:orchestrated:gj-fixture-orch" "bypass:bypass:gj-fixture-bypass"; do
    local tgt="${spec%%:*}"; local rest="${spec#*:}"; local dir="${rest%%:*}"; slug="${rest#*:}"
    tmp="$(seed "$FIX/$dir/jam-$slug" "$slug")"
    (cd "$REPO_ROOT" && python3 "$GJ" --slug "$slug" --target "$tgt" --repo-root "$tmp" >/dev/null 2>&1)
    bad="$(out_of_bounds "$tmp" "$slug")"
    if [ -z "$bad" ]; then pass "$slug — all writes within bounds"; else fail "$slug — out-of-scope: $bad"; fi
    rm -rf "$tmp"
  done
}

t_slug_validation() {
  echo "[slug-validation] path-traversal + non-kebab slugs rejected"
  # Unit-level: validate_slug raises SystemExit for each bad input, returns good input.
  if GJ_PATH="$GJ" python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gj", os.environ["GJ_PATH"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
bad = ["../etc", "foo/bar", "-leading-dash", "Caps", "", " spaces", ".."]
for b in bad:
    try:
        mod.validate_slug(b); raise AssertionError(f"accepted bad slug {b!r}")
    except SystemExit as e:
        assert e.code != 0, b
assert mod.validate_slug("gj-fixture-orch") == "gj-fixture-orch"
PY
  then pass "validate_slug unit-rejects all bad inputs, accepts a good one"; else fail "validate_slug unit check failed"; fi
  # CLI-level: a representative bad slug emits the 'graduate-jam: invalid slug:' line on stderr.
  local out rc
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug=../etc --target bypass --repo-root "$REPO_ROOT" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && echo "$out" | grep -qE "^graduate-jam: invalid slug:" && pass "CLI rejects --slug=../etc with the invalid-slug line" || fail "CLI invalid-slug path: rc=$rc out=$out"
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --slug=-leading-dash --target bypass --repo-root "$REPO_ROOT" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && echo "$out" | grep -qE "^graduate-jam: invalid slug:" && pass "CLI rejects --slug=-leading-dash" || fail "CLI leading-dash path: rc=$rc out=$out"
}

t_module_attrs() {
  echo "[module-attrs] importable functions + regexes + BRIEF_FILES (AC-001/008/009)"
  if GJ_PATH="$GJ" python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gj", os.environ["GJ_PATH"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
for name in ("main", "validate_slug", "wave_slug_from_header", "discover_intent_artifact"):
    assert callable(getattr(mod, name)), name
assert mod.SLUG_RE.pattern == r'^[a-z0-9][a-z0-9-]*$', mod.SLUG_RE.pattern
assert mod.BRIEF_FILES == ('README.md', 'index.md'), mod.BRIEF_FILES
assert mod.wave_slug_from_header("bar baz") == "bar-baz"
assert mod.wave_slug_from_header("Foo") == "foo"
PY
  then pass "module attributes / regex / BRIEF_FILES / wave_slug_from_header all correct"; else fail "module-attrs check failed"; fi
}

t_help_flags() {
  echo "[help-flags] --help lists all flags; missing required flags exit non-zero (AC-003)"
  local out rc
  out="$(cd "$REPO_ROOT" && python3 "$GJ" --help 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "--help exits 0" || fail "--help non-zero"
  echo "$out" | grep -q -- "--slug" && echo "$out" | grep -q -- "--target" && echo "$out" | grep -q -- "--repo-root" \
    && pass "--help lists --slug/--target/--repo-root" || fail "--help missing a flag"
  (cd "$REPO_ROOT" && python3 "$GJ" >/dev/null 2>&1); [ $? -ne 0 ] && pass "bare invocation exits non-zero" || fail "bare invocation exited 0"
  (cd "$REPO_ROOT" && python3 "$GJ" --slug gj-fixture-orch >/dev/null 2>&1); [ $? -ne 0 ] && pass "--slug-only exits non-zero" || fail "--slug-only exited 0"
}

run_all() {
  local before after
  before="$(git -C "$REPO_ROOT" status --porcelain)"
  t_orchestrated; t_bypass; t_intent_readme; t_intent_fallback; t_intent_absent
  t_target_exists; t_no_waves; t_bad_header; t_out_of_scope
  t_merge_first; t_merge_delta; t_merge_idempotent; t_merge_refusal_unchanged
  t_slug_validation; t_module_attrs; t_help_flags
  after="$(git -C "$REPO_ROOT" status --porcelain)"
  echo "[live-tree-untouched] AC-016 — git status --porcelain identical before/after"
  [ "$before" = "$after" ] && pass "live working tree unchanged by the harness" || fail "harness mutated the live tree"
  echo ""
  echo "RESULT: $PASS passed, $FAIL failed."
  [ "$FAIL" -eq 0 ]
}

case "${1:-all}" in
  orchestrated-fixture) t_orchestrated ;;
  bypass-fixture) t_bypass ;;
  intent-readme-fixture) t_intent_readme ;;
  intent-fallback-fixture) t_intent_fallback ;;
  intent-absent-fixture) t_intent_absent ;;
  target-exists-fixture) t_target_exists ;;
  no-waves-fixture) t_no_waves ;;
  bad-header-fixture) t_bad_header ;;
  out-of-scope-write-detector) t_out_of_scope ;;
  merge-first-fixture) t_merge_first ;;
  merge-delta-fixture) t_merge_delta ;;
  merge-idempotent-fixture) t_merge_idempotent ;;
  merge-refusal-unchanged) t_merge_refusal_unchanged ;;
  slug-validation) t_slug_validation ;;
  module-attrs) t_module_attrs ;;
  help-flags) t_help_flags ;;
  all) run_all ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac

[ "$FAIL" -eq 0 ]
