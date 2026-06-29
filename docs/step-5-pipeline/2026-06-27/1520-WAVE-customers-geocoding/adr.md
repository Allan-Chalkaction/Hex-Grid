# ADR-002: Customers + Per-Site Geocoding — Edge-Function Geocode, Client-Side API-First Persistence, security_invoker site_geo View

**Status:** Proposed
**Date:** 2026-06-27
**Feature:** customers-geocoding (Wave 2)
**Spec:** docs/step-5-pipeline/2026-06-27/1520-WAVE-customers-geocoding/customers-geocoding.md
**Builds on:** ADR-001 (docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md)

## Context

Wave 1 shipped the multi-tenant substrate this wave consumes: `auth_tenant_ids()` (SECURITY DEFINER, pinned search_path), the per-table `site_tenant_*` RLS policy shape, the tenant-shared `geocode_cache` (`address_hash` PK, no `tenant_id`), the empty `MapboxOverlay({ layers: [] })` attach point in `MapShell.tsx` (line 33), the W1 form-a11y pattern in `AuthGate.tsx` (`useId`, `role="alert"`, `.field`/`.form-error`), and the RLS-auto-scoped read pattern in `SiteList.tsx`. `site` is empty (no W1 write path), and its write policies are authored-but-unexercised.

Wave 2 turns that empty shell into a usable product: a `customer` (brand) owning 1→N `site`s, per-site geocoding via a keyless US Census Edge Function (cache-first), client-side API-first persistence through PostgREST using EWKT, and deck.gl pins on the map. The load-bearing risks were named at plan time and the scope was already right-sized by a prior cto SIMPLIFY (SQLite import deferred → CSV only; geocode execution forced to a Supabase Edge Function). This ADR locks the migration shape, the geocode/persistence seam split, and the cross-tenant-safe view.

## Decision

Keep ADR-001's posture unchanged: API-first through PostgREST, tenancy enforced in the database by per-table RLS keyed off `membership` via `auth_tenant_ids()`. Add a `customer` table (per-table RLS mirroring `site_tenant_*` exactly), make `site.customer_id` NOT NULL, and expose a **`security_invoker` `site_geo` view** for read/display. **Geocoding and persistence are split across two seams:** the Edge Function does geocoding *only* (address string → lat/lng, cache-first); persistence stays *client-side, API-first* (EWKT insert through PostgREST). The geocoder is consumed through a swappable `Geocoder` interface (W1's R5 seam pattern).

### Component Structure

```
supabase/
  migrations/
    0002_customers_geocoding.sql     # CG-T1 (+ conditional place_site RPC, CG-T4)
  functions/
    geocode/index.ts                 # CG-T2 — Edge Function (Census, cache-first, batch)
src/
  lib/
    geocoder.ts                      # CG-T3 — Geocoder interface + EdgeGeocoder impl
    customers.ts                     # CG-T4 — createCustomerWithSites (manual-add write path)
    csvImport.ts                     # CG-T5 — CSV orchestration (dedup, per-row report)
  components/
    CustomerForm.tsx                 # CG-T6 — manual-add UI (combined customer + ≥1 site)
    CustomerImport.tsx               # CG-T5 — CSV upload UI (progress/cancel/error report)
    CustomerList.tsx                 # CG-T7 — supersedes SiteList; edit/move/delete
    sitePinsLayer.ts                 # CG-T8 — deck.gl ScatterplotLayer from site_geo
    MapShell.tsx                     # CG-T8 — mount sitePinsLayer (replace empty overlay)
    App.tsx                          # CG-T7 — render Form/Import/List; drop SiteList
    SiteList.tsx                     # CG-T7 — DELETED
    index.css                        # CG-T6/T7 — new panel/form/status classes
package.json                         # CG-T5 — add papaparse + @types/papaparse
```

### Data Model

