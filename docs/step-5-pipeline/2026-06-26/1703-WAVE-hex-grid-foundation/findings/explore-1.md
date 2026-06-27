# Explore findings 1

_Persisted by the orchestrator from the workflow return._

Perfect. Now I have sufficient context to produce the validation report. Let me compile my findings:

---

## CODEBASE ASSUMPTIONS VALIDATION — Wave 1 Foundation

### Current State Summary

The repository is **greenfield (empty)** as of commit `23512e78` (2026-06-26). The following are **confirmed in place:**

#### Specifications & Architecture
- **Spec file:** `/Users/allanmittelstaedt/Desktop/Dev/hex-grid/docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/spec.md` (96 lines; full AC-001 through AC-010 defined)
- **ADR-001:** `/Users/allanmittelstaedt/Desktop/Dev/hex-grid/docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md` (locked SQL policies + data model + key patterns)
- **Planner artifacts:** Architecture brief (D1–D4 locked decisions, R1–R7 recommendations) + Build plan (6-wave decomposition) + Wave-1 spec summary
- **Locked design decisions:** Postgres+PostGIS (R2), exact-distance exclusivity (R1), pluggable auth seam (R4), API-first (R7), multi-tenant RLS (R3), H3 res 9 (R6), Census Geocoder (R5)

#### Project Infrastructure
- **Git scaffold:** `.gitignore` correctly configured (blocks `.env`, `node_modules/`, `supabase/.branches/.temp/`, Claude worktrees)
- **Rules files:** `rules-security.md`, `rules-implementation-discipline.md`, `rules-git.md` all in place with binding constraints:
  - NO hardcoded credentials (AC-010)
  - Multi-fix batch isolation (one agent invocation per fix)
  - Investigation-first debugging (full chain audits for DB issues)
  - Conventional Commits format (`type(scope): description`)
  - Branch naming (`feature/`, `fix/`, `chore/`, `docs/`, `refactor/`)
  - Wave→main merge via squash (ADR-071 Part 2), never `--force`, never auto-resolve conflicts
- **Wave-mode configuration:** `max_concurrency: 2` (standard v1 default)
- **Agent protocol:** `implementer-protocol.md` defines shared context-loading order, refusal protocol, dependency-version discipline, per-ticket commit attribution, cross-ticket scope-shift detection

#### Test/Verification Infrastructure
- **db-migration-reviewer:** Auto-routed to AC-003 (two-tenant RLS isolation verification, non-recursive membership policy, SECURITY DEFINER search_path)
- **security-auditor:** Auto-routed to AC-009/AC-010 (no anon policies, SECURITY DEFINER constraints, no committed secrets)
- **ui-review:** Can verify AC-004 map-render aspects

---

### Data Model Assumptions (AC-002)

The spec **locks the exact schema** (ADR-001 §3):

| Table | Columns (binding) | Indexes | Notes |
|-------|-------------------|---------|-------|
| `tenant` | `id` (uuid, PK), `name` (text), `created_at` (timestamptz) | — | Seeded with one dev tenant |
| `membership` | `user_id` (uuid FK → `auth.users`), `tenant_id` (uuid FK → `tenant`), `role` (text, default 'member'), PK(user_id, tenant_id) | — | Non-recursive policy only (`user_id = auth.uid()`) |
| `site` | `id`, `tenant_id`, `name`, `address`, **`geog` (geography(Point, 4326))**, `vertical`, `exclusivity_radius_mi`, `is_zone_on`, **`attributes` (jsonb, not null, default {})**, `created_at`, `updated_at` | `site_geog_gist` (GIST on geog) | RLS selects on `tenant_id in (select auth_tenant_ids())` |
| `geocode_cache` | `address_hash` (PK), `address`, `lat`, `lng`, `provider`, `created_at` | — | **NO `tenant_id`** (deliberately shared); RLS allows any authenticated read+insert |

**Critical constraint:** Implementer MUST NOT add `tenant_id` to `geocode_cache` (AC-002 explicit verification, ADR-001 §2 rationale).

---

### RLS Policy Assumptions (AC-003, AC-009)

**Three traps (locked in ADR-001, must be enforced per-table, not generically):**

1. **`membership` policy MUST NOT subquery `membership`** (infinite recursion trap) → use `user_id = auth.uid()` only
2. **`tenant` policy keys off `id` NOT `tenant_id`** → policy is `id in (select auth_tenant_ids())` not `tenant_id in (...)`
3. **`geocode_cache` has NO `tenant_id`** and deliberately shared → policy is `auth.uid() is not null` for both select and insert

**SECURITY DEFINER helper (binding):**
```sql
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
```

**No anon policies on `tenant`/`membership`/`site`** (unauthenticated denial by construction, AC-003/AC-005). Verification: `git grep -niE "to anon|role.*anon" supabase/migrations/` returns zero on these tables.

