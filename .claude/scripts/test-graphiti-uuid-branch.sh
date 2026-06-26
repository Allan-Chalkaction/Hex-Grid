#!/usr/bin/env bash
# test-graphiti-uuid-branch.sh — deterministic-UUID create-vs-update branch (W3IO-T1, AC-024).
#
# Host-only (NO docker): monkeypatches graphiti_write.subprocess.run to capture the payload sent to
# _INNER, so we assert the create-vs-update DECISION without a live write. A seeded manifest record
# for (content_hash, group_id) -> payload carries update_uuid (UPDATE arm); a cleared manifest ->
# payload omits update_uuid (CREATE arm). Manifest is isolated to a temp dir (no live-rail pollution).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_MANIFEST="$(mktemp -d)"
trap 'rm -rf "$TMP_MANIFEST"' EXIT

GRAPHITI_MANIFEST_DIR="$TMP_MANIFEST" SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PY'
import os, sys, json
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
import graphiti_write as gw
import graphiti_manifest as gm

# Capture the payload _INNER would receive; never touch docker.
captured = {}
def fake_run(cmd, **kwargs):
    captured["input"] = kwargs.get("input")
    class P:  # minimal CompletedProcess stand-in
        returncode = 0
        stdout = "OK 11111111-2222-3333-4444-555555555555"
        stderr = ""
    return P()
gw.subprocess.run = fake_run

BODY = "W3IO-T1 branch test fact: deterministic uuid create-vs-update."
# Resolve gid + content_hash exactly as write_fact does (an unregistered id fails closed to
# quarantine — fine; the test is self-consistent and does no real write).
gid = gw._resolve_group_id("w3io-t1-ephemeral", None)
scrubbed, _ = gw.scrub(BODY)
ch = gw._content_hash(gid, scrubbed)

# --- UPDATE arm: seed a manifest record, expect update_uuid in the payload ---
SEEDED = "deadbeef-0000-0000-0000-000000000001"
gm.record(ch, gid, SEEDED, "2026-06-09T00:00:00+00:00")
gw.write_fact(BODY, group_id="w3io-t1-ephemeral", force=True)
payload = json.loads(captured["input"])
assert payload.get("update_uuid") == SEEDED, f"UPDATE arm: expected update_uuid={SEEDED}, got {payload.get('update_uuid')!r}"
assert payload["group_id"] == gid, f"group_id mismatch: {payload['group_id']!r} != {gid!r}"

# --- CREATE arm: clear the manifest, expect update_uuid omitted ---
for f in os.listdir(os.environ["GRAPHITI_MANIFEST_DIR"]):
    os.remove(os.path.join(os.environ["GRAPHITI_MANIFEST_DIR"], f))
captured.clear()
gw.write_fact(BODY, group_id="w3io-t1-ephemeral", force=True)
payload2 = json.loads(captured["input"])
assert "update_uuid" not in payload2, f"CREATE arm: update_uuid must be absent, got {payload2.get('update_uuid')!r}"

print("OK — UPDATE arm carries update_uuid; CREATE arm omits it")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: uuid create-vs-update branch assertions (rc=$rc)" >&2; exit 1; }

# Static: both the host-side payload field and the _INNER body branch reference update_uuid.
host_hits="$(grep -c 'update_uuid' "$SCRIPTS_DIR/graphiti_write.py")"
[ "${host_hits:-0}" -ge 2 ] || { echo "FAIL: expected >=2 update_uuid references in graphiti_write.py, got $host_hits" >&2; exit 1; }

echo "test-graphiti-uuid-branch: OK"
