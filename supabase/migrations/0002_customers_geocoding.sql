-- 0002_customers_geocoding.sql
-- Wave 2: customer (brand) owns 1->N site; per-site geocoding; client-side
-- API-first persistence through PostgREST (EWKT) or the place_site RPC.
--
-- Build order is BINDING (mirrors 0001's helper-before-policy discipline):
--   1. customer table  ->  2. customer RLS (4 per-table policies)
--   ->  3. site.customer_id (+ empty-site guard)  ->  4. site_geo view
--   ->  5. place_site RPC (default deterministic persistence path).
--
-- This migration REUSES 0001's auth_tenant_ids() helper and geocode_cache table
-- (it NEVER redefines them) and leaves the Wave-3 site radius column untouched
-- (Wave 3 owns the radius grain). See ADR-002 (the wave's spec) + ADR-001.
--
-- Forward-only. Reversible by (in reverse dependency order):
--   drop function if exists place_site(uuid, text, text, double precision, double precision);
--   drop view if exists site_geo;
--   alter table site drop column customer_id;
--   drop table customer;

-- ---------------------------------------------------------------------------
-- 1. customer table (the brand). Tenant-private business data.
-- ---------------------------------------------------------------------------
create table customer (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references tenant (id) on delete cascade,
  name       text not null,
  -- arbitrary brand attributes (logo, vertical, notes, ...); same jsonb
  -- convention as site.attributes in 0001.
  attributes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- the unique key enables PostgREST upsert onConflict=(tenant_id,name) used by
  -- the manual-add form and the CSV import (collapse duplicate brand names to
  -- one customer within a tenant).
  unique (tenant_id, name)
);

-- FK lookup index (tenant scoping is the hottest filter on this table).
create index customer_tenant_id_idx on customer (tenant_id);

-- ---------------------------------------------------------------------------
-- 2. RLS on customer: four per-table policies for `authenticated`, each keyed
--    `tenant_id in (select auth_tenant_ids())`, mirroring site_tenant_* in
--    0001 (0001:125-140) EXACTLY. No generic/shared policy, no anon policy.
--
-- DELIBERATE-NO-ANON: with RLS enabled and no anon policy, unauthenticated
-- PostgREST requests return zero rows / are denied by construction (the desired
-- AC-005 behavior). This mirrors site/tenant/membership in 0001.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3. site.customer_id: every site belongs to exactly one customer; deleting a
--    customer cascades its sites. NOT NULL is safe because site is empty
--    post-W1 (no production data, no backfill). The guard raises loudly if a
--    row ever existed so the NOT NULL add can never silently fail.
-- ---------------------------------------------------------------------------
do $$
begin
  if (select count(*) from site) <> 0 then
    raise exception 'site not empty: 0002 assumes an empty post-W1 site table (no backfill path defined for customer_id NOT NULL)';
  end if;
end;
$$;

alter table site
  add column customer_id uuid not null references customer (id) on delete cascade;

create index site_customer_id_idx on site (customer_id);

-- ---------------------------------------------------------------------------
-- 4. site_geo: read-only display view exposing lat/lng (derived from geog).
--    security_invoker = true is LOAD-BEARING: the view runs under the CALLER's
--    RLS, so it cannot leak cross-tenant. A plain (owner-run) view would bypass
--    the caller's RLS and expose every tenant's sites. No policy is defined on
--    the view itself — the underlying site policies do the scoping.
-- ---------------------------------------------------------------------------
create view site_geo with (security_invoker = true) as
  select
    id,
    customer_id,
    name,
    address,
    ST_Y(geog::geometry) as lat,
    ST_X(geog::geometry) as lng
  from site;

-- ---------------------------------------------------------------------------
-- 5. place_site RPC: the DEFAULT, deterministic persistence path (AC-021).
--    `security invoker` so it runs under the caller's RLS (the site insert is
--    checked against site_tenant_insert; the customer lookup is RLS-scoped, so
--    a caller can only place sites under a customer they can see).
--
--    The Edge Function geocodes ONLY; persistence stays client-side/API-first.
--    The client calls supabase.rpc('place_site', ...). A null lat/lng (failed
--    geocode) persists the site UN-geocoded (geog null) and flagged in the UI,
--    never silently dropped.
-- ---------------------------------------------------------------------------
create function place_site(
  p_customer_id uuid,
  p_name        text,
  p_address     text,
  p_lat         double precision,
  p_lng         double precision
)
  returns uuid
  language plpgsql
  security invoker
  set search_path = public, pg_temp
as $$
declare
  v_tenant_id uuid;
  v_site_id   uuid;
begin
  -- RLS-scoped: returns a row only if the caller can see this customer.
  select tenant_id into v_tenant_id from customer where id = p_customer_id;
  if v_tenant_id is null then
    raise exception 'customer % not found or not visible to caller', p_customer_id;
  end if;

  insert into site (tenant_id, customer_id, name, address, geog)
  values (
    v_tenant_id,
    p_customer_id,
    p_name,
    p_address,
    case
      when p_lat is null or p_lng is null then null
      else ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    end
  )
  returning id into v_site_id;

  return v_site_id;
end;
$$;

-- Tighten the runtime grantee set to authenticated only, mirroring the
-- auth_tenant_ids() treatment in 0001 (Supabase's default ACL auto-grants
-- EXECUTE on new public functions to the unauthenticated + authenticated roles,
-- which we revoke from the unauthenticated role below).
revoke all on function place_site(uuid, text, text, double precision, double precision) from public;
revoke execute on function place_site(uuid, text, text, double precision, double precision) from anon;
grant execute on function place_site(uuid, text, text, double precision, double precision) to authenticated;
