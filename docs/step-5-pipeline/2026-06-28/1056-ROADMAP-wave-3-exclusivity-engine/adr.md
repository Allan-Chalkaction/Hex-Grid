# ADR-003: Exclusivity Engine — Within-Vertical, Per-Site-Radius Conflict Detection via a security_invoker RPC; Circle-Zone Rendering

**Status:** Proposed
**Date:** 2026-06-28
**Feature:** exclusivity-engine (Wave 3)
**Spec:** docs/step-3-specs/hex-grid/waves/exclusivity-engine/exclusivity-engine.md
**Builds on:** ADR-001 (`docs/step-5-pipeline/2026-06-26/1703-WAVE-hex-grid-foundation/adr.md`), ADR-002 (`docs/step-5-pipeline/2026-06-27/1520-WAVE-customers-geocoding/adr.md`)

## Context

Wave 3 is the product's core value: per-site exclusivity zones drawn on the map, with same-vertical conflicts flagged on add/move. The substrate is already built and verified:

- `site.geog geography(Point,4326)` + `site_geog_gist` GIST index (0001:36,47) — reserved for exactly this wave, never yet exercised.
- `site.exclusivity_radius_mi numeric` (0001:38), `site.vertical text` (0001:37), `site.is_zone_on boolean default true` (0001:39) — all reserved nullable in W1.
- `customer` (brand) 1→N `site`, `site.customer_id NOT NULL`, the `security_invoker` `site_geo` view, the `place_site` security-invoker RPC, and the `Geocoder`-style swappable seam (ADR-002).
- The add/move write paths in `src/lib/customers.ts` (`createCustomerWithSites`/`placeSite`, `updateSiteLocation`, `updateSiteAddress`) and the reactive deck.gl seam in `MapShell.tsx`/`sitePinsLayer.ts`.

Operator-locked at kickoff (design AROUND these): conflict scope is **within-vertical** (two sites conflict only if their *customers* share a vertical); radius grain is **per-site** via `site.exclusivity_radius_mi`; picker values off/0.5/1/1.5/2/2.5/3 mi.

**Verification (requested):** `exclusivity_radius_mi` **physically exists** on `site` today — `0001_init_postgis_schema.sql:38`, `numeric`, nullable, untouched by 0002. So 0003 does **not** add it. `site.vertical` and `site.is_zone_on` also already exist (0001:37,39).

## Decision

Keep ADR-001/002 posture: API-first through PostgREST, tenancy enforced by per-table RLS via `auth_tenant_ids()`, spatial truth in the database. Add migration `0003` that (1) promotes **vertical to a real `customer.vertical` column** (the conflict key), (2) adds a **`security_invoker` conflict-detection RPC** that is pure-reporting, and (3) extends the `site_geo` view to carry the zone-render fields. The conflict semantic lives in exactly one place (the RPC predicate); the UI owns block-vs-warn policy; zones render as geodesically-accurate translucent circles.

### Decisions list (load-bearing)

1. **Vertical lives on a real `customer.vertical text` column** (promoted out of `customer.attributes`), NOT on the reserved `site.vertical` column and NOT in jsonb. Justification below.
2. **Conflict threshold = `max(A.radius, B.radius)`** (bidirectional point-in-zone), NOT `A.radius + B.radius` (zone-overlap). Justification below.
3. **Conflict detection = a `security_invoker` RPC** (`conflicts_at(...)` primitive + `site_conflicts(site_id)` wrapper), NOT a client PostgREST query and NOT a view.
4. **RPC is pure-reporting**; the UI decides block-vs-warn. **Recommended default UX = WARN-with-confirm** (non-blocking override).
5. **Zone render = `site_geo` extended** with `exclusivity_radius_mi`, effective-on flag, and `vertical`; circles via a deck.gl `ScatterplotLayer` in `radiusUnits:'meters'`. Hex fill deferred.
6. **Null/off semantics:** effective radius = `is_zone_on ? coalesce(radius,0) : 0`; a null/unequal vertical never conflicts; a zero-effective-radius site claims no territory but can still intrude a neighbor's.

### Decision 1 — Where vertical lives: `customer.vertical` column

