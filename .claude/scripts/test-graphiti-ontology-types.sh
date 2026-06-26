#!/usr/bin/env bash
# test-graphiti-ontology-types.sh — unit-test the 11 typed entity classes + the _SourceAnchored mixin.
# (graphiti-cost-efficiency Wave 2, W2TE-T1.)
#
# Pure Python imports — NO docker needed. Asserts:
#   1. All 11 classes + the _SourceAnchored mixin import from graphiti_ontology_types.py.
#   2. The doc-class subset {ADR, Spec, Roadmap, RunLog, Component} inherits _SourceAnchored.
#   3. The non-doc subset {Decision, Gotcha, Jam, SessionLearning, Person, Project} does NOT.
#   4. Every class carries a non-empty docstring (the docstring IS the extraction prompt).
#   5. Host-only-surface invariant: graphiti_ontology_types.py does NOT reference the in-container
#      ENTITY_TYPES map (a positive grep-assert — the parity test's exclusion is not itself a check).
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_FILE="$SCRIPTS_DIR/graphiti_ontology_types.py"

# 5. Positive host-only-surface assert (cheap, runs first; no python needed).
if grep -nE '(^|[^A-Za-z_])ENTITY_TYPES([^A-Za-z_]|$)' "$HOST_FILE" >/dev/null; then
  echo "FAIL: graphiti_ontology_types.py must NOT reference ENTITY_TYPES (host-only-surface invariant)" >&2
  exit 1
fi

python3 - "$SCRIPTS_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from graphiti_ontology_types import (
    _SourceAnchored, ADR, Spec, Roadmap, RunLog, Component,
    Decision, Gotcha, Jam, SessionLearning, Person, Project,
)

DOC = {"ADR": ADR, "Spec": Spec, "Roadmap": Roadmap, "RunLog": RunLog, "Component": Component}
NONDOC = {"Decision": Decision, "Gotcha": Gotcha, "Jam": Jam,
          "SessionLearning": SessionLearning, "Person": Person, "Project": Project}

assert len(DOC) == 5, f"expected 5 doc-class types, got {len(DOC)}"
assert len(NONDOC) == 6, f"expected 6 non-doc types, got {len(NONDOC)}"

for name, cls in DOC.items():
    assert issubclass(cls, _SourceAnchored), f"{name} must inherit _SourceAnchored"
for name, cls in NONDOC.items():
    assert not issubclass(cls, _SourceAnchored), f"{name} must NOT inherit _SourceAnchored"

# _SourceAnchored declares the four source-anchor fields.
for f in ("source_path", "heading_anchor", "start_line", "end_line"):
    assert f in _SourceAnchored.model_fields, f"_SourceAnchored missing field {f}"

# Doc-class types carry the inherited source-anchor fields; non-doc do not.
for name, cls in DOC.items():
    assert "source_path" in cls.model_fields, f"{name} should carry source_path (inherited)"
for name, cls in NONDOC.items():
    assert "source_path" not in cls.model_fields, f"{name} should NOT carry source_path"

# Every concrete class has a non-empty docstring (the extraction prompt).
ALL = {**DOC, **NONDOC, "_SourceAnchored": _SourceAnchored}
for name, cls in ALL.items():
    doc = (cls.__doc__ or "").strip()
    assert doc, f"{name} has an empty docstring (the docstring IS the extraction prompt)"
    assert len(doc) > 20, f"{name} docstring too thin to be an extraction prompt: {doc!r}"

print(f"OK — 11 typed classes + mixin; {len(DOC)} doc-class, {len(NONDOC)} non-doc; all docstrings present")
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: ontology-types unit assertions failed (rc=$rc)" >&2; exit 1; }
echo "test-graphiti-ontology-types: OK"
