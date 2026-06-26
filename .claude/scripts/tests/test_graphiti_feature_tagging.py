"""W1 (ADR-096) — unit tests for the [feature:] tagging axis in graphiti_write.py.

Pure-stdlib host tests (no docker, no neo4j) covering the write-side feature contract:
  (a) _resolve_feature three paths (registered / unregistered-valid / missing-invalid)
      + the AC-021 divergence (missing/invalid -> None, never the registry fallback).
  (b) hybrid assignment — path-derived default + --feature override augments.
  (c) repeated single-slug stamp form via dry_run (NOT comma-joined).
  (b/c extra) AC-008 content-hash isolation; AC-015 body isolation; AC-017 no-feature byte-identity.
  (g) additive/reversible grep-asserts — no migration file; default read selects CYPHER, not CYPHER_FEATURED.

The live ~/graphiti registry (GRAPHITI_REPO, default ~/graphiti) is exercised directly: it is a
hard prerequisite (GIS-T1, deployed) and these assertions resolve against it. pytest is not on the
host, so this file is also runnable as a plain script (the .sh sibling drives it).

Run:
    pytest core/scripts/tests/test_graphiti_feature_tagging.py
    python3 core/scripts/tests/test_graphiti_feature_tagging.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
REPO_ROOT = SCRIPTS.parent.parent
sys.path.insert(0, str(SCRIPTS))

import graphiti_write as gw  # noqa: E402


# ---------------------------------------------------------------------------
# (a) _resolve_feature three paths + AC-021 divergence
# ---------------------------------------------------------------------------

def test_resolve_feature_known_slug():
    assert gw._resolve_feature("sdr") == "sdr"


def test_resolve_feature_case_insensitive():
    assert gw._resolve_feature("SDR") == "sdr"
    assert gw._resolve_feature("Self-Service") == "self-service"


def test_resolve_feature_unregistered_but_valid_preserved():
    # unregistered-but-charset-valid -> preserved as given (lowercased), caller emits UNREGISTERED_FEATURE
    assert gw._resolve_feature("brand-new-feature") == "brand-new-feature"


def test_resolve_feature_missing_returns_none():
    # AC-021: missing/empty -> None (NOT the registry fallback "general")
    assert gw._resolve_feature(None) is None
    assert gw._resolve_feature("") is None
    assert gw._resolve_feature("   ") is None


def test_resolve_feature_invalid_charset_returns_none():
    # AC-021: invalid charset -> None (no [feature:general] ever)
    assert gw._resolve_feature("bad slug!") is None
    assert gw._resolve_feature("a]b") is None
    assert gw._resolve_feature("'; DROP") is None


# ---------------------------------------------------------------------------
# (b) hybrid assignment — path-derived default + override augments (AC-005)
# ---------------------------------------------------------------------------

def test_derive_features_path_derived():
    assert gw._derive_features("docs/features/sdr/notes.md", None, None) == ["sdr"]


def test_derive_features_path_then_override_augments():
    # path gives sdr; --feature self-service augments (sets-or-augments, ordered, de-duped)
    assert gw._derive_features("docs/features/sdr/notes.md", None, "self-service") == ["sdr", "self-service"]


def test_derive_features_frontmatter_second():
    # no path segment -> frontmatter feature is used
    assert gw._derive_features("README.md", "sdr", None) == ["sdr"]


def test_derive_features_cli_multi_case_insensitive_deduped():
    assert gw._derive_features(None, None, "SDR,Self-Service,sdr") == ["sdr", "self-service"]


def test_derive_features_none_is_empty():
    assert gw._derive_features(None, None, None) == []
    assert gw._derive_features("README.md", None, None) == []


# ---------------------------------------------------------------------------
# (c) repeated single-slug stamp form via dry_run (AC-006)
# ---------------------------------------------------------------------------

def test_stamp_repeated_single_slug_form():
    r = gw.write_fact("a fact about sdr", group_id="claude-infra-v2",
                      feature="sdr,self-service", dry_run=True)
    sd = r["source_description"]
    assert "[feature:sdr]" in sd
    assert "[feature:self-service]" in sd
    # NEVER comma-joined
    assert "[feature:sdr,self-service]" not in sd
    assert "sdr,self-service]" not in sd


def test_no_feature_byte_identity():
    # AC-017: no --feature, non-docs/features path -> no [feature: substring, identical spacing
    r = gw.write_fact("plain fact", group_id="claude-infra-v2",
                      source_description="plain fact", dry_run=True)
    sd = r["source_description"]
    assert "[feature:" not in sd
    assert sd == f"plain fact [sha:{r['content_hash']}]"


def test_invalid_feature_never_general():
    # AC-021: an invalid --feature must produce NO tag, never [feature:general]
    r = gw.write_fact("x", group_id="claude-infra-v2", feature="!!!bad", dry_run=True)
    assert "[feature:" not in r["source_description"]


# ---------------------------------------------------------------------------
# (d) AC-008 content-hash isolation (idempotency immune to the tag)
# ---------------------------------------------------------------------------

def test_content_hash_unaffected_by_feature():
    a = gw.write_fact("identical body", group_id="claude-infra-v2", feature="sdr", dry_run=True)
    b = gw.write_fact("identical body", group_id="claude-infra-v2", feature="self-service", dry_run=True)
    c = gw.write_fact("identical body", group_id="claude-infra-v2", dry_run=True)
    assert a["content_hash"] == b["content_hash"] == c["content_hash"]


def test_content_hash_signature_takes_only_gid_and_scrubbed():
    # the hash takes (group_id, scrubbed) only — feeding a feature/source_description is impossible
    import inspect
    params = list(inspect.signature(gw._content_hash).parameters)
    assert params == ["group_id", "scrubbed"], f"_content_hash signature drifted: {params}"


# ---------------------------------------------------------------------------
# (AC-015) body isolation — feature tag NEVER reaches body/scrubbed
# ---------------------------------------------------------------------------

def test_feature_never_in_body():
    # the resolved tag + slug must reach source_description ONLY, never the (scrubbed) episode body.
    r = gw.write_fact("an opaque body string", group_id="claude-infra-v2",
                      feature="sdr", dry_run=True)
    assert "[feature:" not in r["body"]
    assert "sdr" not in r["body"]
    assert r["body"] == "an opaque body string"


# ---------------------------------------------------------------------------
# (g) additive/reversible (AC-019) — no migration; default read path invariant
# ---------------------------------------------------------------------------

def test_no_migration_file_in_scope():
    # the wave's planned files contain no migration/schema file
    write = (SCRIPTS / "graphiti_write.py").read_text()
    read = (SCRIPTS / "graphiti-read.py").read_text()
    assert "migration" not in write.lower().replace("migration file", "")  # only doc mentions allowed
    # the read path still defines the unfiltered CYPHER default
    assert "CYPHER = (" in read
    assert "CYPHER_FEATURED" in read


def test_default_read_selects_unfiltered_cypher():
    # AC-019/AC-009: with no --feature, fetch_facts must NOT select CYPHER_FEATURED
    import importlib.util
    spec = importlib.util.spec_from_file_location("gr_feat_test", SCRIPTS / "graphiti-read.py")
    gr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gr)
    assert gr._feature_slugs(None) == []  # no slugs -> CYPHER branch
    assert gr._feature_slugs("") == []


def test_feature_slugs_charset_gate_drops_injection():
    # SA-001 / ADR-096: write-read validation symmetry. A quote/bracket-bearing slug must be DROPPED
    # before it can reach the cypher-shell parameter expression `fmarker{i} => '[feature:{slug}]'`.
    import importlib.util
    spec = importlib.util.spec_from_file_location("gr_feat_test_sa001", SCRIPTS / "graphiti-read.py")
    gr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gr)
    assert gr._feature_slugs("x' OR '1'='1") == []        # quote-injection slug dropped
    assert gr._feature_slugs("a]b") == []                 # bracket-bearing slug dropped
    assert gr._feature_slugs("sdr,bad;slug") == ["sdr"]   # valid kept, invalid dropped
    assert gr._feature_slugs("SDR,Self-Service") == ["sdr", "self-service"]  # valid passes, lowercased


# ---------------------------------------------------------------------------
# (f) wire-to-consumer grep-asserts (AC-011/AC-022/AC-023) — run unconditionally
# ---------------------------------------------------------------------------

def test_resolve_feature_called_inside_write_fact():
    src = (SCRIPTS / "graphiti_write.py").read_text()
    assert "def _resolve_feature(" in src, "resolver must be defined"
    # _derive_features (which calls _resolve_feature) is invoked inside write_fact
    body = src.split("def write_fact(", 1)[1]
    assert "_derive_features(" in body, "_derive_features must be CALLED inside write_fact"
    assert "_resolve_feature(" in src.split("def _derive_features(", 1)[1], \
        "_resolve_feature must be CALLED inside _derive_features"


def test_feature_drives_cypher_featured_inside_fetch_facts():
    src = (SCRIPTS / "graphiti-read.py").read_text()
    assert "CYPHER_FEATURED = (" in src, "CYPHER_FEATURED must be declared"
    body = src.split("def fetch_facts(", 1)[1].split("\ndef ", 1)[0]
    assert "CYPHER_FEATURED" in body, "fetch_facts must SELECT CYPHER_FEATURED"
    assert "fmarker" in body, "fetch_facts must bind one fmarker param per slug"


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  [ok] {name}")
            except Exception as e:  # noqa: BLE001
                failures += 1
                print(f"  [FAIL] {name}: {e}")
    print("PASS" if failures == 0 else f"FAIL ({failures})")
    sys.exit(1 if failures else 0)
