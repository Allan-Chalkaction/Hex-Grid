# architect-review

_Persisted by the orchestrator from the roadmap workflow return (FLAG-1: scripts have no FS access; agents cannot Write)._

# Architect Review — Wave 2 (customers-geocoding)

**Verdict:** SOUND (with prescribed decisions). has_ui=true. No ADR-018 crit-1/2/3/5 interrupt — the one architectural decision ADR-001 leaves open (geocode execution location) is resolved below as an ADR-001 addendum, exactly as the CTO framed it.

**Summary:** Add a `customer` (brand) table + `site.customer_id` FK (NOT NULL — `site` is empty post-W1, no backfill), following W1's per-table RLS pattern keyed off `auth_tenant_ids()`. Geocoding runs through a **Supabase Edge Function** (`geocode`) — the keyless US Census call is server-side to dodge browser CORS/rate fragility and to give the manual + bulk paths one code path; this extends ADR-001's "no custom server" posture and is its addendum. Persistence stays API-first: the client writes `site.geog` via PostgREST EWKT and reads pin coords from a `security_invoker` view. CSV import = one row per site, customer upsert-by-name within tenant. `exclusivity_radius_mi` stays untouched on `site` so W3's customer-vs-site radius decision is not foreclosed. Read/write symmetry: PASS (every read entity has an in-scope write path).

---

# ADR-002: Wave 2 — Customer/Site Model, Server-Side Geocoding Seam, and API-First Geo Persistence

**Status:** Proposed
**Date:** 2026-06-27
**Feature:** customers-geocoding (Wave 2)
**Spec:** docs/step-3-specs/hex-grid/waves/customers-geocoding/customers-geocoding.md
**Builds on:** ADR-001 (multi-tenant foundation) — docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md

## Context

W1 shipped `site` (with `tenant_id`, nullable `geog`, nullable `exclusivity_radius_mi`) but no `customer` table and no `site.customer_id`. The operator clarified (BINDING) that `customer` (brand) and `site` (location, holds `geog`) are distinct, 1→N. W2 turns the empty W1 shell into a usable product: add/import customers + sites, geocode each site, render pins, edit/move/delete. The CTO SIMPLIFY folds **SQLite import out** (CSV only) and forces the **geocode-execution-location** decision — the one architectural question ADR-001 does not cover (no custom server, API-first via PostgREST). `site` is empty (no W1 write path), so `customer_id` can be NOT NULL with no backfill. `geocode_cache` already exists tenant-shared.

## Decision

Add `customer` + `site.customer_id`; geocode through a Supabase Edge Function; keep all persistence API-first through PostgREST; render sites as deck.gl pins from a coordinate-exposing view.

### Component Structure
```
supabase/
  migrations/
    0002_customers_geocoding.sql     # customer table + RLS + site.customer_id FK + site_geo view
  functions/
    geocode/
      index.ts                       # Edge Function: addresses[] -> {lat,lng}[]; cache read/write; Census call
src/
  lib/
    geocoder.ts                      # Geocoder interface + EdgeGeocoder (supabase.functions.invoke('geocode'))
    customers.ts                     # data access: createCustomerWithSites, updateSite, moveSite, deleteCustomer, listCustomersWithSites
    csvImport.ts                     # CSV parse (papaparse) + per-row upsert orchestration
  components/
    CustomerForm.tsx                 # add customer (brand) + repeatable site rows (>=1)
    CustomerImport.tsx               # CSV upload + results/errors report
    CustomerList.tsx                 # list customers+sites; edit / move / delete (supersedes SiteList)
    sitePinsLayer.ts                 # deck.gl ScatterplotLayer fed from site_geo, mounted into MapShell
```

### Data Model
```sql
-- 0002_customers_geocoding.sql  (build order: customer -> RLS -> site.customer_id -> view)
-- Reuses auth_tenant_ids() + geocode_cache from 0001. Forward-only; site is EMPTY post-W1.

create table customer (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenant (id) on delete cascade,
  name       text not null,
  attributes jsonb not null default '{}'::jsonb,    -- extensible brand attrs (R2 JSONB)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, name)                          -- dedup / upsert-by-name within tenant (CSV import)
);

-- site is empty in W1 (no write path) => NOT NULL needs no backfill.
-- Implementer: confirm `select count(*) from site` = 0 before applying (it is).
alter table site
  add column customer_id uuid not null
    references customer (id) on delete cascade;      -- delete a brand -> delete its locations
create index site_customer_id_idx on site (customer_id);
```

