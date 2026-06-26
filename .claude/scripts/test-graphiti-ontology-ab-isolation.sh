#!/usr/bin/env bash
# test-graphiti-ontology-ab-isolation.sh — A/B namespace registration + partition isolation smoke.
# (graphiti-cost-efficiency Wave 2, W2TE-T3.)
#
# A/B namespace uses a DASH delimiter (ab-wave2-typed-<topic>), NOT a colon: graphiti-core 0.28.1
# rejects colons in group_id (charset = ASCII alphanumeric + dash + underscore). The colon form in
# ADR-073 R5 / architect D5 is infeasible at the engine layer; the dash form is semantically identical.
#
# Always (no docker needed):
#   * validate_group_id() accepts the SUPPLIED suffixed forms ab-wave2-{typed,freeform}-<topic>
#     (the load-bearing check — if the validator still required exact-match, the T4 harness would
#     silently quarantine every A/B write to unsorted:NEEDS_TRIAGE).
#   * the registry has both ab-wave2-* entries with kind:"ab" and derivable:false.
#
# With docker (mcp container up): writes ONE A/B pair via the sanctioned write_fact() path, then
# asserts via a neo4j READ (mcp venv python + bolt, the dim-guard pattern) that the pair landed in
# exactly two distinct group_ids AND that NOTHING bearing the test topic leaked into the live
# capture group claude-infra-v2 (sacred — Wave 1 T8-B flipped capture-live 2026-06-09T17:38:55Z).
#
# Without docker: skip gracefully (exit 0), mirroring test-graphiti-embedding-dim.sh.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP="${GRAPHITI_MCP_CONTAINER:-docker-graphiti-mcp-1}"
# Locate the graphiti repo: explicit env wins, else probe common $HOME locations.
# Absent everywhere -> the read below fails open and the session continues untouched.
if [ -z "${GRAPHITI_REPO:-}" ]; then
  for _cand in "$HOME/graphiti" "$HOME/Desktop/Dev/graphiti" "$HOME/Desktop/Development/graphiti"; do
    [ -d "$_cand" ] && { GRAPHITI_REPO="$_cand"; break; }
  done
fi
GRAPHITI_REPO="${GRAPHITI_REPO:-$HOME/graphiti}"
PYV="/app/mcp/.venv/bin/python"

# --- Always: validator + registry (host python, no docker) ---
GRAPHITI_REPO="$GRAPHITI_REPO" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["GRAPHITI_REPO"])
import graphiti_groups as gg
reg = gg.load_registry()
for k in ("ab-wave2-typed", "ab-wave2-freeform"):
    e = reg.groups.get(k)
    assert e, f"registry missing {k}"
    assert e.get("kind") == "ab", f"{k} kind != ab ({e.get('kind')})"
    assert e.get("derivable") is False, f"{k} derivable != false"
for g in ("ab-wave2-typed-t3-smoke-pretest", "ab-wave2-freeform-t3-smoke-pretest"):
    valid, eff = gg.validate_group_id(g, reg)
    assert valid and eff == g, f"validator rejected SUPPLIED form {g!r}: {(valid, eff)}"
# Fail-closed preserved for an unregistered ab namespace.
valid, eff = gg.validate_group_id("ab-wave3-typed-x", reg)
assert (not valid) and eff == reg.quarantine, "unregistered ab namespace must fail closed"
print("OK validator+registry (suffixed forms accepted; fail-closed preserved)")
PY
[ "$?" -ne 0 ] && { echo "FAIL: validator/registry assertions" >&2; exit 1; }

# --- docker probe -> skip gracefully ---
if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP}$"; then
  echo "SKIP: docker / ${MCP} not available — validator+registry checks passed; live isolation skipped."
  exit 0
fi

# --- Live: write one A/B pair via the sanctioned write_fact() path ---
TOPIC="t3-isolation-$(date +%s)"
SCRIPTS_DIR="$SCRIPTS_DIR" TOPIC="$TOPIC" python3 - <<'PY'
import os, re, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from graphiti_write import write_fact
# Environmental/API-unavailability conditions that warrant a graceful SKIP (not a code-defect FAIL).
_ENV_API_RE = re.compile(
    r"credit balance|invalid_request_error|rate limit|overloaded|quota|insufficient|billing|503|429",
    re.IGNORECASE)
topic = os.environ["TOPIC"]
text = f"Wave 2 isolation smoke marker {topic}: typed-vs-freeform partition isolation canary fact."
for arm in ("typed", "freeform"):
    gid = f"ab-wave2-{arm}-{topic}"
    r = write_fact(text, group_id=gid, source_description="W2TE-T3 isolation smoke")
    if r.get("status") == "error" and _ENV_API_RE.search(str(r.get("error", ""))):
        print(f"SKIP-ENV: graphiti API unavailable (live write_fact returned {r.get('error')!r})", file=sys.stderr)
        sys.exit(77)
    assert r["status"] in ("written", "duplicate"), f"{arm} write failed: {r}"
    assert r["group_id"] == gid, f"{arm} resolved to wrong group: {r['group_id']} (expected {gid})"
    print(f"  {arm}: {r['status']} -> {r['group_id']}")
print("WROTE_PAIR", topic)
PY
rc=$?
[ "$rc" -eq 77 ] && { echo "SKIP: graphiti API unavailable (credit/billing/rate-limit) — static guards passed; live write skipped."; exit 0; }
[ "$rc" -ne 0 ] && { echo "FAIL: A/B pair write through write_fact()" >&2; exit 1; }

# --- Verify: 2 distinct group_ids + 0 leaked into claude-infra-v2 (neo4j read via mcp venv) ---
OUT="$(docker exec -e SMOKE_TOPIC="$TOPIC" -w /app/mcp "$MCP" "$PYV" -c '
import os
from neo4j import GraphDatabase
topic = os.environ["SMOKE_TOPIC"]
d = GraphDatabase.driver(os.environ["NEO4J_URI"], auth=(os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"]))
with d.session() as s:
    groups = [r["g"] for r in s.run(
        "MATCH (n) WHERE n.group_id IN [$t,$f] RETURN DISTINCT n.group_id AS g",
        t=f"ab-wave2-typed-{topic}", f=f"ab-wave2-freeform-{topic}").data()]
    leaked = s.run(
        "MATCH (n) WHERE n.group_id=$c AND n.name CONTAINS $topic RETURN count(n) AS n",
        c="claude-infra-v2", topic=topic).single()["n"]
print("GROUPS", len(groups))
print("LEAKED", leaked)
d.close()
' 2>/dev/null | grep -E '^(GROUPS|LEAKED) ')"

groups="$(echo "$OUT" | awk '/^GROUPS/{print $2}')"
leaked="$(echo "$OUT" | awk '/^LEAKED/{print $2}')"
echo "  distinct A/B group_ids: ${groups:-?} ; leaked into claude-infra-v2: ${leaked:-?}"
if [ "${groups:-0}" -ne 2 ]; then
  echo "FAIL: expected 2 distinct A/B group_ids, got ${groups:-0} (typed arm may be quarantining)" >&2; exit 1
fi
if [ "${leaked:-1}" -ne 0 ]; then
  echo "FAIL: ${leaked} node(s) bearing the test topic LEAKED into claude-infra-v2 (live capture group is sacred)" >&2; exit 1
fi
echo "test-graphiti-ontology-ab-isolation: OK (topic=${TOPIC})"
