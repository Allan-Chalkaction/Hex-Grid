# Planner session — hex-grid customer map

**Slug:** hex-grid-map · **Started:** 2026-06-24 09:17 · **Track:** planner (advisor-only)

## Operator intent (verbatim from /idea)

> I want to build an interactive map of all my customers locations. I want the map of
> the US, broken into .25 mile hexagons. The map should also each states capital notes
> and medium to large metro areas on the map as well as every customer address that is
> added.

## Decoded requirements (planner's first read)

- Interactive web map of the continental US (probably CONUS; AK/HI TBD).
- A hexagonal tessellation overlay at a **0.25-mile** cell resolution.
- Layers:
  1. **Customer locations** — every customer address that is added (geocoded → pin/marker).
  2. **State capitals** — labeled markers.
  3. **Medium-to-large metro areas** — labeled markers (population threshold TBD).
- "Every customer address that is added" implies an **add-customer flow** + geocoding +
  persistence, not just a static dataset.

## Open questions to resolve before decomposition

- See session notes / round drafts in this folder.

## Status

Planning — feasibility framing first (the 0.25-mi-hex-over-CONUS scale question is load-bearing).
