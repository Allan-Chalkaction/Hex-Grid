# Roadmap (Phase W) — Wave 5: reference-overlays
Ticket key: HGW-5
Graduate the skeleton (docs/step-3-specs/hex-grid/waves/reference-overlays/reference-overlays.md) → build-ready spec + ADR + per-ticket prompts. Advisor-only. Funnel: cto-advisor -> architect-review -> ui-spec -> pm-spec (last).

## Ships (skeleton)
- State capitals (static 50) + metro CBSAs (pop ≥ ~250k) as label layers.
- Toggleable ZIP / ZCTA vector-tile overlay ("click a box and see zip codes").
- Filter sites by vertical (gas/grocery/restaurant/…) + color/icon by vertical.
- Layer-toggle UI for all overlays.

## Built reality (W1-W4 all merged to main)
- W1: MapLibre/deck.gl map shell (MapShell.tsx, reactive MapboxOverlay), PostGIS site.geog, RLS.
- W2: site_geo, sitePinsLayer (deck.gl pins), customer.
- W3: customer.vertical + VERTICAL_OPTIONS/verticalLabel (customers.ts ~70-80), siteZonesLayer, conflictIds.
- W4: coverage.ts (h3-js), saturationLayer/prospectLayer, SaturationPanel (floating top-right, vertical selector + toggles), App lifts selectedVertical/showHeatmap/showProspecting + viewport.

## Forks to resolve (pick-and-document; surface load-bearing ones)
- **ZIP/ZCTA vector-tile SOURCE — the load-bearing dependency.** Options: a free public ZCTA vector-tile source (URL), a hosted tileset (needs key/account), or self-generated tiles. A full ZCTA GeoJSON (~33k polygons) is too big client-side. The architect must pick a concrete source + recommend; if it REQUIRES an operator-provided tileset/API key, FLAG it (CC can't fabricate a tile source).
- Capitals (static 50) + metros (CBSA pop≥250k ~100+) data: embed a small static JSON in the repo? source the data. Recommend.
- Vertical filtering: a site-pin filter by vertical + color/icon-by-vertical — does it REUSE the W4 SaturationPanel vertical selector or add its own? Reconcile the two vertical selectors (avoid two competing controls).
- Layer-toggle UI: a single overlays panel (capitals/metros/ZIP/zones/saturation toggles) vs per-feature toggles — reconcile with the W4 SaturationPanel + the left CRUD panel. Avoid panel proliferation.
- Scope/MVP: cto may SIMPLIFY (e.g. capitals+metros+vertical-filter first; ZIP overlay second if the tile source is a blocker).

## Gates (skeleton): code-reviewer · ui-review (legibility of stacked layers).
