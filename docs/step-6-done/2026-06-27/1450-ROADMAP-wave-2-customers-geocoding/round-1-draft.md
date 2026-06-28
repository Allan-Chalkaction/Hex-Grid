# Wave: customers-geocoding
**Protocol version:** 3
**Has UI:** true

## Tickets

### CG-T1: Author migration `0002_customers_geocoding.sql` (forward-only) following the…
- depends_on: []
- planned_files: [supabase/migrations/0002_customers_geocoding.sql]
- acceptance: [AC-001, AC-002, AC-003, AC-004, AC-005, AC-018]
- gate_recommendations: [db-migration-reviewer, security-auditor]
- manual_review_required: true
- description: |
    Author migration `0002_customers_geocoding.sql` (forward-only) following the BINDING build order customer → RLS → site.customer_id → view. (1) Create the `customer` table: `id`, `tenant_id` FK→tenant `on delete cascade`, `name`, `attributes jsonb default '{}'`, `created_at`, `updated_at`, and `unique (tenant_id, name)`. (2) Enable RLS on `customer` with four per-table policies (select/insert/update/delete) keyed off `tenant_id in (select auth_tenant_ids())`, mirroring `site_tenant_*` in `0001_init_postgis_schema.sql` EXACTLY — no generic/shared policy, no anon policy; the using/with-check expressions must match the `site_tenant_*` shape (template in 0001). (3) Add `site.customer_id uuid NOT NULL references customer(id) on delete cascade` plus index `site_customer_id_idx`; assert `select count(*) from site = 0` (empty post-W1, no backfill). (4) Create view `site_geo` exposing `id, customer_id, name, address, lat, lng` with `(security_invoker = true)` so it runs under the CALLER's RLS (a plain owner-run view leaks cross-tenant). MUST reuse (NOT redefine) `auth_tenant_ids()` and `geocode_cache` from 0001 and leave `site.exclusivity_radius_mi` untouched (W3 owns the radius grain). Reversible by `drop view site_geo; alter table site drop column customer_id; drop table customer;`. The migration also establishes the tenant-isolation posture verified by a two-tenant RLS integration test against `customer` and `site_geo` (tenant B invisible to tenant A; unauthenticated PostgREST select returns zero rows).

### CG-T2: Create the `geocode` Supabase Edge Function…
- depends_on: []
- planned_files: [supabase/functions/geocode/index.ts]
- acceptance: [AC-007, AC-008, AC-016]
- gate_recommendations: [security-auditor, code-reviewer]
- manual_review_required: true
- description: |
    Create the `geocode` Supabase Edge Function (`supabase/functions/geocode/index.ts`). It accepts a BATCH of address strings, hashes each, reads `geocode_cache` (from 0001), and calls the KEYLESS US Census one-line-address endpoint ONLY for cache misses (bounded concurrency 3–5), writes results back to cache, and returns `{lat,lng}|null` per input address IN INPUT ORDER. It forwards the caller's JWT so the `geocode_cache_insert` (authenticated) RLS policy passes. SECURITY: never trust client-supplied coordinates — geocode the address string only (no `lat`/`lng` read from the request body for persistence); cap address length and reject oversized batches; never echo internal/stack errors (return a structured per-address failure reason). Cache behavior is load-bearing for AC-016: a second request for an already-geocoded address must make ZERO outbound Census calls (resolves from `geocode_cache`). Verify locally with `supabase functions serve` + a batch request, then a repeat request asserting no Census call.

### CG-T3: Create `src/lib/geocoder.ts` defining the swappable geocoding seam following…
- depends_on: [CG-T2]
- planned_files: [src/lib/geocoder.ts]
- acceptance: [AC-006]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Create `src/lib/geocoder.ts` defining the swappable geocoding seam following W1's R5 pluggable-seam pattern (`src/lib/auth.ts` / `tenant.ts`). Export a `Geocoder` INTERFACE — the type consumers depend on — and an `EdgeGeocoder` implementation that calls `supabase.functions.invoke('geocode')` (the function from CG-T2). Consumers (`customers.ts`, `csvImport.ts`) MUST import the interface type, not the concrete `EdgeGeocoder` class, so the seam stays swappable. Type the batch contract `addresses[] → ({lat,lng}|null)[]` matching the Edge Function's input-order return.

