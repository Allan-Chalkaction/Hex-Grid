# Feature Spec: Hex-Grid Multi-Tenant Foundation (Wave 1)

**Status:** Draft
**Author:** AI-assisted (pm-spec agent)
**Date:** 2026-06-26
**Slug:** hex-grid-foundation

## Summary

Wave 1 builds the foundation for a multi-tenant, map-based sales-territory / exclusivity system on a greenfield repo: a Vite/React/TS frontend over a Supabase (Postgres + PostGIS + RLS + Auth) backend, with every data path tenant-scoped via per-table RLS keyed off a `membership` join table (the pluggable-auth seam). It delivers a working shell — the app loads, the basemap renders with a deck.gl overlay mounted, and an authenticated user reads tenant-scoped (empty) site rows end-to-end. No later-wave behavior (geocoding, exclusivity, saturation, reference layers) is built; later-wave schema fields exist now (nullable) to avoid migration churn.

## User Stories

- As an **operator (dev user)**, I want to `supabase start`, apply migrations + seed, and `npm run dev`, so that I have a working tenant-scoped app on first run.
- As an **authenticated tenant member**, I want to sign in and see a CONUS map with a count of my tenant's sites, so that the RLS-scoped read path is proven end-to-end (even with an empty list).
- As a **tenant member**, I want my data isolated so that I can never see another tenant's rows, even via the raw PostgREST API.
- As an **unauthenticated visitor**, I want all tenant data denied, so that nothing leaks without a session.
- As the **future parent-app integrator**, I want identity isolated behind a `membership → tenant` seam, so that the parent app's auth can be swapped in later without touching any table policy.
- As a **reviewer (db-migration-reviewer / security-auditor)**, I want the per-table RLS policies and the non-recursive `membership` policy to be explicit and testable, so that the multi-tenant isolation surface is verified, not assumed.

## Acceptance Criteria

ACs use a two-part structure: **Substantive** (what the user/system must experience) + **Verification** (the literal command/procedure proving it). Numbering is universal and stable (AC-NNN).

- [ ] **AC-001.** Substantive: a clean `supabase start` brings up local Postgres + PostGIS + Auth and `supabase/migrations/` applies with zero errors. Verification: from a clean state run `supabase start` then `supabase db reset` (applies migrations + seed); both exit 0 with no migration error in output. PostGIS availability: `supabase db reset` output (or `select postgis_version()` via `supabase db execute`) reports a PostGIS version.

- [ ] **AC-002.** Substantive: the schema matches the locked data model — `postgis` enabled; `tenant` / `membership` / `site` / `geocode_cache` tables exist; `site.geog` is `geography(Point,4326)`; `site.attributes` is `jsonb not null default '{}'`; a `GIST(geog)` index on `site` is present; `geocode_cache` has NO `tenant_id` column. Verification: query `information_schema`/`pg_catalog` (e.g. `\d+ site`, `select indexdef from pg_indexes where tablename='site'`, `select udt_name from information_schema.columns where table_name='site' and column_name in ('geog','attributes')`); confirm `geography`/`jsonb`, the `site_geog_gist` index, and absence of `geocode_cache.tenant_id`.

- [ ] **AC-003.** Substantive: RLS is enabled on `tenant`, `membership`, `site`; an authenticated user of tenant A sees ONLY tenant-A rows and ZERO tenant-B rows across all three tables; the `membership` policy is non-recursive (selecting `membership` as an authed user does not error with infinite recursion); `geocode_cache` is shared-read/insert for ANY authenticated user (intentionally not tenant-isolated); unauthenticated (anon) access to the three tenant-scoped tables returns nothing / is denied. Verification: seed two tenants + two users; as user A (via a session JWT through PostgREST or `set role` + `request.jwt.claims`), `select * from site/tenant/membership` returns only A's rows and zero B rows; `select * from membership` as A does not raise `infinite recursion detected in policy`; an anon PostgREST request to those tables returns `[]` / 401-403; an authed user reads + inserts a `geocode_cache` row regardless of tenant. db-migration-reviewer + security-auditor confirm the per-table policy SQL and the `SECURITY DEFINER` `search_path` pin. Exclusions: N/A (single-repo runtime test).

