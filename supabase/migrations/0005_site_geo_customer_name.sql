-- 0005_site_geo_customer_name.sql
-- CG hover card: expose the owning customer's brand name on the site_geo view.
--
-- The map hover card (MapShell) shows the site name + restricted-area radius; it
-- now also shows the owning customer (brand) name + address. `address` already
-- lives on the view (0003); this migration APPENDS `customer_name` (the brand)
-- from the joined `customer` so the map/list read shape carries it.
--
-- This migration REUSES (never redefines) the 0003 view posture EXACTLY:
-- security_invoker = true (the entire cross-tenant isolation mechanism, ADR-002 —
-- do NOT drop it) and the `join customer c on c.id = s.customer_id`. It keeps the
-- CURRENT column list in its existing order and appends `c.name as customer_name`
-- at the END — Postgres `create or replace view` permits ADDING columns only at
-- the tail, never reordering/renaming existing ones. Existing readers
-- (sitePinsLayer, siteZonesLayer, SitesView, CustomerList) `select('*')` and are
-- additive-safe: a new trailing column never breaks a destructure or an existing
-- `select`. No RLS/grant change is needed — a view inherits; nothing here drops a
-- grant.
--
-- Forward-only, additive, zero-downtime. Reversible via `create or replace view`
-- re-selecting only the 0003 columns (dropping a trailing column, unlike adding
-- one, requires drop+recreate — the 0003 revert block documents that shape):
--   create or replace view site_geo with (security_invoker = true) as
--     select id, customer_id, name, address,
--            ST_Y(geog::geometry) as lat, ST_X(geog::geometry) as lng,
--            exclusivity_radius_mi, is_zone_on, c.vertical
--     from site s join customer c on c.id = s.customer_id;
--   -- NOTE: create-or-replace cannot DROP a column; a true revert is:
--   --   drop view if exists site_geo; create view site_geo ... (0003 shape).

-- ---------------------------------------------------------------------------
-- site_geo: recreate keeping the 0003 column order (security_invoker PRESERVED)
-- then APPEND c.name as customer_name at the END. The brand name lives on the
-- joined customer (like `vertical`), so it comes from `c`, not `s`.
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
    c.vertical,
    c.name as customer_name
  from site s
  join customer c on c.id = s.customer_id;