---

### Auth Seam Assumptions (AC-007)

Implementer MUST create a thin **pluggable identity layer** that isolates the parent app's auth swap point:

- **`src/lib/auth.ts`:** exposes `getSession()`, `signIn()`, `signOut()`, `onAuthStateChange()` only; **is the sole identity source for the app**
- **`src/lib/tenant.ts`:** separate `membership → active tenant_id` resolver (decouples identity from tenancy)
- **`src/components/AuthGate.tsx`:** wraps app; renders login form when unauthenticated, app content when authed
- **Wire-to-consumer:** `git grep -n "onAuthStateChange\|getSession" src/` must show only `AuthGate.tsx` (or `App.tsx`) consuming `auth.ts`; NO direct `supabase.auth` calls outside `auth.ts`

**README requirement (AC-008):** "Auth seam" section documents that swap point is `auth.ts`/the identity source; RLS policies never change because they key off `membership`.

---

### Frontend Assumptions (AC-004, AC-005)

**Tech stack (decision-locked in architecture-brief D1):**
- Vite + React + TypeScript
- MapLibre GL JS (CONUS `liberty` style, centered `[-98.5795, 39.8283]` zoom 4)
- deck.gl + `@deck.gl/mapbox` `MapboxOverlay` interop (empty placeholder layer)
- supabase-js (client auth + PostgREST)
- ESLint + Prettier

**Components (AC-004 + AC-005 bundle):**
- `MapShell.tsx`: MapLibre map + deck.gl overlay (must mount without console errors)
- `SiteList.tsx`: `supabase.from('site').select('*')` fetch + count display (empty in W1, real RLS-scoped path)

**Build verification (AC-004):** `npm run build` exits 0; `vite build` output contains no errors.

---

### Seed/Dev-User Assumptions (AC-006)

**FK ordering constraint:** `membership.user_id` FKs `auth.users`, so the dev user must exist **before** seed runs.

**Workflow (binding):**
1. Operator creates dev user via Supabase Studio Auth UI (or `supabase` CLI)
2. README documents the dev user's **fixed UUID** (e.g., `dev-user-uuid`)
3. `supabase/seed.sql` **upserts** `membership` against that fixed UUID (not creates, upsert handles re-runs)
4. After `supabase db reset`, `select count(*) from membership` ≥ 1; the membership row binds the dev user to the seeded dev tenant

**Verification (AC-006):** After `supabase db reset`, signing in as the dev user yields a resolved `active_tenant_id` in the app (not null, not empty).

---

### Migration Assumptions (AC-001)

**File:** `supabase/migrations/0001_init_postgis_schema.sql` (single raw-SQL file)

**Order (binding — must not reorder; policies reference helper):**
1. `create extension if not exists postgis;`
2. Tables: `tenant`, `membership`, `site`, `geocode_cache` (schema per ADR-001)
3. Index: `create index site_geog_gist on site using gist (geog);`
4. Helper: `create or replace function auth_tenant_ids()...` (SECURITY DEFINER + search_path pin)
5. RLS enable: `alter table tenant/membership/site/geocode_cache enable row level security;`
6. Policies: one per table, in dependency order (helper before policies referencing it)

**Verification (AC-001):** `supabase start` brings up Postgres+PostGIS+Auth; `supabase db reset` applies migration + seed with zero errors; `select postgis_version()` reports version.

---

### File Manifest (In-Scope Creation, AC Binding)

Implementer **must create** exactly these files per spec §Scope:

