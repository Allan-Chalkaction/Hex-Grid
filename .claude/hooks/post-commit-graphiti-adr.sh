#!/usr/bin/env bash
# post-commit-graphiti-adr.sh — capture a directly-authored ADR into the memory graph at commit time.
#
# AMS-T4 (wave-1-writes, AC-005): the "ADR first" birth path. ADRs are routinely orchestrator-authored
# OUTSIDE any engine run (claim the number, write the decision before any build), so the AMS-T2
# persist seam (engine-only) never captures them. This git post-commit trigger detects a
# newly-added/modified docs/decisions/ADR-*.md in the just-made commit and routes it through the
# existing verbatim ingester (graphiti-ingest-doc.py --changed-adrs HEAD), which writes each `##`
# section through graphiti_write.write_fact() — scrub + fail-closed group_id + content-hash idempotency.
#
# This is a LOCAL read-and-ingest only. It NEVER pushes, opens a PR, force-pushes, or mutates shared
# state (rules-git.md push-authority preserved).
#
# OFF BY DEFAULT and NOT auto-registered. To enable as a git hook:
#   1) touch .claude/agent-memory/graphiti-adr-capture-enabled
#   2) ln -sf ../../core/hooks/post-commit-graphiti-adr.sh .git/hooks/post-commit
#      (or append an invocation to an existing .git/hooks/post-commit)
#
# Forward-only: only ADRs changed in THIS commit are captured — no backfill of the existing corpus
# (the operator runs the CLI manually for backfill, per the wave spec).
#
# FAIL-OPEN at every step: any error logs one line and exits 0. A capture failure (engine down,
# docker missing, no API key, git error) MUST NEVER block or fail the commit.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ENABLE_FLAG="${REPO_ROOT}/.claude/agent-memory/graphiti-adr-capture-enabled"
INGEST="${REPO_ROOT}/core/scripts/graphiti-ingest-doc.py"
LOG="${REPO_ROOT}/.claude/agent-memory/graphiti-adr-capture.log"

[ -f "$ENABLE_FLAG" ] || exit 0     # off-by-default -> silent
[ -f "$INGEST" ] || exit 0

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) post-commit ADR capture ==="
  # --changed-adrs HEAD derives the changed ADR set + a fail-closed group_id; a no-op when the
  # commit touched no docs/decisions/ADR-*.md. Swallow any failure (fail-open).
  python3 "$INGEST" --changed-adrs HEAD --repo-root "$REPO_ROOT" 2>&1 \
    || echo "(adr capture failed — fail-open)"
} >> "$LOG" 2>&1 || true

exit 0
