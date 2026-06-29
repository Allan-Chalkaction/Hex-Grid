# Feature Spec: Customers + Per-Site Geocoding (Wave 2)

**Status:** Draft
**Author:** AI-assisted (pm-spec agent)
**Date:** 2026-06-27
**Slug:** customers-geocoding

## Summary
Turn W1's empty multi-tenant shell into a usable product: a `customer` (brand) owns 1→N `site`s; each site is geocoded per-address via a keyless US Census Supabase Edge Function (cache-first); persistence stays client-side API-first through PostgREST using EWKT. Ships an add-customer form, CSV bulk import, a CRUD `CustomerList` (superseding the read-only `SiteList`), and deck.gl pins replacing W1's empty map overlay. Tenancy stays enforced in the database by per-table RLS keyed off `auth_tenant_ids()` (ADR-001/ADR-002).

## User Stories
- As a tenant member, I want to add a customer brand with one or more site addresses so that my sites are geocoded and appear as pins on the map.
- As a tenant member, I want to bulk-import sites from a CSV so that I can onboard many locations at once without manual entry.
- As a tenant member, I want a per-site geocode status (pending / geocoded / failed) with a recovery path so that a failed address is never silently lost.
- As a tenant member, I want to edit a site address, move a site, or delete a customer so that I can correct and maintain my territory data.
- As a tenant member, I want to see only my own tenant's customers and sites so that cross-tenant data never leaks.

## Acceptance Criteria

ACs are numbered AC-001..AC-021 to match the wave manifest's `tickets[].acceptance` references. Each entry is two-part: substantive standard, then verification mechanism.

### Migration & data model (CG-T1, CG-T8 source)

- [ ] **AC-001.** Substantive: a `customer` table exists with `id uuid pk`, `tenant_id uuid not null references tenant on delete cascade`, `name text not null`, `attributes jsonb not null default '{}'`, `created_at`, `updated_at`, `unique (tenant_id, name)`, and index `customer_tenant_id_idx`. The unique constraint enables PostgREST upsert `onConflict=(tenant_id,name)`. Verification: `rg "create table customer" supabase/migrations/0002_customers_geocoding.sql` and `rg "unique \(tenant_id, name\)" supabase/migrations/0002_customers_geocoding.sql`; applying 0002 against a fresh DB succeeds; a duplicate `(tenant_id, name)` insert is rejected.
- [ ] **AC-002.** Substantive: `customer` has RLS enabled with exactly four per-table policies (select/insert/update/delete) for role `authenticated`, each keyed `tenant_id in (select auth_tenant_ids())`, mirroring `site_tenant_*` in 0001 EXACTLY — no generic/shared policy, no anon policy (DELIBERATE-NO-ANON). Verification: `rg "create policy customer_tenant_(select|insert|update|delete)" supabase/migrations/0002_customers_geocoding.sql` returns four matches; `rg -i "to anon" supabase/migrations/0002_customers_geocoding.sql` returns nothing; db-migration-reviewer confirms the using/with-check expressions match the `site_tenant_*` shape.
- [ ] **AC-003.** Substantive: `site.customer_id uuid not null references customer(id) on delete cascade` is added with index `site_customer_id_idx`, guarded by a `do $$ ... $$` block that raises if `select count(*) from site <> 0` (empty post-W1, no backfill). Verification: `rg "add column customer_id" supabase/migrations/0002_customers_geocoding.sql` and `rg "site not empty" supabase/migrations/0002_customers_geocoding.sql`; the migration applies cleanly on the empty W1 schema and the guard fails loudly if `site` has rows.
- [ ] **AC-004.** Substantive: a view `site_geo` exists `with (security_invoker = true)` exposing `id, customer_id, name, address, ST_Y(geog::geometry) as lat, ST_X(geog::geometry) as lng` from `site`; it runs under the CALLER's RLS so it cannot leak cross-tenant. Verification: `rg "create view site_geo with \(security_invoker = true\)" supabase/migrations/0002_customers_geocoding.sql`; `rg "ST_Y\(.*geog.*\) as lat" supabase/migrations/0002_customers_geocoding.sql`; security-auditor + db-migration-reviewer confirm `security_invoker` is present and no policy is defined on the view.
- [ ] **AC-005.** Substantive: cross-tenant isolation holds end-to-end — a two-tenant RLS test seeds tenants A and B; as A, `customer` and `site_geo` return only A's rows (zero of B's); an unauthenticated PostgREST select on `customer` and `site_geo` returns zero rows. Verification: run the seeded two-tenant integration test (described in Testing Strategy); db-migration-reviewer confirms tenant B is invisible to A and the unauthenticated query is empty.
- [ ] **AC-018.** Substantive: 0002 is forward-only and reversible (`drop view site_geo; alter table site drop column customer_id; drop table customer;`, plus `drop function place_site` if the RPC fallback was added); it REUSES `auth_tenant_ids()` and `geocode_cache` from 0001 (never redefines them) and leaves `site.exclusivity_radius_mi` untouched (W3 owns the radius grain). Verification: `rg "create (or replace )?function auth_tenant_ids|create table geocode_cache|exclusivity_radius" supabase/migrations/0002_customers_geocoding.sql` returns nothing (no redefinition/mutation); the documented reverse statements drop all 0002 objects cleanly.

