-- tests/migrations/vertical-backfill.sql
-- Proves 0003's idempotent customer.vertical backfill (AC-002):
--   update customer set vertical = attributes->>'vertical'
--     where vertical is null and attributes ? 'vertical';
--
-- The backfill is a raw-SQL, migration-time statement using jsonb operators
-- (`attributes ? 'vertical'`, `attributes->>'vertical'`) that the application
-- test suite (npm test, supabase-js/PostgREST) cannot express or re-run — it
-- only fires once at migration time. So, like backfill-populated.sql, this runs
-- inside a SINGLE transaction that always ROLLS BACK, seeding the three input
-- shapes, running the EXACT 0003 backfill, and asserting:
--   (a) a customer with attributes.vertical and a null column   → backfilled,
--   (b) a customer with NO attributes.vertical                  → stays null,
--   (c) a customer with a MANUALLY-set vertical (≠ attributes)  → NOT clobbered,
--   (d) a second run changes ZERO rows (idempotent).
-- Nothing is persisted: the closing ROLLBACK leaves the real schema/data intact.
--
-- Run:
--   docker exec -i supabase_db_hex-grid psql -U postgres -v ON_ERROR_STOP=1 \
--     < tests/migrations/vertical-backfill.sql
-- A clean run prints the OK notices and ends with "ROLLBACK". Any failed
-- assertion raises an exception and (with ON_ERROR_STOP=1) exits non-zero.

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. A throwaway tenant + the three input shapes.
-- ---------------------------------------------------------------------------
insert into tenant (id, name)
  values ('00000000-0000-0000-0000-0000000000c3', 'Vertical Backfill Tenant')
  on conflict (id) do nothing;

-- (a) attributes.vertical present, column null → should be backfilled to 'gas'.
insert into customer (id, tenant_id, name, attributes, vertical) values
  ('00000000-0000-0000-0000-0000000000a1',
   '00000000-0000-0000-0000-0000000000c3', 'Has-Attr',
   '{"vertical":"gas"}'::jsonb, null);

-- (b) no attributes.vertical → should stay null.
insert into customer (id, tenant_id, name, attributes, vertical) values
  ('00000000-0000-0000-0000-0000000000a2',
   '00000000-0000-0000-0000-0000000000c3', 'No-Attr',
   '{"logo":"x"}'::jsonb, null);

-- (c) manually-set column with a DIFFERENT attributes.vertical → must NOT clobber.
insert into customer (id, tenant_id, name, attributes, vertical) values
  ('00000000-0000-0000-0000-0000000000a3',
   '00000000-0000-0000-0000-0000000000c3', 'Manual-Set',
   '{"vertical":"grocery"}'::jsonb, 'pharmacy');

-- ---------------------------------------------------------------------------
-- 2. Run the EXACT 0003 backfill statement.
-- ---------------------------------------------------------------------------
update customer
  set vertical = attributes->>'vertical'
  where vertical is null
    and attributes ? 'vertical';

-- ---------------------------------------------------------------------------
-- 3. Assertions (a)(b)(c).
-- ---------------------------------------------------------------------------
do $$
declare
  v_a text;
  v_b text;
  v_c text;
begin
  select vertical into v_a from customer where id = '00000000-0000-0000-0000-0000000000a1';
  select vertical into v_b from customer where id = '00000000-0000-0000-0000-0000000000a2';
  select vertical into v_c from customer where id = '00000000-0000-0000-0000-0000000000a3';

  if v_a is distinct from 'gas' then
    raise exception 'FAIL (a): attributes.vertical not backfilled (got %)', v_a;
  end if;
  if v_b is not null then
    raise exception 'FAIL (b): no-attribute customer did not stay null (got %)', v_b;
  end if;
  if v_c is distinct from 'pharmacy' then
    raise exception 'FAIL (c): manually-set vertical was clobbered (got %)', v_c;
  end if;

  raise notice 'OK (a): attributes.vertical backfilled to gas';
  raise notice 'OK (b): customer with no attributes.vertical stays null';
  raise notice 'OK (c): manually-set vertical not clobbered (pharmacy preserved)';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Idempotence (d): a second run changes ZERO rows.
-- ---------------------------------------------------------------------------
do $$
declare
  v_changed int;
begin
  with upd as (
    update customer
      set vertical = attributes->>'vertical'
      where vertical is null
        and attributes ? 'vertical'
      returning 1
  )
  select count(*) into v_changed from upd;
  if v_changed <> 0 then
    raise exception 'FAIL (d): backfill not idempotent (% rows changed on re-run)', v_changed;
  end if;
  raise notice 'OK (d): second backfill run changed 0 rows (idempotent)';
end $$;

-- ---------------------------------------------------------------------------
-- 5. Undo everything — this script never persists.
-- ---------------------------------------------------------------------------
rollback;
