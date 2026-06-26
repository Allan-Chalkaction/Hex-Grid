#!/usr/bin/env bash
# test-merge-orchestrate.sh — fixture-driven harness for merge-orchestrate.py (ADR-071 Part 2).
#
# Each sub-test runs in an isolated git fixture repo in $TMPDIR — the harness NEVER mutates the
# live repo's working tree or refs. The fixture is git-init'd, seeded with branches, and the
# script is invoked against that fixture's root via cwd. A fake `git` shim on PATH is used in the
# never-push/never-reset assertions so the harness can prove no forbidden invocation ever leaves
# the script even at runtime, regardless of fixture state.
#
# Subcommands (no arg = run all):
#   clean-merge          textual conflict halts, tree left clean, branch blocked, no auto-resolve
#   conflict-halt
#   deterministic-order  recommended order is stable across two invocations
#   never-push-reset     greps the script for forbidden tokens + fake-git-shim runtime check
#   atomic-state         state writes are atomic, terminal statuses honored on resume
#   resume-honors-done
#   too-many-branches    >6 branches refused
#   post-merge-gate-red  failing test command halts at the gate (branch stays merged)
#   help-flags
#   structural-invariants  defensive guard refuses on direct push/reset --hard injection
#   argv-injection-rejected  SA-001: flag-shaped base ref / branch name refused; --exec= canary not exec'd
#   dirty-tree-refused      CR-002: merge-next on a dirty tree halts 'refused', operator edit preserved
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MO="$REPO_ROOT/core/scripts/merge-orchestrate.py"

PASS=0
FAIL=0
pass() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# ---- fixture builders ------------------------------------------------------

# fixture_clean: a repo with main + two non-conflicting feature branches (different files).
# Echoes the tmp dir path. The run-dir for state files lives in a SIBLING tmp dir (NOT inside
# the fixture's working tree) so "tree clean" assertions aren't tripped by the untracked
# run-dir. The fixture also gitignores runs/ defensively.
fixture_clean() {
  local tmp; tmp="$(mktemp -d)"
  git -C "$tmp" init -q -b main
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  echo "main initial" > "$tmp/main.txt"
  echo "runs/" > "$tmp/.gitignore"
  git -C "$tmp" add main.txt .gitignore
  git -C "$tmp" commit -q -m "init main"
  # branch A — adds a.txt
  git -C "$tmp" checkout -q -b feature/foo
  echo "foo content" > "$tmp/a.txt"
  git -C "$tmp" add a.txt
  git -C "$tmp" commit -q -m "feat(foo): add a.txt"
  # branch B — adds b.txt
  git -C "$tmp" checkout -q main
  git -C "$tmp" checkout -q -b feature/bar
  echo "bar content" > "$tmp/b.txt"
  git -C "$tmp" add b.txt
  git -C "$tmp" commit -q -m "feat(bar): add b.txt"
  git -C "$tmp" checkout -q main
  echo "$tmp"
}

# fixture_textual_conflict: main + branch that conflicts textually on shared.txt.
# Same run-dir-outside-tree discipline as fixture_clean.
fixture_textual_conflict() {
  local tmp; tmp="$(mktemp -d)"
  git -C "$tmp" init -q -b main
  git -C "$tmp" config user.email t@t
  git -C "$tmp" config user.name t
  echo "line A from main" > "$tmp/shared.txt"
  echo "runs/" > "$tmp/.gitignore"
  git -C "$tmp" add shared.txt .gitignore
  git -C "$tmp" commit -q -m "init main with shared.txt"
  # branch off
  git -C "$tmp" checkout -q -b feature/conflict
  echo "line A from branch (different)" > "$tmp/shared.txt"
  git -C "$tmp" add shared.txt
  git -C "$tmp" commit -q -m "feat(conflict): change shared.txt"
  # main advances on the same file (conflict territory)
  git -C "$tmp" checkout -q main
  echo "line A from main, evolved" > "$tmp/shared.txt"
  git -C "$tmp" add shared.txt
  git -C "$tmp" commit -q -m "main: evolve shared.txt"
  echo "$tmp"
}

# ---- tests -----------------------------------------------------------------