### Geocoding seam & Edge Function (CG-T2, CG-T3)

- [ ] **AC-007.** Substantive: a `geocode` Supabase Edge Function (`supabase/functions/geocode/index.ts`) accepts a BATCH of address strings, hashes each, reads `geocode_cache`, calls the KEYLESS US Census one-line-address endpoint ONLY for cache misses (bounded concurrency 3–5), writes misses back to cache, and returns `{lat,lng}|null` per input address IN INPUT ORDER. It forwards the caller's JWT so `geocode_cache_insert` (authenticated) RLS passes. Verification: `supabase functions serve` + a batch request returns a result array of equal length in input order; code-reviewer confirms cache-read-before-fetch and JWT forwarding.
- [ ] **AC-008.** Substantive: the Edge Function NEVER trusts client-supplied coordinates (it geocodes the address string only; no `lat`/`lng` is read from the request body for persistence), caps address length and rejects oversized batches, and never echoes internal/stack errors — failures return a structured per-address reason. Verification: security-auditor reviews `index.ts`; a request carrying `lat`/`lng` in the body is ignored; an oversized batch / over-length address is rejected with a structured (non-stack) error.
- [ ] **AC-016.** Substantive: a second geocode request for an already-cached address makes ZERO outbound Census calls (resolves from `geocode_cache`). Verification: with `supabase functions serve`, geocode an address (populates cache), then repeat; assert no outbound Census call fires on the repeat (log/trace or network assertion).
- [ ] **AC-006.** Substantive: `src/lib/geocoder.ts` exports a `Geocoder` INTERFACE (`(addresses: string[]) => Promise<({lat,lng}|null)[]>`, input-order) and an `EdgeGeocoder` impl calling `supabase.functions.invoke('geocode')`, mirroring W1's seam pattern (`auth.ts`/`tenant.ts`). Consumers import the interface TYPE, never the concrete class. Verification: `rg "export interface Geocoder" src/lib/geocoder.ts` and `rg "supabase.functions.invoke\('geocode'\)" src/lib/geocoder.ts`; `rg "EdgeGeocoder" src/lib/customers.ts src/lib/csvImport.ts` shows consumers depend on the interface type (concrete class constructed once at the seam, not imported by name for typing).

### Wire-to-consumer atoms (mandatory — funnel-tuning T5)

