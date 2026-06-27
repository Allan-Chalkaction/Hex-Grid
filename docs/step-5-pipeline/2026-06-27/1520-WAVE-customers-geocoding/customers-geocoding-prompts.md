## Build prose — Wave: customers-geocoding (wave-2)

Shared context (read once): W1 shipped the multi-tenant shell. The DB seam is `supabase/migrations/0001_init_postgis_schema.sql` (tenant / membership / site / geocode_cache + `auth_tenant_ids()` SECURITY DEFINER helper + per-table `site_tenant_*` RLS). The client seam pattern is in `src/lib/auth.ts` / `src/lib/tenant.ts` (export an interface, swap the impl); the form a11y north star is `src/components/AuthGate.tsx` (`useId`, `<label htmlFor>`, `role="alert"`+`aria-live`, `.field`/`.form-error`, real `<button>`); the async-load north star is `src/components/SiteList.tsx` (RLS-auto-scoped read, no client `where tenant_id`); the map attach point is `src/components/MapShell.tsx` (the empty `MapboxOverlay({ layers: [] })` at line 33). CSS is plain semantic CSS in `src/index.css` — NO Tailwind, NO tokens; the only color literals in play are `#1a73e8` (interactive blue), `#b00020` (error red), `#555` (helper grey). Build order across the wave is dependency-driven by the manifest; the BINDING DB build order inside CG-T1 is customer → RLS → `site.customer_id` → view.

---

### CG-T1 — migration `0002_customers_geocoding.sql`

**Context.** This is the foundation ticket (no deps); CG-T4 and CG-T8 block on it. Mirror 0001's structure and comment style exactly — 0001 is the literal template, not just inspiration.

**Approach.** Follow the BINDING order: (1) `create table customer` with `id`, `tenant_id uuid not null references tenant(id) on delete cascade`, `name text not null`, `attributes jsonb not null default '{}'::jsonb`, `created_at`/`updated_at timestamptz not null default now()`, `unique (tenant_id, name)`. (2) `alter table customer enable row level security` then four policies `customer_tenant_{select,insert,update,delete}` copied verbatim from `site_tenant_*` (lines 125–140 of 0001) with `customer` substituted — `using`/`with check` = `tenant_id in (select auth_tenant_ids())`. (3) `alter table site add column customer_id uuid not null references customer(id) on delete cascade` + `create index site_customer_id_idx on site (customer_id)`. (4) `create view site_geo with (security_invoker = true) as select s.id, s.customer_id, s.name, s.address, st_y(s.geog::geometry) as lat, st_x(s.geog::geometry) as lng from site s`.

**Gotchas.** The `security_invoker = true` is load-bearing — a plain (owner-run) view bypasses `site` RLS and leaks cross-tenant; db-migration-reviewer will block without it. `site.customer_id` is `NOT NULL` with no backfill — this is only safe because `site` is empty post-W1; the migration should confirm `select count(*) from site = 0` posture. Do NOT redefine `auth_tenant_ids()` or `geocode_cache` (reuse from 0001). Do NOT touch `site.exclusivity_radius_mi` — W3 owns the radius grain. No anon policy (unauthenticated denied by construction, like 0001). Forward-only; reversible by `drop view site_geo; alter table site drop column customer_id; drop table customer;`.

**Acceptance.** AC-001 (customer table + unique), AC-002 (customer_id NOT NULL + index + cascade), AC-003 (four policies match `site_tenant_*` shape), AC-004 (`site_geo` security_invoker), AC-005 (reuse helper/cache, leave radius), AC-018 (two-tenant RLS isolation through `customer` and `site_geo`; unauthenticated → zero rows). Note: CG-T4 may append a conditional `place_site` RPC to THIS file — that edit is serialized behind this ticket.

---

### CG-T2 — `geocode` Edge Function

**Context.** No deps; CG-T3 wraps it. This is the only new infra in the wave (ADR-002 / ADR-001 addendum). Keyless US Census one-line-address endpoint — no secret management needed.

**Approach.** `supabase/functions/geocode/index.ts` accepts a BATCH of address strings. For each: hash, read `geocode_cache` (by `address_hash`), and only for cache misses call the Census endpoint with bounded concurrency (3–5). Write fresh results back to `geocode_cache` (provider tag), and return `({lat,lng}|null)[]` strictly IN INPUT ORDER. Forward the caller's JWT (read the incoming `Authorization` header into the Supabase client) so the `geocode_cache_insert` authenticated policy passes.

**Gotchas.** Cache behavior is load-bearing for AC-016 — a second request for an already-geocoded address must make ZERO outbound Census calls; structure the miss-set computation so a full cache hit short-circuits the network entirely. SECURITY (AC-008): geocode the address string ONLY — never read `lat`/`lng` from the request body for persistence (client coords are untrusted). Cap address length and reject oversized batches up front. Never echo internal/stack errors — return a structured per-address failure reason (map cleanly to the four UI failure classes: no-match / ambiguous / network-timeout / rate-limit-429). Preserve input-order alignment even when some entries hit cache and others call out.

