#!/usr/bin/env bash
# core/scripts/tests/test-watch-mirror.sh
#
# Test suite for the OBS-W2-WATCH live-mirror watcher
# (`core/scripts/watch-run-artifacts.sh`).
#
# Cases (ticket T-004 description):
#   1. writes-confined-to-run-dir   (AC-031) — only writes under <run-dir>/
#   2. no-race-with-persist         (AC-032) — running watcher + persist is
#                                              indistinguishable from persist alone
#                                              (no conflicting content, no orphans
#                                              outside findings/, persist's output
#                                              fully intact)
#   3. no-manifest-writes           (AC-033) — no manifest.json written/updated
#   4. kill-mid-run-then-persist    (AC-034) — kill the watcher mid-run; persist
#                                              still produces a clean result
#   5. end-to-end-fixture           (AC-036) — exercises the watcher against
#                                              fixtures/journal-fallback/agent-sample.jsonl
#                                              (the same fixture as PERSIST)
#
# All cases are runnable via `--case <name>` (default: run all).
#
# AC-035 (DRY — watcher sources the same path-resolution helper as PERSIST) is
# verified by a code-side grep — the watcher's `.` line sources
# `core/scripts/lib/native-transcript-path.sh`. Captured here as the
# `helper-sourced` case for CI.

set -eo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$THIS_DIR/../../.." && pwd)"
WATCHER="$REPO_ROOT/core/scripts/watch-run-artifacts.sh"
PERSIST="$REPO_ROOT/core/scripts/persist-run-artifacts.py"
FIXTURE_DIR="$THIS_DIR/fixtures/journal-fallback"
FIXTURE_JSONL="$FIXTURE_DIR/agent-sample.jsonl"
FIXTURE_META="$FIXTURE_DIR/agent-sample.meta.json"

PASS=0
FAIL=0
ONLY_CASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --case) ONLY_CASE="$2"; shift 2 ;;
    -h|--help) sed -n '3,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- helpers ----------------------------------------------------------------

# Set up a per-case tmp environment shaped like the PERSIST tests:
#   - tmp_home: HOME for the test, with ~/.claude/projects/<slug>/<session>/subagents/agent-X.jsonl
#   - tmp_repo: a tiny git repo so git rev-parse --git-common-dir resolves
#   - copies fixture jsonl + meta into the fake subagents/ dir under a chosen agent id
# Args: $1 = case_name, $2 = session_id (default), $3 = agent_id (default)
# Echoes (one per line): tmp_home tmp_repo session_id agent_id jsonl_path subagents_dir
_setup_env() {
  local case_name="$1"
  local sess="${2:-test-session-$RANDOM-$$}"
  local agt="${3:-atestagent0000001}"
  local TMP_HOME TMP_REPO
  TMP_HOME=$(mktemp -d "/tmp/watch-${case_name}-XXXXXX")
  TMP_REPO=$(mktemp -d "/tmp/watch-repo-${case_name}-XXXXXX")

  ( cd "$TMP_REPO" && git init -q && git -c user.email=t@t -c user.name=t commit \
       --allow-empty -q -m "init" ) >/dev/null 2>&1

  local SLUG
  SLUG=$(echo "$TMP_REPO" | sed 's|/|-|g')
  local SUBAGENTS_DIR="$TMP_HOME/.claude/projects/$SLUG/$sess/subagents"
  mkdir -p "$SUBAGENTS_DIR"
  cp "$FIXTURE_JSONL" "$SUBAGENTS_DIR/agent-${agt}.jsonl"
  cp "$FIXTURE_META"  "$SUBAGENTS_DIR/agent-${agt}.meta.json"

  echo "$TMP_HOME"
  echo "$TMP_REPO"
  echo "$sess"
  echo "$agt"
  echo "$SUBAGENTS_DIR/agent-${agt}.jsonl"
  echo "$SUBAGENTS_DIR"
}

