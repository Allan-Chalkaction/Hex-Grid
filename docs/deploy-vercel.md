# Deploying hex-grid to Vercel

Vercel hosts the **static Vite frontend**. The backend is **Supabase** (Postgres/PostGIS
+ RLS + the `geocode` Edge Function), which must be a **hosted** project — the local
`supabase start` stack at `127.0.0.1:54321` is not reachable from Vercel. So deployment is
two halves: **frontend → Vercel** and **backend → hosted Supabase**.

`vercel.json` (repo root) already pins the build: framework `vite`, `npm run build` →
`dist`, with a SPA catch-all rewrite. Vercel also auto-detects most of this.

---

## 0. Prerequisites
- The repo is on GitHub (`Allan-Chalkaction/Hex-Grid`).
- Supabase CLI logged in: `supabase login`.
- Node 18+ (Vite 8 requirement). Vercel's default Node is fine; pin via a `"engines"`
  field in `package.json` or the Vercel project's Node setting if you want it explicit.

## 1. Create the hosted Supabase project
1. supabase.com → New project. Note the **Project URL** and the **anon (publishable) key**
   (Settings → API). Pick a strong DB password.
2. Confirm PostGIS is available (it is on Supabase) — migration `0001` enables it.

## 2. Push migrations to the prod DB
```bash
supabase link --project-ref <your-project-ref>
supabase db push          # applies 0001–0004 to the hosted DB
```
- A fresh prod DB is **empty**, so `0002`'s empty-table guard passes cleanly.
- (If you ever push `0002` onto a DB that already has `site` rows, the guard fires — see
  the W2 deferral; not a concern for a first deploy.)

## 3. Deploy the geocode Edge Function
```bash
supabase functions deploy geocode      # keyless US Census; cache-first
```
- `supabase/config.toml` already sets `[functions.geocode] verify_jwt = true` — the
  function rejects unauthenticated calls; authenticated users invoke it via the client.
- ⚠️ **AUTH-1 (verify before relying on geocoding in prod):** confirm a real
  authenticated user can actually invoke `geocode`. Locally we saw an ES256-user-token
  vs HS256-gateway mismatch (a local-stack artifact). On hosted Supabase the GoTrue
  signing + the function gateway are normally aligned, but smoke-test a signed-in user
  hitting the function before trusting it.

## 4. Create real auth users
The `dev@hex-grid.local / devpass123` user is **local-only** (seeded). For prod:
- Use Supabase Auth (email signup/invite via the dashboard or the app's login).
- Each user needs a `membership` row (`user_id → tenant_id`) — RLS keys all tenant
  isolation off `membership` via `auth_tenant_ids()`. Create a `tenant` + `membership`
  for your first user (SQL editor or a seed) or they'll see zero rows.

## 5. Import to Vercel + set env vars
1. Vercel → New Project → import the GitHub repo. It auto-detects **Vite**
   (`vercel.json` confirms build `npm run build`, output `dist`).
2. **Environment Variables** (Project Settings → Environment Variables) — these are
   inlined at **build time** by Vite, so they must be set before/at the build:

   | Var | Value | Required |
   |-----|-------|----------|
   | `VITE_SUPABASE_URL` | hosted project URL | **yes** |
   | `VITE_SUPABASE_ANON_KEY` | hosted anon/publishable key | **yes** |
   | `VITE_ZCTA_TILES_URL` | a ZCTA/USPS vector-tile URL (TileJSON or `pmtiles://`) | no (ZIP toggle stays disabled if unset) |
   | `VITE_ZCTA_SOURCE_LABEL` | e.g. `USPS ZIP` or `ZCTA approximation` | no |

   Without the two required vars the build succeeds but the app throws at load (the
   anon key is missing) — set them for **Production** (and Preview if you use it).
3. Deploy. Vercel rebuilds on every push to `main`.

## 6. ZIP/ZCTA overlay (optional)
The overlay degrades gracefully — the toggle ships **disabled** with a "configure a ZCTA
source" note until `VITE_ZCTA_TILES_URL` is set. To enable it, build + host a ZCTA5
vector tileset (Census TIGER → tippecanoe → a Range-capable bucket) per
`docs/zcta-tiles-setup.md`, then point the env var at it (source-layer named `zcta`).

---

## What this deploy does NOT include (deferred — W6 trigger: parent attach)
- The **real parent auth provider** + final API contract — the app ships the
  parent-agnostic provider seam (`src/lib/providers.ts` + `configureIdentity`); binding it
  to a parent app's identity is the deferred embed-harden work.
- See the run-folder `deferrals-log.md` files for the other logged follow-ups
  (perf `tenant_conflicts()` RPC, h3-js code-split, component-test harness).

## Quick reference
| | |
|---|---|
| Build command | `npm run build` (`tsc --noEmit && vite build`) |
| Output dir | `dist` |
| Framework | Vite |
| Backend | hosted Supabase (URL + anon key via env) |
| SPA routing | catch-all rewrite → `/index.html` (in `vercel.json`) |
