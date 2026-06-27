# pm-spec

_Persisted by the orchestrator from the roadmap workflow return (FLAG-1: scripts have no FS access; agents cannot Write)._

# Feature Spec: Wave 2 — Customers + Geocoding CRUD

**Status:** Draft
**Author:** AI-assisted (pm-spec agent)
**Date:** 2026-06-27
**Slug:** customers-geocoding

## Summary
Turn the empty W1 multi-tenant shell into a usable product: add/import customers (brands) and their sites (locations), geocode each site server-side through a Supabase Edge Function (US Census, keyless, cached), persist sites API-first via PostgREST, and render them as pins on the existing deck.gl map. Includes manual add, CSV bulk import with a per-row results/errors report, and edit/move/delete. A `0002` migration introduces the `customer` table and `site.customer_id` FK, mirroring W1's per-table RLS pattern.

## User Stories
- As a tenant member, I want to add a customer (brand) and one-or-more sites in one form so that each location is geocoded and appears as a pin.
- As a tenant member, I want to bulk-import sites from a CSV (one row per site, customer matched/created by name) so that I can onboard many locations at once and see exactly which rows succeeded, failed, or were de-duplicated.
- As a tenant member, I want to edit a site's address (re-geocode), move a site, or delete a customer (cascading its sites) so that I can keep my data correct.
- As a tenant member, I want re-adding the same address to be free (cache hit) so that imports do not re-call the external geocoder.
- As a tenant member, I must never see another tenant's customers, sites, or pins, so that tenant isolation holds across the new entities.

## Acceptance Criteria

### Schema & migration (0002)

- [ ] **AC-001.** Substantive: a `customer` table exists with `id`, `tenant_id` (FK→tenant, `on delete cascade`), `name`, `attributes jsonb default '{}'`, `created_at`, `updated_at`, and `unique (tenant_id, name)`. Verification: `0002_customers_geocoding.sql` applies cleanly to a 0001 baseline; `\d customer` shows the columns and the `unique (tenant_id, name)` constraint.
- [ ] **AC-002.** Substantive: `site.customer_id uuid NOT NULL references customer(id) on delete cascade` is added, with index `site_customer_id_idx`. Because `site` is empty post-W1, the NOT NULL add needs no backfill. Verification: migration asserts/relies on `select count(*) from site = 0` before the add; `\d site` shows `customer_id` NOT NULL + the index; `\d+ site` shows the cascade FK.
- [ ] **AC-003.** Substantive: `customer` has RLS enabled with four per-table policies (select/insert/update/delete) keyed off `tenant_id in (select auth_tenant_ids())`, mirroring `site_tenant_*` exactly (no generic/shared policy, no anon policy). Verification: `git grep -n 'customer_tenant_' supabase/migrations/0002_customers_geocoding.sql` shows all four; the using/with-check expressions match the `site_tenant_*` shape in `0001_init_postgis_schema.sql`.
- [ ] **AC-004.** Substantive: a `site_geo` view exposes pin coordinates (`id, customer_id, name, address, lat, lng`) and is created `with (security_invoker = true)` so it runs under the CALLER's RLS (a plain owner-run view would leak cross-tenant). Verification: `git grep -n 'security_invoker' supabase/migrations/0002_customers_geocoding.sql` returns the view; the cross-tenant RLS test (AC-018) passes through `site_geo`.
- [ ] **AC-005.** Substantive: the migration reuses (does not redefine) `auth_tenant_ids()` and `geocode_cache` from 0001, and leaves `site.exclusivity_radius_mi` untouched (W3 owns the radius-grain decision). Verification: `0002` contains no `create ... auth_tenant_ids`, no `create table geocode_cache`, and no DDL referencing `exclusivity_radius_mi`.

### Geocoding seam (Edge Function + client interface)

