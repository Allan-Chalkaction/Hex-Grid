#!/usr/bin/env bash
# test-graphiti-source-stamp.sh — source_path/heading_anchor provenance stamp (W3IO-T7, AC-030).
#
# Host-only (NO docker): dry_run=True returns the composed source_description. Assert the stamped
# shape with source_path+heading_anchor, and that omitting source_path preserves the prior format
# byte-for-byte (just `... [sha:<hex16>]`). Also grep the kwarg through write_fact + graphiti-distill.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPTS_DIR="$SCRIPTS_DIR" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from graphiti_write import write_fact

# With source_path + heading_anchor -> [src:<path>#<anchor>] prefix, [sha:..] at the end.
r = write_fact("W3IO-T7 stamp probe.", group_id="w3-test-stamp", dry_run=True,
               source_path="docs/decisions/ADR-076.md", heading_anchor="decision")
sd = r["source_description"]
assert re.match(r"^\[src:docs/decisions/ADR-076\.md#decision\] .* \[sha:[0-9a-f]{16}\]$", sd), \
    f"stamped source_description wrong: {sd!r}"

# source_path only (no anchor) -> [src:<path>] prefix.
r2 = write_fact("W3IO-T7 stamp probe.", group_id="w3-test-stamp", dry_run=True,
                source_path="docs/decisions/ADR-076.md")
assert re.match(r"^\[src:docs/decisions/ADR-076\.md\] .* \[sha:[0-9a-f]{16}\]$", r2["source_description"]), \
    f"path-only source_description wrong: {r2['source_description']!r}"

# No source_path -> prior shape preserved byte-for-byte (no [src:] prefix).
r3 = write_fact("W3IO-T7 stamp probe.", group_id="w3-test-stamp", dry_run=True)
sd3 = r3["source_description"]
assert re.match(r"^.* \[sha:[0-9a-f]{16}\]$", sd3) and "[src:" not in sd3, \
    f"backward-compat shape broken: {sd3!r}"

# heading_anchor WITHOUT source_path -> ignored (no prefix).
r4 = write_fact("W3IO-T7 stamp probe.", group_id="w3-test-stamp", dry_run=True, heading_anchor="x")
assert "[src:" not in r4["source_description"], f"anchor-without-path must not stamp: {r4['source_description']!r}"

print("OK — stamped (path#anchor / path-only) + backward-compatible bare shape + anchor-without-path ignored")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: source-stamp assertions (rc=$rc)" >&2; exit 1; }

# Kwarg threaded through both files.
grep -q 'source_path' "$SCRIPTS_DIR/graphiti_write.py" || { echo "FAIL: source_path not in graphiti_write.py" >&2; exit 1; }
grep -q 'source_path' "$SCRIPTS_DIR/graphiti-distill.py" || { echo "FAIL: source_path not threaded in graphiti-distill.py" >&2; exit 1; }
echo "test-graphiti-source-stamp: OK"