- [ ] **AC-004.** Substantive: the frontend builds and renders the OpenFreeMap CONUS basemap with a deck.gl overlay (`MapboxOverlay` interop) mounted carrying one empty placeholder layer, with no console errors. Verification: `npm run build` (i.e. `vite build`) exits 0; loading the dev app shows the basemap centered on CONUS (`[-98.5795, 39.8283]`, zoom ~4) with the deck.gl overlay attached and the browser console free of errors. (UI-render aspects may be confirmed by ui-review.)

- [ ] **AC-005.** Substantive: an authenticated dev user fetches tenant-scoped sites (empty in W1) via `supabase-js` and the path is real end-to-end; an unauthenticated client is blocked by RLS (empty / denied). Verification: signed-in, `supabase.from('site').select('*')` resolves to `[]` (no error) and the UI shows a count of 0; signed-out, the same fetch returns `[]` / a denial — the read path is exercised, not stubbed. Wire-to-consumer: the `SiteList` component's mount actually calls the fetch — `git grep -n "from('site')" src/` shows the call site inside `SiteList.tsx` AND the component is rendered by `App.tsx` behind the `AuthGate`.

- [ ] **AC-006.** Substantive: the seed creates one dev tenant + one dev `membership` binding a dev `auth.users` id, so the app has a working tenant context on first run (no empty-tenant state). Verification: after `supabase db reset`, `select count(*) from tenant` ≥ 1 and `select count(*) from membership` ≥ 1 with `membership.tenant_id` matching the seeded tenant; the README documents the create-dev-user-first step (Studio/CLI) and the seed upserts membership against a fixed dev UUID; signing in as the dev user yields a resolved active `tenant_id` in the app.

- [ ] **AC-007.** Substantive: the auth seam is isolated and documented — identity flows through one thin module, tenant resolution is a separate `membership → active tenant_id` step, and table policies key off `membership` (not the identity source) so the parent app's auth can be swapped without touching any policy. Verification: `src/lib/auth.ts` exposes session/signIn/signOut/onAuthStateChange and `src/lib/tenant.ts` resolves the active tenant from membership; the README has an "Auth seam" section stating the swap point is `auth.ts`/the identity source and that RLS policies never change because they key off `membership`. Wire-to-consumer: `git grep -n "onAuthStateChange\|getSession" src/` shows `AuthGate.tsx` (or `App.tsx`) consuming `auth.ts`, not calling `supabase.auth` directly outside the seam module.

- [ ] **AC-008.** Substantive: a `README.md` quickstart stands the system up from clean — `supabase start`, apply migrations/seed (create dev user first), `npm install` + `npm run dev`. Verification: `README.md` contains an ordered quickstart covering (1) `supabase start`, (2) create dev auth user + `supabase db reset` (migrations + seed), (3) `.env` from `.env.example`, (4) `npm run dev`; following the steps from clean yields a running tenant-scoped app (the AC-001/004/005/006 happy path).

### Cross-cutting (apply to every ticket)

- [ ] **AC-009.** Substantive: no `anon`-role policy is added to `tenant` / `membership` / `site` (unauthenticated denial is by construction); the `SECURITY DEFINER` helper `auth_tenant_ids()` pins `search_path` and is granted only to `authenticated`. Verification: `git grep -niE "to anon|role.*anon" supabase/migrations/` returns no anon policy on the three tenant-scoped tables; the migration contains `set search_path = public, pg_temp`, `revoke all on function auth_tenant_ids() from public`, and `grant execute on function auth_tenant_ids() to authenticated`. Exclusions: comments documenting the deliberate-no-anon decision do NOT count as an anon policy.

