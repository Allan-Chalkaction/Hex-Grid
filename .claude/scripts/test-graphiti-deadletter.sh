#!/usr/bin/env bash
# test-graphiti-deadletter.sh — consumer-wrapper dead-letter sink (W3IO-T5, AC-028).
#
# Host-only (NO docker): monkeypatch graphiti_write.subprocess.run into the error path and assert a
# dead-letter record lands with EXACTLY {ts, episode_name, group_id, content_hash, error} and NO body
# field. REPO_ROOT + manifest dir isolated to temp dirs (no live-rail / real-sink pollution).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_ROOT="$(mktemp -d)"
TMP_MANIFEST="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT" "$TMP_MANIFEST"' EXIT

REPO_ROOT="$TMP_ROOT" GRAPHITI_MANIFEST_DIR="$TMP_MANIFEST" SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PY'
import os, sys, json, glob
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
import graphiti_write as gw

# Force the error path: subprocess.run returns a failing proc (returncode 1, no "OK").
def fake_run(cmd, **kwargs):
    class P:
        returncode = 1
        stdout = "ERR simulated add_episode failure"
        stderr = "boom"
    return P()
gw.subprocess.run = fake_run

r = gw.write_fact("W3IO-T5 dead-letter probe: this write is forced to fail.",
                  group_id="w3-test-deadletter", source_description="W3IO-T5 test", force=True)
assert r["status"] == "error", f"expected status=error, got {r['status']}"

sink_dir = os.path.join(os.environ["REPO_ROOT"], ".claude", "agent-memory", "graphiti-deadletter")
files = glob.glob(os.path.join(sink_dir, "deadletter-*.jsonl"))
assert files, f"no dead-letter file created under {sink_dir}"
recs = []
for f in files:
    for ln in open(f, encoding="utf-8"):
        ln = ln.strip()
        if ln:
            recs.append(json.loads(ln))
assert len(recs) == 1, f"expected exactly 1 dead-letter record, got {len(recs)}"
rec = recs[0]

# EXACTLY the five fields — no more, no less.
assert set(rec.keys()) == {"ts", "episode_name", "group_id", "content_hash", "error"}, \
    f"dead-letter field set wrong: {sorted(rec.keys())}"
# Security invariant: NO body / episode_body / payload anywhere on the record.
for forbidden in ("body", "episode_body", "payload"):
    assert forbidden not in rec, f"SECURITY: dead-letter record must NOT carry {forbidden!r}"
assert rec["content_hash"] == r["content_hash"], "content_hash mismatch"
assert rec["group_id"] == r["group_id"], "group_id mismatch"
assert rec["error"], "error field must be populated"
print(f"  dead-letter OK: 5 fields, no body; content_hash={rec['content_hash']} group_id={rec['group_id']}")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: dead-letter assertions (rc=$rc)" >&2; exit 1; }

# Static no-body invariant: no dead-letter write call places a body field.
if grep -nE '_write_deadletter\(' "$SCRIPTS_DIR/graphiti_write.py" | grep -q body; then
  echo "FAIL: a _write_deadletter call references body" >&2; exit 1
fi
echo "test-graphiti-deadletter: OK"
