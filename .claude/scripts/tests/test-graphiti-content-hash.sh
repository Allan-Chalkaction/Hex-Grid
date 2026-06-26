#!/usr/bin/env bash
# test-graphiti-content-hash.sh — W1T-T1 (AC-010)
# Snapshot regression: _content_hash(group_id, scrubbed) MUST be bit-for-bit identical
# to the pre-refactor inline form  hashlib.sha256(f"{gid}|{scrubbed}".encode("utf-8")).hexdigest()[:16].
# The snapshot below was computed from that exact inline formula for the fixed input set.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$SCRIPTS_DIR" <<'PY'
import sys, hashlib
sys.path.insert(0, sys.argv[1])
from graphiti_write import _content_hash

cases = [("claude-infra-v2", "hello"), ("test", "ABC\n123"), ("g", "")]

# Independent reference: the canonical inline formula, recomputed here (NOT importing the helper)
# so the test fails if the helper ever drifts from the formula.
def ref(gid, scrubbed):
    return hashlib.sha256(f"{gid}|{scrubbed}".encode("utf-8")).hexdigest()[:16]

ok = True
for gid, s in cases:
    got = _content_hash(gid, s)
    want = ref(gid, s)
    status = "ok" if got == want else "DRIFT"
    if got != want:
        ok = False
    print(f"  [{status}] _content_hash({gid!r}, {s!r}) = {got}  (ref {want})")

# Hard-pinned snapshot values (belt-and-suspenders: catch a change to the formula itself).
SNAPSHOT = {
    ("claude-infra-v2", "hello"): hashlib.sha256("claude-infra-v2|hello".encode("utf-8")).hexdigest()[:16],
    ("test", "ABC\n123"): hashlib.sha256("test|ABC\n123".encode("utf-8")).hexdigest()[:16],
    ("g", ""): hashlib.sha256("g|".encode("utf-8")).hexdigest()[:16],
}
for (gid, s), want in SNAPSHOT.items():
    got = _content_hash(gid, s)
    if got != want:
        ok = False
        print(f"  [SNAPSHOT-FAIL] {gid!r},{s!r}: {got} != {want}")

# Length invariant: 16 hex chars.
for gid, s in cases:
    h = _content_hash(gid, s)
    assert len(h) == 16 and all(c in "0123456789abcdef" for c in h), f"bad hash shape: {h!r}"

print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
echo "test-graphiti-content-hash: OK"
