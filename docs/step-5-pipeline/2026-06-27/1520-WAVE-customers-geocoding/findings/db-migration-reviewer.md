# Migration Review — Wave 2 (customers-geocoding) · `0002_customers_geocoding.sql`

**Verdict: APPROVE** · Safe to apply on the empty post-W1 schema. RLS shape, view invoker flag, search_path pinning, anon-revoke all correct + faithful to ADR-002/0001. No Critical/High. One Medium hardening + minor index/defense notes.

Schema: `customer` table (4 per-table RLS policies mirroring `site_tenant_*`, `unique(tenant_id,name)`), `site.customer_id NOT NULL` behind empty-table DO-guard, `site_geo` security_invoker view, `place_site` security-invoker RPC. Rollback documented + dependency-correct (`:14-18`).

## MR-001 — No DB-level tenant↔customer consistency on direct `site` insert surface — MEDIUM · `_criterion_match_: none` · DEFER/APPLY
`site.customer_id` FK (`:83-84`) + inherited `site_tenant_insert` RLS checks only `tenant_id ∈ auth_tenant_ids()`. FK bypasses RLS → a direct PostgREST `site` insert can pair caller's own tenant_id with another tenant's customer_id. Intra-tenant integrity gap (no leak; row stays in attacker's tenant). Shipped create path uses `place_site` (derives tenant from customer) → immune; the open PostgREST insert surface remains unconstrained.
**Remediation:** composite unique `customer(tenant_id,id)` + composite FK `site(tenant_id,customer_id)`, or revoke direct INSERT on `site` and route all creation through `place_site`.

## MR-002 — Redundant `customer_tenant_id_idx` — LOW · `unique(tenant_id,name)` already covers `where tenant_id=?`. Drop the standalone index.
## MR-003 — `site_geo` not revoked from anon (defense-in-depth) — LOW · invoker semantics already safe; add `revoke select on site_geo from anon` for consistency with `place_site`.
## MR-004 — Hard cascade delete of sites, no recovery — LOW · intended AC-015; direct PostgREST customer delete bypasses UI confirm + irreversible. Noted for production.
## MR-005 — `place_site` deviates from ADR signature (returns uuid/plpgsql vs returns site/sql) — INFO · functionally correct + arguably better; TS caller matches.

Validation checklist: RLS enabled + conventions ✓; rollbackable ✓; zero-downtime ✓ (ADD COLUMN NOT NULL safe only because site empty; DO-guard aborts loudly; single txn); FK indexes ✓; cascade intentional ✓; ADR shape ✓; AC-018 reuse-not-redefine confirmed (no redefinition of auth_tenant_ids/geocode_cache, exclusivity_radius_mi untouched).