- [ ] **AC-009.** Substantive (wire-to-consumer): the geocoder is actually INVOKED — once per site in `createCustomerWithSites` (`customers.ts`) and once per row in `csvImport.ts` — BEFORE the site insert, not merely defined; client/CSV-supplied lat/lng is ignored and the address string is geocoded. Verification: `rg "geocod(e|er)" src/lib/customers.ts src/lib/csvImport.ts` shows the call sites; the add-flow test and the CSV-import test each assert the geocoder is called per site / per row.
- [ ] **AC-010.** Substantive (wire-to-consumer): `sitePinsLayer` fires in the REAL `MapShell` render path — `MapShell.tsx` imports and mounts it into the existing `MapboxOverlay`, and the empty `MapboxOverlay({ layers: [] })` placeholder NO LONGER appears. A newly-added/geocoded site renders as a pin. Verification: `rg "sitePinsLayer" src/components/MapShell.tsx` shows the import + mount; `rg "MapboxOverlay\(\{ layers: \[\] \}\)" src/components/MapShell.tsx` returns nothing; manual/visual check shows a pin for a geocoded site.

### Manual-add form & persistence (CG-T4, CG-T6)

- [ ] **AC-011.** Substantive: `CustomerForm.tsx` is a SINGLE combined surface — customer brand fields (name + attrs) plus a repeatable list of site rows requiring ≥1 site (submit blocked with 0 rows). On submit it calls `createCustomerWithSites` (upsert customer → geocode each site → EWKT insert); a successful add makes the site's pin appear. Verification: code-reviewer + ui-review confirm the combined surface and the ≥1-site submit guard; an attempted 0-site submit is blocked; a successful add produces a `site_geo` row and a map pin.
- [ ] **AC-012.** Substantive: per-site geocode status is shown DISTINCTLY (pending / geocoded / failed), signaled non-color-alone (word + glyph + color) and screen-reader readable; a failed-geocode site is persisted UN-geocoded and flagged, never silently dropped; the four failure classes (no-match / ambiguous / network-timeout / rate-limit-429) each surface a specific recovery path (manual coords / pick-candidate / retry / backoff+retry). Verification: accessibility-auditor confirms non-color-alone status + SR-readability; a forced failure of each class shows its recovery affordance and the site still persists.
- [ ] **AC-021.** Substantive: persistence is API-first via PostgREST EWKT (`geog: 'SRID=4326;POINT(lng lat)'`) supplying `tenant_id` (from `tenant.ts`), `customer_id`, `name`, `address`. The implementer MUST verify a single EWKT insert round-trips to a readable `site_geo` row BEFORE adopting the approach; if it does NOT, add a `security invoker` RPC `place_site(customer_id, name, address, lat, lng)` (`ST_SetSRID(ST_MakePoint(lng,lat),4326)`) to migration 0002 (the only conditional edit, serialized behind CG-T1) and call the RPC instead. Verification: an EWKT insert yields a readable `site_geo` row in the round-trip test; if the RPC path was taken, `rg "create .*function place_site" supabase/migrations/0002_customers_geocoding.sql` shows `security invoker` and `customers.ts` calls it. The Edge Function does geocoding ONLY; persistence never moves server-side.

### CSV bulk import (CG-T5)

- [ ] **AC-013.** Substantive: `CustomerImport.tsx` + `csvImport.ts` accept a CSV (one row per site: `customer_name, site_name?, address, …`; extra columns ignored, unknown/missing columns reported precisely), parse with papaparse, upsert `customer` by `(tenant_id, name)` via `onConflict`, geocode each address through the `Geocoder` interface, and insert each site. A per-row results report (created / geocode-failed / skipped-duplicate) is ALWAYS rendered — even on total failure — and maps 1:1 to input rows with exactly one outcome each. Verification: code-reviewer confirms the 1:1 row→outcome mapping and the always-rendered report; an import with mixed outcomes shows the correct per-row classification; a CSV with a missing required column reports it precisely.
- [ ] **AC-014.** Substantive: the import UI shows an in-flight `<progress>` with a cancel control and a copy/download-errors affordance. Verification: ui-review + accessibility-auditor confirm a real `<progress>` element, a working cancel, and a copy/download-errors control; cancelling mid-import stops further network calls.
- [ ] **AC-017.** Substantive: dedup — a duplicate `customer_name` within a tenant collapses to one customer (upsert), and a duplicate site is reported `skipped-duplicate` (application-level), not inserted twice. Verification: an import containing repeated customer names creates one customer; a repeated site row is classified `skipped-duplicate` in the report. (Concurrent-import double-insert is out of scope — see Out of Scope.)
- [ ] **AC-019.** Substantive: untrusted CSV is parsed CLIENT-SIDE only (no server file storage); size (~5 MB) / type / row caps (~1000) are enforced BEFORE any network call; addresses are geocoded (CSV lat/lng never trusted); no internal/stack errors are echoed. Verification: security-auditor confirms client-side-only parse + pre-upload caps; an oversized/over-row/ wrong-type file is rejected before any network call; a CSV lat/lng column is ignored in favor of geocoding.