### Access Control Policies
```sql
alter table customer enable row level security;

-- Mirror the site_tenant_* per-table pattern exactly (ADR-001). Keyed off the helper.
create policy customer_tenant_select on customer
  for select to authenticated using (tenant_id in (select auth_tenant_ids()));
create policy customer_tenant_insert on customer
  for insert to authenticated with check (tenant_id in (select auth_tenant_ids()));
create policy customer_tenant_update on customer
  for update to authenticated
  using (tenant_id in (select auth_tenant_ids()))
  with check (tenant_id in (select auth_tenant_ids()));
create policy customer_tenant_delete on customer
  for delete to authenticated using (tenant_id in (select auth_tenant_ids()));

-- Pin coords. security_invoker=true => the view runs with the CALLER's RLS, so site's
-- tenant policy still applies (a plain view would run as owner and LEAK cross-tenant).
create view site_geo with (security_invoker = true) as
  select s.id, s.customer_id, s.name, s.address,
         st_y(s.geog::geometry) as lat,
         st_x(s.geog::geometry) as lng
  from site s;
```
`site` write policies (insert/update/delete) already exist from W1 — W2 is the first wave to exercise them. No new `site` policy needed.

### Key Patterns
- **Geocoding (the load-bearing decision — ADR-001 addendum):** **Recommended: a Supabase Edge Function `geocode`.** It accepts a batch of addresses, hashes each, reads `geocode_cache`, calls the **keyless** US Census one-line-address endpoint for misses (small concurrency, e.g. 3–5), writes results back to cache, returns `{lat,lng}` per address. It forwards the caller's JWT so `geocode_cache_insert` (authenticated) passes under RLS. Server-side because the Census geocoder's browser CORS is unreliable and batch-from-browser is fragile; one code path serves manual + bulk. No secret needed in W2 (Census is keyless). The client `Geocoder` interface (`geocoder.ts`) stays the swappable seam (R5) — `EdgeGeocoder` is its W2 implementation. **Alternative if** the team rejects new infra: client-side `fetch` for manual-only — rejected as default (CORS-fragile, no bulk home).
- **Geo persistence (stays API-first):** the client writes `site.geog` directly via PostgREST EWKT — `supabase.from('site').insert({ tenant_id, customer_id, name, address, geog: 'SRID=4326;POINT(lng lat)' })`. `site_tenant_insert` WITH CHECK enforces tenant. The Edge Function does geocoding only, not persistence (clean separation; coords it returns are server-derived). Reads for pins go through the `site_geo` view. **Recommended fallback if** EWKT-through-PostgREST does not round-trip cleanly: a `security invoker` RPC `place_site(customer_id, name, address, lat, lng)` doing `ST_SetSRID(ST_MakePoint(lng,lat),4326)`. Implementer must verify the EWKT path round-trips before committing to it.
- **Add flow:** single combined form — customer (name + brand attrs) + a repeatable list of site rows (require ≥1). On submit: upsert customer, then per-site geocode → insert. Follows the `useId`/labelled-input/`role="alert"` a11y pattern in `src/components/AuthGate.tsx`.
- **CSV import grain:** **one row per site** (`customer_name, site_name?, address, …`). Per row: upsert `customer` by `(tenant_id, name)` (the `unique` constraint backs `onConflict`), geocode the address (ignore any CSV lat/lng), insert `site`. Emit a per-row results/errors report (created / geocode-failed / skipped-duplicate). Parse with **papaparse** (robust quoting) rather than hand-rolling.
- **Pins:** read `site_geo` (RLS-scoped), feed a deck.gl `ScatterplotLayer`; mount into `src/components/MapShell.tsx`, replacing the empty placeholder layer. Follows the `MapboxOverlay` wiring already in `MapShell.tsx`.
- **List + edit/move/delete:** `CustomerList.tsx` supersedes `SiteList.tsx`'s read-only pattern (`src/components/SiteList.tsx`); edit site address → re-geocode; move → update `geog`; delete customer → cascades sites (confirm "deletes N sites" in UI).

## Consequences

### Benefits
- Resolves the customer/site conflation W1 noted; exercises the W1-authored `site` write policies.
- Server-side geocoding removes the CORS/rate-limit fragility and centralises the external surface behind one auditable function; cache makes re-adds free.
- Persistence stays API-first (PostgREST) — only geocoding crosses to the Edge Function, keeping new infra minimal (keyless, secret-free).