- [ ] **AC-010.** Substantive: no secret (Supabase service-role key, anon key value, DB password) is committed; the client reads `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` from env. Verification: `git grep -niE "service_role|sb_secret|eyJ[A-Za-z0-9_-]{20,}" -- ':!*.example' ':!docs/'` returns no committed key; `.env.example` lists the var NAMES only (no values); `.env` is git-ignored. Exclusions: `.env.example` placeholders, docs describing variable names, and past-tense planning artifacts under `docs/` do NOT count as committed secrets.

## Scope

### In Scope (Phase 1 / Wave 1)

- Repo + tooling scaffold: Vite/React/TS, Supabase CLI init (`supabase/config.toml`), ESLint + Prettier, README skeleton, `.env.example`.
- Single raw-SQL migration `0001_init_postgis_schema.sql`: extension → tables → GIST index → `auth_tenant_ids()` helper → per-table RLS policies (in that order).
- `seed.sql`: one dev tenant + one dev membership (against a fixed dev UUID; README documents create-dev-user-first).
- Supabase auth wiring: bare login (email/password or magic link), the `auth.ts` seam, and `tenant.ts` tenant-context resolver.
- Map shell: MapLibre (CONUS, OpenFreeMap `liberty` style) + deck.gl `MapboxOverlay` with one empty placeholder layer.
- Tenant-scoped `site` fetch via `supabase-js` + trivial count/list beside the map.
- README quickstart + documented auth seam.

### Out of Scope (Future — Waves 2+)

- Geocoding (US Census Geocoder, provider interface, populating `geocode_cache` from real lookups).
- Add-customer forms, CSV / SQLite import.
- Exclusivity radius logic (`ST_DWithin` conflict detection), zone rendering.
- Saturation / H3 hex layers; reference layers (capitals / metros / ZIP / ZCTA); vertical filtering.
- Any UI that **writes** sites. (The `site` insert/update/delete RLS policies are authored now for table coherence, but no Wave-1 UI exercises them — Wave 2.)
- **Interim data note (Data Lifecycle):** `geocode_cache` is read/written by no Wave-1 feature; the table + shared policy exist now, populated by later waves. `site` rows are seeded as zero — the app legitimately shows an empty list in Wave 1.

### Files in scope

- `package.json` — *create*
- `tsconfig.json` — *create*
- `vite.config.ts` — *create*
- `index.html` — *create*
- `.env.example` — *create*
- `.gitignore` — *create*
- `.eslintrc.cjs` (or `eslint.config.js`) — *create*
- `.prettierrc` — *create*
- `README.md` — *create*
- `supabase/config.toml` — *create* (Supabase CLI init output)
- `supabase/migrations/0001_init_postgis_schema.sql` — *create*
- `supabase/seed.sql` — *create*
- `src/main.tsx` — *create*
- `src/App.tsx` — *create*
- `src/lib/supabaseClient.ts` — *create*
- `src/lib/auth.ts` — *create*
- `src/lib/tenant.ts` — *create*
- `src/components/AuthGate.tsx` — *create*
- `src/components/MapShell.tsx` — *create*
- `src/components/SiteList.tsx` — *create*

Implementer may add supporting files by convention (e.g. `src/vite-env.d.ts`, a global stylesheet, type modules) without amendment — these are additive atom-traceable additions. Exact lint/format config filename (`.eslintrc.cjs` vs flat `eslint.config.js`) is implementer's choice by current tooling convention.

## Technical Notes

### Existing Patterns to Reuse

Greenfield empty repo — no existing source to reuse. The binding patterns are dictated by the ADR (`docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md`) and the planner artifacts under `docs/step-5-pipeline/2026-06-24/0917-PLANNER-hex-grid-map/`. The canonical Supabase multi-tenant RLS pattern (`SECURITY DEFINER` `auth_tenant_ids()` wrapped in `in (select ...)`) is the reuse target.

### New Components Needed

