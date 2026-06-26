# Wave 1 spec — Map shell + data foundation (BUILD TARGET)

**This is the scope for the first `/orchestrated` run.** Greenfield empty repo. Goal: a reviewed,
solid foundation — map renders, Supabase backend with PostGIS + RLS multi-tenancy stands up, the
app is tenant-scoped. Everything past this is Waves 2–6 (see `build-plan.md`) and is **out of scope
here**.

## Locked stack (do not re-litigate — see `architecture-brief.md`)

- **Frontend:** React + Vite + TypeScript; **MapLibre GL JS + deck.gl**.
- **Backend:** **Supabase** (managed Postgres + **PostGIS** + **RLS** + Auth); local dev via the
  **Supabase CLI** (`supabase start` → Postgres/PostGIS/Auth in Docker).
- **Data access = API-first via Supabase** (PostgREST / `supabase-js`) — the client does NOT issue
  raw SQL; the PostgREST layer IS the API boundary (keeps the "attach to another app" seam clean).
- **Migrations:** raw SQL under `supabase/migrations/` (best for PostGIS + RLS).
- **Basemap tiles:** **OpenFreeMap** (`https://tiles.openfreemap.org/styles/liberty`, no API key) for
  Wave 1 simplicity. *Alt:* MapTiler free tier (needs key) — note in README, don't block on it.

## Schema (Wave 1 migration)

Enable `postgis`. Tables (all tenant-scoped tables carry `tenant_id`):

- `tenant(id uuid pk default gen_random_uuid(), name text not null, created_at timestamptz default now())`
- `membership(user_id uuid references auth.users, tenant_id uuid references tenant, role text default 'member', primary key (user_id, tenant_id))`
  — maps a Supabase auth user → tenant(s); this is the **pluggable-auth seam** (swap the identity
  source later, keep the membership→tenant model).
- `site(id uuid pk default gen_random_uuid(), tenant_id uuid not null references tenant, name text not null, address text, geog geography(Point,4326), vertical text, exclusivity_radius_mi numeric, is_zone_on boolean default true, attributes jsonb not null default '{}', created_at timestamptz default now(), updated_at timestamptz default now())`
  — geog/vertical/radius are nullable in Wave 1 (populated in Wave 2/3); schema includes them now so
  downstream waves need no migration churn.
- `geocode_cache(address_hash text primary key, address text not null, lat double precision, lng double precision, provider text, created_at timestamptz default now())`
- Index: `GIST (geog)` on `site`.

**RLS (load-bearing):** enable RLS on `tenant`, `site`, `geocode_cache`, `membership`. Tenant-scoped
read/write policy pattern:
`tenant_id in (select m.tenant_id from membership m where m.user_id = auth.uid())`.
`geocode_cache` may be tenant-shared or tenant-scoped — default tenant-scoped for isolation in v1.

**Seed:** one dev tenant + dev user membership so the app has a working tenant context out of the box.

## Frontend (Wave 1)

- Vite React TS app; minimal Supabase **auth** (email/password or magic link) so RLS has a real
  `auth.uid()`. Keep login bare — it's a seam, not a feature.
- **Map shell:** MapLibre centered on CONUS (`center [-98.5795, 39.8283]`, `zoom ~4`), OpenFreeMap
  style; **deck.gl overlay mounted** via `MapboxOverlay` interop with a placeholder/empty layer
  (proves the deck.gl pipeline works — no data yet).
- Authenticated app fetches tenant-scoped `site` rows via `supabase-js` (empty list in Wave 1) and
  shows a trivial count/list beside the map — proves the RLS-scoped read path end to end.

## Acceptance criteria

- **AC-001** `supabase start` brings up local Postgres + PostGIS + Auth; `supabase/migrations` apply clean.
- **AC-002** Schema matches above: `postgis` enabled; `tenant`/`membership`/`site`/`geocode_cache`
  exist; `site.geog` is `geography(Point,4326)`; `attributes` is `jsonb`; `GIST(geog)` index present.
- **AC-003** RLS enabled on all tenant tables; a user sees **only** their tenant's rows (verify a
  second tenant's rows are invisible). Unauthenticated access returns nothing / is denied.
- **AC-004** Frontend builds (`vite build`) and renders the OpenFreeMap CONUS basemap with a deck.gl
  overlay mounted and no console errors.
- **AC-005** Authenticated dev user → app fetches tenant-scoped sites (empty) via `supabase-js`;
  unauthenticated → blocked by RLS.
- **AC-006** Seed creates a dev tenant + membership; app has a working tenant context on first run.
- **AC-007** Auth seam documented: identity → `membership` → tenant is isolated so the parent app's
  auth can be swapped in later without touching table policies.
- **AC-008** `README.md` quickstart: `supabase start`, apply migrations/seed, `npm run dev`.

## Explicitly OUT of scope for Wave 1 (later waves)

Geocoding, add-customer forms, CSV/SQLite import, exclusivity radius logic, zone rendering, saturation
/ H3 hex layers, reference layers (capitals/metros/ZIP), vertical filtering. Schema *fields* for these
exist now; the *behavior* does not.

## Recommended gates (the engine adds these)

architect-review (PRE — authors the foundation ADR + validates soundness) · db-migration-reviewer
(schema + **RLS isolation**) · code-reviewer · **security-auditor** (multi-tenant RLS + auth is a
security surface — the engine auto-adds this).

## Suggested ticket slicing (the decompose step will refine)

1. Repo + tooling scaffold (Vite/React/TS, Supabase CLI init, lint/format, README skeleton).
2. Supabase schema migration + RLS policies + GIST index + seed.
3. Supabase auth wiring (login seam) + tenant-context/membership.
4. Map shell (MapLibre CONUS + OpenFreeMap style) + deck.gl overlay mount.
5. Tenant-scoped `site` fetch via supabase-js + trivial list/count beside the map.