### CG-T4: Create `src/lib/customers.ts` with `createCustomerWithSites` — the…
- depends_on: [CG-T1, CG-T3]
- planned_files: [src/lib/customers.ts, supabase/migrations/0002_customers_geocoding.sql]
- acceptance: [AC-009, AC-021]
- gate_recommendations: [code-reviewer, db-migration-reviewer]
- manual_review_required: true
- description: |
    Create `src/lib/customers.ts` with `createCustomerWithSites` — the manual-add write path. It upserts the customer (by `(tenant_id, name)`), geocodes EACH site through the `Geocoder` interface (CG-T3) BEFORE insert, and inserts each site via PostgREST API-first using EWKT: `geog: 'SRID=4326;POINT(lng lat)'`. WIRE-TO-CONSUMER (AC-009): the geocoder must actually be INVOKED here (and in csvImport.ts, CG-T5) — proven to fire, not merely defined; the add-flow test asserts the geocoder is called per site. AC-021 (API-first geo, EWKT round-trip): the implementer MUST verify a single EWKT insert round-trips to a readable `site_geo` row BEFORE committing to the approach; if it does NOT, add a `security invoker` RPC `place_site(customer_id, name, address, lat, lng)` doing `ST_SetSRID(ST_MakePoint(lng,lat),4326)` to migration `0002` (this is the only conditional edit to that file — serialized behind CG-T1) and call the RPC instead. The Edge Function does geocoding ONLY; persistence stays client-side API-first.

### CG-T5: Create the CSV bulk-import path: `src/lib/csvImport.ts` (orchestration) +…
- depends_on: [CG-T4, CG-T6]
- planned_files: [src/lib/csvImport.ts, src/components/CustomerImport.tsx, package.json]
- acceptance: [AC-009, AC-013, AC-014, AC-017, AC-019]
- gate_recommendations: [security-auditor, accessibility-auditor, code-reviewer]
- manual_review_required: true
- description: |
    Create the CSV bulk-import path: `src/lib/csvImport.ts` (orchestration) + `src/components/CustomerImport.tsx` (UI), and add `papaparse` + its types to `package.json`. The component accepts a CSV (one row per site: `customer_name, site_name?, address, …`; extra columns ignored, unknown/missing columns reported precisely), validates size (~5 MB) / type / row caps (~1000) CLIENT-SIDE BEFORE any network call, parses with papaparse, and per row: upserts `customer` by `(tenant_id, name)` via `onConflict` (reusing customers.ts helpers, CG-T4), geocodes the address through the `Geocoder` interface IGNORING any CSV lat/lng (AC-009 wire — the geocoder must fire per row), and inserts the site. Dedup (AC-017): duplicate `customer_name` within a tenant collapses to one customer; a duplicate site is reported `skipped-duplicate`, not inserted twice. Always render a per-row results/errors report (created / geocode-failed / skipped-duplicate) — EVEN on total failure — with an in-flight `<progress>` + cancel and a copy/download-errors affordance; report rows map 1:1 to input rows with one outcome each. SECURITY (AC-019): untrusted CSV parsed client-side only (no server file storage), caps enforced pre-upload, addresses geocoded (never trust CSV lat/lng), no internal errors echoed. Uses the form/field/report CSS classes authored in CG-T6 (no `index.css` edit here; shared-sink edge to CG-T6).