### CRUD list, app composition, a11y (CG-T7)

- [ ] **AC-015.** Substantive: `CustomerList.tsx` supersedes `SiteList.tsx`, lists customers with their sites via an RLS-auto-scoped read (no client `where tenant_id`, like W1 `SiteList`), and supports edit-site-address (re-geocode via the geocoder seam → pin moves), move-site (update `geog` → pin moves), and delete-customer (cascades its sites; a confirm dialog states "deletes N sites" before proceeding). Reads use `site_geo`; writes target the `site`/`customer` BASE tables. Verification: code-reviewer confirms no client tenant filter and base-table writes; editing an address re-geocodes and moves the pin; deleting a customer shows the N-sites confirm and cascades.
- [ ] **AC-020.** Substantive: every new form/list surface meets WCAG 2.2 AA — `useId()` label association, real `<label>`/`<button>`, `role="alert"`/`aria-live` errors, native focus order, status non-color-alone; the link-as-body-text blue is darkened to `#1558b0` (~5.9:1) in `index.css` where it would fail AA; `App.tsx` renders `CustomerForm`, `CustomerImport`, `CustomerList` and NO LONGER renders `SiteList` (which is deleted). Verification: accessibility-auditor reviews against the four W1 north-star files (`AuthGate.tsx`, `SiteList.tsx`, `index.css`, `MapShell.tsx`); `rg "SiteList" src/` returns nothing after deletion; contrast checks pass AA; `npm run build` (tsc + vite) is clean.

## Scope

### In Scope (Phase 1)
- Migration 0002: `customer` table + per-table RLS, `site.customer_id NOT NULL`, `site_geo` security_invoker view; reuse 0001 helper/cache.
- `geocode` Edge Function (Census, keyless, batch, cache-first); `geocoder.ts` swappable seam.
- Manual-add `CustomerForm` (combined customer + ≥1 site) with per-site geocode status + recovery paths.
- CSV bulk import (`csvImport.ts` + `CustomerImport.tsx`) with caps, dedup, per-row report, progress/cancel.
- `CustomerList` CRUD (edit-address, move-site, delete-customer cascade) superseding `SiteList`.
- deck.gl `sitePinsLayer` mounted in `MapShell`, replacing the empty overlay.
- Two-tenant RLS isolation test against `customer` and `site_geo`.

### Out of Scope (Future)
- **SQLite bulk import** — deferred by the plan-time cto SIMPLIFY; CSV is the only bulk path this wave. Until SQLite lands, bulk onboarding is CSV-only.
- **DB-level unique constraint on `site`** — dedup is application-level only, so two *concurrent* imports could double-insert (AC-017 note). Accepted; not addressed this wave.
- **`site.exclusivity_radius_mi` / radius grain** — owned by W3; left untouched by 0002.
- **`updated_at` trigger** — 0001 added none; the update path sets it or leaves the default (not load-bearing this wave).
- **Geocode provider swap** — the `Geocoder` interface enables it, but only `EdgeGeocoder` (Census) ships now.

### Files in scope

