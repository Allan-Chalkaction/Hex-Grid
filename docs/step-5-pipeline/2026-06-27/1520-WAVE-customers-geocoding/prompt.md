# Wave 2 — customers-geocoding (Customers + geocoding CRUD)
Ticket key: HGW-2

Build the graduated 8-ticket wave (CG-T1..CG-T8) authored by /roadmap Phase W. The ticket
graph (depends_on / planned_files / gate_recommendations) is passed to the engine — build the
AUTHORED graph; do not re-decompose.

## Binding model (operator clarification)
`customer` (brand, e.g. "Joe's Pizza Shack") and `site` (physical location, holds geog) are
distinct, 1→N. W1 shipped `site` (tenant_id, no customer_id) + `geocode_cache`. W2 adds a
`customer` table + `site.customer_id NOT NULL` (migration 0002), geocodes PER SITE via a keyless
US Census Edge Function (persistence stays client-side API-first via PostgREST/EWKT), and ships
the add/import/list/edit/move/delete UI + deck.gl pins. SQLite import deferred (cto SIMPLIFY) —
CSV only.

## Standing instructions
- Honor W1's patterns: per-table RLS keyed off auth_tenant_ids(); pluggable seams (auth/tenant →
  now geocoder); API-first PostgREST; W1 form a11y pattern (useId, role=alert).
- Full spec: customers-geocoding.md (this folder); per-ticket prose: customers-geocoding-prompts.md.
- Gates per ticket as authored; security-auditor auto-added on migration/Edge-Function surfaces.