The locked rule is phrased customer-keyed ("two sites conflict only if their **customers** share a vertical"). A vertical is a brand-level property: every site of a gas brand is gas. Storing it on `site` (the W1-reserved `site.vertical`) denormalizes a customer attribute onto its children — a customer's sites could silently disagree, and "customers share a vertical" would have no single source of truth. A typed nullable column (over `attributes->>'vertical'`) is indexable for the conflict join, type-stable, and follows ADR-002's instinct to promote a hot attribute out of jsonb. **The W1-reserved `site.vertical` column is superseded by this decision — leave it untouched this wave** (dropping a column is heavier and out of W3's radius-grain scope; flagged as debt below).

### Decision 2 — The conflict threshold: bidirectional `max(A.radius, B.radius)`

An exclusivity radius is the *protected territory a site claims to be free of same-vertical competitors*. A conflict exists when one site's location intrudes the **other's** claimed territory. `ST_DWithin(A.geog,B.geog,d)` is symmetric (it is `distance(A,B) <= d`), so "bidirectional" means choosing a symmetric `d`: A intrudes B's zone iff `dist <= B.radius`; B intrudes A's iff `dist <= A.radius`; either-or ⇒ `dist <= max(A.radius,B.radius)`.

`A.radius + B.radius` (zone-overlap) over-flags: two 0.5 mi zones 0.8 mi apart "overlap their buffers" (sum=1.0) yet neither site sits inside the other's exclusive 0.5 mi territory. That is a personal-space semantic, not an exclusive-territory one. `max()` also handles the off-radius case correctly: A off (0), B = 2 ⇒ `max=2` ⇒ A intruding B's 2 mi territory is flagged.

**Exact predicate** (miles→meters = `* 1609.344`; effective radius folds in `is_zone_on`):

```sql
-- effective radius (meters) for a row r:
--   case when r.is_zone_on then coalesce(r.exclusivity_radius_mi,0) else 0 end * 1609.344
-- A,B conflict iff:
--   a.customer.vertical is not null
--   AND b.customer.vertical is not null
--   AND a.customer.vertical = b.customer.vertical          -- within-vertical
--   AND a.geog is not null AND b.geog is not null
--   AND ST_DWithin(a.geog, b.geog, GREATEST(eff_a, eff_b)) -- meters, geodesic
--   AND GREATEST(eff_a, eff_b) > 0                          -- both-off => no conflict
```

### Decision 3 + 4 — Detection runs in a pure-reporting `security_invoker` RPC

A spatial self-join with a per-pair `GREATEST()` threshold and a cross-table vertical join is not expressible in plain PostgREST. The RPC encapsulates the predicate (single source of spatial truth), uses the GIST index, and — crucially — is **`security invoker`**, so the candidate `site`/`customer` scan runs under the caller's RLS and can only ever see the caller's tenant. (A `security definer` RPC here would bypass RLS and leak cross-tenant — forbidden, exactly as ADR-002 reasoned for `site_geo`/`place_site`.) The RPC **only reports**; it never blocks an insert. Block-vs-warn is UI policy (Decision 4) so it can vary and support overrides; coupling it into `place_site` would freeze policy into persistence.

```sql
-- 0003 — primitive: conflicts for a PROSPECTIVE point/vertical/radius (add + move preview).
-- security INVOKER: candidate rows scoped to caller tenant by site/customer RLS.
create or replace function conflicts_at(
  p_geog      geography,    -- prospective point (EWKT 'SRID=4326;POINT(lng lat)' casts in)
  p_radius_mi numeric,      -- prospective site's radius (null/0 = off)
  p_vertical  text,         -- prospective customer's vertical
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
    and p_vertical is not null and c.vertical is not null and c.vertical = p_vertical
    and ST_DWithin(
          s.geog, p_geog,
          greatest(
            case when s.is_zone_on then coalesce(s.exclusivity_radius_mi,0) else 0 end,
            coalesce(p_radius_mi,0)
          ) * 1609.344)
    and greatest(
          case when s.is_zone_on then coalesce(s.exclusivity_radius_mi,0) else 0 end,
          coalesce(p_radius_mi,0)) > 0;
$$;

-- convenience wrapper: conflicts for an ALREADY-PERSISTED site (list/move surfaces).
create or replace function site_conflicts(p_site_id uuid)
  returns table (
    site_id uuid, site_name text, customer_id uuid,
    customer_name text, distance_mi numeric, radius_mi numeric
  )
  language sql
  stable
  security invoker
  set search_path = public, pg_temp
as $$
  select cf.*
  from site s
  join customer c on c.id = s.customer_id
  cross join lateral conflicts_at(s.geog,
              case when s.is_zone_on then s.exclusivity_radius_mi else 0 end,
              c.vertical, s.id) cf
  where s.id = p_site_id;
$$;
```

### Access Control Policies

No new table policies — `site`/`customer` RLS (0001:125-140, 0002:53-68) already scope the RPC's reads via `security invoker`. Grants mirror `place_site`/`auth_tenant_ids()` exactly (Supabase default-ACL tightening):

```sql
revoke all     on function conflicts_at(geography, numeric, text, uuid) from public;
revoke execute on function conflicts_at(geography, numeric, text, uuid) from anon;
grant  execute on function conflicts_at(geography, numeric, text, uuid) to authenticated;
revoke all     on function site_conflicts(uuid) from public;
revoke execute on function site_conflicts(uuid) from anon;
grant  execute on function site_conflicts(uuid) to authenticated;
```

### Decision 5 — Zone-render data flow

```sql
-- 0003 — extend site_geo (security_invoker PRESERVED — load-bearing) with the
-- render fields. CREATE OR REPLACE keeps the W2 column order then appends.
create or replace view site_geo with (security_invoker = true) as
  select
    s.id, s.customer_id, s.name, s.address,
    ST_Y(s.geog::geometry) as lat,
    ST_X(s.geog::geometry) as lng,
    s.exclusivity_radius_mi,
    s.is_zone_on,
    c.vertical
  from site s
  join customer c on c.id = s.customer_id;
```

The client draws a circle per located site with an effective zone: center `(lng,lat)`, radius `exclusivity_radius_mi * 1609.344` meters, via a new deck.gl `ScatterplotLayer` (`radiusUnits:'meters'`, translucent fill + stroke, `getFillColor` keyed on conflict state). This mirrors the existing `sitePinsLayer.ts` pattern and adds a second layer to the `MapShell` overlay array. **Conflict state is pairwise/dynamic — NOT a view column.** The UI derives it from the conflicts RPC: on data change, color a zone "conflicting" if it appears in any conflict result (a single `site_conflicts` per recently-changed site for add/move, or an on-demand whole-tenant pass for full coloring).

**Render circles, not hexes, for the zone geometry.** `ST_DWithin` on `geography` is a geodesic circle, so a circle keeps viz == semantics. The "hex fill" branding is a visual style that can later ride an H3 `H3HexagonLayer` (needs an `h3-js` dep + site→cell binning) — **deferred**; W3 ships meter-accurate circles + conflict coloring.

### Key Patterns

- **Migration:** follow `0001`/`0002` literally — `security invoker`, pinned `search_path`, the revoke-anon/grant-authenticated ACL tightening, reuse (never redefine) `auth_tenant_ids()`.
- **View:** `create or replace view ... with (security_invoker = true)` — the invoker flag is the entire cross-tenant isolation mechanism (ADR-002); do NOT drop it, do NOT add an anon policy.
- **Conflict seam:** add `src/lib/conflicts.ts` exporting a `findConflicts(...)` wrapper over `supabase.rpc('conflicts_at'|'site_conflicts', ...)`, returning a typed `Conflict[]` — mirrors the `geocoder.ts`/`customers.ts` seam style; consumers never call `supabase.rpc` directly.
- **Add/move composition:** `createCustomerWithSites`/`placeSite` and `updateSiteLocation` call `findConflicts` (prospective point) before/after persisting; the form/list surfaces present the warn-with-confirm.
- **Radius write path:** the per-site picker writes `site.exclusivity_radius_mi` via a small `updateSiteRadius(siteId, mi|null)` helper (PostgREST update on `site`, RLS-scoped by `site_tenant_update`); off ⇒ `null`. Optionally extend `place_site` with `p_radius_mi` for set-at-create.
- **deck.gl:** add a `siteZonesLayer.ts` (`ScatterplotLayer`, meters) alongside `sitePinsLayer`; mount both in the `MapShell` overlay layer array.

## Consequences

### Benefits
- One source of spatial truth (the RPC predicate); `security invoker` means tenant isolation is inherited from the proven `site`/`customer` RLS — no new policy surface to audit.
- The W1-reserved GIST index, radius column, and `is_zone_on` flag are finally exercised with zero new spatial migration cost.
- Pure-reporting RPC keeps block-vs-warn policy in the UI (overridable), and circle rendering keeps the picture identical to the computed semantic.

### Tradeoffs
- Whole-tenant zone coloring is pairwise — bounded by GIST + within-tenant + same-vertical; computed on data change, not per frame. Acceptable at wave scale (hundreds of sites).
- `customer.vertical` duplicates a now-dead `site.vertical` column left in place; documented debt, not dropped this wave.
- Hex-fill branding deferred to a later H3 pass.

### Risks
- **`security definer` slip on the RPC → cross-tenant leak.** Mitigation: `security invoker` is mandatory and load-bearing; a two-tenant test (tenant B's sites never appear in A's conflicts) is required; security-auditor + db-migration-reviewer gate it.
- **GIST not used for the dynamic `GREATEST()` threshold.** `ST_DWithin` is index-aware; PostGIS expands the index range from the distance expression. Mitigation: if EXPLAIN shows a seq scan at scale, pre-filter by the fixed picker max (`3 * 1609.344` m) then exact-filter `GREATEST()`. performance-reviewer confirms the plan.
- **Vertical never set ⇒ no conflicts ever fire** (null vertical never matches). Mitigation: backfill from `attributes->>'vertical'` (below) AND a vertical write path must be in W3 scope (see Spec Issues).
- **`site_geo` consumers break on shape change.** `SiteGeo` (customers.ts:23) gains three fields; existing readers (`sitePinsLayer`) are unaffected (additive). Implementer extends the type.

## Implementation Notes

### Migration Safety (0003)
- **Forward-only, all additive/nullable, zero-downtime.** Reversible in reverse order: `drop function site_conflicts(uuid); drop function conflicts_at(geography,numeric,text,uuid);` then `create or replace view site_geo` back to the ADR-002 shape; `alter table customer drop column vertical;`.
- `exclusivity_radius_mi` already exists — **do not add it**. No radius backfill needed (null = off).
- Vertical backfill is idempotent: `update customer set vertical = attributes->>'vertical' where vertical is null and attributes ? 'vertical';`
- Build order: `customer.vertical` (+ optional index) → `create or replace view site_geo` (needs the column) → RPCs (need the view/columns) → grants.

### Testing Strategy
- **Critical (RLS):** two tenants; tenant A's `conflicts_at`/`site_conflicts` never return B's sites; unauthenticated RPC denied.
- **Spatial unit:** same-vertical pair at 0.9 mi with radii (0.5,0.5) ⇒ no conflict; (1.0,0.5) ⇒ conflict; cross-vertical at 0.1 mi ⇒ no conflict; one-off-radius (0,2) intruding ⇒ conflict; both-off ⇒ no conflict; null-vertical ⇒ no conflict.
- **Composition:** add/move calls `findConflicts`; warn-with-confirm fires; `place_site` still inserts regardless of conflict.
- **Render:** zone circle radius == `radius_mi * 1609.344` m; conflicting zone recolors; `site_geo` returns the three new fields.

### Performance Considerations
- `site_geog_gist` (0001:47) serves `ST_DWithin`. Add `customer(tenant_id, vertical)` index to support the same-vertical join filter. `site_customer_id_idx` (0002:110) serves the join.
- `ScatterplotLayer` is GPU-instanced — N zones in the hundreds/low-thousands is cheap. Recompute coloring on data change, never per frame.

## Alternatives Considered

### Threshold = `A.radius + B.radius` (zone-overlap)
Rejected. Over-flags pairs where neither site is inside the other's exclusive territory (the buffers touch but no one intrudes). Wrong semantic for franchise exclusivity.

### Client-side PostgREST conflict query (no RPC)
Rejected. A spatial self-join with a per-pair `GREATEST()` threshold and a cross-table vertical join is not expressible in PostgREST, and it would scatter the spatial semantic across the client. The RPC keeps one source of truth and uses the index.

### Conflict as a static `site_geo` column / materialized view
Rejected. Conflict is pairwise and changes whenever any sibling site moves or its radius/vertical changes; a static column is immediately stale. Derived on demand from the RPC instead.

### Vertical on `site` (use the reserved column) or in `attributes` jsonb
Rejected. The locked rule is customer-keyed; `site.vertical` denormalizes and can self-disagree; jsonb is unindexed and untyped for the hot join. A typed `customer.vertical` column is the single source of truth.

### `H3HexagonLayer` hex tessellation for zones this wave
Deferred. The exclusivity geometry is a geodesic circle; circles keep viz == semantics with no new dep. Hex fill is a later visual style.

## Spec Issues Found

### Blockers (must fix before implementation)
- **None.** Every read entity has a write/source path: `exclusivity_radius_mi` (radius picker, in-scope), `customer.vertical` (backfill + vertical picker — see below), `site.geog` (W2 add/move), conflict results (RPC over existing tables).

### Recommendations (should fix)
- **A customer vertical write path MUST be in W3 scope.** Conflicts only fire when two customers share a non-null vertical; the backfill from `attributes->>'vertical'` seeds existing data, but without an ongoing vertical picker/field the feature is inert for new customers. The wave spec / ui-spec must name this (a vertical selector on the customer add/edit surface). Flagging now so pm-spec/ui-spec include it.
- **Define the vertical value set.** Free text vs a controlled list (gas/grocery/…). A controlled list makes "share a vertical" reliable; recommend a small enum-like list surfaced in the picker (kept as `text` in the column for flexibility).

### Notes (FYI for implementer)
- `site.vertical` (0001:37) is now dead/superseded — leave it untouched this wave; a later chore may drop it.
- `is_zone_on` (0001:39, default true) is folded into the effective radius; the picker's "off" sets `exclusivity_radius_mi = null` (the locked off semantic) — `is_zone_on` remains a separate master toggle the predicate already honors.
- `SiteGeo` (`src/lib/customers.ts:23`) must gain `exclusivity_radius_mi`, `is_zone_on`, `vertical`; readers are additive-safe.
- EWKT casts into the `geography` RPC param: pass `'SRID=4326;POINT(lng lat)'` exactly as `updateSiteLocation` already builds (customers.ts:169).

---

## Amendment — CR-001: configurable per-customer exclusivity scope (2026-06-28, EX-T7)

**Context.** The code-review gate (CR-001, MED) found the 0003 conflict predicate flags a brand's OWN sibling sites as conflicts: two sites of the same customer are always same-vertical, so any sibling pair within `max(radius)` surfaced as "Conflict". For a multi-site brand this is pervasive false positives. Whether same-customer pairs should conflict is a product decision ADR-003 (this doc) never addressed (competitor-only exclusivity vs. franchise-territory protection incl. same-brand).

**Decision (operator).** Exclusivity scope is **PER-CUSTOMER configurable**. The **default is competitor-only** — a brand does NOT conflict with its own sites. A per-customer toggle (`customer.self_conflict`, default `false`) opts a customer into same-brand territory protection.

**Mechanism (migration `0004_exclusivity_scope.sql`).**
- New column `customer.self_conflict boolean not null default false` (false = competitor-only).
- `conflicts_at` gains a fifth parameter `p_customer_id uuid` (the old 4-arg overload is dropped). The predicate gains `and (s.customer_id is distinct from p_customer_id or c.self_conflict)`: a same-customer pair conflicts only when that customer opted in; cross-customer same-vertical always conflicts. A null `p_customer_id` (brand-new-customer add) behaves as cross-customer — correct, since a brand-new customer has no existing same-customer sites.
- `site_conflicts` keeps its signature and passes the persisted site's own `customer_id` as `p_customer_id`, so suppression applies symmetrically for persisted sites.
- `security invoker` + pinned `search_path = public, pg_temp` + grants (revoke public/anon, grant authenticated) preserved exactly. Reversible (recreate the RPCs to the 0003 4-arg shape, then drop the column).

**Seam + UI.** `findConflicts(point, radiusMi, vertical, excludeId, customerId)` gains the `customerId` arg (CustomerList move passes `site.customer_id`; CustomerForm brand-new add passes `null`). `updateCustomerSelfConflict()` is the edit path. A per-customer checkbox ("Also protect this brand's own sites from each other") on CustomerForm (add) and CustomerRow (edit), default unchecked.

**Test evidence (live Supabase).** Same-customer pair, same vertical, within radius: `self_conflict=false` → zero conflicts in BOTH directions (and via the prospective `conflicts_at` primitive); `self_conflict=true` → conflict in both directions. Cross-customer same-vertical → conflict regardless of either flag. Existing AC-005/AC-011/AC-012 (which assert same-customer conflict mechanics) were re-seeded with `self_conflict=true` to preserve their original intent under the new default.
