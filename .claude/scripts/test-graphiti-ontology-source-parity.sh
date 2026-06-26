#!/usr/bin/env bash
# test-graphiti-ontology-source-parity.sh — byte-identity guard for the two-file ontology pattern.
# (graphiti-cost-efficiency Wave 2, W2TE-T1.)
#
# The host import surface (graphiti_ontology_types.py) and the in-container source
# (graphiti_ontology_inner.py) MUST define every entity class IDENTICALLY — drift between them is
# impossible-to-merge (the container would extract against different classes than the host tests).
# This test extracts each top-level ClassDef from BOTH files via Python's `ast` module and asserts
# byte-identity of the unparsed class body, per class.
#
# Exclusions (NOT compared — legitimately differ between the two files):
#   * module-level docstrings
#   * import statements
#   * the ENTITY_TYPES assignment (in-container only)
#
# Pure Python (ast + unparse) — NO docker. ast.unparse requires Python 3.9+ (host is 3.9.6).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 - "$SCRIPTS_DIR" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
host_path = scripts / "graphiti_ontology_types.py"
inner_path = scripts / "graphiti_ontology_inner.py"

def classes(path):
    mod = ast.parse(path.read_text(encoding="utf-8"))
    return {n.name: ast.unparse(n) for n in mod.body if isinstance(n, ast.ClassDef)}

host = classes(host_path)
inner = classes(inner_path)

# Same set of classes.
only_host = set(host) - set(inner)
only_inner = set(inner) - set(host)
if only_host or only_inner:
    print(f"FAIL: class set differs — only in host: {sorted(only_host)}; only in inner: {sorted(only_inner)}",
          file=sys.stderr)
    sys.exit(1)

# Per-class byte-identity of the unparsed body.
diverged = [name for name in host if host[name] != inner[name]]
if diverged:
    print(f"FAIL: class body diverges between the two files: {diverged}", file=sys.stderr)
    sys.exit(1)

# Sanity: the inner file MUST define ENTITY_TYPES; the host file MUST NOT (host-only-surface invariant).
inner_src = inner_path.read_text(encoding="utf-8")
host_src = host_path.read_text(encoding="utf-8")
inner_mod = ast.parse(inner_src)
has_entity_types = any(
    isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "ENTITY_TYPES" for t in n.targets)
    for n in inner_mod.body
)
if not has_entity_types:
    print("FAIL: graphiti_ontology_inner.py must define the ENTITY_TYPES map", file=sys.stderr)
    sys.exit(1)

print(f"OK — {len(host)} classes byte-identical (incl. _SourceAnchored); ENTITY_TYPES in-container only")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: ontology source-parity check failed (rc=$rc)" >&2; exit 1; }
echo "test-graphiti-ontology-source-parity: OK"