**Acceptance.** AC-007 (batch + cache + keyless Census + JWT-forward + input-order), AC-008 (no client coords, caps, no error echo), AC-016 (cache hit = zero Census calls). Verify locally: `supabase functions serve` + a batch request, then a repeat asserting no Census call.

---

### CG-T3 — `src/lib/geocoder.ts` (the seam)

**Context.** Depends on CG-T2 (it wraps that function). Follows W1's R5 pluggable-seam pattern — look at how `auth.ts` exposes functions and `tenant.ts` exports the `Membership` interface; here the INTERFACE is the contract.

**Approach.** Export a `Geocoder` interface — `geocode(addresses: string[]): Promise<({ lat: number; lng: number } | null)[]>` (input-order array matching CG-T2's return). Export an `EdgeGeocoder` implementation calling `supabase.functions.invoke('geocode', { body: { addresses } })`. Keep it thin — no persistence, no parsing logic here.

**Gotchas.** The whole point of the seam is swappability: consumers (`customers.ts`, `csvImport.ts`) MUST depend on the `Geocoder` interface TYPE, not the concrete `EdgeGeocoder` class. Type the batch contract precisely to mirror the Edge Function's input-order `({lat,lng}|null)[]` so a null (failed) entry is representable per address.

**Acceptance.** AC-006 (`interface Geocoder` defined; consumers import the interface, not the class).

---

### CG-T4 — `src/lib/customers.ts` (manual-add write path)

**Context.** Depends on CG-T1 (schema) and CG-T3 (geocoder seam). This is the core write-path library; CG-T6 (form) and CG-T5 (import, via shared helpers) build on it.

**Approach.** Implement `createCustomerWithSites`: upsert the customer by `(tenant_id, name)` (PostgREST `upsert` with `onConflict: 'tenant_id,name'`), then geocode EACH site through the injected `Geocoder` interface BEFORE insert, then insert each site API-first via PostgREST EWKT: `geog: 'SRID=4326;POINT(lng lat)'` (note lng-then-lat order). Also stub the helpers CG-T7 needs (`updateSite`, `moveSite`, `deleteCustomer`, `listCustomersWithSites`) per ADR-002's component list, or at minimum the upsert helper CG-T5 reuses.

**Gotchas.** WIRE-TO-CONSUMER (AC-009): the geocoder must actually FIRE here — the add-flow test asserts it's called per site, not merely imported. AC-021 verification gate: BEFORE committing to EWKT, verify a single `geog: 'SRID=4326;POINT(lng lat)'` insert round-trips to a readable `site_geo` row. If it does NOT round-trip, add a `security invoker` RPC `place_site(customer_id, name, address, lat, lng)` doing `ST_SetSRID(ST_MakePoint(lng,lat),4326)` to migration `0002` (this is the ONLY authorized conditional edit to that file — it's serialized behind CG-T1) and call the RPC instead. Persistence stays client-side API-first either way — the Edge Function geocodes ONLY. A failed-geocode site must still persist (un-geocoded, flagged) — don't drop it.

**Acceptance.** AC-009 (geocoder invoked + proven to fire), AC-021 (API-first EWKT round-trip verified, RPC fallback only if needed).

---

### CG-T5 — CSV bulk-import path (`csvImport.ts` + `CustomerImport.tsx` + papaparse)

**Context.** Depends on CG-T4 (reuses upsert helpers) and CG-T6 (uses its CSS classes — shared `index.css` edge; do NOT edit `index.css` here). Add `papaparse` + `@types/papaparse` to `package.json`.

**Approach.** `src/lib/csvImport.ts` orchestrates; `src/components/CustomerImport.tsx` is the UI. Accept a CSV (one row per site: `customer_name, site_name?, address, …`; extra columns ignored, unknown/missing columns reported precisely). Validate size (~5 MB) / type / row cap (~1000) CLIENT-SIDE BEFORE any network call. Parse with papaparse (robust quoting — do not hand-roll). Per row: upsert `customer` by `(tenant_id, name)` via `onConflict` (reuse CG-T4 helpers), geocode the address through the `Geocoder` interface IGNORING any CSV lat/lng, insert the site. Always render a per-row results/errors report (created / geocode-failed / skipped-duplicate) — EVEN on total failure — with an in-flight `<progress>` + cancel and a copy/download-errors affordance; report rows map 1:1 to input rows with one outcome each.

**Gotchas.** AC-009 wire: the geocoder must fire per row. Dedup (AC-017): duplicate `customer_name` within a tenant collapses to ONE customer (upsert); a duplicate site is reported `skipped-duplicate`, never inserted twice. SECURITY (AC-019): untrusted CSV is parsed client-side only (no server file storage), caps enforced PRE-upload (before any network call), CSV lat/lng never trusted (always geocode the address), no internal errors echoed. Consume the form/field/report classes authored in CG-T6 — this ticket must not touch `index.css` (serialized sink behind CG-T6).

**Acceptance.** AC-009 (geocoder fires per row), AC-013 (parse + pre-upload caps + per-row upsert), AC-014 (report always renders + `<progress>`/cancel + copy/download), AC-017 (dedup), AC-019 (untrusted-CSV security posture).

