#!/usr/bin/env bash
# test-graphiti-ontology-wire.sh — verify the typed-ontology wire-in in graphiti_write.py.
# (graphiti-cost-efficiency Wave 2, W2TE-T2.)
#
# Pure Python + grep — NO docker. Asserts:
#   1. _select_ontology routes the four canonical cases correctly (typed only for ab-wave2-typed-).
#   2. The _INNER body passes entity_types= (the per-call kwarg seam).
#   3. edge_types=None and edge_type_map={} appear (architect D4, unconditional).
#   4. The host-side compile() syntax check on the composed inner is present.
#   5. _compose_inner(_INNER) actually compiles host-side (catches a real composition/syntax break).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRITE_PY="$SCRIPTS_DIR/graphiti_write.py"

# 1 + 5: selector cases and the composed-inner compiles host-side.
python3 - "$SCRIPTS_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from graphiti_write import _select_ontology, _compose_inner, _INNER
# Delimiter is "-" not ":" — graphiti-core 0.28.1 rejects colons in group_id (charset = alnum/-/_).
assert _select_ontology("ab-wave2-typed-foo") == "typed", "typed prefix must route typed"
assert _select_ontology("ab-wave2-freeform-foo") == "freeform", "freeform arm must route freeform"
assert _select_ontology("claude-infra-v2") == "freeform", "live capture group must stay freeform"
assert _select_ontology("nia") == "freeform", "ordinary group must stay freeform"
# The composed (preamble + _INNER) unit must compile on the host — proves the inline-source seam.
composed = _compose_inner(_INNER)
assert "ENTITY_TYPES" in composed, "composed inner must carry the ENTITY_TYPES map"
compile(composed, "<wire-test>", "exec")
print("OK — selector routes 4/4; composed inner compiles host-side")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: selector / compose assertions failed (rc=$rc)" >&2; exit 1; }

# 2: entity_types= kwarg present in the _INNER body.
grep -n 'entity_types=' "$WRITE_PY" >/dev/null || { echo "FAIL: entity_types= not found in graphiti_write.py" >&2; exit 1; }
# 3: both explicit-None edge lines present.
grep -nE 'edge_types=None' "$WRITE_PY" >/dev/null || { echo "FAIL: edge_types=None not found" >&2; exit 1; }
grep -nE 'edge_type_map=\{\}' "$WRITE_PY" >/dev/null || { echo "FAIL: edge_type_map={} not found" >&2; exit 1; }
# 4: host-side syntax check present.
grep -n 'compile(combined' "$WRITE_PY" >/dev/null || { echo "FAIL: host-side compile() syntax check missing" >&2; exit 1; }

echo "test-graphiti-ontology-wire: OK"