t_clean_merge() {
  echo "[clean-merge] two non-conflicting branches land cleanly, state -> done"
  local tmp run out
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  out="$(cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/foo feature/bar 2>&1)" \
    && pass "init succeeds" || { fail "init failed: $out"; return; }
  # state file exists
  [ -f "$run/merge-state.json" ] && pass "merge-state.json created" || fail "merge-state.json missing"
  # merge first branch
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"
  echo "$out" | grep -qE "AGENT_GATE_PENDING branch=feature/foo" && pass "first merge AGENT_GATE_PENDING" || fail "no AGENT_GATE_PENDING: $out"
  echo "$out" | grep -qE "status=clean branch=feature/foo" && pass "first merge clean" || fail "first merge not clean: $out"
  # state reflects done
  python3 -c "
import json,sys
s=json.load(open('$run/merge-state.json'))
assert s['branches'][0]['status']=='done', s['branches'][0]
assert s['branches'][0]['merge_sha'], 'no merge_sha'
" && pass "branch 0 status=done with merge_sha" || fail "branch 0 state wrong"
  # second branch
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"
  echo "$out" | grep -qE "AGENT_GATE_PENDING branch=feature/bar" && pass "second merge AGENT_GATE_PENDING" || fail "second merge no AGENT_GATE_PENDING: $out"
  # final pass: COMPLETE
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"
  echo "$out" | grep -qE "status=complete" && pass "next call after all done -> COMPLETE" || fail "not COMPLETE: $out"
  # working tree clean on main
  [ -z "$(git -C "$tmp" status --porcelain)" ] && pass "working tree clean after clean merges" || fail "working tree dirty: $(git -C "$tmp" status --porcelain)"
  rm -rf "$tmp"
}

t_conflict_halt() {
  echo "[conflict-halt] textual conflict HALTS: non-zero, tree CLEAN, branch blocked, no resolution"
  local tmp run out rc
  tmp="$(fixture_textual_conflict)"
  run="$tmp/runs"
  (cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/conflict >/dev/null 2>&1) || { fail "init failed"; return; }
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "merge-next exits non-zero on conflict" || fail "merge-next did NOT exit non-zero (rc=$rc): $out"
  echo "$out" | grep -qE "status=halted reason=rebase_conflict" && pass "halt-reason=rebase_conflict surfaced" || fail "halt-reason wrong: $out"
  echo "$out" | grep -qE "HALT-PAYLOAD: " && pass "structured HALT-PAYLOAD emitted" || fail "no HALT-PAYLOAD: $out"
  # working tree is left CLEAN (rebase --abort restored it)
  [ -z "$(git -C "$tmp" status --porcelain)" ] && pass "working tree CLEAN after halt (rebase --abort fired)" || fail "tree dirty after halt: $(git -C "$tmp" status --porcelain)"
  # branch is blocked in state
  python3 -c "
import json
s=json.load(open('$run/merge-state.json'))
assert s['branches'][0]['status']=='blocked', s['branches'][0]
assert s['halted'] is True, s
assert s['halt_reason']=='rebase_conflict', s
" && pass "state: branch blocked, top-level halted=true" || fail "state shape wrong"
  # nothing landed on main — main HEAD is the pre-merge main commit.
  # The fixture sets up: init (shared.txt + .gitignore) -> branch off -> main evolves shared.txt.
  # So main is at 2 commits BEFORE merge-next; a successful merge would add 1 more.
  main_log_count=$(git -C "$tmp" log --oneline main | wc -l | tr -d ' ')
  [ "$main_log_count" -eq 2 ] && pass "main HEAD unchanged (no auto-resolution)" || fail "main has $main_log_count commits (expected 2)"
  rm -rf "$tmp"
}

t_deterministic_order() {
  echo "[deterministic-order] scan order is stable across two invocations"
  local tmp out1 out2
  tmp="$(fixture_clean)"
  out1="$(cd "$tmp" && python3 "$MO" scan --base main feature/foo feature/bar 2>&1 | tail -1)"
  out2="$(cd "$tmp" && python3 "$MO" scan --base main feature/foo feature/bar 2>&1 | tail -1)"
  [ "$out1" = "$out2" ] && pass "scan summary identical across two runs" || fail "scan output drift: '$out1' vs '$out2'"
  # Also: reordering the input doesn't change the recommended order (it's sorted, deterministic).
  local out3
  out3="$(cd "$tmp" && python3 "$MO" scan --base main feature/bar feature/foo 2>&1 | tail -1)"
  [ "$out1" = "$out3" ] && pass "scan order invariant under input reordering" || fail "input reordering changed order: '$out1' vs '$out3'"
  rm -rf "$tmp"
}

