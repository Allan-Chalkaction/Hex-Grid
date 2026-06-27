# hex-grid

A multi-tenant, map-based sales-territory / exclusivity system. **Wave 1** is the
foundation: a Vite/React/TS frontend over a Supabase (Postgres + PostGIS + RLS +
Auth) backend, with every data path tenant-scoped via per-table row-level security
keyed off a `membership` join table (the pluggable-auth seam). The app loads, the
CONUS basemap renders with a deck.gl overlay mounted, and an authenticated user
reads tenant-scoped (empty in W1) site rows end-to-end.

## Prerequisites

- **Docker** — required by the Supabase CLI local stack.
- **Supabase CLI** — `supabase` on your PATH (`brew install supabase/tap/supabase`).
- **Node** 20+ and **npm**.

## Quickstart (clean start → running app)

Follow these steps in order from a clean checkout.

### 1. Start the local Supabase stack

```bash
supabase start
```

This brings up local Postgres + PostGIS + Auth (via Docker) and prints your local
**API URL** and **anon (publishable) key** — you need both for step 3. PostGIS is
available in the stack (verify with `supabase db reset` output or
`select postgis_version();`).

### 2. Create the dev auth user, then apply migrations + seed

There is one ordering constraint: `membership.user_id` has a foreign key to
`auth.users(id)`, so a dev auth user must exist before the membership seed binds to
it. There are two supported paths.

**Path A — self-contained (default; zero manual steps).** The seed
(`supabase/seed.sql`) inserts a local-only dev auth user itself, so a clean reset
stands the whole system up:

```bash
supabase db reset      # applies supabase/migrations/ then supabase/seed.sql
```

The seed uses these fixed local-dev identifiers (idempotent — `db reset` is
re-runnable):

| Item            | Value                                                    |
| --------------- | -------------------------------------------------------- |
| Dev user UUID   | `00000000-0000-0000-0000-0000000000d1`                   |
| Dev tenant UUID | `00000000-0000-0000-0000-0000000000a1`                   |
| Dev login       | `dev@hex-grid.local` / `devpass123` **(LOCAL DEV ONLY)** |

**Path B — operator-created (production-shaped).** Create the dev user FIRST via
the Supabase Studio Auth UI (`http://127.0.0.1:54323` → Authentication → Add user)
or the CLI, then run `supabase db reset`. The seed upserts the `membership` row
against the **same fixed dev UUID** above, so it reconciles rather than duplicates.
Use this path when you want to model the real "identity exists independently of the
app" flow.

After reset: `select count(*) from tenant` ≥ 1 and `select count(*) from membership`
≥ 1, with `membership.tenant_id` matching the seeded `Dev Tenant`. Signing in as the
dev user resolves an active `tenant_id`.

### 3. Configure the client environment

```bash
cp .env.example .env
```

Then fill in the two variables from step 1's `supabase start` output (or
`supabase status`):

```
VITE_SUPABASE_URL=        # e.g. http://127.0.0.1:54321
VITE_SUPABASE_ANON_KEY=   # the anon / publishable key
```

`.env` is git-ignored — never commit it, and never commit the service-role key.
`.env.example` holds variable **names** only.

### 4. Install dependencies and run the dev server

```bash
npm install
npm run dev
```

Open the printed local URL, sign in as the dev user (`dev@hex-grid.local` /
`devpass123` on Path A), and you should see the CONUS basemap with the deck.gl
overlay mounted and a tenant-scoped site count of **0** (Wave 1 seeds no sites).

`npm run build` (which runs `tsc --noEmit && vite build`) produces a production
build.

## Auth seam (swap point)

Identity is isolated behind a single thin module so the parent application can later
swap in its own auth provider **without touching any table policy**:

- **`src/lib/auth.ts`** is the swap point. It is the only module that touches
  `supabase.auth`, exposing `getSession` / `signIn` / `signOut` /
  `onAuthStateChange`. To attach a different identity source later, change this file
  only.
- **`src/lib/tenant.ts`** resolves the active tenant as a separate
  `membership → active tenant_id` step.
- **RLS policies never change when the identity source is swapped**, because they
  key off the `membership` table (resolved by the `SECURITY DEFINER`
  `auth_tenant_ids()` helper), **not** off the identity source. Swapping `auth.ts`
  changes _who_ is authenticated; the membership-keyed policies keep enforcing
  tenant isolation unchanged.

## Basemap

The map uses the **OpenFreeMap `liberty`** style
(`https://tiles.openfreemap.org/styles/liberty`) — **no API key required**, so a
clean checkout renders the map with zero configuration. If you prefer a different
provider, **MapTiler**'s free tier is a keyed alternative (set a style URL with your
key in `src/components/MapShell.tsx`); do not block setup on obtaining a key.

## Multi-tenant isolation — verification

Tenant isolation is enforced in the database by per-table RLS (see
`supabase/migrations/0001_init_postgis_schema.sql`). The Wave-1 acceptance floor is
a **runnable two-tenant invisibility check**: seed two tenants + two users, then as
user A confirm `select * from site` / `tenant` / `membership` returns only A's rows
and **zero** of B's, that selecting `membership` does not raise
`infinite recursion detected in policy`, and that an unauthenticated request returns
nothing. `geocode_cache` is the deliberate exception — it is tenant-shared (any
authenticated user reads/inserts; it has no `tenant_id` column).

You can run this as a psql procedure against the local DB. Example (replace
`<DB_CONTAINER>` with your `supabase_db_*` container name from `docker ps`):

```bash
docker exec -i <DB_CONTAINER> psql -U postgres -d postgres <<'SQL'
-- seed two tenants + users + sites, then, as user A, in a transaction:
--   set local role authenticated;
--   set local request.jwt.claims = '{"sub":"<user-A-uuid>","role":"authenticated"}';
--   select count(*) from site;   -- only A's rows; zero of B's
--   select count(*) from membership;  -- no recursion error
-- and as anon: select count(*) from site/tenant/membership;  -- all zero
SQL
```

The non-recursive `membership` policy keys off `auth.uid()` directly (never
subqueries `membership`), and the `tenant` policy keys off `id` (not `tenant_id`) —
both are required by the schema's shape, so the policies are deliberately per-table
rather than one generic pattern.

## Project layout

```
supabase/
  config.toml                      # supabase init output
  migrations/
    0001_init_postgis_schema.sql   # extension + tables + GIST index + RLS helper + policies
  seed.sql                         # dev tenant + dev membership (+ local dev auth user)
src/
  lib/
    supabaseClient.ts              # supabase-js client (anon key, from env)
    auth.ts                        # the auth seam (the swap point)
    tenant.ts                      # membership -> active tenant_id resolver
  components/
    AuthGate.tsx                   # bare email/password login; renders app when authed
    MapShell.tsx                   # MapLibre (CONUS, OpenFreeMap) + deck.gl MapboxOverlay
    SiteList.tsx                   # tenant-scoped site fetch + count
  App.tsx                          # composition: SiteList behind AuthGate, over MapShell
  main.tsx                         # React root mount
```

## Scope note (Wave 1)

Wave 1 builds the foundation only. Geocoding, add-customer forms / import,
exclusivity-radius logic, saturation / H3 hex layers, and reference layers are
**later waves**. Later-wave schema fields (e.g. `site.geog`, `site.vertical`) exist
now as nullable columns to avoid migration churn, but no Wave-1 feature writes
`site` or `geocode_cache` rows — the app legitimately shows an empty site list.
