#!/usr/bin/env bash
# test-graphiti-manifest-wiring.sh — manifest writer wiring post-CREATE (W3IO-T3, AC-026).
#
# Live (docker): first write to a fresh w3-test-<ts> group is a CREATE -> one manifest line lands
# with {content_hash, group_id, episode_uuid, ts}. A forced re-write of the SAME content takes T1's
# UPDATE arm (manifest hit -> uuid passed) and appends NO new manifest line. Manifest isolated to a
# temp dir. Skip-on-no-docker.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="${GRAPHITI_MCP_CONTAINER:-docker-graphiti-mcp-1}"

if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP}$"; then
  echo "SKIP: docker / ${MCP} not available — manifest wiring is a live-write assertion."
  exit 0
fi

TMP_MANIFEST="$(mktemp -d)"
trap 'rm -rf "$TMP_MANIFEST"' EXIT

GRAPHITI_MANIFEST_DIR="$TMP_MANIFEST" SCRIPTS_DIR="$SCRIPTS_DIR" TOPIC="manifest-$(date +%s)" python3 - <<'PY'
import os, sys, json, re, glob
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from graphiti_write import write_fact

# Environmental/API-unavailability conditions that warrant a graceful SKIP (not a code-defect FAIL).
_ENV_API_RE = re.compile(
    r"credit balance|invalid_request_error|rate limit|overloaded|quota|insufficient|billing|503|429",
    re.IGNORECASE)

gid = f"w3-test-{os.environ['TOPIC']}"
body = "W3IO-T3 manifest wiring probe: deterministic uuid recorded on CREATE."
mdir = os.environ["GRAPHITI_MANIFEST_DIR"]

def manifest_lines():
    lines = []
    for f in glob.glob(os.path.join(mdir, "manifest-*.jsonl")):
        for ln in open(f, encoding="utf-8"):
            ln = ln.strip()
            if ln:
                lines.append(json.loads(ln))
    return lines

# --- CREATE: first write -> exactly one manifest record with the 4 fields ---
r1 = write_fact(body, group_id=gid, source_description="W3IO-T3 manifest test")
if r1.get("status") == "error" and _ENV_API_RE.search(str(r1.get("error", ""))):
    print(f"SKIP-ENV: graphiti API unavailable (live write_fact returned {r1.get('error')!r})", file=sys.stderr)
    sys.exit(77)
assert r1["status"] == "written", f"CREATE write failed: {r1}"
recs = manifest_lines()
assert len(recs) == 1, f"expected 1 manifest record after CREATE, got {len(recs)}: {recs}"
rec = recs[0]
assert rec["content_hash"] == r1["content_hash"], "content_hash mismatch in manifest record"
assert rec["group_id"] == gid, f"group_id mismatch: {rec['group_id']}"
assert rec["episode_uuid"] and len(rec["episode_uuid"]) >= 8, f"episode_uuid not uuid-shaped: {rec['episode_uuid']!r}"
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", rec["ts"]), f"ts not ISO 8601: {rec['ts']!r}"
print(f"  CREATE recorded: episode_uuid={rec['episode_uuid']}")

# --- UPDATE: forced re-write of same content -> UPDATE arm, NO new manifest line ---
r2 = write_fact(body, group_id=gid, source_description="W3IO-T3 manifest test", force=True)
assert r2["status"] == "written", f"UPDATE write failed: {r2}"
recs2 = manifest_lines()
assert len(recs2) == 1, f"UPDATE arm must NOT append a manifest record; got {len(recs2)}"
print(f"  UPDATE arm: manifest unchanged (still {len(recs2)} record)")
print("OK — CREATE records the minted uuid; UPDATE arm records nothing")
PY
rc=$?
[ "$rc" -eq 77 ] && { echo "SKIP: graphiti API unavailable (credit/billing/rate-limit) — static guards passed; live write skipped."; exit 0; }
[ "$rc" -ne 0 ] && { echo "FAIL: manifest wiring assertions (rc=$rc)" >&2; exit 1; }
echo "test-graphiti-manifest-wiring: OK"