_cleanup_env() {
  local TMP_HOME="$1"; local TMP_REPO="$2"
  [ -n "$TMP_HOME" ] && [ -d "$TMP_HOME" ] && rm -rf "$TMP_HOME"
  [ -n "$TMP_REPO" ] && [ -d "$TMP_REPO" ] && rm -rf "$TMP_REPO"
}

# Run the watcher (always --once, --session SESS). Args:
#   $1 TMP_HOME, $2 TMP_REPO, $3 session_id, $4 run_dir, $5+ extra args
# Stdout to WATCH_STDOUT, stderr to WATCH_STDERR. Returns exit code.
_run_watch_once() {
  local TMP_HOME="$1"; local TMP_REPO="$2"; local SESS="$3"; local RUN_DIR="$4"; shift 4
  WATCH_STDOUT=$(mktemp); WATCH_STDERR=$(mktemp)
  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" \
    bash "$WATCHER" --run-dir "$RUN_DIR" --session "$SESS" --once "$@"
  ) >"$WATCH_STDOUT" 2>"$WATCH_STDERR"
  local rc=$?
  set -e
  return $rc
}

# Run persist (dropped-return / journal-fallback path).
_run_persist() {
  local TMP_HOME="$1"; local TMP_REPO="$2"; local SESS="$3"; local RUN_DIR="$4"; shift 4
  PERSIST_STDOUT=$(mktemp); PERSIST_STDERR=$(mktemp)
  set +e
  (
    cd "$TMP_REPO"
    HOME="$TMP_HOME" \
    CLAUDE_CODE_SESSION_ID="$SESS" \
    python3 "$PERSIST" --run-dir "$RUN_DIR" --no-manifest "$@"
  ) >"$PERSIST_STDOUT" 2>"$PERSIST_STDERR"
  local rc=$?
  set -e
  return $rc
}

_pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

_skip() { [ -n "$ONLY_CASE" ] && [ "$ONLY_CASE" != "$1" ]; }

# Capture the inode + mtime + size of all files under a tree, deterministically.
# Used to detect "nothing was written" / "set unchanged" assertions.
_snapshot_tree() {
  local root="$1"
  if [ ! -d "$root" ]; then echo ""; return 0; fi
  (cd "$root" && find . -type f -print 2>/dev/null | sort | while read -r f; do
    # path|mtime|size — stat flags differ on macOS vs Linux; use a portable shim.
    local st
    if st=$(stat -f '%m|%z' "$f" 2>/dev/null); then
      printf '%s|%s\n' "$f" "$st"
    else
      st=$(stat -c '%Y|%s' "$f" 2>/dev/null) || st="?|?"
      printf '%s|%s\n' "$f" "$st"
    fi
  done)
}

# --- case: helper-sourced (code-side AC-035 grep) ----------------------------
# AC-035 substantive: the watcher sources THE SAME helper as PERSIST. The
# build-wave code-reviewer cites it; we also enshrine it as a CI grep so any
# future drift (copy-paste of resolver logic into the watcher) fails fast.

case_helper_sourced() {
  _skip "helper-sourced" && return 0
  echo
  echo "== case: helper-sourced (AC-035 DRY grep) =="
  # Must source the canonical helper (not re-implement git rev-parse).
  if grep -qE '^\s*[.]\s+.*lib/native-transcript-path\.sh' "$WATCHER" \
     || grep -qE '^\s*source\s+.*lib/native-transcript-path\.sh' "$WATCHER"; then
    _pass "helper-sourced: watcher sources core/scripts/lib/native-transcript-path.sh (AC-035 DRY)"
  else
    _fail "helper-sourced: watcher does NOT source the shared helper"
  fi
  # Watcher must NOT re-implement git rev-parse --git-common-dir locally.
  if grep -qE 'git rev-parse --git-common-dir' "$WATCHER"; then
    _fail "helper-sourced: watcher re-implements git rev-parse --git-common-dir (use the helper)"
  else
    _pass "helper-sourced: watcher does not re-implement git rev-parse --git-common-dir"
  fi
}

