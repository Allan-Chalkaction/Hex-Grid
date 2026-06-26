#!/usr/bin/env bash
#
# worktree-staleness-check.sh — the thin pre-merge staleness guard for the v2
# orchestrated engine (T5b, AC-5). The reusable, standalone descendant of the v1
# INFRA-019 inline check (which lived in the now-retired execute.md / t-implement.md).
#
# WHY THIS EXISTS (the AC-5 verdict: GUARDED, not covered).
#   Native `isolation:"worktree"` (Workflow + Agent tools) roots each worktree at a
#   SESSION-STABLE base ref captured at session start / first dispatch — NOT at current
#   HEAD. This is the harness's documented behavior (the INFRA-019 contract) with a
#   four-catch incident history in v1. Consequence: if the wave branch advances after the
#   base ref is captured (e.g. a prior wave merged earlier in a long session), a later
#   worktree branch is still rooted at the stale base, and merging it would silently
#   reverse-delta the intervening commits. Native isolation does NOT cover this, so the
#   v2 orchestrated engine keeps this thin guard and calls it before integrating any
#   per-ticket commit into the wave branch.
#
# CONTRACT
#   For each <ref> (a commit SHA or branch), the guard asks: does <ref> contain <base>?
#     behind = `git log --oneline <ref>..<base> | wc -l`
#   behind == 0  -> <ref> is rooted at or after <base> (FRESH; safe to merge).
#   behind  > 0  -> <base> has commits not in <ref> (<ref>'s base is STALE relative to
#                   <base>); merging would reverse-delta those commits. REFUSE.
#   Refuse-on-stale, NOT warn-on-stale (INFRA-019 discipline). No auto-rebase.
#
# Usage:
#   worktree-staleness-check.sh <base_ref> <ref> [<ref> ...]
#
# Exit codes:
#   0  all refs are fresh relative to <base_ref> (safe to integrate)
#   2  at least one ref is stale (REFUSE the merge; operator rebases or discards)
#   1  usage error / unknown ref / not a git repo
#
set -uo pipefail

die() { printf 'worktree-staleness-check: %s\n' "$*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: worktree-staleness-check.sh <base_ref> <ref> [<ref> ...]"

git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

BASE="$1"; shift
git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null 2>&1 || die "base ref not found: ${BASE}"

stale=0
stale_list=""
for ref in "$@"; do
  if ! git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
    die "ref not found: ${ref}"
  fi
  behind=$(git log --oneline "${ref}..${BASE}" 2>/dev/null | wc -l | tr -d ' ')
  if [ "${behind:-0}" -gt 0 ]; then
    short=$(git rev-parse --short "${ref}" 2>/dev/null || echo "${ref}")
    echo "[STALE] ${short} is rooted behind ${BASE} by ${behind} commit(s) — merging would reverse-delta them" >&2
    stale=$((stale + 1))
    stale_list="${stale_list} ${ref}"
  else
    short=$(git rev-parse --short "${ref}" 2>/dev/null || echo "${ref}")
    echo "[fresh] ${short} contains ${BASE} (safe to integrate)"
  fi
done

if [ "${stale}" -gt 0 ]; then
  echo "REFUSE: ${stale} stale ref(s) —${stale_list}. Rebase onto ${BASE} (or discard) then retry." >&2
  exit 2
fi
echo "OK: all $# ref(s) fresh relative to ${BASE}"
exit 0
