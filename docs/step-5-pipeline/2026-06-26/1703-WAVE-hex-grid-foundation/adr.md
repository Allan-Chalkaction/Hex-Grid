# ADR-001: Multi-Tenant Foundation — Supabase/PostGIS + Per-Table RLS + Pluggable-Auth Seam

**Status:** Proposed
**Date:** 2026-06-26
**Feature:** hex-grid-foundation (Wave 1)
**Spec:** docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/prompt.md
**Planner source:** docs/step-5-pipeline/2026-06-24/0917-PLANNER-hex-grid-map/{architecture-brief.md, build-plan.md, wave-1-spec.md}

## Context

Greenfield empty repo. Wave 1 builds the foundation for a multi-tenant, map-based sales-territory / exclusivity system: the app loads, a Supabase (Postgres + PostGIS + RLS + Auth) backend stands up, and every data path is tenant-scoped. The load-bearing decisions (Postgres+PostGIS+RLS multi-tenancy, API-first via PostgREST, a pluggable-auth seam) were deliberated and locked at plan time (architecture-brief.md R2/R3/R4/R7) and are not re-litigated here.

The single real risk is the multi-tenant RLS isolation surface. A prior cto pass caught three traps the spec now resolves: (1) `membership`'s policy must not subquery `membership` (infinite recursion); (2) `tenant`'s key is `id`, not `tenant_id`, so its policy is `id in (...)` not the generic `tenant_id in (...)`; (3) `geocode_cache` is deliberately tenant-shared (no `tenant_id` column). This ADR locks the canonical mitigation — a `SECURITY DEFINER` `auth_tenant_ids()` helper — and the exact per-table policy SQL the implementer builds against.

## Decision

Build a Vite/React/TS frontend over a Supabase backend. Data access is API-first through PostgREST/supabase-js — the client issues no raw SQL. Tenancy is enforced in the database by per-table RLS keyed off a `membership(user_id, tenant_id)` join table, which is the swappable identity seam. Schema carries later-wave fields now (nullable) to avoid migration churn, but no later-wave behavior is built.

### Component Structure

```
hex-grid/
  supabase/
    config.toml                      # supabase init output
    migrations/
      0001_init_postgis_schema.sql   # extension + tables + GIST index + RLS helper + policies
    seed.sql                         # dev tenant + dev membership (+ note on seeding the auth user)
  src/
    lib/
      supabaseClient.ts              # supabase-js client (anon key, from env)
      auth.ts                        # the auth seam: getSession/signIn/signOut + onAuthStateChange
      tenant.ts                      # tenant-context resolver: membership -> active tenant_id
    components/
      AuthGate.tsx                   # bare login (email/password or magic link); renders app when authed
      MapShell.tsx                   # MapLibre (CONUS, OpenFreeMap) + deck.gl MapboxOverlay (empty layer)
      SiteList.tsx                   # tenant-scoped site fetch (empty in W1) + count beside the map
    App.tsx
    main.tsx
  .env.example                       # VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY
  index.html
  package.json / tsconfig.json / vite.config.ts / eslint+prettier config
  README.md                          # quickstart (AC-008)
```

### Data Model

```sql
create extension if not exists postgis;

create table tenant (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

create table membership (
  user_id   uuid not null references auth.users (id) on delete cascade,
  tenant_id uuid not null references tenant (id) on delete cascade,
  role      text not null default 'member',
  primary key (user_id, tenant_id)
);

create table site (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references tenant (id) on delete cascade,
  name                 text not null,
  address              text,
  geog                 geography(Point, 4326),   -- nullable in W1, populated W2/W3
  vertical             text,                     -- nullable in W1
  exclusivity_radius_mi numeric,                 -- nullable in W1
  is_zone_on           boolean not null default true,
  attributes           jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index site_geog_gist on site using gist (geog);

-- shared cache: NO tenant_id by design (address->lat/lng is public, deterministic, non-tenant-private)
create table geocode_cache (
  address_hash text primary key,
  address      text not null,
  lat          double precision,
  lng          double precision,
  provider     text,
  created_at   timestamptz not null default now()
);
```

### Access Control Policies

The recursion-safe helper is the linchpin. It is `SECURITY DEFINER` so the lookup inside it bypasses RLS on `membership`, which is what prevents the policy-evaluating-a-policy recursion. Lock the `search_path` and grant tightly.