# --- case: end-to-end-fixture (AC-036) --------------------------------------
# Watcher runs once against a tmp env populated with the shared fixture jsonl.
# A `findings/01-implementer.md` lands under the run-dir with the fixture's
# terminal text ("Continuation block …").

case_end_to_end_fixture() {
  _skip "end-to-end-fixture" && return 0
  echo
  echo "== case: end-to-end-fixture =="
  local out; out=$(_setup_env e2e) || return 1
  local TMP_HOME=$(echo "$out" | sed -n '1p')
  local TMP_REPO=$(echo "$out" | sed -n '2p')
  local SESS=$(echo "$out" | sed -n '3p')
  trap "_cleanup_env '$TMP_HOME' '$TMP_REPO'" RETURN

  local RUN_DIR="$TMP_REPO/run-e2e"
  mkdir -p "$RUN_DIR"

  local rc=0
  _run_watch_once "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" || rc=$?
  if [ $rc -ne 0 ]; then
    _fail "end-to-end-fixture: watcher exited $rc"
    cat "$WATCH_STDERR" | sed 's/^/    /'
    return 1
  fi

  # AC-036: a file lands under findings/.
  local landed
  landed=$(ls "$RUN_DIR/findings/" 2>/dev/null | sort)
  if [ -z "$landed" ]; then
    _fail "end-to-end-fixture: no findings/ files written"
    return 1
  fi
  _pass "end-to-end-fixture: findings/ has files: $landed"

  # The fixture's meta.json says agentType=implementer; expect 01-implementer.md.
  if [ -f "$RUN_DIR/findings/01-implementer.md" ]; then
    _pass "end-to-end-fixture: findings/01-implementer.md created (meta agentType=implementer)"
  else
    _fail "end-to-end-fixture: expected findings/01-implementer.md (got: $landed)"
  fi

  # Fixture terminal text: "Continuation block — the extractor keeps the LAST assistant record's text…"
  if grep -qF "Continuation block" "$RUN_DIR/findings/01-implementer.md"; then
    _pass "end-to-end-fixture: terminal text captured (AC-036)"
  else
    _fail "end-to-end-fixture: terminal text missing"
    head -20 "$RUN_DIR/findings/01-implementer.md" | sed 's/^/    /'
  fi
}

# --- case: writes-confined-to-run-dir (AC-031) ------------------------------
# Snapshot the WHOLE tmp tree (TMP_HOME + TMP_REPO) before/after the watcher
# runs; assert the set of changed/new files is a strict subset of <run-dir>/.

