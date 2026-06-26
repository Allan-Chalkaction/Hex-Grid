# Feasibility framing — the 0.25-mile-hex-over-CONUS scale problem

## The headline fact

A **static** 0.25-mile hexagonal grid covering the continental US is **tens of millions of
cells**. You cannot render that as one map layer in a browser.

CONUS land area ≈ 3.1M sq mi. Regular-hexagon area = 2.598 × s². "0.25 mile" is ambiguous —
which dimension?

| "0.25 mile" means | cell area (sq mi) | cells over CONUS |
|---|---|---|
| edge length        | 0.162  | ~19 million |
| flat-to-flat width  | 0.054  | ~57 million |
| vertex-to-vertex    | 0.041  | ~76 million |

Even the smallest reading (~19M polygons) is ~100–1000× past what a browser can draw as vector
geometry. So a "draw the whole grid" approach is off the table regardless of which dimension is meant.

## Why it's not actually a problem (the standard answer)

Two facts make this easy once you stop thinking "precompute the whole grid":

1. **0.25-mi hexes are sub-pixel at national zoom.** At a zoom level where you see the whole US,
   a quarter-mile cell is invisible. The grid only becomes meaningful zoomed in to ~street level.
   So you never need all cells at once — only the few thousand currently in the viewport.

2. **Hex grids are computed on demand, not stored.** The grid is a deterministic function of
   (viewport bounds, zoom). You generate only the cells intersecting the current view, at the
   current resolution. Pan/zoom → regenerate. This is a few thousand polygons at a time, trivial
   to render on the GPU.

### Recommended mechanism: H3 + GPU rendering

- **H3** (Uber's hierarchical hex grid) is the industry standard for exactly this. It gives stable
  global hex IDs, fast "which cells are in this bbox" queries, and free aggregation. 0.25 mile sits
  between **H3 resolution 8** (~0.46 km edge, coarser) and **resolution 9** (~0.17 km edge, finer) —
  res 9 is the closest standard rung; a custom non-H3 grid can hit exactly 0.25 mi if that precision
  matters, at the cost of losing H3's free binning.
- **deck.gl** ships an `H3HexagonLayer` and a GPU `HexagonLayer` built for this — millions of points
  binned into hexes, rendered on the GPU, over a MapLibre/Mapbox base map.

So: render hexes **per-viewport**, bin customers **with H3**, and the "20–75M cells" number never
has to exist in memory at once.

## The question this raises: what are the hexagons FOR?

Two very different builds hide under "broken into 0.25-mile hexagons":

- **(A) Visual grid overlay** — a reference lattice drawn over the map, decorative/locational.
  Customers, capitals, metros are separate pin layers on top. Hexes carry no data.
- **(B) Data binning / density** — customers are *aggregated into* hex cells (count per cell,
  color = density / heatmap). This is the high-value version and the reason H3 exists. The grid
  becomes the analytic — "where are my customers concentrated."

The intent text reads more like (A) (grid + separate customer pins), but (B) is usually what people
actually want from a hex map. This is load-bearing — it changes the data model and the renderer.

## Recommended stack (fresh empty repo — nothing settled yet)

| Concern | Recommendation | Why |
|---|---|---|
| Map renderer | **MapLibre GL JS** (open) + **deck.gl** overlay | GPU vector rendering; deck.gl has native H3/hex layers; no per-map-load fees |
| Hex grid | **H3** (res 8/9) | viewport queries + free binning; the standard |
| Geocoding | **US Census Geocoder** (free) for US addresses; Mapbox/Google as paid fallback | "every customer address that is added" needs address → lat/lng |
| Frontend | React + Vite + TypeScript | conventional; deck.gl + MapLibre have first-class React bindings |
| Capitals / metros | static datasets (50 capitals; Census CBSA list for metros, pop-thresholded) | small, ship as JSON/seed |
| Persistence | TBD — depends on single- vs multi-user (see open questions) | a customer table + geocode cache |

## Open questions (load-bearing → surfaced to operator)

1. **Hex purpose:** (A) visual overlay vs (B) bin customers into cells (density). [#1 — changes everything]
2. **Mapping stack:** confirm MapLibre + deck.gl + H3, or a constraint I should know (existing
   Google Maps license, must-be-Leaflet, etc.).
3. **Customer add flow + scale:** one-at-a-time manual form vs bulk CSV/API import; rough # of
   customers (hundreds? millions?) — sets geocoding + binning strategy.
4. **Single-user vs multi-user:** is this just you, or a team/customers logging in? Sets DB + auth.

Non-load-bearing defaults (will assume unless told): CONUS only (AK/HI deferred); web (not native);
"medium-to-large metro" = CBSA population ≥ ~250k (tunable).
