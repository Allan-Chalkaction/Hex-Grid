-- 0004_exclusivity_scope.sql
-- Wave 3 (EX-T7): configurable PER-CUSTOMER exclusivity scope (resolves CR-001).
--
-- The 0003 conflict predicate flagged a brand's OWN sibling sites as conflicts
-- (same customer ⇒ always same vertical ⇒ any sibling pair within max(radius)
-- surfaced as "Conflict"). The operator decision (CR-001 / ADR-003 amendment):
-- exclusivity scope is PER-CUSTOMER configurable, DEFAULT = competitor-only
-- (a brand does NOT conflict with its own sites). A per-customer `self_conflict`
-- toggle opts a customer into same-brand territory protection.
--
-- This migration REUSES (never redefines) the 0001/0002/0003 posture exactly:
-- security invoker, pinned search_path = public, pg_temp, grants revoke
-- public/anon + grant authenticated. It REPLACES the two conflict RPCs to fold
-- the per-customer flag into the predicate.
--
-- Build order is BINDING:
--   1. customer.self_conflict column (default false = competitor-only)
--   2. DROP the old 4-arg conflicts_at (we add a 5-arg overload — drop the old
--      so no dangling overload remains)
--   3. create conflicts_at (5-arg: + p_customer_id) [security_invoker]
--   4. create or replace site_conflicts → call the 5-arg conflicts_at, passing
--      the persisted site's own customer_id [security_invoker]
--   5. ACL grants (revoke public/anon, grant authenticated) on the new 5-arg
--
-- Additive, zero-downtime: the new column has a NOT NULL default so existing
-- rows get the competitor-only default with no table rewrite concern at this
-- scale. Forward-only. Reversible in REVERSE dependency order:
--   -- recreate the RPCs to the 0003 shape (4-arg conflicts_at, no self_conflict):
--   drop function if exists site_conflicts(uuid);
--   drop function if exists conflicts_at(geography, numeric, text, uuid, uuid);
--   create or replace function conflicts_at(
--     p_geog geography, p_radius_mi numeric, p_vertical text, p_exclude_id uuid)
--     returns table (...) language sql stable security invoker
--     set search_path = public, pg_temp as $$ <0003 4-arg body> $$;
--   create or replace function site_conflicts(p_site_id uuid)  -- 0003 body
--     ... cross join lateral conflicts_at(s.geog, ..., c.vertical, s.id) ...;
--   revoke all on function conflicts_at(geography, numeric, text, uuid) from public;
--   revoke execute on function conflicts_at(geography, numeric, text, uuid) from anon;
--   grant  execute on function conflicts_at(geography, numeric, text, uuid) to authenticated;
--   revoke all on function site_conflicts(uuid) from public; ... grant authenticated;
--   -- then drop the column LAST:
--   alter table customer drop column self_conflict;

-- ---------------------------------------------------------------------------
-- 1. customer.self_conflict: the per-customer scope toggle (CR-001 resolution).
--    DEFAULT false = competitor-only (a brand does NOT conflict with its own
--    sites). true = also protect this brand's own sites from each other. NOT
--    NULL with a default so existing rows get the competitor-only default.
-- ---------------------------------------------------------------------------
alter table customer add column self_conflict boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2. Drop the 0003 4-arg conflicts_at. We are replacing it with a 5-arg shape
--    (+ p_customer_id); dropping the old signature avoids leaving a dangling
--    4-arg overload that site_conflicts / the seam could accidentally resolve.
-- ---------------------------------------------------------------------------
drop function if exists conflicts_at(geography, numeric, text, uuid);

-- ---------------------------------------------------------------------------
-- 3. conflicts_at (5-arg): the prospective-point primitive, now SCOPE-AWARE.
--    Adds p_customer_id (the prospective customer's id). The predicate gains:
--      and (s.customer_id is distinct from p_customer_id or c.self_conflict)
--    so a SAME-customer pair conflicts ONLY when that customer's self_conflict
--    is true; a CROSS-customer same-vertical pair always conflicts. When
--    p_customer_id is null (brand-new-customer add) `is distinct from` is true
--    → behaves as cross-customer, which is correct: a brand-new customer has no
--    existing same-customer sites to suppress.
--    security invoker + pinned search_path PRESERVED (the 0003 posture).
-- ---------------------------------------------------------------------------
create or replace function conflicts_at(
  p_geog        geography,   -- prospective point (EWKT 'SRID=4326;POINT(lng lat)' casts in)
  p_radius_mi   numeric,     -- prospective site's radius (null/0 = off)
  p_vertical    text,        -- prospective customer's vertical
  p_exclude_id  uuid,        -- self, on a move/edit; null on add
  p_customer_id uuid         -- prospective customer's id; null on brand-new add
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
    -- CR-001: a same-customer pair conflicts ONLY when that customer opts in
    -- (self_conflict). Cross-customer same-vertical always conflicts.
    and (s.customer_id is distinct from p_customer_id or c.self_conflict)
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
-- 4. site_conflicts: UNCHANGED signature. Internally it already knows the
--    persisted site's customer_id — pass it as p_customer_id into the lateral
--    conflicts_at call so the same-customer suppression applies symmetrically
--    for a persisted site. The candidate join already exposes c.self_conflict
--    (read inside conflicts_at via its own join).
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
    s.id,
    s.customer_id) cf
  where s.id = p_site_id;
$$;

-- ---------------------------------------------------------------------------
-- 5. ACL grants on the NEW 5-arg conflicts_at: tighten to authenticated only,
--    mirroring 0003 EXACTLY. site_conflicts keeps its 0003 grants (signature
--    unchanged); re-asserting them is harmless and keeps the posture explicit.
-- ---------------------------------------------------------------------------
revoke all     on function conflicts_at(geography, numeric, text, uuid, uuid) from public;
revoke execute on function conflicts_at(geography, numeric, text, uuid, uuid) from anon;
grant  execute on function conflicts_at(geography, numeric, text, uuid, uuid) to authenticated;

revoke all     on function site_conflicts(uuid) from public;
revoke execute on function site_conflicts(uuid) from anon;
grant  execute on function site_conflicts(uuid) to authenticated;