t_never_push_reset() {
  echo "[never-push-reset] script source contains NO forbidden git verbs in subprocess calls"
  # Static grep: look for `"push"` / `"reset", "--hard"` / `"--force"` in arg LISTS.
  # The forbidden tokens may appear in error/string messages (those are the refusal text) —
  # but the actual subprocess invocations should never contain them outside _refuse_forbidden.
  # We assert that every mutating subprocess in the script goes through _guarded_git
  # (which calls _refuse_forbidden).
  local bad
  # Look for any direct ["push", or "--force" in a subprocess-shaped invocation. The script
  # uses subprocess.run only via _git (which is wrapped); direct subprocess.run with git args
  # outside _git/_guarded_git would be a regression.
  bad=$(grep -nE 'subprocess\.run\(\s*\["git"' "$MO" | grep -vE '"git", "merge-tree"' || true)
  if [ -n "$bad" ]; then
    fail "direct subprocess.run(['git', ...]) call(s) found that bypass the _guarded_git wrapper:"
    echo "$bad" | sed 's/^/        /'
  else
    pass "all git mutations route through _guarded_git wrapper"
  fi
  # Token sweep: literal forbidden tokens MUST NOT appear in arg-list shapes.
  bad=$(grep -nE '\["push"' "$MO" || true)
  [ -z "$bad" ] && pass "no \"push\" git-arg lists in script" || { fail "found push arg list: $bad"; }
  bad=$(grep -nE '"reset",.*"--hard"' "$MO" || true)
  [ -z "$bad" ] && pass "no reset --hard arg lists in script" || { fail "found reset --hard: $bad"; }
  # The script contains "--force" tokens in three legitimate places:
  #   1. The _refuse_forbidden guard (checks for and rejects these tokens in git args).
  #   2. The init subcommand's `--force` argparse flag (CLI flag to overwrite state file —
  #      a SCRIPT flag, never passed to git).
  #   3. Docstring / comment text describing the refusal.
  # The forbidden case is a literal git-arg-list shape: ["push", "--force", ...]. The static
  # check above (`grep -nE '"push"' / '"reset",.*"--hard"'`) already covers git-arg lists.
  # Here we additionally verify there is no `_guarded_git(` or `_git(` invocation whose arg
  # list contains a force token. If grep finds none, we're done.
  bad=$(grep -nE '_(guarded_)?git\([^)]*--force' "$MO" || true)
  [ -z "$bad" ] && pass "no _git / _guarded_git invocation contains --force" || fail "force-flag in git invocation: $bad"

  # Runtime: a fake git on PATH that records every invocation; run a clean merge and confirm
  # no `push`, `reset --hard`, or `--force` ever appears in the call log.
  local tmp run shim_dir log
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  shim_dir="$(mktemp -d)"
  log="$shim_dir/git-calls.log"
  # The shim records args and delegates to the real git.
  REAL_GIT="$(command -v git)"
  cat > "$shim_dir/git" <<SHIM
#!/usr/bin/env bash
echo "git \$*" >> "$log"
exec "$REAL_GIT" "\$@"
SHIM
  chmod +x "$shim_dir/git"
  # Run the workflow under the shim.
  PATH="$shim_dir:$PATH" python3 "$MO" init --base main --run-dir "$run" feature/foo feature/bar >/dev/null 2>&1 \
    && PATH="$shim_dir:$PATH" bash -c "cd '$tmp' && python3 '$MO' merge-next --run-dir '$run'" >/dev/null 2>&1 \
    && PATH="$shim_dir:$PATH" bash -c "cd '$tmp' && python3 '$MO' merge-next --run-dir '$run'" >/dev/null 2>&1
  # Inspect the log.
  if grep -qE "^git push" "$log"; then
    fail "fake git shim recorded a 'git push' call"
    grep -E "^git push" "$log" | head -3 | sed 's/^/        /'
  else
    pass "no 'git push' recorded by fake git shim"
  fi
  if grep -qE "^git reset --hard" "$log"; then
    fail "fake git shim recorded 'git reset --hard'"
  else
    pass "no 'git reset --hard' recorded by fake git shim"
  fi
  if grep -qE -- "--force(-with-lease)?" "$log"; then
    fail "fake git shim recorded --force / --force-with-lease usage"
    grep -E -- "--force" "$log" | head -3 | sed 's/^/        /'
  else
    pass "no --force / --force-with-lease recorded by fake git shim"
  fi
  rm -rf "$tmp" "$shim_dir"
}