- `supabaseClient.ts` — supabase-js client from `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`.
- `auth.ts` — identity seam (session/signIn/signOut/onAuthStateChange).
- `tenant.ts` — `membership → active tenant_id` resolver.
- `AuthGate.tsx` — bare login; renders app when authed.
- `MapShell.tsx` — MapLibre + deck.gl `MapboxOverlay` (empty layer).
- `SiteList.tsx` — tenant-scoped `site` fetch + count/list.
- `App.tsx` / `main.tsx` — composition.

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| `tenant` | new table | seed (dev tenant) | NEW — seeded via `seed.sql`; no in-app CRUD in W1 | in-scope (seed only) |
| `membership` | new table | seed (dev membership) | NEW — seeded via `seed.sql`; the pluggable-auth seam. Full management DEFERRED | in-scope (seed only) |
| `site` | new table | (none in W1) | DEFERRED — Wave 2 (add-customer form / import). W1 reads empty | deferred |
| `geocode_cache` | new table (shared, no tenant_id) | (none in W1) | DEFERRED — Wave 2 geocoding populates it | deferred |
| `auth.users` (dev user) | Supabase Auth | operator (Studio/CLI) | EXISTS — Supabase Auth UI / CLI; README documents create-first | exists (external) |

**Interim data strategy.** `site` and `geocode_cache` have no Wave-1 write path by design — the AC set explicitly proves the *empty* read path (AC-005). The dev `auth.users` row is created manually (Studio/CLI) per the README before `supabase db reset` seeds `membership` against a fixed dev UUID (FK ordering: `membership.user_id` → `auth.users`). This concrete create-first → seed-upsert path is the AC-006 working-tenant-context guarantee — not "the data will be there."

### Database Changes

- **Migration `0001_init_postgis_schema.sql`** (forward-only greenfield, idempotent-friendly): `create extension if not exists postgis`; tables `tenant`, `membership`, `site`, `geocode_cache` exactly per the ADR data model; `create index site_geog_gist on site using gist (geog)`; `create or replace function auth_tenant_ids()` (`language sql stable security definer set search_path = public, pg_temp`); `revoke all ... from public` + `grant execute ... to authenticated`; `enable row level security` on all four tables; per-table policies (order: helper before policies).
- **RLS policies (binding — per the ADR, do not collapse to one generic pattern):**
  - `membership`: `for select to authenticated using (user_id = auth.uid())` — MUST NOT subquery `membership`.
  - `tenant`: `for select to authenticated using (id in (select auth_tenant_ids()))` — `id`, not `tenant_id`.
  - `site`: select/insert/update/delete `to authenticated` using/with-check `tenant_id in (select auth_tenant_ids())`.
  - `geocode_cache`: select + insert `to authenticated using/with check (auth.uid() is not null)` — deliberately tenant-shared; NO `tenant_id`.
  - No `anon`-role policy on the three tenant-scoped tables (unauth denial by construction).
- **Data classification:** tenant data (`tenant`/`membership`/`site`) is tenant-private — isolated by RLS. `geocode_cache` (address → lat/lng) is deliberately non-tenant-private/public-derivable; shared across tenants. (No `docs/privacy/data-classification.md` exists in this greenfield repo; classification stated inline.)

### API / Edge Functions

None new beyond PostgREST/supabase-js. Data access is API-first through PostgREST — the client issues no raw SQL. No Edge Functions in Wave 1.

### Security Considerations

- **Multi-tenant isolation is the load-bearing security surface.** RLS enforced in the database (defense-in-depth — the client cannot bypass it via PostgREST). security-auditor + db-migration-reviewer are auto-routed at exactly this surface.
- **`SECURITY DEFINER` footgun:** `auth_tenant_ids()` MUST pin `set search_path = public, pg_temp` and be granted only to `authenticated` (revoke from public) — an unpinned search_path is a privilege-escalation vector.
- **Non-recursive `membership` policy:** the `membership` policy keys off `auth.uid()` directly, never subquerying `membership` (the helper is `SECURITY DEFINER` precisely so its lookup bypasses `membership` RLS).
- **No secrets committed:** anon key + URL come from env (`VITE_*`); `.env` git-ignored; `.env.example` holds variable names only. Never commit the service-role key.
- **Unauthenticated denial by construction:** RLS on + no anon policy → anon PostgREST requests denied (AC-003/AC-005). Reference: project `rules-security.md` (no hardcoded credentials, no `.env` commits).

