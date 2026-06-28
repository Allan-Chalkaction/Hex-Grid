-- tests/migrations/backfill-populated.sql
-- Proves 0002 section 3 (the expand-contract customer_id backfill) is correct on a
-- POPULATED site table — the production case that the old empty-table guard aborted on.
--
-- 0002 is unmerged and can only ever be APPLIED (never un-applied) against local dev,
-- so we cannot down-migrate to re-run it. Instead this script, inside a SINGLE
-- transaction that always ROLLS BACK, reconstructs the W1 state (a site table with NO
-- customer_id, carrying rows across >=2 tenants) and then runs the EXACT NEW section-3
-- DDL+backfill, asserting:
--   (a) every site ends up with a non-null customer_id,
--   (b) each site maps to its OWN tenant's 'Unassigned' placeholder (no cross-tenant leak),
--   (c) the placeholder insert is idempotent via the unique (tenant_id, name) key.
-- Nothing is persisted: the closing ROLLBACK leaves the real schema/data untouched.
--
-- Run:
--   docker exec -i supabase_db_hex-grid psql -U postgres -v ON_ERROR_STOP=1 \
--     < tests/migrations/backfill-populated.sql
-- A clean run prints the OK notices and ends with "ROLLBACK". Any failed assertion
-- raises an exception and (with ON_ERROR_STOP=1) exits non-zero.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. Reconstruct the W1 state: strip the W2 customer_id (and its dependents).
--    site_geo selects customer_id, so it must go first; the index + column follow.
--    (All transactional — undone by the final ROLLBACK.)
-- ---------------------------------------------------------------------------
drop view  if exists site_geo;
drop index if exists site_customer_id_idx;
alter table site drop column customer_id;

-- ---------------------------------------------------------------------------
-- 2. Seed >=2 tenants and several W1-style sites (no customer_id column exists now).
-- ---------------------------------------------------------------------------
insert into tenant (id, name) values
  ('00000000-0000-0000-0000-0000000000b1', 'Backfill Test Tenant B1'),
  ('00000000-0000-0000-0000-0000000000b2', 'Backfill Test Tenant B2')
on conflict (id) do nothing;

insert into site (tenant_id, name, address) values
  ('00000000-0000-0000-0000-0000000000b1', 'B1 Site Alpha', '1 First St'),
  ('00000000-0000-0000-0000-0000000000b1', 'B1 Site Beta',  '2 Second St'),
  ('00000000-0000-0000-0000-0000000000b1', 'B1 Site Gamma', '3 Third St'),
  ('00000000-0000-0000-0000-0000000000b2', 'B2 Site Delta', '4 Fourth St'),
  ('00000000-0000-0000-0000-0000000000b2', 'B2 Site Epsilon','5 Fifth St');

select count(*) as w1_sites_before_backfill from site;

-- ---------------------------------------------------------------------------
-- 3. Run the EXACT NEW section-3 expand-contract block from 0002.
-- ---------------------------------------------------------------------------
-- (a) EXPAND: nullable add.
alter table site
  add column customer_id uuid references customer (id) on delete cascade;

-- (b) BACKFILL: idempotent, tenant-scoped.
insert into customer (tenant_id, name)
  select distinct s.tenant_id, 'Unassigned'
  from site s
  where s.customer_id is null
  on conflict (tenant_id, name) do nothing;

update site s
  set customer_id = c.id
  from customer c
  where c.tenant_id = s.tenant_id
    and c.name = 'Unassigned'
    and s.customer_id is null;

-- (c) CONTRACT: enforce NOT NULL (this is the step that aborts if any row is unfilled).
alter table site
  alter column customer_id set not null;

create index site_customer_id_idx on site (customer_id);

-- ---------------------------------------------------------------------------
-- 4. Assertions.
-- ---------------------------------------------------------------------------
do $$
declare
  v_null_sites   int;
  v_mismapped    int;
  v_placeholders int;
begin
  -- (a) every site now has a non-null customer_id.
  select count(*) into v_null_sites from site where customer_id is null;
  if v_null_sites <> 0 then
    raise exception 'FAIL (a): % site(s) still have a null customer_id', v_null_sites;
  end if;

  -- (b) every site maps to ITS OWN tenant's 'Unassigned' placeholder (no cross-tenant leak).
  select count(*) into v_mismapped
  from site s
  join customer c on c.id = s.customer_id
  where c.tenant_id <> s.tenant_id or c.name <> 'Unassigned';
  if v_mismapped <> 0 then
    raise exception 'FAIL (b): % site(s) point at the wrong tenant / non-placeholder customer', v_mismapped;
  end if;

  -- one placeholder per tenant that had orphan sites (our two test tenants => 2).
  select count(*) into v_placeholders
  from customer
  where name = 'Unassigned'
    and tenant_id in ('00000000-0000-0000-0000-0000000000b1',
                      '00000000-0000-0000-0000-0000000000b2');
  if v_placeholders <> 2 then
    raise exception 'FAIL: expected 2 per-tenant placeholders, found %', v_placeholders;
  end if;

  raise notice 'OK (a): every site has a non-null customer_id';
  raise notice 'OK (b): every site maps to its own tenant''s Unassigned placeholder';
  raise notice 'OK: exactly 2 per-tenant Unassigned placeholders created';
end $$;

-- (c) idempotency: the placeholder insert, re-run for ALL tenants in site (ignoring the
--     null filter so it actually attempts the inserts), must add ZERO rows thanks to the
--     unique (tenant_id, name) ON CONFLICT key.
do $$
declare
  v_before int;
  v_after  int;
begin
  select count(*) into v_before from customer;
  insert into customer (tenant_id, name)
    select distinct tenant_id, 'Unassigned'
    from site
    on conflict (tenant_id, name) do nothing;
  select count(*) into v_after from customer;
  if v_before <> v_after then
    raise exception 'FAIL (c): placeholder insert is not idempotent (% -> % customers)', v_before, v_after;
  end if;
  raise notice 'OK (c): placeholder insert idempotent via unique(tenant_id,name) (count stable at %)', v_after;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Undo everything — this script never persists.
-- ---------------------------------------------------------------------------
rollback;