**Root/Config:**
- `package.json` (deps: vite, react, react-dom, typescript, @supabase/supabase-js, maplibre-gl, deck.gl, @deck.gl/mapbox, eslint, prettier)
- `tsconfig.json`
- `vite.config.ts`
- `index.html`
- `.env.example` (var NAMES only: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`)
- `.eslintrc.cjs` or `eslint.config.js` (implementer choice)
- `.prettierrc`
- `README.md` (quickstart + auth seam section, AC-008)
- `.gitignore` (already in place)

**Backend:**
- `supabase/config.toml` (Supabase CLI init output)
- `supabase/migrations/0001_init_postgis_schema.sql` (schema + RLS + helper)
- `supabase/seed.sql` (dev tenant + dev membership upsert)

**Frontend:**
- `src/main.tsx`
- `src/App.tsx`
- `src/lib/supabaseClient.ts`
- `src/lib/auth.ts` (identity seam)
- `src/lib/tenant.ts` (membership → tenant_id resolver)
- `src/components/AuthGate.tsx` (login gate)
- `src/components/MapShell.tsx` (MapLibre + deck.gl)
- `src/components/SiteList.tsx` (fetch + count)

**Additive by convention (no amendment needed):**
- `src/vite-env.d.ts` (Vite type globals)
- Global stylesheet, type modules, etc.

---

### Dependency/Tooling Patterns (Implementer Must Infer)

1. **No npm package version pins from training data** — implementer must query latest compatible versions at build time
2. **Pre-flight service dependencies** (shared protocol): if a ticket changes DB schema, confirm migrations apply locally before committing
3. **Per-ticket commits** with format `<TICKET-KEY>: <description>` (wave-implementer pattern, not individual atoms in W1 per spec structure)
4. **Typecheck after each file layer** (focused checks, not full build per change)
5. **Verify step at wave end** (typecheck + tests + lint + build) ONCE, per shared protocol

---

### Cross-Cutting Verification Points (AC-003, AC-009, AC-010)

1. **db-migration-reviewer findings due at merge:** per-table RLS policies explicitly checked against three traps; SECURITY DEFINER search_path pinned; two-tenant isolation tested (manual SQL or test script acceptable)
2. **security-auditor findings due at merge:** no anon policies on tenant-scoped tables confirmed via grep; no secrets in git history confirmed via grep
3. **Accessibility (AC-004 + form chrome):** login form has `<label>` for each input, email/password types correct, submit is `<button>`, errors announced; login fully keyboard-operable; map is not a keyboard trap; site count/list is real text

---

### Decision Outcomes (Spec §Open Questions)

Implementer has **freedom on:**
- Email/password vs. magic link (either satisfies AC-006; email/password simplest for local dev)
- ESLint config format (`.eslintrc.cjs` vs flat `eslint.config.js`)
- Specific deck.gl + MapLibre versions (must be compatible; empty-layer overlay must mount without errors)

Implementer **cannot choose:**
- Multi-tenant RLS per-table pattern (three tables, three policies, one helper; not generic)
- Auth seam location (`src/lib/auth.ts` + `tenant.ts`, not elsewhere)
- Migration file location/name (`supabase/migrations/0001_init_postgis_schema.sql`)
- Dev tenant + membership seeding (README documents create-user-first, seed upserts against fixed UUID)

---

### Data Lifecycle (W1 Interim Strategy)

- **`site`:** zero rows in W1 (AC-005 proves empty read path); write paths (insert/update/delete) are seeded now for table coherence but NOT exercised in W1 UI (Wave 2)
- **`geocode_cache`:** zero rows in W1; no W1 feature populates it (Wave 2 geocoding does)
- **`tenant` + `membership`:** seeded once at dev setup; no W1 UI CRUD (full management deferred)
- **`auth.users`:** operator-created dev user (outside DB, in Supabase Auth); seed binds to `membership`

---

### File Path Conventions & Imports (Inferred from Spec)

Based on spec structure and ADR patterns:
- **Library modules:** `src/lib/*.ts` (auth seam, tenant resolver, client)
- **Components:** `src/components/*.tsx` (gates, map shell, data components)
- **Config imports:** env vars via `import.meta.env.VITE_*` (Vite convention)
- **Supabase client:** single instance in `src/lib/supabaseClient.ts`, imported by `auth.ts` and components

No existing `src/` codebase to reuse (greenfield); implementer establishes conventions for W1 and future waves.

---

### Summary: Implementer Binding Checklist

**Do not modify these locked decisions:**
- Data model (exact schema per ADR-001)
- Three RLS trap mitigations (per-table policies, non-recursive membership, no tenant_id on geocode_cache)
- Auth seam location and shape (src/lib/auth.ts + tenant.ts)
- Migration order (extension → tables → index → helper → policies)
- Seed FK ordering (dev user first, upsert membership against fixed UUID)
- No anon policies on tenant-scoped tables

**Do establish conventions for wave consistency:**
- Import paths (all supabase-js calls go through supabaseClient)
- Error handling (consistent error surfacing in AuthGate + SiteList)
- Type organization (infer from component needs; namespace auth types under `Auth.*`, tenant under `Tenant.*`)
- Build config (ESLint + Prettier rules; no strict formatting conflicts with spec)

**Verification must include:**
- Database: `supabase start` + `supabase db reset` both exit 0; `select postgis_version()` succeeds
- Schema: `\d+ site` shows geography + jsonb + index; no `geocode_cache.tenant_id`; GIST index present
- RLS: two-tenant isolation test (optional but preferred) or documented manual procedure
- Frontend: `npm run build` succeeds; dev app loads map + overlay; console free of errors
- Auth: signed-in user fetches tenant-scoped sites (empty []); signed-out blocked; onAuthStateChange wired to AuthGate

---

All AC-001 through AC-010 are substantive (user/system experience), not aspirational. Each has a concrete verification step. The implementer's job is to build the exact shape the spec + ADR lock, then surface any observed scope conflicts to the orchestrator.