- [ ] **AC-006.** Substantive: a `Geocoder` interface in `src/lib/geocoder.ts` defines the swappable seam (W1's R5 pluggable-seam pattern), with an `EdgeGeocoder` implementation that calls `supabase.functions.invoke('geocode')`. The interface is the type consumers depend on — not the concrete class. Verification: `git grep -n 'interface Geocoder' src/lib/geocoder.ts` and consumers (`customers.ts`, `csvImport.ts`) import the interface type, not `EdgeGeocoder` directly.
- [ ] **AC-007.** Substantive: the `geocode` Edge Function accepts a batch of addresses, hashes each, reads `geocode_cache`, calls the keyless US Census one-line-address endpoint only for misses (bounded concurrency 3–5), writes results back to cache, and returns `{lat,lng}|null` per input address in input order. It forwards the caller's JWT so `geocode_cache_insert` (authenticated) passes RLS. Verification: `supabase functions serve` + a batch request returns coords; a second request for the same address makes no Census call (cache hit — AC-016).
- [ ] **AC-008.** Substantive: the Edge Function never trusts client-supplied coordinates — it geocodes the address string only. It caps address length and rejects oversized batches, and never echoes internal/stack errors to the client (returns a structured per-address failure reason). Verification: a request with an over-cap address or over-cap batch is rejected with a clean error; code review confirms no `lat`/`lng` is read from the request body for persistence.

### Wire-to-consumer (mandatory)

- [ ] **AC-009.** Substantive: `EdgeGeocoder` is actually invoked by both write paths — the manual add flow (`customers.ts createCustomerWithSites`) and the CSV import orchestration (`csvImport.ts`) call the geocoder before inserting a site; it is not merely defined. Verification: `git grep -n 'geocode' src/lib/customers.ts src/lib/csvImport.ts` shows the call sites AND the add-flow test asserts the geocoder is called per site.
- [ ] **AC-010.** Substantive: `sitePinsLayer.ts`'s deck.gl `ScatterplotLayer` is mounted into `MapShell.tsx`, replacing the empty `MapboxOverlay({ layers: [] })` placeholder, and is fed from `site_geo`. The layer fires in the real render path, not just exists. Verification: `git grep -n 'sitePinsLayer\|ScatterplotLayer' src/components/MapShell.tsx src/components/sitePinsLayer.ts` shows the import + mount; `MapboxOverlay({ layers: [] })` (empty) no longer appears in `MapShell.tsx`.

### Manual add flow (UI)

- [ ] **AC-011.** Substantive: `CustomerForm.tsx` renders a single combined form — customer brand fields (name + attrs) plus a repeatable list of site rows requiring ≥1 site. On submit it upserts the customer, geocodes each site, and inserts each site via PostgREST EWKT (`geog: 'SRID=4326;POINT(lng lat)'`); a successful add makes the site's pin appear on the map. Verification: manual run — add customer + 1 site → pin appears; the form blocks submit with 0 site rows.
- [ ] **AC-012.** Substantive: per-site geocode status is shown distinctly — pending, geocoded, or failed — and a failed-geocode site is persisted un-geocoded and flagged, never silently dropped. The four failure classes (no-match, ambiguous, network/timeout, rate-limit/429) each surface a recovery path (manual coords / pick-candidate / retry / backoff+retry), signaled non-color-alone (word + glyph + color). Verification: simulate each failure class → site persists flagged with its specific recovery affordance; status text is screen-reader readable.

### CSV bulk import (UI)

- [ ] **AC-013.** Substantive: `CustomerImport.tsx` accepts a CSV (one row per site: `customer_name, site_name?, address, …`), validates size/type/row caps client-side BEFORE any network call, parses with papaparse, and per row upserts `customer` by `(tenant_id, name)` (via `onConflict`), geocodes the address (ignoring any CSV lat/lng), and inserts the site. Verification: an over-size/over-row CSV is rejected pre-upload with no network call; two rows with the same `customer_name` produce one customer + two sites (dedup — AC-017).
- [ ] **AC-014.** Substantive: the import always renders a per-row results/errors report (created / geocode-failed / skipped-duplicate), even on total failure, with an in-flight `<progress>` + cancel and a copy/download-errors affordance. Verification: a CSV where every row fails still renders the report; the report rows map 1:1 to input rows with an outcome each.

### Edit / move / delete (UI)

- [ ] **AC-015.** Substantive: `CustomerList.tsx` (superseding the read-only `SiteList.tsx`) lists customers with their sites and supports edit-site-address (re-geocode + pin moves), move-site (update `geog`, pin moves), and delete-customer (cascades its sites; UI confirms "deletes N sites" before proceeding). Verification: manual — edit address → pin moves; delete customer → its sites + pins gone, confirm dialog shows the site count; `App.tsx` renders `CustomerList`, not `SiteList`.

### Tenant isolation, cache, security, a11y

- [ ] **AC-016.** Substantive: re-adding an already-geocoded address makes no external Census call (cache hit). Verification: integration test — second add/import of the same address resolves from `geocode_cache` with zero outbound Census requests.
- [ ] **AC-017.** Substantive: CSV dedup is correct — duplicate `customer_name` within a tenant upserts to one customer; a duplicate site is reported `skipped-duplicate`, not inserted twice. Verification: the two-row-same-customer test (AC-013) plus a duplicate-site-row test report the dedup outcome.
- [ ] **AC-018.** Substantive: tenant isolation holds for the new entities — tenant B's customers and pins are invisible to tenant A through both `customer` and `site_geo`, and unauthenticated PostgREST requests are denied/return zero rows. Verification: two-tenant RLS integration test (same shape as ADR-001 AC-003) for `customer` and `site_geo`; unauthenticated select returns empty.
- [ ] **AC-019.** Substantive: untrusted CSV is handled safely — parsed client-side (no server file storage), size capped (~5 MB) and rows capped (~1000), addresses geocoded (never trust CSV lat/lng), no internal errors echoed. Verification: security-auditor gate passes; caps are enforced pre-upload (AC-013); Edge Function caps address length (AC-008).
- [ ] **AC-020.** Substantive: every new form/list surface carries the W1 a11y contract — `useId()` label association, real `<label>`/`<button>`, `role="alert"`/`aria-live` for errors, native focus order, status non-color-alone, and the link-as-body-text blue darkened to `#1558b0` where it would otherwise fail AA. Verification: accessibility review against the four W1 north-star files (`AuthGate.tsx`, `SiteList.tsx`, `index.css`, `MapShell.tsx`); contrast checks pass WCAG 2.2 AA.
- [ ] **AC-021.** Substantive: geo persistence is API-first — the client writes `site.geog` directly via PostgREST EWKT and reads pin coords from `site_geo`; the Edge Function does geocoding ONLY, not persistence. The implementer MUST verify the EWKT path round-trips on a single insert before committing to it; if it does not, fall back to a `security invoker` RPC `place_site(customer_id, name, address, lat, lng)` doing `ST_SetSRID(ST_MakePoint(lng,lat),4326)`. Verification: a single EWKT insert round-trips to a readable `site_geo` row; otherwise the `place_site` RPC is added and used.

## Scope

### In Scope (Phase 1)
- `customer` table + `site.customer_id` FK + `site_geo` view + RLS (migration `0002`).
- `geocode` Edge Function (US Census, keyless, cache read/write, batch).
- `Geocoder` interface + `EdgeGeocoder` client seam.
- Manual add form (customer + ≥1 sites, per-site geocode status).
- CSV import (one row per site, customer upsert-by-name, dedup, results/errors report, pre-upload caps).
- Edit / move / delete with destructive confirm.
- deck.gl pin layer fed from `site_geo`, mounted in `MapShell`.

### Out of Scope (Future)
- **SQLite bulk import** — CTO SIMPLIFY folded it out; CSV only this wave. Interim: users export SQLite to CSV.
- **Exclusivity radius grain** (customer-level default vs per-site) — owned by W3; `exclusivity_radius_mi` stays on `site` untouched so W3 is not foreclosed.
- **Census API key / secret management** — Census is keyless in W2; no secret store needed yet.
- **Hex-grid exclusivity zones / spatial queries** — W3/W4.

### Files in scope
- `supabase/migrations/0002_customers_geocoding.sql` — *create*
- `supabase/functions/geocode/index.ts` — *create*
- `src/lib/geocoder.ts` — *create*
- `src/lib/customers.ts` — *create*
- `src/lib/csvImport.ts` — *create*
- `src/components/CustomerForm.tsx` — *create*
- `src/components/CustomerImport.tsx` — *create*
- `src/components/CustomerList.tsx` — *create*
- `src/components/sitePinsLayer.ts` — *create*
- `src/components/MapShell.tsx` — *modify* (mount pin layer; remove empty placeholder)
- `src/App.tsx` — *modify* (render `CustomerForm`/`CustomerImport`/`CustomerList`, retire `SiteList`)
- `src/components/SiteList.tsx` — *delete* (superseded by `CustomerList.tsx`)
- `src/index.css` — *modify* (new panel/form/report/status classes; `#1558b0` link tweak)
- `package.json` — *modify* (add `papaparse` + types)

## Technical Notes

### Existing Patterns to Reuse
- Per-table RLS keyed off `auth_tenant_ids()` — `supabase/migrations/0001_init_postgis_schema.sql` (`site_tenant_*` is the exact template for `customer_tenant_*`).
- Pluggable seam pattern (R5) — `src/lib/auth.ts` / `tenant.ts`; `Geocoder` follows it.
- RLS-auto-scoped read (no client `where tenant_id`) — `SiteList.tsx`.
- Form + error a11y pattern (`useId`, `role="alert"`, `.field`/`.form-error`) — `AuthGate.tsx`.
- deck.gl `MapboxOverlay` attach point — `MapShell.tsx` (replace empty `layers: []`).
- Plain semantic CSS (NO Tailwind/tokens) — `src/index.css`; two color literals `#1a73e8`, `#b00020`, additive `#555` helper.

### New Components Needed
- `geocode` Edge Function; `geocoder.ts`, `customers.ts`, `csvImport.ts`; `CustomerForm`, `CustomerImport`, `CustomerList`, `sitePinsLayer`.

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| customer | new table (0002) | tenant user | `CustomerForm` (add) + `CustomerImport` (upsert) + `CustomerList` (edit/delete) | NEW — in scope |
| site | existing table (0001) + `customer_id` (0002) | tenant user | `CustomerForm` + `CustomerImport` (insert); `CustomerList` (edit/move/delete) | NEW write path — in scope |
| site coordinates (`geog`) | derived (geocode → EWKT) | system (Edge Function geocode) + tenant user write | written via PostgREST EWKT; read via `site_geo` | in-scope |
| geocode_cache | existing table (0001) | system (Edge Function) | read+write by `geocode` Edge Function | exists |

Every read entity has a concrete in-scope write path; read/write symmetry passes (architect PASS).

### Database Changes
- `0002_customers_geocoding.sql`: `customer` table; `site.customer_id NOT NULL` FK + `site_customer_id_idx`; `site_geo` view (`security_invoker = true`); four `customer_tenant_*` RLS policies.
- Data classification: customer brand names + site addresses are tenant-private (per-tenant RLS). `geocode_cache` is deliberately tenant-shared (address→coords is public, non-private — ADR-001).
- Build order (BINDING): customer → RLS → `site.customer_id` → view. Forward-only; reversible by `drop view site_geo; alter table site drop column customer_id; drop table customer;`.

### API / Edge Functions
- `geocode` Edge Function: `addresses[] → ({lat,lng}|null)[]`; cache read/write; keyless Census call; JWT forwarded.

### Security Considerations
- `site_geo` MUST be `security_invoker = true` (cross-tenant leak otherwise) — db-migration-reviewer confirms.
- CSV parsed client-side, no server file storage; size ~5 MB + rows ~1000 caps pre-upload; addresses geocoded (never trust CSV lat/lng); Edge Function caps address length and never echoes internal errors.
- All new tables/views inherit the W1 RLS posture (no anon policy → unauthenticated denied by construction).
- security-auditor gate (file upload + external geocode calls) is mandatory for this wave.

### Accessibility Requirements
- WCAG 2.2 AA: `useId()` label association on all inputs; `role="alert"`/`aria-live` for errors and per-row import failures; native focus order; status signaling non-color-alone (word + glyph + color); native `<dialog>` (focus trap + ESC + backdrop) recommended for the add surface with a `.site-panel` fallback.
- Contrast: error `#b00020` (~7.4:1), helper `#555` (~7.5:1), focus `#1a73e8` (~3.9:1 PASS at 3:1); link-as-body-text darkened to `#1558b0` (~5.9:1).

## Open questions / assumptions
- **EWKT round-trip through PostgREST** — Assumption: it round-trips; implementer verifies on one insert before committing, else falls back to `place_site` RPC (AC-021).
- **CSV column schema** — Assumption: `customer_name, site_name?, address` minimum; extra columns ignored. Confirm exact header set at build; report surfaces unknown/missing columns precisely.
- **Caps (size/rows)** — Assumption: ~5 MB / ~1000 rows / address-length cap in the Edge Function; exact numbers set at build.
- **Add surface: dialog vs panel** — Assumption: native `<dialog>` (UI-spec recommendation); `.site-panel` fallback acceptable.
- **`customer.attributes` shape** — Assumption: free-form JSONB brand attrs in W2; no fixed schema yet.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-002 (Wave 2 — customer/site model, server-side geocoding, API-first geo) | architect / manifest | AC-001..AC-021 | none | spec implements the prescribed schema, Edge Function seam, `security_invoker` view, EWKT-with-RPC-fallback |
| ADR-001 (multi-tenant foundation) + geocode-location addendum | architect / ADR-002 | AC-003 (RLS mirror), AC-005 (reuse helper/cache), AC-007 (Edge Function = the addendum) | none | server-side geocoding extends ADR-001's no-custom-server posture; persistence stays API-first |

## Dependencies
- Wave 1 (hex-grid-foundation) — shipped & merged to main (`tenant`, `membership`, `site`, `geocode_cache`, `auth_tenant_ids()`, map shell, auth seam).
- `papaparse` (new npm dependency) for CSV parsing.
- Supabase Edge Functions runtime (`supabase functions serve` locally; deploy step).
- External: US Census one-line-address geocoder (keyless).