```sql
-- 0002_customers_geocoding.sql
-- BINDING build order: customer table -> customer RLS -> site.customer_id -> site_geo view.
-- REUSES (never redefines) auth_tenant_ids() and geocode_cache from 0001.
-- Leaves site.exclusivity_radius_mi UNTOUCHED (W3 owns the radius grain).

-- 1. customer
create table customer (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenant (id) on delete cascade,
  name       text not null,
  attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, name)               -- enables PostgREST upsert onConflict=(tenant_id,name)
);
create index customer_tenant_id_idx on customer (tenant_id);

-- 3. site.customer_id (site is EMPTY post-W1 — no backfill; assert before NOT NULL)
do $$ begin
  if (select count(*) from site) <> 0 then
    raise exception 'site not empty: customer_id NOT NULL needs a backfill strategy';
  end if;
end $$;
alter table site
  add column customer_id uuid not null references customer (id) on delete cascade;
create index site_customer_id_idx on site (customer_id);

-- 4. site_geo view — security_invoker so it runs under the CALLER's RLS (PG15+).
-- A plain owner-run view would bypass site/customer RLS and leak cross-tenant.
create view site_geo with (security_invoker = true) as
  select s.id, s.customer_id, s.name, s.address,
         ST_Y(s.geog::geometry) as lat,
         ST_X(s.geog::geometry) as lng
  from site s;

-- Reversible: drop view site_geo; alter table site drop column customer_id; drop table customer;
```

### Access Control Policies

```sql
-- 2. customer RLS — four per-table policies, mirroring site_tenant_* in 0001 EXACTLY.
-- No generic/shared policy, no anon policy (DELIBERATE-NO-ANON: with RLS on and no anon
-- policy, unauthenticated PostgREST returns zero rows — the AC-003/AC-005 posture).
alter table customer enable row level security;

create policy customer_tenant_select on customer
  for select to authenticated
  using (tenant_id in (select auth_tenant_ids()));

create policy customer_tenant_insert on customer
  for insert to authenticated
  with check (tenant_id in (select auth_tenant_ids()));

create policy customer_tenant_update on customer
  for update to authenticated
  using (tenant_id in (select auth_tenant_ids()))
  with check (tenant_id in (select auth_tenant_ids()));

create policy customer_tenant_delete on customer
  for delete to authenticated
  using (tenant_id in (select auth_tenant_ids()));
```