---

### CG-T6 — `src/components/CustomerForm.tsx` + CSS (manual-add UI)

**Context.** Depends on CG-T4. First writer to `src/index.css` in the wave (CG-T5 and CG-T7 consume/extend it — serialize the sink). Follow the `AuthGate.tsx` a11y pattern exactly.

**Approach.** A SINGLE combined surface: customer brand fields (name + attrs) PLUS a repeatable list of site rows requiring ≥1 site (block submit with 0 rows). On submit call `customers.ts createCustomerWithSites` (CG-T4) — upsert customer, geocode each site, insert via EWKT; a successful add makes the site's pin appear on the map. Author the new panel/form/status CSS classes in `src/index.css` as plain semantic CSS (NO Tailwind/tokens) following the existing literals (`#1a73e8`, `#b00020`, `#555`). Native `<dialog>` (focus trap + ESC + backdrop) recommended with a `.site-panel`-style fallback.

**Gotchas.** AC-012 — per-site geocode status shown DISTINCTLY (pending / geocoded / failed), signaled non-color-alone (word + glyph + color). A failed-geocode site persists UN-geocoded and flagged — never silently dropped. The four failure classes each surface a SPECIFIC recovery path: no-match → manual coords; ambiguous → pick-candidate; network-timeout → retry; rate-limit-429 → backoff+retry. Status text must be screen-reader readable (`role="alert"`/`aria-live`). Reuse `useId`, `<label htmlFor>`, `.field`/`.form-error`, real `<button>` from `AuthGate.tsx`.

**Acceptance.** AC-011 (combined form, ≥1 site, EWKT insert, pin appears), AC-012 (distinct non-color-alone per-site status + four recovery paths + flagged-not-dropped).

---

### CG-T7 — `src/components/CustomerList.tsx` + `App.tsx` wiring + delete `SiteList.tsx` + final a11y CSS pass

**Context.** Depends on CG-T5 and CG-T6. This is the integration/cleanup ticket: it supersedes the read-only `SiteList.tsx`, composes all new surfaces into `App.tsx`, and applies the final a11y CSS pass (shares `index.css` with CG-T6/CG-T5 — serialize).

**Approach.** `CustomerList.tsx` lists customers with their sites, RLS-auto-scoped (no client `where tenant_id`, like `SiteList`'s `supabase.from(...).select(...)`). Support: edit-site-address (re-geocode via the `Geocoder` seam → pin moves), move-site (update `geog` → pin moves), delete-customer (cascades its sites; UI confirm dialog shows "deletes N sites" BEFORE proceeding). Rewrite `src/App.tsx` to render `CustomerForm` (CG-T6), `CustomerImport` (CG-T5), and `CustomerList` — and NO LONGER render `SiteList`. Delete `src/components/SiteList.tsx`.

**Gotchas.** `App.tsx` currently imports `SiteList` (line 3) and renders it inside `.site-panel` (line 19) — remove both; deleting the file without removing the import breaks the build. AC-020 (a11y across EVERY new form/list surface): `useId()` label association, real `<label>`/`<button>`, `role="alert"`/`aria-live` for errors, native focus order, status non-color-alone. Darken the link-as-body-text blue to `#1558b0` (~5.9:1) in `index.css` where `#1a73e8` (~3.9:1) would otherwise fail AA as normal-weight body text. Review against the four W1 north-star files (`AuthGate.tsx`, `SiteList.tsx`, `index.css`, `MapShell.tsx`); contrast passes WCAG 2.2 AA.

**Acceptance.** AC-015 (list + edit/move/delete + "deletes N sites" confirm + `App.tsx` renders `CustomerList` not `SiteList`), AC-020 (a11y contract + `#1558b0` link darken + AA contrast).

---

### CG-T8 — `src/components/sitePinsLayer.ts` + mount into `MapShell.tsx`

**Context.** Depends on CG-T1 (`site_geo` view). Parallel to the UI tickets — its only seam is the map. Independent of the form/import/list path.

**Approach.** Create `src/components/sitePinsLayer.ts` exporting a deck.gl `ScatterplotLayer` fed from the `site_geo` view (`id, customer_id, name, address, lat, lng`). MOUNT it into `src/components/MapShell.tsx`, REPLACING the empty `MapboxOverlay({ layers: [] })` placeholder at line 33 (the existing W1 attach point) — pass the real layer(s) into the overlay.

**Gotchas.** WIRE-TO-CONSUMER (AC-010): the layer must fire in the REAL render path, not just exist — `MapShell.tsx` must import and mount `sitePinsLayer`, AND the empty `MapboxOverlay({ layers: [] })` must NO LONGER appear in `MapShell.tsx` (the grep for the empty literal must come back clean). Source pins from `site_geo` so a newly-added/geocoded site renders as a pin. Keep the maplibre lifecycle/cleanup in the existing `useEffect` intact (the `map.remove()` teardown at lines 36–39).

**Acceptance.** AC-010 (layer imported + mounted, fed from `site_geo`, empty placeholder gone).
