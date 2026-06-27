-- 0001_init_postgis_schema.sql
-- Multi-tenant foundation: PostGIS + per-table RLS keyed off a `membership` seam.
-- Build order is BINDING: extension -> tables -> GIST index -> auth_tenant_ids() helper
-- -> per-table RLS policies. The helper MUST precede the policies that reference it.
-- See ADR-001 (docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md).

-- ---------------------------------------------------------------------------
-- 1. Extension
-- ---------------------------------------------------------------------------
create extension if not exists postgis;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
create table tenant (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

-- membership is the swappable identity seam: it binds an auth.users id to a tenant.
-- RLS policies key off THIS table, not the identity source, so the parent app's auth
-- can later be swapped without touching a single table policy.
create table membership (
  user_id   uuid not null references auth.users (id) on delete cascade,
  tenant_id uuid not null references tenant (id) on delete cascade,
  role      text not null default 'member',
  primary key (user_id, tenant_id)
);

create table site (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references tenant (id) on delete cascade,
  name                  text not null,
  address               text,
  geog                  geography(Point, 4326),  -- nullable in W1, populated W2/W3
  vertical              text,                     -- nullable in W1 (later-wave field)
  exclusivity_radius_mi numeric,                  -- nullable in W1 (later-wave field)
  is_zone_on            boolean not null default true,
  attributes            jsonb not null default '{}'::jsonb,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- Spatial index present now (no cost in W1) so Waves 3-4 spatial queries avoid a
-- later migration.
create index site_geog_gist on site using gist (geog);

-- geocode_cache is DELIBERATELY tenant-shared: address -> lat/lng is public,
-- deterministic, and non-tenant-private. It has NO tenant_id column by design.
-- Reviewers MUST NOT "fix" this into tenant isolation (ADR-001).
create table geocode_cache (
  address_hash text primary key,
  address      text not null,
  lat          double precision,
  lng          double precision,
  provider     text,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Recursion-safe tenant lookup (the linchpin)
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER => the body bypasses RLS on `membership`, which is precisely
-- what prevents a policy-evaluating-a-policy recursion. The search_path is pinned
-- (a SECURITY DEFINER function with an unpinned search_path is a privilege-
-- escalation vector) and execute is granted ONLY to authenticated.
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
-- Supabase ships a default ACL (pg_default_acl) that auto-grants EXECUTE on every
-- new public function to the unauthenticated, authenticated, and service roles.
-- `revoke ... from public` does NOT remove those role-specific default grants, so
-- we additionally revoke EXECUTE from the unauthenticated role to keep the runtime
-- grantee set to authenticated only (AC-009 "granted only to authenticated"). This
-- strengthens — does not contradict — the ADR's "grant tightly" intent. (Harmless
-- even if left: the body keys off auth.uid(), which is NULL when unauthenticated,
-- so such a call returns zero rows.)
revoke execute on function auth_tenant_ids() from anon;
grant execute on function auth_tenant_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Enable RLS on all four tables
-- ---------------------------------------------------------------------------
alter table tenant        enable row level security;
alter table membership    enable row level security;
alter table site          enable row level security;
alter table geocode_cache enable row level security;

-- ---------------------------------------------------------------------------
-- 5. Per-table RLS policies
-- ---------------------------------------------------------------------------
-- NOTE: these are intentionally per-table, NOT one generic pattern. Three traps
-- make a single generic policy actively wrong here:
--   (1) membership must key off auth.uid() directly and MUST NOT subquery
--       membership (infinite-recursion trap).
--   (2) tenant's key is `id`, not `tenant_id`, so its policy is `id in (...)`.
--   (3) geocode_cache has no tenant_id and is deliberately shared.
--
-- DELIBERATE-NO-ANON: there is NO anon-role policy on tenant/membership/site.
-- With RLS enabled and no anon policy, unauthenticated PostgREST requests return
-- zero rows / are denied by construction (the desired AC-003/AC-005 behavior).

-- membership: a user sees ONLY their own rows. Keys off auth.uid() directly;
-- MUST NOT subquery membership (recursion trap).
create policy membership_self_select on membership
  for select to authenticated
  using (user_id = auth.uid());

-- tenant: keyed on `id` (NOT tenant_id) — a user sees tenants they belong to.
create policy tenant_member_select on tenant
  for select to authenticated
  using (id in (select auth_tenant_ids()));

-- site: generic tenant-scoped pattern. SELECT exercised in W1; the write policies
-- are authored now for table coherence but no W1 UI exercises them (Wave 2 CRUD).
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

-- geocode_cache: DELIBERATELY tenant-shared. Read + insert by ANY authenticated
-- user, regardless of tenant. No tenant_id column, no per-tenant scoping.
create policy geocode_cache_read on geocode_cache
  for select to authenticated
  using (auth.uid() is not null);

create policy geocode_cache_insert on geocode_cache
  for insert to authenticated
  with check (auth.uid() is not null);
