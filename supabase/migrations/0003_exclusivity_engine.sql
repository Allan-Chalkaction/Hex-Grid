-- 0003_exclusivity_engine.sql
-- Wave 3: per-site exclusivity zones + within-vertical conflict detection.
--
-- Promotes `vertical` to a real `customer.vertical` column (the conflict key),
-- extends the `site_geo` view with the zone-render fields, and adds two
-- security-invoker conflict-detection RPCs (`conflicts_at` primitive +
-- `site_conflicts` wrapper) that PURE-REPORT — the UI owns block-vs-warn policy.
--
-- This migration REUSES (never redefines) 0001's auth_tenant_ids() helper,
-- geocode_cache table, and site_geog_gist index, and the 0001/0002 RLS posture.
-- It adds NO new table RLS policy: the existing site/customer policies scope the
-- RPC reads via `security invoker`. See ADR-003 (the wave's spec) + ADR-001/002.
--
-- exclusivity_radius_mi already physically exists (0001:38) — it is NOT added
-- here. site.vertical (0001:37) is superseded by customer.vertical and left
-- untouched this wave (documented debt; a later chore may drop it).
--
-- Build order is BINDING (mirrors 0001/0002's dependency-ordered discipline):
--   1. customer.vertical column (+ supporting index)
--   2. idempotent backfill from attributes->>'vertical'
--   3. create or replace view site_geo (needs the column)   [security_invoker]
--   4. conflicts_at + site_conflicts RPCs (need the view/columns) [security_invoker]
--   5. ACL grants (revoke public/anon, grant authenticated)
--
-- Forward-only, all additive/nullable, zero-downtime. Reversible in REVERSE
-- dependency order:
--   drop function if exists site_conflicts(uuid);
--   drop function if exists conflicts_at(geography, numeric, text, uuid);
--   drop view if exists site_geo;                  -- NOT `create or replace`:
--   create view site_geo with (security_invoker = true) as  -- Postgres cannot
--     select id, customer_id, name, address,       -- DROP columns via CREATE OR
--            ST_Y(geog::geometry) as lat,           -- REPLACE VIEW, so the
--            ST_X(geog::geometry) as lng            -- revert drops + recreates
--     from site;                                    -- the ADR-002 shape.
--   alter table customer drop column vertical;
--   -- MR-001 DATA-LOSS CAVEAT: dropping customer.vertical is irreversible — any
--   -- picker-set vertical NOT mirrored in attributes->>'vertical' is lost (the
--   -- backfill seeded FROM attributes, it does not write BACK). Snapshot before
--   -- reverting if those values matter.

-- ---------------------------------------------------------------------------
-- 1. customer.vertical: a typed, nullable column promoted out of the jsonb
--    attributes. This is the conflict KEY (two customers "share a vertical"
--    iff their non-null vertical strings are equal). A typed column over
--    attributes->>'vertical' is indexable, type-stable, and a single source of
--    truth (ADR-003 Decision 1). site.vertical (0001:37) is NOT used here.
-- ---------------------------------------------------------------------------
alter table customer add column vertical text;

-- Supports the same-vertical join filter in the conflict RPC (tenant scoping is
-- the hottest filter; vertical narrows within it). ADR-003 Performance.
create index customer_tenant_vertical_idx on customer (tenant_id, vertical);

-- ---------------------------------------------------------------------------
-- 2. Idempotent backfill: seed customer.vertical from the W2 free-text
--    attributes.vertical where present and the column is still null, so:
--      * re-running this migration never clobbers a manually-set value, and
--      * a customer with no attributes.vertical stays null (AC-002).
-- ---------------------------------------------------------------------------
update customer
  set vertical = attributes->>'vertical'
  where vertical is null
    and attributes ? 'vertical';

-- ---------------------------------------------------------------------------
-- 3. site_geo: recreate (security_invoker PRESERVED — the entire cross-tenant
--    isolation mechanism, ADR-002; do NOT drop it) keeping the W2 column order
--    then APPENDING the three zone-render fields. The vertical comes from the
--    joined customer (the conflict key lives on customer, not site). Existing
--    readers (sitePinsLayer) are additive-safe (AC-003).
-- ---------------------------------------------------------------------------
create or replace view site_geo with (security_invoker = true) as
  select
    s.id,
    s.customer_id,
    s.name,
    s.address,
    ST_Y(s.geog::geometry) as lat,
    ST_X(s.geog::geometry) as lng,
    s.exclusivity_radius_mi,
    s.is_zone_on,
    c.vertical
  from site s
  join customer c on c.id = s.customer_id;

-- ---------------------------------------------------------------------------
-- 4. conflicts_at: the prospective-point primitive (add + move preview).
--    `security invoker` so the candidate site/customer scan runs under the
--    CALLER's RLS and can only ever see the caller's tenant (a `security
--    definer` slip would leak cross-tenant — forbidden). Pinned search_path.
--    PURE-REPORTS: it never blocks an insert; the UI decides block-vs-warn.
--
--    Predicate (ADR-003 Decision 2/3): same non-null vertical both sides,
--    exclude self, bidirectional point-in-zone via ST_DWithin with the
--    GREATEST(effA, effB) threshold in METERS (1 mi = 1609.344 m), and
--    GREATEST(...) > 0 so two off zones never conflict. Effective radius folds
--    in is_zone_on: case when is_zone_on then coalesce(radius,0) else 0 end.
-- ---------------------------------------------------------------------------
create or replace function conflicts_at(
  p_geog       geography,   -- prospective point (EWKT 'SRID=4326;POINT(lng lat)' casts in)
  p_radius_mi  numeric,     -- prospective site's radius (null/0 = off)
  p_vertical   text,        -- prospective customer's vertical
  p_exclude_id uuid         -- self, on a move/edit; null on add
)
  returns table (
    site_id       uuid,
    site_name     text,
    customer_id   uuid,
    customer_name text,
    distance_mi   numeric,
    radius_mi     numeric
  )
  language sql
  stable
  security invoker
  set search_path = public, pg_temp
as $$
  select s.id, s.name, s.customer_id, c.name,
         (ST_Distance(s.geog, p_geog) / 1609.344)::numeric,
         s.exclusivity_radius_mi
  from site s
  join customer c on c.id = s.customer_id
  where s.geog is not null
    and (p_exclude_id is null or s.id <> p_exclude_id)
    and p_vertical is not null
    and c.vertical is not null
    and c.vertical = p_vertical
    and ST_DWithin(
          s.geog, p_geog,
          greatest(
            case when s.is_zone_on then coalesce(s.exclusivity_radius_mi, 0) else 0 end,
            coalesce(p_radius_mi, 0)
          ) * 1609.344)
    and greatest(
          case when s.is_zone_on then coalesce(s.exclusivity_radius_mi, 0) else 0 end,
          coalesce(p_radius_mi, 0)) > 0;
$$;

-- ---------------------------------------------------------------------------
-- 4b. site_conflicts: convenience wrapper for an ALREADY-PERSISTED site (list /
--     move surfaces). Reports conflicts for the site by cross-join-lateral over
--     conflicts_at with the site's own geog / effective-radius / vertical,
--     excluding self. Same security invoker + pinned search_path (AC-005).
-- ---------------------------------------------------------------------------
create or replace function site_conflicts(p_site_id uuid)
  returns table (
    site_id       uuid,
    site_name     text,
    customer_id   uuid,
    customer_name text,
    distance_mi   numeric,
    radius_mi     numeric
  )
  language sql
  stable
  security invoker
  set search_path = public, pg_temp
as $$
  select cf.*
  from site s
  join customer c on c.id = s.customer_id
  cross join lateral conflicts_at(
    s.geog,
    case when s.is_zone_on then s.exclusivity_radius_mi else 0 end,
    c.vertical,
    s.id) cf
  where s.id = p_site_id;
$$;

-- ---------------------------------------------------------------------------
-- 5. ACL grants: tighten the runtime grantee set to authenticated only,
--    mirroring place_site / auth_tenant_ids() in 0001/0002 EXACTLY (Supabase's
--    default ACL auto-grants EXECUTE on new public functions to anon +
--    authenticated; we revoke from public + anon, grant to authenticated). No
--    anon policy is added; unauthenticated callers are denied by construction
--    (the W1 posture). AC-006/AC-012.
-- ---------------------------------------------------------------------------
revoke all     on function conflicts_at(geography, numeric, text, uuid) from public;
revoke execute on function conflicts_at(geography, numeric, text, uuid) from anon;
grant  execute on function conflicts_at(geography, numeric, text, uuid) to authenticated;

revoke all     on function site_conflicts(uuid) from public;
revoke execute on function site_conflicts(uuid) from anon;
grant  execute on function site_conflicts(uuid) to authenticated;
