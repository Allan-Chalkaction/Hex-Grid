# Reframe — this is a territory / exclusivity system, not a density map

## What the operator actually wants (round 2)

The hexagons are **not** for binning customer density. They're for **exclusivity zones**:

- Certain **sites** have an exclusivity radius — no other customer may be placed within it.
- The radius is **variable / per-site**: 1, 1.5, 2, 2.5, or 3 miles.
- The hex grid is the tool to **determine / visualize** that exclusivity radius.
- New requirement: a **toggleable US ZIP-code overlay** ("click a box and see zip codes").

So the core feature is **conflict detection**, not visualization for its own sake:
> When I add a new customer, is it inside any existing site's exclusivity zone? And do any
> existing zones overlap (conflict) with each other?

The map, the hexes, the capitals/metros, the zips are all in service of answering "where can I
place the next customer / which territory is open."

## The genuine fork the hexes open

"No customer within X miles" is fundamentally a **distance** rule — exactly computable from two
lat/lngs, no grid required. So what are the hexes really doing? Two readings:

- **(A) Hex = territory UNIT (discrete allocation).** A site claims every H3 cell whose center is
  within its radius. Claimed cells are off-limits. Conflict = two sites claim (or would claim) the
  same cell. Pro: clean tiling, a national grid of "claimed vs open" territory, great for
  prospecting ("show me open cells near here"). Con: the zone edge is hex-stair-stepped, not a true
  circle; exclusivity is approximate to ±~one cell.
- **(B) Hex = VISUALIZATION only; exclusivity is an exact circle.** The radius is a true geodesic
  buffer; conflict = exact point-to-point distance. Hexes are just how you *draw* the zone (and a
  prospecting grid). Pro: exact, defensible ("you are 0.92 mi away → violation"). Con: zones can
  overlap arbitrarily; no clean discrete "this cell is taken" model.

**Planner lean:** exact-distance as the *source of truth* for conflict (B-style logic), hexes as the
*visual + prospecting layer* on top. It's the defensible version (a contract dispute over
exclusivity wants "0.92 miles," not "hex 8a2f…"). But if you want territory to tile discretely and
be claimed cell-by-cell, (A) is legitimate — say so. This is load-bearing (ADR-018 crit 1).

At 0.25-mi cells, a 3-mi-radius zone is ~175–520 cells — trivial to compute/render per site with
H3 `gridDisk` / polygon-fill. Resolution is fine for 1–3 mi radii either way.

## ZIP-code overlay — feasible, reinforces the stack choice

US has ~33,000 ZCTAs (Census ZIP Code Tabulation Areas) as polygons. Drawing all 33k at once is
exactly what **vector tiles** are for — MapLibre renders them smoothly; Leaflet would struggle.
Source: Census ZCTA shapefiles → tile with `tippecanoe`, or use a hosted ZCTA tileset. This is a
toggle layer. (Note: ZCTAs ≈ USPS ZIPs but aren't identical — fine for a visual overlay; flag if
you need true USPS delivery boundaries, which are a paid dataset.)

## Updated data model sketch

- **site / customer** — lat/lng (geocoded), name/address, `is_site` (does it generate a zone?),
  `exclusivity_radius_mi` (nullable; 1/1.5/2/2.5/3), tier?
- **geocode cache** — address → lat/lng.
- **(if A) territory_claim** — site_id → H3 cell id (the claimed set), for conflict queries.
- Reference layers (static): state capitals, metro CBSAs, ZCTA tiles.

## Still-open, still load-bearing

1. **Hex role:** (A) discrete territory unit vs (B) exact-circle exclusivity, hex-rendered. [#1]
2. **Who gets a zone + how the radius is set:** every customer, or only flagged "sites"? Is the
   1/1.5/2/2.5/3 radius chosen per-site by you, or by tier/rule?
3. **Stack confirm:** MapLibre + deck.gl + H3 + vector-tile ZCTA (vs a constraint I should know).
4. **Users:** just you / shared team / multi-tenant (sets DB + auth).

Defaults I'll assume unless told: CONUS only; web app; "medium-large metro" = CBSA pop ≥ ~250k;
support both manual add + CSV import for customers.
