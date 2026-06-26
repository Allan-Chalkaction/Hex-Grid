#!/usr/bin/env bash
# test-graphiti-ingest-idempotent.sh — GCE-T3 (AC-008, AC-012)
# Proves re-ingest of an UNCHANGED locked doc is a no-op: every chunk skipped, written=0, exit 0.
# Exercises the REAL lockstate_decision call site in graphiti-ingest-doc.py (AC-012 wire-to-consumer)
# without requiring the Graphiti/Docker container: the lock-state index is host-side and pure, so a
# locked doc previously recorded in the lock-state ledger resolves to 'skip' on the next run.
# Bash wrapper over stdlib python (pytest is unavailable on the host — mirrors test-graphiti-manifest.sh).
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

REPO_ROOT="$TMPDIR_T/repo"
LOCKED_DOC_REL="docs/step-6-done/2026-06-13/sample.md"   # step-6-done -> locked taxonomy
LOCKED_DOC="$REPO_ROOT/$LOCKED_DOC_REL"
mkdir -p "$(dirname "$LOCKED_DOC")"
cat > "$LOCKED_DOC" <<'EOF'
# Sample Locked Doc

## Section One
This is a body of text comfortably above the minimum character threshold for ingestion so it counts
as a real chunk worth writing into the graph store during the section-split pass over this document.

## Section Two
Another section with enough verbatim prose to exceed the min-chars gate and produce a second chunk.
The content is deliberately stable so a re-ingest is bit-for-bit identical and must be a no-op.
EOF

LSDIR="$TMPDIR_T/lockstate"
MFDIR="$TMPDIR_T/manifest"

# STEP 1 — seed the lock-state ledger with the CURRENT content hash for this locked doc (simulating a
# prior successful ingest). We compute the hash exactly as the ingest path does: content_hash(gid,
# scrub(chunk)[0]) for each "<title> — §<head>\n\n<body>" chunk. Using the script's own split/clean so
# the seeded hashes match the real run's hashes bit-for-bit.
GROUP_ID="claude-infra-v2"
GRAPHITI_LOCKSTATE_DIR="$LSDIR" python3 - "$SCRIPTS_DIR" "$LOCKED_DOC" "$LOCKED_DOC_REL" "$GROUP_ID" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import importlib.util
# load the hyphenated module file directly
spec = importlib.util.spec_from_file_location("ingest", sys.argv[1] + "/graphiti-ingest-doc.py")
ingest = importlib.util.module_from_spec(spec); spec.loader.exec_module(ingest)
import graphiti_write as gw
import graphiti_lockstate as gls
from datetime import datetime, timezone

doc, rel, gid = sys.argv[2], sys.argv[3], sys.argv[4]
title, sections = ingest.split_sections(open(doc, encoding="utf-8").read())
n = 0
for head, body in sections:
    body = ingest.clean(body)
    if len(body) < 60:
        continue
    chunk = f"{title} — §{head}\n\n{body}"
    chash = gls.content_hash(gid, gw.scrub(chunk)[0])
    # chunk-scoped key matches the ingest path's lockstate_decision(rel#anchor, ...) call.
    chunk_key = f"{rel}#{ingest._anchor(head)}"
    gls.record(chunk_key, chash, gls.derive_lock_state(chunk_key), datetime.now(timezone.utc).isoformat())
    n += 1
print(f"seeded {n} lock-state records for {rel}")
PY

# STEP 2 — re-ingest the UNCHANGED locked doc. Every chunk must resolve to 'skip' via lockstate_decision
# (locked + unchanged content hash), so written=0 and exit 0 — no container write attempted.
OUT="$TMPDIR_T/run2.out"
set +e
GRAPHITI_LOCKSTATE_DIR="$LSDIR" GRAPHITI_MANIFEST_DIR="$MFDIR" REPO_ROOT="$REPO_ROOT" \
  python3 "$SCRIPTS_DIR/graphiti-ingest-doc.py" "$LOCKED_DOC" \
  --group-id "$GROUP_ID" --repo-root "$REPO_ROOT" > "$OUT" 2>&1
RC=$?
set -e
cat "$OUT"

# Assertions.
[ "$RC" -eq 0 ] || { echo "  [FAIL] expected exit 0, got $RC"; exit 1; }
echo "  [ok] AC-008 exit code 0 on unchanged re-ingest"

SUMMARY="$(grep -E '^files=' "$OUT" | tail -1)"
[ -n "$SUMMARY" ] || { echo "  [FAIL] no summary line found"; exit 1; }
echo "  summary: $SUMMARY"

echo "$SUMMARY" | grep -qE 'written=0' || { echo "  [FAIL] expected written=0 in: $SUMMARY"; exit 1; }
echo "  [ok] AC-008 written=0 on unchanged re-ingest"

# skipped >= chunk count (2 chunks above min-chars).
CHUNKS="$(echo "$SUMMARY" | sed -nE 's/.*chunks=([0-9]+).*/\1/p')"
SKIPPED="$(echo "$SUMMARY" | sed -nE 's/.*skipped=([0-9]+).*/\1/p')"
[ "$SKIPPED" -ge "$CHUNKS" ] || { echo "  [FAIL] skipped=$SKIPPED < chunks=$CHUNKS"; exit 1; }
[ "$CHUNKS" -ge 2 ] || { echo "  [FAIL] expected >=2 chunks, got $CHUNKS"; exit 1; }
echo "  [ok] AC-008 skipped ($SKIPPED) >= chunks ($CHUNKS)"

# AC-012 wire-to-consumer: the call site exists in the real ingest path.
grep -q 'lockstate_decision' "$SCRIPTS_DIR/graphiti-ingest-doc.py" \
  || { echo "  [FAIL] lockstate_decision not consulted in graphiti-ingest-doc.py"; exit 1; }
echo "  [ok] AC-012 lockstate_decision consulted in the ingest path"

# AC-009 / AC-018b: no body logged on the skip path (the only path exercised here).
if grep -nE 'episode_body|scrubbed' "$OUT" >/dev/null 2>&1; then
  echo "  [FAIL] body-ish token leaked into ingest output"; exit 1
fi
echo "  [ok] AC-009 no body in ingest skip-path output"

echo "test-graphiti-ingest-idempotent: OK"