t_atomic_state() {
  echo "[atomic-state] state file is written via tmp+rename, terminal statuses preserved on resume"
  local tmp run
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  (cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/foo feature/bar >/dev/null 2>&1) || { fail "init failed"; return; }
  # Inspect: the script uses os.replace for atomicity. Static check: the script defines
  # _atomic_write_json and writes via that. Grep for it.
  grep -q "_atomic_write_json" "$MO" && pass "script defines _atomic_write_json helper" || fail "no atomic-write helper"
  grep -q "os.replace" "$MO" && pass "script uses os.replace for atomicity" || fail "no os.replace"
  # Run first merge -> mark first branch done.
  (cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" >/dev/null 2>&1) || { fail "merge-next 1 failed"; return; }
  # Manually mutate state to mark second branch 'skipped' and verify resume honors it.
  python3 -c "
import json
p='$run/merge-state.json'
s=json.load(open(p))
s['branches'][1]['status']='skipped'
import tempfile, os
tmp=p+'.t'
open(tmp,'w').write(json.dumps(s,indent=2))
os.replace(tmp,p)
"
  out="$(cd "$tmp" && python3 "$MO" resume --run-dir "$run" 2>&1)"
  echo "$out" | grep -qE "status=complete" && pass "resume honors terminal 'skipped' status (treats run COMPLETE)" || fail "resume did not honor terminal status: $out"
  rm -rf "$tmp"
}

t_resume_honors_done() {
  echo "[resume-honors-done] resume after a halt re-attempts blocked branch only"
  local tmp run out
  tmp="$(fixture_textual_conflict)"
  run="$tmp/runs"
  (cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/conflict >/dev/null 2>&1) || { fail "init failed"; return; }
  # First merge-next: halt
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)" || true
  # Resume without fixing -> the rebase will still conflict, halt again.
  out="$(cd "$tmp" && python3 "$MO" resume --run-dir "$run" 2>&1)" || true
  echo "$out" | grep -qE "status=halted" && pass "resume re-halts (conflict not resolved)" || fail "resume did not halt: $out"
  # Working tree still clean (runs/ is .gitignored by the fixture so it doesn't count).
  [ -z "$(git -C "$tmp" status --porcelain)" ] && pass "tree still CLEAN after resume halt" || fail "tree dirty after resume: $(git -C "$tmp" status --porcelain)"
  rm -rf "$tmp"
}

t_too_many_branches() {
  echo "[too-many-branches] >6 branches refused"
  local tmp out rc
  tmp="$(mktemp -d)"
  git -C "$tmp" init -q -b main
  git -C "$tmp" config user.email t@t; git -C "$tmp" config user.name t
  echo x > "$tmp/x.txt"; git -C "$tmp" add x.txt; git -C "$tmp" commit -q -m init
  for i in 1 2 3 4 5 6 7; do git -C "$tmp" branch "feature/b$i"; done
  out="$(cd "$tmp" && python3 "$MO" init --base main --run-dir "$tmp/r" feature/b1 feature/b2 feature/b3 feature/b4 feature/b5 feature/b6 feature/b7 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "init refused 7 branches (rc=$rc)" || fail "init accepted 7 branches"
  echo "$out" | grep -qF "refusing >6 branches per run" && pass "refusal message present" || fail "refusal message wrong: $out"
  # Same on scan.
  out="$(cd "$tmp" && python3 "$MO" scan --base main feature/b1 feature/b2 feature/b3 feature/b4 feature/b5 feature/b6 feature/b7 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "scan refused 7 branches" || fail "scan accepted 7 branches"
  rm -rf "$tmp"
}