case_writes_confined_to_run_dir() {
  _skip "writes-confined-to-run-dir" && return 0
  echo
  echo "== case: writes-confined-to-run-dir =="
  local out; out=$(_setup_env confined) || return 1
  local TMP_HOME=$(echo "$out" | sed -n '1p')
  local TMP_REPO=$(echo "$out" | sed -n '2p')
  local SESS=$(echo "$out" | sed -n '3p')
  local JOURNAL=$(echo "$out" | sed -n '5p')
  local SUBAGENTS_DIR=$(echo "$out" | sed -n '6p')
  trap "_cleanup_env '$TMP_HOME' '$TMP_REPO'" RETURN

  local RUN_DIR="$TMP_REPO/run-confined"
  mkdir -p "$RUN_DIR"

  # Snapshot the journal dir (the read-only target) BEFORE.
  local JOURNAL_BEFORE
  JOURNAL_BEFORE=$(_snapshot_tree "$SUBAGENTS_DIR")
  # Snapshot the rest of TMP_HOME (excluding what's under run-dir, which doesn't
  # exist under HOME — run-dir is under TMP_REPO).
  local HOME_BEFORE
  HOME_BEFORE=$(_snapshot_tree "$TMP_HOME")
  # Snapshot TMP_REPO outside of run-dir.
  local REPO_BEFORE_NON_RUN
  REPO_BEFORE_NON_RUN=$(cd "$TMP_REPO" && find . -type f -not -path "./$(basename "$RUN_DIR")/*" 2>/dev/null | sort | while read -r f; do
    local st
    st=$(stat -f '%m|%z' "$f" 2>/dev/null || stat -c '%Y|%s' "$f" 2>/dev/null || echo "?|?")
    printf '%s|%s\n' "$f" "$st"
  done)

  local rc=0
  _run_watch_once "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" || rc=$?
  if [ $rc -ne 0 ]; then _fail "writes-confined: watcher exited $rc"; cat "$WATCH_STDERR"; return 1; fi

  # AFTER snapshots.
  local JOURNAL_AFTER
  JOURNAL_AFTER=$(_snapshot_tree "$SUBAGENTS_DIR")
  local HOME_AFTER
  HOME_AFTER=$(_snapshot_tree "$TMP_HOME")
  local REPO_AFTER_NON_RUN
  REPO_AFTER_NON_RUN=$(cd "$TMP_REPO" && find . -type f -not -path "./$(basename "$RUN_DIR")/*" 2>/dev/null | sort | while read -r f; do
    local st
    st=$(stat -f '%m|%z' "$f" 2>/dev/null || stat -c '%Y|%s' "$f" 2>/dev/null || echo "?|?")
    printf '%s|%s\n' "$f" "$st"
  done)

  # Journal dir unchanged (file set + size — mtime is mostly stable but a read
  # MAY bump atime on some filesystems; we don't include atime in the snapshot).
  if [ "$JOURNAL_BEFORE" = "$JOURNAL_AFTER" ]; then
    _pass "writes-confined: subagents/ journal dir unchanged (no journal writes)"
  else
    _fail "writes-confined: subagents/ journal dir changed (watcher wrote the journal?)"
    diff <(echo "$JOURNAL_BEFORE") <(echo "$JOURNAL_AFTER") | sed 's/^/    /'
  fi

  # TMP_REPO outside run-dir unchanged.
  if [ "$REPO_BEFORE_NON_RUN" = "$REPO_AFTER_NON_RUN" ]; then
    _pass "writes-confined: TMP_REPO outside run-dir unchanged"
  else
    _fail "writes-confined: TMP_REPO outside run-dir changed"
    diff <(echo "$REPO_BEFORE_NON_RUN") <(echo "$REPO_AFTER_NON_RUN") | sed 's/^/    /'
  fi

  # TMP_HOME outside the subagents/ journal also unchanged.
  if [ "$HOME_BEFORE" = "$HOME_AFTER" ]; then
    _pass "writes-confined: TMP_HOME unchanged (no writes outside the run dir)"
  else
    _fail "writes-confined: TMP_HOME changed (writes leaked outside the run dir)"
    diff <(echo "$HOME_BEFORE") <(echo "$HOME_AFTER") | sed 's/^/    /'
  fi

  # Positive: run-dir/findings/ DID receive at least one file.
  if ls "$RUN_DIR/findings/"*.md >/dev/null 2>&1; then
    _pass "writes-confined: writes landed in run-dir/findings/ (positive)"
  else
    _fail "writes-confined: nothing written to run-dir/findings/"
  fi
}

# --- case: no-manifest-writes (AC-033) --------------------------------------

