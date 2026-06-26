#!/usr/bin/env bash
# test-closeout-jam.sh — fixture-driven test harness for closeout-jam.py (ADR-106/107, W1DLP-T9).
#
# Each sub-test runs in an isolated, git-init'd tempdir — the harness NEVER mutates the live repo's working
# tree. Mirrors core/scripts/test-graduate-jam.sh's idiom (seed → run → assert → rm -rf).
#
# Covers (AC-019):
#   gated-no-op       NO-OPS when the produced spec has NOT advanced (the load-bearing assertion)
#   move-on-advance   moves the husk to step-6-done/jams/<slug>/ once the spec advances
#   move-not-delete   no rm/DELETE of jam content — the husk is moved, never deleted
#   idempotent        a re-run after the move is a no-op
#   missing-source    an absent post-graduation home WARNs + exits cleanly
#   stage-only        no commit is produced by the invocation (supports AC-020)
#   slug-safety       path-traversal slugs are rejected
#   help-flag         --help runs
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CJ="$REPO_ROOT/core/scripts/closeout-jam.py"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# seed_jam <slug> <advanced:yes|no> -> prints the tempdir.
# Seeds the post-graduation home docs/step-3-specs/<slug>/ with jam material; when advanced=yes, also
# writes the BUILT-PENDING-MERGE.md advancement marker.
seed_jam() {
  local slug="$1" advanced="$2" tmp
  tmp="$(mktemp -d)"
  local sp="$tmp/docs/step-3-specs/$slug"
  mkdir -p "$sp/source"
  echo "# converged brief for $slug" > "$sp/README.md"
  echo "an original source idea (only tree copy)" > "$sp/source/idea-1.md"
  if [ "$advanced" = "yes" ]; then
    echo "built, awaiting merge" > "$sp/BUILT-PENDING-MERGE.md"
  fi
  git -C "$tmp" init -q
  git -C "$tmp" add -A
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m seed
  echo "$tmp"
}

commit_count() { git -C "$1" rev-list --count HEAD; }

t_gated_no_op() {
  echo "[gated-no-op] NO-OPS when the produced spec has NOT advanced (AC-019 load-bearing)"
  local slug=cj-fixture tmp out
  tmp="$(seed_jam "$slug" no)"
  out="$(cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" 2>&1)"
  echo "$out" | grep -q 'GATED NO-OP' && pass "reports GATED NO-OP" || { fail "did not gate"; echo "    $out" | tail -2; }
  [ -d "$tmp/docs/step-3-specs/$slug" ] && pass "husk stays live at post-graduation home" || fail "husk wrongly moved"
  [ ! -d "$tmp/docs/step-6-done/jams/$slug" ] && pass "husk NOT moved to terminal home" || fail "husk wrongly at terminal home"
  rm -rf "$tmp"
}

t_move_on_advance() {
  echo "[move-on-advance] moves to step-6-done/jams/<slug>/ once the spec advances"
  local slug=cj-fixture tmp
  tmp="$(seed_jam "$slug" yes)"
  (cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" >/dev/null 2>&1)
  [ -d "$tmp/docs/step-6-done/jams/$slug" ] && pass "husk moved to terminal home" || fail "husk not moved"
  [ ! -d "$tmp/docs/step-3-specs/$slug" ] && pass "post-graduation home emptied (git mv)" || fail "source still present"
  rm -rf "$tmp"
}

t_move_not_delete() {
  echo "[move-not-delete] jam content (incl. only-tree-copy source ideas) survives the move"
  local slug=cj-fixture tmp
  tmp="$(seed_jam "$slug" yes)"
  (cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" >/dev/null 2>&1)
  [ -f "$tmp/docs/step-6-done/jams/$slug/README.md" ] && pass "brief preserved at terminal home" || fail "brief lost"
  [ -f "$tmp/docs/step-6-done/jams/$slug/source/idea-1.md" ] && pass "only-tree-copy source idea preserved" || fail "source idea lost (DELETE not MOVE)"
  # the script source carries no destructive delete of jam content
  grep -qE '\bshutil\.rmtree\b|\bos\.remove\b|subprocess.*\["rm"' "$CJ" && fail "closeout-jam.py contains a destructive delete" || pass "no destructive delete in closeout-jam.py"
  rm -rf "$tmp"
}

t_idempotent() {
  echo "[idempotent] a re-run after the move is a no-op"
  local slug=cj-fixture tmp out
  tmp="$(seed_jam "$slug" yes)"
  (cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" >/dev/null 2>&1)
  out="$(cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" 2>&1)"
  echo "$out" | grep -q 'already at terminal home' && pass "re-run reports already-moved no-op" || { fail "re-run did not no-op"; echo "    $out" | tail -2; }
  rm -rf "$tmp"
}

t_missing_source() {
  echo "[missing-source] an absent post-graduation home WARNs + exits cleanly"
  local tmp out rc
  tmp="$(seed_jam cj-present yes)"
  out="$(cd "$REPO_ROOT" && python3 "$CJ" cj-absent --repo-root "$tmp" 2>&1)"; rc=$?
  echo "$out" | grep -qiE 'not found|missing source' && pass "absent source WARNs" || { fail "no WARN on absent source"; echo "    $out" | tail -2; }
  [ "$rc" -eq 0 ] && pass "exits cleanly (rc=0) on absent source" || fail "non-zero exit on absent source (rc=$rc)"
  rm -rf "$tmp"
}

t_stage_only() {
  echo "[stage-only] no commit produced by the invocation (AC-020)"
  local slug=cj-fixture tmp before after
  tmp="$(seed_jam "$slug" yes)"
  before="$(commit_count "$tmp")"
  (cd "$REPO_ROOT" && python3 "$CJ" "$slug" --repo-root "$tmp" >/dev/null 2>&1)
  after="$(commit_count "$tmp")"
  [ "$before" = "$after" ] && pass "no commit produced (before=$before after=$after)" || fail "invocation produced a commit"
  git -C "$tmp" diff --cached --quiet && fail "nothing staged (move not staged)" || pass "the move is staged in the index"
  rm -rf "$tmp"
}

t_slug_safety() {
  echo "[slug-safety] path-traversal slugs are rejected"
  local tmp rc
  tmp="$(seed_jam cj-present yes)"
  (cd "$REPO_ROOT" && python3 "$CJ" "../etc" --repo-root "$tmp" >/dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] && pass "traversal slug '../etc' rejected" || fail "traversal slug accepted"
  rm -rf "$tmp"
}

t_help_flag() {
  echo "[help-flag] --help runs"
  (cd "$REPO_ROOT" && python3 "$CJ" --help >/dev/null 2>&1) && pass "--help runs" || fail "--help failed"
}

run_all() {
  t_gated_no_op
  t_move_on_advance
  t_move_not_delete
  t_idempotent
  t_missing_source
  t_stage_only
  t_slug_safety
  t_help_flag
}

case "${1:-all}" in
  all) run_all ;;
  gated-no-op) t_gated_no_op ;;
  move-on-advance) t_move_on_advance ;;
  move-not-delete) t_move_not_delete ;;
  idempotent) t_idempotent ;;
  missing-source) t_missing_source ;;
  stage-only) t_stage_only ;;
  slug-safety) t_slug_safety ;;
  help-flag) t_help_flag ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac

echo ""
echo "=== test-closeout-jam.sh: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