t_post_merge_gate_red() {
  echo "[post-merge-gate-red] failing test command halts at the gate, branch stays merged"
  local tmp run out rc
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  # Configure a failing test command via project-paths.sh. The CR-002 dirty-tree guard
  # refuses to run merge-next on an untracked tree, so extend the fixture's .gitignore
  # to also exclude .claude/ (the project-paths.sh lives there).
  echo ".claude/" >> "$tmp/.gitignore"
  git -C "$tmp" add .gitignore && git -C "$tmp" commit -q -m "gitignore .claude/"
  mkdir -p "$tmp/.claude"
  cat > "$tmp/.claude/project-paths.sh" <<'EOF'
export TYPECHECK_CMD="true"
export TEST_CMD="false"
EOF
  (cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/foo >/dev/null 2>&1) || { fail "init failed"; return; }
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "merge-next exits non-zero on red gate" || fail "merge-next did NOT exit non-zero (rc=$rc): $out"
  echo "$out" | grep -qE "halt_reason.*post_merge_gate_red" && pass "halt_reason=post_merge_gate_red surfaced" || fail "halt_reason wrong: $out"
  # Branch still merged (post_gate_verdict=red) — not auto-reverted.
  python3 -c "
import json
s=json.load(open('$run/merge-state.json'))
assert s['branches'][0]['merge_sha'], 'no merge_sha recorded'
assert s['branches'][0]['post_gate_verdict']=='red', s['branches'][0]
assert s['branches'][0]['status']=='in_progress', s['branches'][0]  # halted mid-loop
" && pass "branch stays merged (sha recorded), post_gate=red, no auto-revert" || fail "post-merge state wrong"
  # Report file present.
  ls "$run/per-branch/feature-foo/post-merge-gate-report.md" >/dev/null 2>&1 && pass "per-branch gate report written" || fail "no gate report"
  rm -rf "$tmp"
}

t_help_flags() {
  echo "[help-flags] --help works on the script and every subcommand"
  local rc
  python3 "$MO" --help >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 0 ] && pass "top-level --help exits 0" || fail "top-level --help non-zero (rc=$rc)"
  for sub in scan preflight init merge-next status resume; do
    python3 "$MO" "$sub" --help >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] && pass "$sub --help exits 0" || fail "$sub --help non-zero"
  done
  python3 "$MO" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] && pass "bare invocation exits non-zero" || fail "bare invocation exited 0"
}