case_no_manifest_writes() {
  _skip "no-manifest-writes" && return 0
  echo
  echo "== case: no-manifest-writes =="
  local out; out=$(_setup_env nomani) || return 1
  local TMP_HOME=$(echo "$out" | sed -n '1p')
  local TMP_REPO=$(echo "$out" | sed -n '2p')
  local SESS=$(echo "$out" | sed -n '3p')
  trap "_cleanup_env '$TMP_HOME' '$TMP_REPO'" RETURN

  local RUN_DIR="$TMP_REPO/run-nomani"
  mkdir -p "$RUN_DIR"

  # (a) Cold case: no manifest exists; watcher must NOT create one.
  local rc=0
  _run_watch_once "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" || rc=$?
  if [ $rc -ne 0 ]; then _fail "no-manifest-writes (cold): watcher exited $rc"; return 1; fi
  if [ -f "$RUN_DIR/manifest.json" ]; then
    _fail "no-manifest-writes (cold): watcher CREATED manifest.json"
  else
    _pass "no-manifest-writes (cold): no manifest.json after watcher (AC-033)"
  fi

  # (b) Existing-manifest case: pre-seed a manifest; watcher must NOT mutate it.
  local MAN="$RUN_DIR/manifest.json"
  printf '{"sentinel":"watcher-must-not-touch-this","schema":"thin-manifest/1"}\n' > "$MAN"
  local BEFORE_HASH
  BEFORE_HASH=$(shasum "$MAN" | awk '{print $1}')

  _run_watch_once "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" || rc=$?
  if [ $rc -ne 0 ]; then _fail "no-manifest-writes (warm): watcher exited $rc"; return 1; fi
  local AFTER_HASH
  AFTER_HASH=$(shasum "$MAN" | awk '{print $1}')
  if [ "$BEFORE_HASH" = "$AFTER_HASH" ]; then
    _pass "no-manifest-writes (warm): pre-existing manifest.json byte-identical after watcher (AC-033)"
  else
    _fail "no-manifest-writes (warm): pre-existing manifest.json was mutated"
  fi
}

# --- case: no-race-with-persist (AC-032) ------------------------------------
# Run watcher, then persist (journal-fallback). Compare against a reference
# run where ONLY persist ran.
#
# Assertions:
#   (a) Persist's output files exist with the same byte content in both runs
#       (the watcher does not poison persist's writes).
#   (b) No files exist OUTSIDE findings/ that persist itself wouldn't have
#       written (no orphans).
#   (c) For any file that BOTH the watcher and persist would write, the
#       persist-alone version equals the watcher+persist version (persist
#       wins; no conflicts).