```sql
-- Recursion-safe tenant lookup. SECURITY DEFINER => body bypasses membership RLS.
create or replace function auth_tenant_ids()
  returns setof uuid
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select tenant_id from membership where user_id = auth.uid()
$$;

revoke all on function auth_tenant_ids() from public;
grant execute on function auth_tenant_ids() to authenticated;

alter table tenant        enable row level security;
alter table membership    enable row level security;
alter table site          enable row level security;
alter table geocode_cache enable row level security;

-- membership: a user sees ONLY their own rows. MUST NOT subquery membership (recursion trap).
create policy membership_self_select on membership
  for select to authenticated
  using (user_id = auth.uid());

-- tenant: key is `id`, so id-in-membership (NOT the tenant_id-column pattern).
create policy tenant_member_select on tenant
  for select to authenticated
  using (id in (select auth_tenant_ids()));

-- site: generic tenant-scoped pattern. SELECT for W1; write policies scoped for W2 CRUD.
create policy site_tenant_select on site
  for select to authenticated
  using (tenant_id in (select auth_tenant_ids()));

create policy site_tenant_insert on site
  for insert to authenticated
  with check (tenant_id in (select auth_tenant_ids()));

create policy site_tenant_update on site
  for update to authenticated
  using (tenant_id in (select auth_tenant_ids()))
  with check (tenant_id in (select auth_tenant_ids()));

create policy site_tenant_delete on site
  for delete to authenticated
  using (tenant_id in (select auth_tenant_ids()));

-- geocode_cache: DELIBERATELY tenant-shared. Read+insert by any authenticated user.
create policy geocode_cache_read on geocode_cache
  for select to authenticated
  using (auth.uid() is not null);

create policy geocode_cache_insert on geocode_cache
  for insert to authenticated
  with check (auth.uid() is not null);
```

**Note (binding for the implementer):** with RLS enabled and NO policy granting `anon`, unauthenticated PostgREST requests return zero rows / are denied — this is the desired AC-003/AC-005 behavior. Do not add an `anon`-role policy to any of these tables. The `site` write policies are included now (low cost, keeps the table coherent) but Wave 1 builds no UI that writes sites — that is Wave 2.

### Key Patterns

- **Migration:** single raw-SQL file `supabase/migrations/0001_init_postgis_schema.sql` containing extension → tables → index → helper → policies in that order (policies reference the helper, so the helper must precede them). This matches the locked "raw SQL under supabase/migrations/" decision.
- **Seed (`supabase/seed.sql`):** insert one `tenant`, then one `membership` row binding a dev `auth.users` id to it. Because `membership.user_id` FKs `auth.users`, the dev auth user must exist first. Document in the README that the operator creates the dev user via the Supabase Studio Auth UI (or `supabase` CLI), then the seed binds membership. Prefer README-documented Studio-create + a seed that upserts membership against a fixed dev UUID; keep the concrete interim path explicit (this is the AC-006 working-tenant-context guarantee).
- **Auth seam (`src/lib/auth.ts` + `tenant.ts`):** all identity goes through one thin module exposing session/signIn/signOut/onAuthStateChange; tenant resolution is a separate `membership -> active tenant_id` step. The parent app later swaps `auth.ts` for its own provider; table policies never change because they key off `membership`, not the identity source (AC-007). Document this seam in the README.
- **Map shell (`MapShell.tsx`):** MapLibre `Map` with `style: 'https://tiles.openfreemap.org/styles/liberty'`, `center: [-98.5795, 39.8283]`, `zoom: 4`; mount deck.gl via `MapboxOverlay` (the `@deck.gl/mapbox` interop) added as a MapLibre control with one empty placeholder layer (proves the pipeline, AC-004).
- **Site fetch (`SiteList.tsx`):** `supabase.from('site').select('*')` — RLS auto-scopes to the authed user's tenant; render count + list. Empty in W1, but the path is end-to-end real (AC-005).

## Consequences

### Benefits
- Hard tenant isolation enforced in the database (defense-in-depth — the client cannot bypass it via PostgREST).
- The `membership` join table is a clean, swappable identity seam: the embed wave changes the identity source, not a single table policy.
- Schema carries later-wave fields now, so Waves 2–4 add behavior with zero migration churn on these tables.

### Tradeoffs
- Per-table (not generic) policies are slightly more SQL to maintain, but the three traps make a single generic pattern incorrect here — explicit per-table policies are the correct cost.
- `geocode_cache` being tenant-shared is a deliberate, documented exception; reviewers must not "fix" it into tenant isolation.

