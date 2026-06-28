# Round 0 intent — Wave 2 (customers-geocoding)

_Snapshot of the wave's fat skeleton from `docs/step-3-specs/hex-grid/waves/customers-geocoding/customers-geocoding.md`, plus epic context from the build-plan. Note: no canonical `roadmap.md` exists for this epic; the per-wave skeletons + `build-plan.md` are the de-facto roadmap. Graduating Wave 2 only._

## Wave 2 — customers-geocoding (Customers + geocoding CRUD)

**Ships:** add/import customers + their sites, see them as pins.

- Manual add form → geocode (US Census, behind a `Geocoder` interface) → persist → pin.
- CSV / SQLite bulk import: parse → batch geocode → dedup → persist, with a results/errors report.
- Edit / move / delete; geocode cache so re-adds are free.

**Gates:** code-reviewer · security-auditor (file upload + external geocode calls) · db-migration-reviewer (the `0002` migration).

Depends on: Wave 1 (hex-grid-foundation) — shipped & merged to main.

## Domain-model clarification (operator, 2026-06-27) — BINDING

`customer` and `site` are **distinct entities**:

- **customer** = a *brand* (e.g. "Joe's Pizza Shack"). Has **no geography of its own**.
- **site** = a *physical location*. Holds the `geog` point. **A customer has many sites** (1→N).

Wave 1 shipped `site` with `tenant_id` but **no `customer_id`**, and there is **no `customer` table yet**. So Wave 2 must:

1. **Add a `customer` table** (`tenant_id`, `name`, brand attrs) with the same per-table RLS pattern as W1 (keyed off `auth_tenant_ids()`), and
2. **Add `site.customer_id`** FK → `customer` (nullable→backfill vs. required: decide at design).

### Open questions the design funnel MUST resolve
- **What gets geocoded?** Geography lives on `site`, not `customer`. The "add-customer" flow is really *add a customer (brand) + one-or-more sites*, and **geocoding runs per site**. Settle the form/flow shape.
- **CSV/import grain:** row = a site (with a customer name to match/create), or a customer? Likely **one row per site** with customer dedup/upsert by name within the tenant.
- **Cross-wave (W3 exclusivity):** build-plan says "radius per customer." Reconcile: customer-level default applied to all its sites, vs. per-site. Owned by W3, but the W2 schema (`exclusivity_radius_mi` currently on `site`) must not foreclose it.
- **Migration:** `0002_*` adds `customer` + `site.customer_id`; db-migration-reviewer gate applies.

## Existing W1 substrate the design must build on (verify-by-view)
- `supabase/migrations/0001_init_postgis_schema.sql` — `tenant`, `membership`, `site`, `geocode_cache`; per-table RLS; `auth_tenant_ids()` SECURITY DEFINER helper (search_path pinned).
- `src/lib/{supabaseClient,auth,tenant}.ts` — pluggable auth seam + tenant resolver.
- `src/components/{MapShell,SiteList,AuthGate}.tsx` + `App.tsx` — map shell + tenant-scoped list.
- `geocode_cache` already exists (tenant-shared, `address_hash` PK) — the W2 geocoder writes here.