case_no_race_with_persist() {
  _skip "no-race-with-persist" && return 0
  echo
  echo "== case: no-race-with-persist =="
  # Reference run (persist alone, same fixture).
  local out_ref; out_ref=$(_setup_env race-ref) || return 1
  local REF_HOME=$(echo "$out_ref" | sed -n '1p')
  local REF_REPO=$(echo "$out_ref" | sed -n '2p')
  local REF_SESS=$(echo "$out_ref" | sed -n '3p')
  local REF_JOURNAL=$(echo "$out_ref" | sed -n '5p')
  local REF_RUN_DIR="$REF_REPO/run-ref"; mkdir -p "$REF_RUN_DIR"
  touch "$REF_JOURNAL"
  _run_persist "$REF_HOME" "$REF_REPO" "$REF_SESS" "$REF_RUN_DIR" \
    || { _fail "no-race-with-persist (ref): persist failed"; cat "$PERSIST_STDERR"; return 1; }
  local REF_TREE
  REF_TREE=$(cd "$REF_RUN_DIR" && find . -type f -print | sort)

  # Comparison run (watcher then persist, same fixture).
  local out_cmp; out_cmp=$(_setup_env race-cmp) || return 1
  local CMP_HOME=$(echo "$out_cmp" | sed -n '1p')
  local CMP_REPO=$(echo "$out_cmp" | sed -n '2p')
  local CMP_SESS=$(echo "$out_cmp" | sed -n '3p')
  local CMP_JOURNAL=$(echo "$out_cmp" | sed -n '5p')
  local CMP_RUN_DIR="$CMP_REPO/run-cmp"; mkdir -p "$CMP_RUN_DIR"
  touch "$CMP_JOURNAL"

  _run_watch_once "$CMP_HOME" "$CMP_REPO" "$CMP_SESS" "$CMP_RUN_DIR" \
    || { _fail "no-race-with-persist (cmp watch): watcher failed"; cat "$WATCH_STDERR"; return 1; }
  _run_persist  "$CMP_HOME" "$CMP_REPO" "$CMP_SESS" "$CMP_RUN_DIR" \
    || { _fail "no-race-with-persist (cmp persist): persist failed"; cat "$PERSIST_STDERR"; return 1; }
  local CMP_TREE
  CMP_TREE=$(cd "$CMP_RUN_DIR" && find . -type f -print | sort)

  trap "_cleanup_env '$REF_HOME' '$REF_REPO'; _cleanup_env '$CMP_HOME' '$CMP_REPO'" RETURN

  # (a) Persist's output present in both, byte-identical (modulo timestamps).
  # Persist embeds `Persisted: <now>` in run-log.md — compare modulo that line.
  local p_ok=0
  for rel in $REF_TREE; do
    # Use a stable, timestamp-free comparison for run-log.md; byte-identical for the rest.
    if [ "$rel" = "./run-log.md" ]; then
      if [ ! -f "$CMP_RUN_DIR/run-log.md" ]; then
        _fail "no-race (a): persist's run-log.md absent in cmp run"
        p_ok=1
      else
        local REF_NORM CMP_NORM
        REF_NORM=$(grep -v "Persisted:" "$REF_RUN_DIR/run-log.md" | shasum | awk '{print $1}')
        CMP_NORM=$(grep -v "Persisted:" "$CMP_RUN_DIR/run-log.md" | shasum | awk '{print $1}')
        if [ "$REF_NORM" != "$CMP_NORM" ]; then
          _fail "no-race (a): run-log.md differs (modulo Persisted timestamp) between ref and cmp"
          diff <(grep -v "Persisted:" "$REF_RUN_DIR/run-log.md") \
               <(grep -v "Persisted:" "$CMP_RUN_DIR/run-log.md") | head -40 | sed 's/^/    /'
          p_ok=1
        fi
      fi
    else
      if [ ! -f "$CMP_RUN_DIR/$rel" ]; then
        _fail "no-race (a): persist's file '$rel' absent in cmp run"
        p_ok=1
      else
        local REF_H CMP_H
        REF_H=$(shasum "$REF_RUN_DIR/$rel" | awk '{print $1}')
        CMP_H=$(shasum "$CMP_RUN_DIR/$rel" | awk '{print $1}')
        if [ "$REF_H" != "$CMP_H" ]; then
          _fail "no-race (a): persist's file '$rel' differs between ref and cmp (watcher poisoned it?)"
          p_ok=1
        fi
      fi
    fi
  done
  if [ $p_ok -eq 0 ]; then
    _pass "no-race (a): persist's output set byte-identical in ref vs watcher+persist (modulo Persisted timestamp)"
  fi

  # (b) No orphans OUTSIDE findings/. Files in cmp \ ref are only allowed if
  # they live under findings/ (the watcher's NN-<agent>.md is an additive
  # in-flight snapshot under findings/ that persist's end-of-run output does
  # not disagree with — explicitly permitted by AC-032's "indistinguishable
  # from persist alone" reading: no orphans outside findings/, no conflicting
  # content for shared paths).
  local extras
  extras=$(comm -13 <(echo "$REF_TREE") <(echo "$CMP_TREE"))
  local bad=""
  if [ -n "$extras" ]; then
    while IFS= read -r rel; do
      [ -z "$rel" ] && continue
      case "$rel" in
        ./findings/*) ;;   # permitted additive snapshots
        *) bad="${bad}${rel}"$'\n' ;;
      esac
    done <<<"$extras"
  fi
  if [ -z "$bad" ]; then
    _pass "no-race (b): no orphans outside findings/ (watcher additions are all under findings/)"
  else
    _fail "no-race (b): orphans outside findings/:"
    printf '%s' "$bad" | sed 's/^/    /'
  fi

  # (c) For files BOTH would write, persist wins. Persist's nimble branch writes
  # `findings/implementer.md` (flat name); the watcher writes `findings/NN-<agent>.md`.
  # In this fixture set those names don't collide — but we still verify any shared
  # path is byte-identical (the diff at (a) already covered persist-set paths).
  # This sub-assertion is a no-op for the fixture set today; it future-proofs.
  local shared_diff=""
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if [ -f "$REF_RUN_DIR/$rel" ] && [ -f "$CMP_RUN_DIR/$rel" ]; then
      if [ "$rel" = "./run-log.md" ]; then continue; fi
      local rh ch
      rh=$(shasum "$REF_RUN_DIR/$rel" | awk '{print $1}')
      ch=$(shasum "$CMP_RUN_DIR/$rel" | awk '{print $1}')
      if [ "$rh" != "$ch" ]; then
        shared_diff="${shared_diff}${rel}"$'\n'
      fi
    fi
  done < <(comm -12 <(echo "$REF_TREE") <(echo "$CMP_TREE"))
  if [ -z "$shared_diff" ]; then
    _pass "no-race (c): no conflicting content for shared paths (persist wins)"
  else
    _fail "no-race (c): conflicting content at:"
    printf '%s' "$shared_diff" | sed 's/^/    /'
  fi
}

# --- case: kill-mid-run-then-persist (AC-034) -------------------------------
# Simulate "watcher killed mid-run" by running it once (the --once branch IS
# the mid-run-snapshot — a single pass leaves whatever it caught), then run
# persist and verify the final state is clean and matches persist-alone.

case_kill_mid_run_then_persist() {
  _skip "kill-mid-run-then-persist" && return 0
  echo
  echo "== case: kill-mid-run-then-persist =="
  local out; out=$(_setup_env killmid) || return 1
  local TMP_HOME=$(echo "$out" | sed -n '1p')
  local TMP_REPO=$(echo "$out" | sed -n '2p')
  local SESS=$(echo "$out" | sed -n '3p')
  local JOURNAL=$(echo "$out" | sed -n '5p')
  trap "_cleanup_env '$TMP_HOME' '$TMP_REPO'" RETURN

  local RUN_DIR="$TMP_REPO/run-killmid"; mkdir -p "$RUN_DIR"
  touch "$JOURNAL"

  # Mid-run snapshot (the watcher catches the fixture's current state, then
  # exits as if SIGTERM hit it).
  _run_watch_once "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" \
    || { _fail "kill-mid: watcher failed"; cat "$WATCH_STDERR"; return 1; }

  # Confirm the partial state is non-empty (we want a real "mid-run" surface).
  if ! ls "$RUN_DIR/findings/"*.md >/dev/null 2>&1; then
    _fail "kill-mid: watcher wrote nothing; cannot exercise the kill-mid-run scenario"
    return 1
  fi
  _pass "kill-mid: watcher produced a partial state (then 'killed' via --once exit)"

  # Now end-of-run persist (journal-fallback) runs over the same dir and the
  # partial state. It must succeed cleanly and overwrite/coexist with the
  # partial state.
  _run_persist "$TMP_HOME" "$TMP_REPO" "$SESS" "$RUN_DIR" \
    || { _fail "kill-mid: persist failed after kill-mid"; cat "$PERSIST_STDERR"; return 1; }
  _pass "kill-mid: persist succeeded after watcher partial-state (AC-034)"

  # The authoritative artifacts persist would produce must be present, and the
  # run-log records the journal-fallback provenance (sanity: persist's pipeline
  # is unimpeded by the partial state).
  if [ ! -f "$RUN_DIR/run-log.md" ] || [ ! -f "$RUN_DIR/findings/implementer.md" ]; then
    _fail "kill-mid: persist's authoritative artifacts not all present"
    return 1
  fi
  if ! grep -qF "Input source: journal-fallback" "$RUN_DIR/run-log.md"; then
    _fail "kill-mid: persist's run-log does NOT record journal-fallback provenance"
    return 1
  fi
  _pass "kill-mid: persist overwrites cleanly; authoritative artifacts intact (AC-034)"
}

# --- run --------------------------------------------------------------------

case_helper_sourced
case_end_to_end_fixture
case_writes_confined_to_run_dir
case_no_manifest_writes
case_no_race_with_persist
case_kill_mid_run_then_persist

echo
echo "================================================================"
echo "test-watch-mirror: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[ "$FAIL" -eq 0 ]