- `supabase/migrations/0002_customers_geocoding.sql` — *create* (CG-T1; conditional `place_site` RPC per AC-021 / CG-T4, serialized behind CG-T1)
- `supabase/functions/geocode/index.ts` — *create* (CG-T2)
- `src/lib/geocoder.ts` — *create* (CG-T3)
- `src/lib/customers.ts` — *create* (CG-T4)
- `src/lib/csvImport.ts` — *create* (CG-T5)
- `src/components/CustomerForm.tsx` — *create* (CG-T6)
- `src/components/CustomerImport.tsx` — *create* (CG-T5)
- `src/components/CustomerList.tsx` — *create* (CG-T7)
- `src/components/sitePinsLayer.ts` — *create* (CG-T8)
- `src/components/MapShell.tsx` — *modify* (CG-T8 — mount pins, drop empty overlay)
- `src/App.tsx` — *modify* (CG-T7 — render new surfaces, drop SiteList)
- `src/components/SiteList.tsx` — *delete* (CG-T7)
- `src/index.css` — *modify* (CG-T6/T7 — panel/form/status classes; `#1558b0`; shared sink, serialized CG-T6→CG-T7)
- `package.json` — *modify* (CG-T5 — add `papaparse` + `@types/papaparse`)

## Technical Notes

### Existing Patterns to Reuse
- **Migration shape:** `supabase/migrations/0001_init_postgis_schema.sql` — per-table policy literal `tenant_id in (select auth_tenant_ids())`, DELIBERATE-NO-ANON note, helper/cache reused not redefined.
- **Seam pattern:** `src/lib/auth.ts` / `src/lib/tenant.ts` — export interface, single concrete impl, consumers depend on the type.
- **RLS-auto-scoped read:** `src/components/SiteList.tsx` (`supabase.from('site').select(...)`, no client tenant filter).
- **Form a11y:** `src/components/AuthGate.tsx` (`useId`, real `<label>`/`<button>`, `role="alert"`/`aria-live`, `.field`/`.form-error`).
- **deck.gl attach point:** `src/components/MapShell.tsx:33` (`MapboxOverlay`); `ScatterplotLayer` from the existing `deck.gl` umbrella dep.
- **CSS:** plain semantic classes in `src/index.css` (literals `#1a73e8`, `#b00020`, `#555`) — no Tailwind/tokens.
- **EWKT insert:** supabase-js insert with `geog: 'SRID=4326;POINT(lng lat)'` + `tenant_id` from `tenant.ts`.

### New Components Needed
- `geocoder.ts` (`Geocoder` interface + `EdgeGeocoder`), `customers.ts` (`createCustomerWithSites`), `csvImport.ts`.
- `CustomerForm`, `CustomerImport`, `CustomerList`, `sitePinsLayer`.
- `geocode` Edge Function (only server-side code; geocoding only).

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| `customer` | new table (0002) | tenant user | `CustomerForm` (add), `CustomerImport` (CSV upsert), `CustomerList` (edit/delete) | NEW — in scope |
| `site` | existing table (0001) | tenant user | `CustomerForm`/`CustomerImport` (create via EWKT), `CustomerList` (edit-address/move/delete) | in-scope (write path first exercised this wave) |
| `site_geo` | new view (0002), derived from `site` | system (view) | read-only display surface (CustomerList, sitePinsLayer) — no write path needed; edits target `site` base table | in-scope (read), no write path required |
| `geocode_cache` | existing table (0001), tenant-shared | system (Edge Function on cache miss) | no UI — populated/read by the `geocode` Edge Function only | exists (write path = Edge Function) |
| US Census geocoder | external keyless API | n/a (live-queried) | live-queried by the Edge Function for cache misses; keyless, no configuration/record-mapping needed | external — live-queried |

Every read entity has a concrete write/source path: `customer`/`site` via the in-scope forms/import/list; `site_geo` is a derived view (writes go to base tables); `geocode_cache` is written by the Edge Function; Census is live-queried.

### Database Changes
- New table `customer` (+ `customer_tenant_id_idx`); four per-table RLS policies for `authenticated`, no anon policy.
- `site.customer_id uuid NOT NULL references customer on delete cascade` (+ `site_customer_id_idx`); empty-`site` guard before NOT NULL.
- New view `site_geo` `with (security_invoker = true)` — the entire cross-tenant isolation mechanism for the read surface (no policy on the view).
- Conditional `place_site` `security invoker` RPC only if the EWKT round-trip fails (AC-021).
- Data classification: tenant-private business data (customer/site). `geocode_cache` is deliberately tenant-shared (address→lat/lng is public, non-private) — do NOT add `tenant_id`.