The `site_geo` view inherits enforcement from `site`/`customer` RLS via `security_invoker = true` — no policy is defined *on* the view (views don't take RLS policies; the invoker flag is the entire isolation mechanism). An anon caller's underlying RLS returns zero rows, so the view returns zero rows by construction. **Do not** add an anon policy; **do not** drop `security_invoker`.

### Persistence: EWKT-first, RPC fallback (the one conditional migration edit)

**Recommended (default): client-side EWKT insert through PostgREST.** After geocoding, `customers.ts`/`csvImport.ts` insert each site via supabase-js with `geog: 'SRID=4326;POINT(lng lat)'`, supplying `tenant_id` (resolved from `tenant.ts`), `customer_id`, `name`, `address`. PostGIS parses EWKT text → `geography`; RLS `with check (tenant_id in (...))` passes. The implementer MUST verify a single EWKT insert round-trips to a readable `site_geo` row *before* committing to this approach (AC-021).

**Alternatives if the EWKT round-trip fails:** add a `security invoker` RPC `place_site` to migration `0002` (the only conditional edit to that file — serialized behind CG-T1 under the single wave-builder) and call it instead:

```sql
create or replace function place_site(
  p_customer_id uuid, p_name text, p_address text,
  p_lat double precision, p_lng double precision
) returns site
  language sql
  security invoker                       -- caller RLS still enforced (NOT definer)
  set search_path = public, pg_temp
as $$
  insert into site (tenant_id, customer_id, name, address, geog)
  select c.tenant_id, p_customer_id, p_name, p_address,
         ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
  from customer c
  where c.id = p_customer_id
  returning *;
$$;
```

The Edge Function does geocoding ONLY regardless of which path persists — persistence never moves server-side.

### Key Patterns

- **Migration:** follow `0001_init_postgis_schema.sql` literally — same per-table policy shape (`tenant_id in (select auth_tenant_ids())`), same DELIBERATE-NO-ANON note, helper/cache reused not redefined.
- **Geocoder seam (`geocoder.ts`):** mirror `auth.ts`/`tenant.ts` — export a `Geocoder` *interface* (`(addresses: string[]) => Promise<({lat,lng}|null)[]>`, input-order) and an `EdgeGeocoder` impl calling `supabase.functions.invoke('geocode')`. Consumers import the *interface type*, never the concrete class.
- **Reads (`CustomerList`, `sitePinsLayer`):** RLS-auto-scoped, no client `where tenant_id` — exactly the `SiteList.tsx` pattern. Pins/list display read `site_geo`; edits/moves/deletes write the `site`/`customer` *base tables* (a view is not the write surface).
- **Form a11y (`CustomerForm`, `CustomerImport`, `CustomerList`):** follow `AuthGate.tsx` — `useId()` label association, real `<label>`/`<button>`, `role="alert"`/`aria-live` for errors, status signalled non-color-alone (word + glyph + color). Native `<dialog>` (focus trap + ESC + backdrop) is the recommended default for the add/confirm surfaces, with a `.site-panel`-style fallback.
- **CSS:** extend `src/index.css` with plain semantic classes (no Tailwind/tokens), following existing literals (`#1a73e8`, `#b00020`, `#555`). Darken link-as-body-text blue to `#1558b0` (~5.9:1) where it would fail AA.
- **deck.gl pins:** `ScatterplotLayer` (from the `deck.gl` umbrella, already a dep) fed from `site_geo`, mounted into the existing `MapboxOverlay` at `MapShell.tsx:33` — the empty-layer placeholder must no longer appear.

## Consequences

### Benefits
- Cross-tenant isolation holds end-to-end: `customer` mirrors the proven `site` policy shape and `site_geo` enforces via `security_invoker`, so the new read surface cannot leak.
- Geocode/persistence split keeps secrets and untrusted input server-bounded only where needed (geocoding) while persistence stays in the proven API-first path; the `Geocoder` interface lets the provider swap without touching consumers.
- `geocode_cache` (tenant-shared) makes a repeat address cost zero Census calls (AC-016); W1's unused `site` write policies are finally exercised, reducing latent debt.

### Tradeoffs
- Per-site geocoding is inherently latency-bound; bulk import is gated on bounded-concurrency Census calls. Accepted — cache absorbs repeats, and a failed-geocode site is persisted un-geocoded and flagged, never dropped.
- Site dedup (AC-017) is application-level (no DB unique constraint on `site`), so two *concurrent* imports could double-insert. Out of wave scope; acceptable.

### Risks
- **security_invoker omitted → cross-tenant leak.** Mitigation: `with (security_invoker = true)` is mandatory and load-bearing; db-migration-reviewer + security-auditor gate this surface; a two-tenant RLS test (tenant B invisible to A; unauthenticated → zero rows) against `customer` and `site_geo` is required.
- **EWKT round-trip uncertainty.** Mitigation: verify-before-commit (above); RPC fallback prescribed with exact SQL — no implementer guesswork.
- **Untrusted CSV / client-supplied coords.** Mitigation: CSV parsed client-side only (no server storage), size/type/row caps enforced *pre-upload*; geocode the address string only — never persist client/CSV lat/lng; never echo internal errors.
- **Census availability / failure classes.** Mitigation: four classes (no-match / ambiguous / timeout / rate-limit-429) each surface a specific recovery path; Edge Function returns structured per-address failure, bounded concurrency (recommend 4, range 3–5), batch-size + address-length caps.

## Implementation Notes

### Migration Safety
- Forward-only; reversible via `drop view site_geo; alter table site drop column customer_id; drop table customer;`. The conditional `place_site` RPC reverses with `drop function place_site`.
- No backfill: the `do $$ ... $$` guard asserts `site` is empty before the NOT NULL add — fails loudly if W1 left data.
- Build order is BINDING (customer → RLS → `customer_id` → view); the view's `ST_Y/ST_X` need the column present.

### Testing Strategy
- **Critical (RLS):** seed two tenants; as tenant A assert `customer` and `site_geo` return only A's rows, zero of B's; unauthenticated PostgREST select returns zero rows. db-migration-reviewer confirms.
- **Cache (AC-016):** a second geocode of an already-cached address makes ZERO outbound Census calls.
- **Wire-to-consumer:** the geocoder is *invoked* per site in `customers.ts` and per row in `csvImport.ts` (asserted, not merely defined); `sitePinsLayer` fires in the real `MapShell` render path and the empty overlay is gone.
- **EWKT round-trip:** one insert → readable `site_geo` row, before adopting the approach.
- **CSV:** per-row report maps 1:1 to input rows (created / geocode-failed / skipped-duplicate), rendered even on total failure; caps reject oversized files pre-upload.
- **a11y:** WCAG 2.2 AA against the four W1 north-star files; status non-color-alone; `vite build` clean.

### Performance Considerations
- `site_customer_id_idx` + `customer_tenant_id_idx` support the list/pin reads; `site_geog_gist` (from 0001) remains for W3/W4.
- `in (select auth_tenant_ids())` is the Supabase wrapped-subquery form (evaluates once, not per-row).
- Geocode batching: cache-first, bounded concurrency (4) for misses only; payloads are small (CONUS site sets).

## Alternatives Considered

### Geocode + persist both server-side (Edge Function writes sites)
Rejected. It abandons the locked API-first/PostgREST posture (ADR-001), duplicates RLS enforcement into function code, and centralizes write logic the client already does safely. The Edge Function is scoped to geocoding (the one thing that genuinely needs a server: a keyless outbound call + shared-cache writes under the caller's JWT).

### Owner-run (non-invoker) site_geo view
Rejected — actively unsafe. A default view runs as its owner and bypasses the underlying RLS, leaking every tenant's sites to every caller. `security_invoker = true` is the only correct option here.

### Generic single RLS policy for customer
Rejected for the same reason ADR-001 rejected it: explicit per-table policies matching `site_tenant_*` keep the surface auditable and avoid the `tenant`/`membership`/`geocode_cache` traps. `customer` is a straightforward `tenant_id`-keyed table, so it takes the `site`-shaped four policies verbatim.

### Persist CSV/manual lat/lng directly (skip geocoding when coords present)
Rejected (AC-009/AC-019). Trusting client/CSV coordinates is a data-integrity and spoofing hazard; always geocode the address string. The geocoder MUST fire per site/row.

## Spec Issues Found

### Blockers (must fix before implementation)
- None. Every read entity (`customer`, `site`, `site_geo`, `geocode_cache`, Census) has a verified in-scope or W1 write/source path.

### Recommendations (should fix)
- **`site_geo` lat/lng derivation:** the view must compute `ST_Y(geog::geometry) as lat, ST_X(geog::geometry) as lng` (geog has no direct lat/lng columns). Specified in the SQL above so the implementer doesn't guess.
- **`site` insert needs `tenant_id`:** the EWKT client insert must supply `tenant_id` (from `tenant.ts`) alongside `customer_id` or the RLS `with check` fails; the RPC fallback derives it from the customer row.

### Notes (FYI for implementer)
- `security_invoker` views require PG15+ (Supabase satisfies this).
- No `updated_at` trigger exists (0001 didn't add one); set it in the update path or leave the default — not load-bearing this wave.
- Reuse `geocode_cache` and `auth_tenant_ids()` from 0001 verbatim — do not redefine; do not add a `tenant_id` to `geocode_cache` (deliberately shared, ADR-001).
- The `deck.gl` umbrella dep already provides `ScatterplotLayer`; only `papaparse` needs adding (CG-T5).