t_structural_invariants() {
  echo "[structural-invariants] the defensive guard refuses forbidden args"
  # Spawn a tiny python that imports the module and calls _refuse_forbidden directly.
  if MO_PATH="$MO" python3 - <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("mo", os.environ["MO_PATH"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
# push -> SystemExit
def _expect_die(args, label):
    try:
        mod._refuse_forbidden(args)
    except SystemExit as e:
        assert e.code != 0, label
        return
    raise AssertionError(f"{label}: _refuse_forbidden did NOT die on {args}")
_expect_die(["push", "origin", "main"], "push")
_expect_die(["reset", "--hard", "HEAD~1"], "reset --hard")
_expect_die(["push", "--force", "origin", "main"], "push --force")
_expect_die(["branch", "--force-with-lease"], "--force-with-lease")
# SA-001 / SA-006: scan ALL positions for push/reset --hard, not just args[0].
_expect_die(["-C", "/tmp", "push", "origin", "main"], "push mid-args (SA-006)")
_expect_die(["-C", "/tmp", "reset", "--hard", "HEAD"], "reset --hard mid-args (SA-006)")
# RCE-flag rejection (token form + =value form).
_expect_die(["rebase", "--exec=touch /tmp/pwn"], "rebase --exec= (SA-001)")
_expect_die(["rebase", "--exec", "touch /tmp/pwn"], "rebase --exec token (SA-001)")
_expect_die(["fetch", "--upload-pack=/tmp/evil"], "fetch --upload-pack= (SA-001)")
_expect_die(["push", "--receive-pack=/tmp/evil"], "push --receive-pack= (SA-001)")
# allowed verbs MUST NOT die
for ok in (["checkout","main"],["merge","--squash","feature/x"],["rebase","main"],["status","--porcelain"]):
    mod._refuse_forbidden(ok)  # raises only if violated
PY
  then
    pass "_refuse_forbidden dies on push/reset --hard/--force/RCE flags, allows safe verbs"
  else
    fail "_refuse_forbidden guard check failed"
  fi
}

t_argv_injection_rejected() {
  echo "[argv-injection-rejected] flag-shaped base ref / branch name refused (SA-001)"
  local tmp run out rc canary
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  # An unpredictable canary so a parallel test run can't false-positive on a stale file.
  canary="/tmp/pwn-merge-test-$$-$RANDOM"
  rm -f "$canary"
  # 1) --base shaped as --exec=… (the documented git-rebase RCE vector).
  out="$(cd "$tmp" && python3 "$MO" init --base "--exec=touch $canary" --run-dir "$run" feature/foo 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "init refuses --base=--exec=… (rc=$rc)" \
    || fail "init accepted --base=--exec=… (rc=$rc)"
  [ ! -e "$canary" ] && pass "RCE canary NOT created" \
    || { fail "RCE canary WAS created at $canary"; rm -f "$canary"; }
  # 2) Flag-shaped branch name (leading '-'). Use argparse's `--` end-of-flags so the
  # leading '-' reaches _validate_ref rather than tripping argparse first. Either path is
  # a refusal (argparse error / our explicit message); the explicit message proves
  # _validate_ref is what blocked it.
  out="$(cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" -- "-bad-branch" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "init refuses flag-shaped branch name '-bad-branch'" \
    || fail "init accepted flag-shaped branch name"
  echo "$out" | grep -qE "refusing flag-shaped ref" \
    && pass "leading-'-' ref rejected with explicit _validate_ref message" \
    || fail "leading-'-' ref refusal message wrong: $out"
  # Without --, argparse rejects it first — that's also a refusal (defense in depth).
  out="$(cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" "-bad-branch" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "init refuses flag-shaped branch name (argparse layer)" \
    || fail "init accepted flag-shaped branch name (no -- guard)"
  # 3) Bad ref shape (caught by git check-ref-format — '..' is disallowed in refs).
  out="$(cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" "bad..ref" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "init refuses bad ref shape 'bad..ref'" \
    || fail "init accepted bad ref shape"
  # 4) The same guards apply on scan + preflight (every CLI ref entry point).
  out="$(cd "$tmp" && python3 "$MO" scan --base "--exec=touch $canary" feature/foo 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "scan refuses --base=--exec=… (rc=$rc)" \
    || fail "scan accepted --base=--exec=…"
  out="$(cd "$tmp" && python3 "$MO" preflight --base main "--exec=touch $canary" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "preflight refuses --exec=…-shaped branch name (rc=$rc)" \
    || fail "preflight accepted --exec=…-shaped branch name"
  [ ! -e "$canary" ] && pass "RCE canary STILL not created after scan + preflight attempts" \
    || { fail "RCE canary created during scan/preflight"; rm -f "$canary"; }
  # 5) Direct unit-test on _validate_ref via Python import (no shell-arg layer).
  if MO_PATH="$MO" python3 - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("mo", os.environ["MO_PATH"])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
def _expect_die(ref, label):
    try:
        mod._validate_ref(ref)
    except SystemExit as e:
        assert e.code != 0, label
        return
    raise AssertionError(f"{label}: _validate_ref did NOT die on {ref!r}")
_expect_die("", "empty ref")
_expect_die(None, "None ref")
_expect_die("-bad", "leading-dash")
_expect_die("--exec=touch /tmp/x", "flag-shaped --exec=")
_expect_die("bad..ref", "bad..ref (check-ref-format)")
_expect_die(".starts-with-dot", "leading-dot")
_expect_die("has\nnewline", "newline in ref")
_expect_die("has\x00null", "NUL in ref")
# good refs MUST NOT die
for ok in ("main", "feature/foo", "fix/issue-123", "chore/release-v2.1"):
    mod._validate_ref(ok)
PY
  then
    pass "_validate_ref unit test passes (rejects bad shapes, accepts good refs)"
  else
    fail "_validate_ref unit test failed"
  fi
  rm -rf "$tmp"
  rm -f "$canary"
}

t_dirty_tree_refused() {
  echo "[dirty-tree-refused] merge-next halts 'refused' on a dirty working tree, preserves edits (CR-002)"
  local tmp run out rc edit_before edit_after
  tmp="$(fixture_clean)"
  run="$tmp/runs"
  (cd "$tmp" && python3 "$MO" init --base main --run-dir "$run" feature/foo feature/bar >/dev/null 2>&1) \
    || { fail "init failed"; return; }
  # Dirty the working tree: modify the tracked main.txt with operator content the script
  # MUST NOT overwrite.
  edit_before="operator-WIP-do-not-clobber-$RANDOM"
  echo "$edit_before" > "$tmp/main.txt"
  # Confirm the tree IS dirty before merge-next.
  [ -n "$(git -C "$tmp" status --porcelain)" ] && pass "working tree dirty before merge-next" \
    || fail "fixture failed to dirty the tree"
  # merge-next must halt with reason=refused.
  out="$(cd "$tmp" && python3 "$MO" merge-next --run-dir "$run" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && pass "merge-next exits non-zero on dirty tree (rc=$rc)" \
    || fail "merge-next accepted dirty tree (rc=$rc): $out"
  echo "$out" | grep -qE "status=halted reason=refused" \
    && pass "halt_reason=refused surfaced for dirty tree" \
    || fail "halt_reason wrong on dirty tree: $out"
  # The operator's edit MUST be preserved on disk.
  edit_after="$(cat "$tmp/main.txt")"
  [ "$edit_after" = "$edit_before" ] \
    && pass "operator edit PRESERVED (no silent overwrite)" \
    || fail "operator edit was discarded — expected '$edit_before' got '$edit_after'"
  # The state should reflect run-level halt (halt_branch=null since no branch was selected).
  python3 -c "
import json
s=json.load(open('$run/merge-state.json'))
assert s['halted'] is True, s
assert s['halt_reason']=='refused', s
# No branch was selected (we halted BEFORE _next_pending).
assert s.get('halt_branch') in (None, ''), s
# No branch became in_progress.
assert s['branches'][0]['status']=='pending', s['branches'][0]
" && pass "state: halted=true, halt_reason=refused, branches still pending" \
    || fail "state shape wrong after dirty-tree halt"
  rm -rf "$tmp"
}

# ---- harness wrap ----------------------------------------------------------

run_all() {
  local before after
  before="$(git -C "$REPO_ROOT" status --porcelain)"
  t_clean_merge
  t_conflict_halt
  t_deterministic_order
  t_never_push_reset
  t_atomic_state
  t_resume_honors_done
  t_too_many_branches
  t_post_merge_gate_red
  t_help_flags
  t_structural_invariants
  t_argv_injection_rejected
  t_dirty_tree_refused
  after="$(git -C "$REPO_ROOT" status --porcelain)"
  echo "[live-tree-untouched] git status --porcelain identical before/after on the REAL repo"
  [ "$before" = "$after" ] && pass "live working tree unchanged by harness" || fail "harness mutated the live tree"
  echo ""
  echo "RESULT: $PASS passed, $FAIL failed."
  [ "$FAIL" -eq 0 ]
}

case "${1:-all}" in
  clean-merge)            t_clean_merge ;;
  conflict-halt)          t_conflict_halt ;;
  deterministic-order)    t_deterministic_order ;;
  never-push-reset)       t_never_push_reset ;;
  atomic-state)           t_atomic_state ;;
  resume-honors-done)     t_resume_honors_done ;;
  too-many-branches)      t_too_many_branches ;;
  post-merge-gate-red)    t_post_merge_gate_red ;;
  help-flags)             t_help_flags ;;
  structural-invariants)  t_structural_invariants ;;
  argv-injection-rejected) t_argv_injection_rejected ;;
  dirty-tree-refused)     t_dirty_tree_refused ;;
  all) run_all ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac

[ "$FAIL" -eq 0 ]