### CG-T6: Create `src/components/CustomerForm.tsx` — the manual-add UI — and author…
- depends_on: [CG-T4]
- planned_files: [src/components/CustomerForm.tsx, src/index.css]
- acceptance: [AC-011, AC-012]
- gate_recommendations: [accessibility-auditor, ui-review, code-reviewer]
- manual_review_required: true
- description: |
    Create `src/components/CustomerForm.tsx` — the manual-add UI — and author the new panel/form/status CSS classes in `src/index.css` (plain semantic CSS, NO Tailwind/tokens; follow the existing `src/index.css` literals `#1a73e8`, `#b00020`, `#555` helper). The form is a SINGLE combined surface: customer brand fields (name + attrs) PLUS a repeatable list of site rows requiring ≥1 site (submit blocked with 0 rows). On submit it calls `customers.ts createCustomerWithSites` (CG-T4) to upsert the customer, geocode each site, and insert via EWKT; a successful add makes the site's pin appear on the map. Per-site geocode status (AC-012) is shown DISTINCTLY — pending, geocoded, or failed — signaled non-color-alone (word + glyph + color); a failed-geocode site is persisted UN-geocoded and flagged, never silently dropped. The four failure classes (no-match / ambiguous / network-timeout / rate-limit-429) each surface a specific recovery path (manual coords / pick-candidate / retry / backoff+retry); status text is screen-reader readable. Follow the W1 form a11y pattern (`useId`, `role="alert"`, `.field`/`.form-error`) from `AuthGate.tsx`; native `<dialog>` (focus trap + ESC + backdrop) recommended with a `.site-panel` fallback.

### CG-T7: Create `src/components/CustomerList.tsx` (superseding the read-only…
- depends_on: [CG-T5, CG-T6]
- planned_files: [src/components/CustomerList.tsx, src/App.tsx, src/components/SiteList.tsx, src/index.css]
- acceptance: [AC-015, AC-020]
- gate_recommendations: [accessibility-auditor, ui-review, code-reviewer]
- manual_review_required: true
- description: |
    Create `src/components/CustomerList.tsx` (superseding the read-only `SiteList.tsx`), wire all new surfaces into `src/App.tsx`, delete `src/components/SiteList.tsx`, and apply the final a11y CSS pass to `src/index.css`. CustomerList lists customers with their sites (RLS-auto-scoped read — no client `where tenant_id`, like W1 `SiteList`) and supports: edit-site-address (re-geocode via the geocoder seam + pin moves), move-site (update `geog`, pin moves), and delete-customer (cascades its sites; UI confirm dialog shows "deletes N sites" before proceeding). `App.tsx` must render `CustomerForm` (CG-T6), `CustomerImport` (CG-T5), and `CustomerList` and NO LONGER render `SiteList`. AC-020 (a11y, applies across every new form/list surface): `useId()` label association, real `<label>`/`<button>`, `role="alert"`/`aria-live` for errors, native focus order, status non-color-alone; darken the link-as-body-text blue to `#1558b0` (~5.9:1) in `index.css` where it would otherwise fail AA. Accessibility review against the four W1 north-star files (`AuthGate.tsx`, `SiteList.tsx`, `index.css`, `MapShell.tsx`); contrast passes WCAG 2.2 AA. (Shares `index.css` with CG-T6/CG-T5 — direct edges to both serialize the sink.)

### CG-T8: Create `src/components/sitePinsLayer.ts` (a deck.gl `ScatterplotLayer` fed…
- depends_on: [CG-T1]
- planned_files: [src/components/sitePinsLayer.ts, src/components/MapShell.tsx]
- acceptance: [AC-010]
- gate_recommendations: [ui-review, code-reviewer]
- manual_review_required: true
- description: |
    Create `src/components/sitePinsLayer.ts` (a deck.gl `ScatterplotLayer` fed from the `site_geo` view, CG-T1) and MOUNT it into `src/components/MapShell.tsx`, REPLACING the empty `MapboxOverlay({ layers: [] })` placeholder at the existing W1 attach point. WIRE-TO-CONSUMER (AC-010): the layer must fire in the REAL render path, not just exist — `MapShell.tsx` imports and mounts `sitePinsLayer`, and the empty `MapboxOverlay({ layers: [] })` no longer appears in `MapShell.tsx`. Pins are sourced from `site_geo` (`id, customer_id, name, address, lat, lng`), so a newly-added/geocoded site renders as a pin.
