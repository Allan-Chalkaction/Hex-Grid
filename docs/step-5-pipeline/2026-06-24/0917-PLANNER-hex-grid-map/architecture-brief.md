# Architecture brief — hex-grid territory & exclusivity system

**Status:** planner draft v1 · 2026-06-24 · greenfield (empty repo)
One-liner: a multi-tenant, map-based **sales-territory / exclusivity** system. Add customers →
geocode → draw per-customer exclusivity zones → **block conflicts** on add → measure **area
saturation** with a hex grid → reference overlays (capitals, metros, ZIP).

---

## Locked decisions (from operator)

| # | Decision | Value |
|---|---|---|
| D1 | Map stack | **MapLibre GL JS + deck.gl + H3**, React + Vite + TypeScript |
| D2 | ZIP overlay | toggleable **Census ZCTA** vector-tile layer |
| D3 | Zones | **every customer** has a zone; radius ∈ {off, 0.5, 1, 1.5, 2, 2.5, 3 mi}, set per-customer |
| D4 | Tenancy | **multi-tenant** now; **designed to attach to another application** later |

## Planner recommendations (R1, R2 + JSONB CONFIRMED 2026-06-24; rest pending)

| # | Decision | Recommendation | Why |
|---|---|---|---|
| R1 | Exclusivity rule | ✅ **CONFIRMED** — **Exact geodesic distance** is the source of truth (PostGIS `ST_DWithin`). Hexes are visualization + saturation, not the rule. | "0.92 mi → violation" is defensible; hex-stair-stepped edges aren't. Revisitable before the exclusivity wave. |
| R2 | Database | ✅ **CONFIRMED** — **Postgres + PostGIS** (+ `h3-pg`) runtime; SQLite/CSV as load/import format only. Customer/site gets a **JSONB `attributes`** column for extensible site info. | Exact spatial distance queries, mature multi-tenant row-level isolation, native H3 binning. SQLite fails the multi-tenant + geospatial + embed locks. |
| R3 | Tenant isolation | tenant-scoped rows + **Postgres RLS**; `tenant_id` on every table | Hard isolation now; clean seam for the parent app to own identity later |
| R4 | Auth | **pluggable auth interface** — a thin identity provider the app calls, swappable for the parent app's auth on embed | D4 says "attach to another application" — don't hardwire a login |
| R5 | Geocoding | **US Census Geocoder** (free) behind a `Geocoder` interface; paid provider as drop-in fallback; **cache** every result | "every address added" needs address→lat/lng cheaply; interface avoids lock-in |
| R6 | Hex resolution | **H3 res 9** (~0.17 km edge ≈ closest standard rung to 0.25 mi); custom-grid only if exact 0.25 mi proves load-bearing | standard, free binning, viewport-queryable; res 9 is plenty for 0.5–3 mi radii |
| R7 | Shape | **API-first** backend (the territory engine is a service; the map is one client) | makes D4 embedding real instead of aspirational |

## The two spatial jobs (the crux of the design)

1. **Conflict detection (exact).** On add/move a customer: server runs `ST_DWithin(new, each
   other customer's geog, that customer's radius)` → any hit = exclusivity violation → warn/block.
   Bidirectional (new point inside an existing zone OR an existing point inside the new zone).
2. **Area saturation (hex).** Tessellate a region into H3 cells; a cell is "covered" if its center
   falls in any zone (or weight by # overlapping zones). Saturation = covered/total over a
   viewport / metro / ZIP. Renders as a heatmap → "this territory is 80% locked up; open pockets here."

This split is why the hexes belong in the build: exact circles answer *can I place here*, the hex
grid answers *how saturated is this area* — and only a tessellation can answer the second.

## Scale notes (resolved, not blockers)

- A full static 0.25-mi grid over CONUS is ~20–75M cells — **never materialized**. Hexes are
  generated **per-viewport** and only where saturation is being measured. (See `feasibility-framing.md`.)
- 33k ZCTAs render fine as **vector tiles**; not as raw polygons. ZCTA ≈ USPS ZIP but not identical
  — fine for a visual overlay; flag if true USPS delivery boundaries are needed (paid dataset).
- A 3-mi zone at res 9 is a few hundred cells — trivial per customer.

## ADR topics to formalize (load-bearing)

- **ADR — Exclusivity model**: exact-distance rule + hex-for-saturation (R1). The defining decision.
- **ADR — Persistence & tenancy**: Postgres + PostGIS + RLS multi-tenancy (R2/R3).
- **ADR — Embeddability & auth seam**: API-first + pluggable identity for the future parent app (R4/R7).
- (lighter) Geocoding provider interface (R5); H3 resolution choice (R6).

## Assumed defaults (say the word to change)

CONUS only (AK/HI deferred) · web app · "medium-large metro" = CBSA pop ≥ ~250k (tunable) ·
customer add = both manual form + CSV import.
