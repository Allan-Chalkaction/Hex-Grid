#!/usr/bin/env bash
# test-graphiti-embedding-dim.sh — embedding-dimension consistency guard
# (graphiti-cost-efficiency; addresses docs/step-6-done/deferrals/DONE-2026-06-09-graphiti-embedding-dim-consistency-guard.md)
#
# WHY: on 2026-06-09 an embedder-dim drift (config 1536 vs stored 1024) made add_episode's dedup
# vector.similarity.cosine() fail on EVERY write — silently (in-memory queue, no dead-letter), while
# reads + get_status stayed green. It cost a full debugging detour. This guard FAILS LOUDLY when the
# dimension the write path will produce does not match what's stored, so the drift surfaces in one line.
#
# Checks three sources agree:
#   1. graphiti_write.py _INNER embedder dim (the deliberate-remember / capture write path)
#   2. the MCP server's in-container config.yaml `dimensions` (the add_memory write path)
#   3. the stored Entity.name_embedding dimension for the target group(s) in neo4j
# Container-dependent checks SKIP gracefully (exit 0 with a notice) when docker/container/group is absent,
# so this is safe in CI without the stack; it only FAILS on an actual, observable mismatch.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP="${1:-claude-infra-v2}"
MCP="${GRAPHITI_MCP_CONTAINER:-docker-graphiti-mcp-1}"
PYV="/app/mcp/.venv/bin/python"

# 1. write-path dim (parse from graphiti_write.py _INNER)
write_dim="$(grep -oE 'embedding_dim=[0-9]+' "$SCRIPTS_DIR/graphiti_write.py" | head -1 | grep -oE '[0-9]+' || true)"
echo "write-path embedding_dim (graphiti_write.py): ${write_dim:-<not found>}"
[ -z "$write_dim" ] && { echo "FAIL: could not parse embedding_dim from graphiti_write.py" >&2; exit 1; }

# container-dependent checks
if ! command -v docker >/dev/null 2>&1 || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${MCP}$"; then
  echo "SKIP: docker / ${MCP} not available — write-path dim parsed OK (${write_dim}); container checks skipped."
  exit 0
fi

# 2. in-container config.yaml dimensions
cfg_dim="$(docker exec "$MCP" sh -c 'grep -A2 "model:.*text-embedding" /app/mcp/config/config.yaml | grep -oE "dimensions: [0-9]+"' 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
echo "config.yaml dimensions (in-container): ${cfg_dim:-<not found>}"

# 3. stored name_embedding dim for the group
stored_dims="$(docker exec -w /app/mcp "$MCP" "$PYV" -c "
import os
from neo4j import GraphDatabase
d = GraphDatabase.driver(os.environ['NEO4J_URI'], auth=(os.environ['NEO4J_USER'], os.environ['NEO4J_PASSWORD']))
with d.session() as s:
    rows = s.run('MATCH (n:Entity) WHERE n.group_id=\$g AND n.name_embedding IS NOT NULL RETURN DISTINCT size(n.name_embedding) AS dim', g='$GROUP').data()
print(' '.join(str(r['dim']) for r in rows))
d.close()
" 2>/dev/null | grep -vE "INFO|WARNING" | tail -1 || true)"
echo "stored name_embedding dims for group '$GROUP': ${stored_dims:-<none / empty group>}"

fail=0
# config vs write-path
if [ -n "$cfg_dim" ] && [ "$cfg_dim" != "$write_dim" ]; then
  echo "MISMATCH: config.yaml dimensions ($cfg_dim) != write-path embedding_dim ($write_dim)" >&2; fail=1
fi
# stored vs write-path (only when the group has stored embeddings)
if [ -n "$stored_dims" ]; then
  for sd in $stored_dims; do
    if [ "$sd" != "$write_dim" ]; then
      echo "MISMATCH: stored name_embedding dim ($sd) for group '$GROUP' != write-path dim ($write_dim) — writes will FAIL on vector.similarity.cosine()" >&2; fail=1
    fi
  done
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: embedding-dimension drift detected — fix before writing (see docs/step-6-done/deferrals/DONE-2026-06-09-graphiti-embedding-dim-consistency-guard.md)." >&2
  exit 1
fi
echo "test-graphiti-embedding-dim: OK (write-path=${write_dim}, config=${cfg_dim:-skip}, stored=${stored_dims:-empty} all consistent)"