### Tradeoffs
- An Edge Function is new infra (local `supabase functions serve`, deploy step) — accepted as the smallest viable extension of ADR-001, and the keyless Census call means no secret management in W2.
- `site_geo` view + EWKT writes are slightly more moving parts than a single RPC, but keep the client API-first and exercise existing RLS.

### Risks
- **`site_geo` cross-tenant leak if `security_invoker` is omitted** — a plain view runs as owner and bypasses `site` RLS. **Recommended mitigation:** `with (security_invoker = true)` (in the SQL above); db-migration-reviewer must confirm.
- **EWKT-through-PostgREST may not round-trip** — **Recommended mitigation:** verify on a single insert first; **alternative:** the `place_site` SECURITY INVOKER RPC.
- **Untrusted CSV upload + external calls** — **Recommended mitigation:** parse client-side (no server file storage), cap size (~5 MB) and rows (~1000), cap address length in the Edge Function, geocode addresses (never trust CSV lat/lng), never echo internal errors. security-auditor gates this.

## Implementation Notes

### Migration Safety
- Forward-only; reversible by `drop view site_geo; alter table site drop column customer_id; drop table customer;`. No backfill (`site` empty). `customer_id NOT NULL` add fails if rows exist — confirm zero first (it is).
- `on delete cascade` on `site.customer_id`: deleting a customer deletes its sites (matches the brand→locations domain).

### Testing Strategy
- **RLS (unit/integration):** two-tenant invisibility for `customer` and through `site_geo` (tenant B's customers/pins invisible to A; unauthenticated denied) — same shape as ADR-001 AC-003.
- **Geocode cache:** second add of the same address makes no Census call (cache hit).
- **CSV import:** dedup — two rows, same customer name → one customer, two sites; geocode-failure row reported, others persist.
- **Manual:** add customer+site → pin appears; edit address → pin moves; delete customer → sites + pins gone.
- **Manual verification:** Edge Function under `supabase functions serve`; oversized/over-row CSV rejected.

### Performance Considerations
- `site_customer_id_idx` for customer→sites joins; `unique (tenant_id, name)` doubles as the upsert index. `site_geog_gist` already present (W1) for W3/W4.
- Geocode cost is first-import-only (cache amortises); bound concurrency to stay polite to Census. Payloads small at W2 scale.

## Alternatives Considered

### Client-side browser geocoding (no Edge Function)
Rejected as default: Census geocoder browser CORS is unreliable and batch-from-browser exposes/rate-limits the external call. Kept only as the manual-only fallback if new infra is refused.

### Single RPC for all geo writes (`place_site`) instead of EWKT + view
Viable and prescribed as the fallback. Not the default because direct PostgREST EWKT writes keep the client uniformly API-first and exercise the existing `site` write policies; the RPC is the safety net if EWKT does not round-trip.

### Move `exclusivity_radius_mi` to `customer` in W2
Rejected: that radius decision is **owned by W3** (customer-level default vs per-site). W2 leaves the field on `site` untouched; adding the `customer` table simply gives W3 a home for a customer-level default later — the schema enables, not forecloses, the W3 choice.

## Spec Issues Found

### Blockers (must fix before implementation)
- None. Read/write symmetry passes: customer (form+import write), site (form+import+edit write; W1 policies exist), coords (geocode→EWKT write; `site_geo` read), geocode_cache (Edge Function read/write). Census integration has config (keyless), mapping (address→coords), and query strategy (Edge Function batch + cache).

### Recommendations (should fix)
- Confirm the **Edge Function** as the accepted ADR-001 addendum (prescribed default) before build — it is new infra.
- CSV import MUST geocode the address and **ignore any client-supplied lat/lng** (security).
- `site_geo` MUST be `security_invoker = true` (cross-tenant leak otherwise).
- Add **papaparse** for CSV rather than hand-rolling quote/escape handling.

### Notes (FYI for implementer)
- `customer_id` is NOT NULL with `on delete cascade` — every site belongs to a brand; deleting a brand deletes its locations (confirm in UI).
- `exclusivity_radius_mi` stays on `site`, untouched — W3 owns the radius-grain decision.
- ADR numbered **002** to follow the cited ADR-001; the orchestrator assigns the next-free number on persist.