### Accessibility Requirements

(WCAG 2.2 AA; no `docs/accessibility/wcag-checklist.md` in this greenfield repo — stated inline, scoped to the bare W1 surfaces.)

- **Login form (`AuthGate`):** every input has an associated `<label>` (programmatic name); email/password fields use correct `type` + `autocomplete`; the submit control is a real `<button>`; auth errors are announced (e.g. `role="alert"` / `aria-live`) and not conveyed by color alone.
- **Keyboard:** the login flow is fully keyboard-operable; visible focus indicators; logical tab order. The map is a known a11y-difficult surface — at minimum it is not a keyboard trap and the surrounding app chrome (login, site count/list) is keyboard-reachable.
- **Site count/list:** the count is real text (screen-reader readable), not icon-only.
- Full map-canvas a11y (keyboard pan/zoom alternatives) is acknowledged as a later concern; Wave 1 scopes a11y to the auth + list chrome.

## Open Questions / Assumptions

Non-blocking — assumptions recorded to proceed (no human in the loop under the engine).

- **Q: Email/password vs. magic link for the bare login?** Assumption: implementer's choice; either satisfies "real `auth.uid()`". Email/password is simplest for a local dev user. (AC-005/AC-006 unaffected.)
- **Q: How is the dev `auth.users` row created given the `membership` FK?** Assumption (from ADR): operator creates the dev user via Studio/CLI first; seed upserts `membership` against a fixed documented dev UUID. README documents this ordering. (AC-006.)
- **Q: Does AC-003's two-tenant isolation test ship as an automated test or a documented manual procedure?** Assumption: a runnable verification (SQL script or test) is preferred and db-migration-reviewer confirms; a documented psql procedure is the acceptable floor for W1. Either satisfies the substantive standard.
- **Q: Exact ESLint config format (legacy `.eslintrc.cjs` vs flat `eslint.config.js`)?** Assumption: implementer's choice by current tooling default; not load-bearing.
- **Q: deck.gl version / `MapboxOverlay` import path (`@deck.gl/mapbox`)?** Assumption: implementer pins a current compatible deck.gl + MapLibre + `@deck.gl/mapbox` set; the empty-layer overlay must mount without console errors (AC-004).

## ADR Alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-001 (Multi-Tenant Foundation — Supabase/PostGIS + Per-Table RLS + Pluggable-Auth Seam) | prompt + run folder `adr.md` | AC-001..AC-010 (whole spec); data model → AC-002; per-table RLS + `auth_tenant_ids()` → AC-003/AC-009; auth seam → AC-007; map shell → AC-004; site fetch → AC-005; seed/FK ordering → AC-006; quickstart → AC-008 | none | Spec is a faithful decomposition of ADR-001; the three RLS traps (non-recursive `membership`, `tenant.id`-keyed policy, tenant-shared `geocode_cache`) and the `SECURITY DEFINER` hardening are carried verbatim into ACs. |

## Dependencies

- **Supabase CLI** (`supabase start` → Docker Postgres/PostGIS/Auth) — local dev runtime.
- **Docker** — required by the Supabase CLI local stack.
- **npm packages:** `vite`, `react`, `react-dom`, `typescript`, `@supabase/supabase-js`, `maplibre-gl`, `deck.gl` (+ `@deck.gl/mapbox`), ESLint + Prettier toolchain.
- **OpenFreeMap** `liberty` style (`https://tiles.openfreemap.org/styles/liberty`, no API key) — external basemap tile source. MapTiler free tier noted as a keyed alternative in the README; do not block on a key.
- **No dependency on later waves** — Wave 1 is the foundation; Waves 2+ depend on it, not the reverse.