### Risks
- **RLS recursion / mis-scoping** (the load-bearing risk). Mitigation is locked: `SECURITY DEFINER auth_tenant_ids()` with a pinned `search_path`; `membership` policy never subqueries `membership`. **db-migration-reviewer + security-auditor are auto-routed against exactly this surface** — AC-003 requires a two-tenant invisibility test (tenant B's rows invisible to tenant A; unauthenticated denied).
- **`SECURITY DEFINER` footgun:** an unpinned `search_path` is a privilege-escalation vector. **Recommended mitigation:** `set search_path = public, pg_temp` on the function (done in the SQL above) plus `revoke ... from public` / `grant execute ... to authenticated`. **Alternative if** the team prefers no SECURITY DEFINER at all: inline `tenant_id in (select tenant_id from membership where user_id = auth.uid())` on `site`/`tenant` — this works because those policies query `membership` (not their own table), so there is no recursion; but it loses the single-source helper and is more error-prone. The helper is recommended.
- **Seed/auth-user ordering:** `membership.user_id` FKs `auth.users`, so the dev user must exist before the membership seed. **Recommended mitigation:** README documents create-dev-user-first (Studio/CLI), seed upserts membership against a fixed dev UUID — concrete, not "will be available."

## Implementation Notes

### Migration Safety
- Forward-only greenfield migration; reversibility is moot (no prior state). It is idempotent-friendly (`create extension if not exists`, `create or replace function`).
- No data backfill — empty database.
- Zero-downtime is N/A (greenfield, local dev via `supabase start`).

### Testing Strategy
- **RLS isolation (the critical test, AC-003):** seed two tenants + two users; as user A, assert `select * from site`/`tenant`/`membership` returns only A's rows and zero of B's; assert an unauthenticated/`anon` request returns nothing. db-migration-reviewer must confirm.
- **Recursion:** confirm `select * from membership` as an authed user does not error (proves the membership policy is non-recursive).
- **Frontend:** `vite build` succeeds; the app renders the CONUS basemap with the deck.gl overlay and zero console errors (AC-004); authed empty-site fetch works, unauthed is blocked (AC-005).
- **Quickstart:** the README steps actually stand the system up from clean (AC-001/AC-008).

### Performance Considerations
- `GIST(geog)` index present now for the spatial queries Waves 3–4 will run (no cost in W1, avoids a later migration).
- W1 payloads are trivial (empty site list). The `in (select auth_tenant_ids())` form is the Supabase-recommended pattern (the subquery is wrapped so it evaluates once, not per-row).
- No caching layer needed in W1.

## Alternatives Considered

### Single generic RLS pattern (`tenant_id in (...)` on every table)
Rejected: incorrect for this schema. `tenant`'s key is `id` not `tenant_id`, `membership` would recurse, and `geocode_cache` has no `tenant_id`. The three traps make a one-size policy actively wrong — per-table policies are required, not stylistic.

### SQLite / app-layer tenancy (no PostGIS, no RLS)
Rejected at plan time (architecture-brief R2/R3): SQLite fails the multi-tenant + geospatial + embed locks. App-layer-only tenancy puts isolation in application code where a single missed `where tenant_id =` leaks cross-tenant data; database RLS is defense-in-depth and the canonical Supabase approach.

### Hardwired Supabase Auth (no membership seam)
Rejected (architecture-brief R4/R7, D4 "attach to another application"): keying policies directly off `auth.uid() = owner` would hardwire the identity source. The `membership` indirection lets the parent app own identity later without touching table policies (AC-007).

## Spec Issues Found

### Blockers (must fix before implementation)
- None.

### Recommendations (should fix)
- **Seed/auth-user FK ordering:** make the interim path concrete — create the dev `auth.users` user first (Studio/CLI), then seed upserts `membership` against a fixed dev UUID. Required for AC-006; do not leave as "the user will be available."
- **SECURITY DEFINER hardening:** pin `set search_path = public, pg_temp` on `auth_tenant_ids()` and `revoke from public` / `grant execute to authenticated`. The security-auditor will check this.

### Notes (FYI for implementer)
- `site` write policies (insert/update/delete) are in the migration now for table coherence; Wave 1 builds no site-writing UI (Wave 2). Not scope creep.
- `geocode_cache` tenant-shared with no `tenant_id` is deliberate and documented — do not "fix" it into isolation.
- With RLS on and no `anon` policy, unauthenticated PostgREST requests are denied by construction (AC-003/AC-005) — do not add an `anon`-role policy.