### API / Edge Functions
- `supabase/functions/geocode/index.ts` — batch address→lat/lng, cache-first, keyless Census, bounded concurrency 3–5, JWT-forwarded, structured per-address failure. Geocoding ONLY; never persists sites.

### Security Considerations
- **RLS:** `customer` mirrors `site_tenant_*` exactly; `site_geo` relies on `security_invoker = true` (load-bearing — omission leaks every tenant). No anon policy → unauthenticated reads return zero rows by construction.
- **Untrusted input:** never trust client/CSV lat/lng — always geocode the address string (AC-008/AC-009/AC-019). CSV parsed client-side only, no server storage, caps enforced pre-upload.
- **Error hygiene:** never echo internal/stack errors (Edge Function returns structured per-address reasons) — per `rules-security.md`.
- **Secrets:** Census is keyless; no API key handling. anon key stays public/RLS-gated (W1 posture).
- **Gates:** db-migration-reviewer + security-auditor gate the migration and Edge Function surfaces.

### Accessibility Requirements (WCAG 2.2 AA)
- Label association via `useId()`; real `<label>`/`<button>`; `role="alert"`/`aria-live` for errors (AuthGate pattern).
- Per-site geocode status non-color-alone (word + glyph + color), screen-reader readable (AC-012).
- CSV import: real `<progress>`, keyboard-operable cancel + copy/download-errors (AC-014).
- Native focus order; native `<dialog>` (focus trap + ESC + backdrop) recommended for add/confirm, `.site-panel`-style fallback.
- Contrast: darken link-as-body-text blue to `#1558b0` (~5.9:1) where it would fail AA (AC-020).

## Open questions / assumptions
- **Census endpoint variant / batch size cap.** Assumption: use the public one-line-address endpoint; per-batch address cap and per-address length cap chosen by the implementer within the ADR's "small CONUS site sets" guidance (recommend ≤~100/batch). Proceeding on that assumption; tune if Census limits bite.
- **Bounded concurrency value.** Assumption: 4 (ADR range 3–5). Proceeding.
- **Size/row caps.** Assumption: ~5 MB / ~1000 rows (from the wave spec). Proceeding; adjust if product wants different limits.
- **CSV column schema.** Assumption: `customer_name, site_name?, address` with extra columns ignored and unknown/missing required columns reported precisely. Proceeding.
- **`updated_at` on update.** Assumption: set in the update path or leave the default (no trigger); not load-bearing. Proceeding.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-002-customers-geocoding | prompt / wave manifest | AC-001..AC-006, AC-007..AC-009, AC-010..AC-021 (full set) | none | Spec mirrors ADR-002's locked migration shape, geocode/persistence seam split, and security_invoker view |
| ADR-001 (builds-on) | prompt / ADR-002 Context | AC-002 (mirrors `site_tenant_*`), AC-006 (R5 seam), AC-015/AC-016/AC-018 (reuse `auth_tenant_ids()`/`geocode_cache`, no redefine) | none | Wave 2 consumes W1 substrate unchanged; posture (API-first, RLS-in-DB) preserved |

## Dependencies
- **W1 (ADR-001):** `auth_tenant_ids()`, `site_tenant_*` policy shape, `geocode_cache`, the `MapboxOverlay` attach point (`MapShell.tsx:33`), the AuthGate a11y pattern, the `SiteList` RLS-read pattern, `tenant.ts` resolver. All present and verified.
- **Ticket order (from wave manifest):** CG-T1, CG-T2 independent; CG-T3←T2; CG-T4←T1,T3; CG-T6←T4; CG-T5←T4,T6; CG-T7←T5,T6; CG-T8←T1. `src/index.css` is a shared sink across CG-T6/T7 (and referenced by CG-T5) — serialize T6→T7.
- **External:** keyless US Census geocoding endpoint (live-queried via the Edge Function).
- **New package:** `papaparse` + `@types/papaparse` (CG-T5).
