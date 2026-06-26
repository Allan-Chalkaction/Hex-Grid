# Kickoff brief — hex-grid territory & exclusivity system

**Purpose:** single consolidated brief for the build engine (`/orchestrated` / `/orchestrate-epic`).
Folds `architecture-brief.md` + `build-plan.md` + `new-ideas-log.md` into one source. 2026-06-24.

## Vision (one paragraph)

A multi-tenant, map-based **sales-territory / exclusivity** system. The operator adds customer
**sites**, each geocoded and carrying a configurable **exclusivity zone** (off / 0.5 / 1 / 1.5 / 2 /
2.5 / 3 mi). The map (MapLibre + deck.gl) renders sites, zones, and reference layers; the system
**blocks/warns on exclusivity conflicts** when a new site would violate an existing zone, and
measures **area saturation** with an H3 hex grid. Designed API-first to later **attach to another
application**.

## Locked architecture (do not re-litigate)

- **Stack:** React + Vite + TypeScript; **MapLibre GL JS + deck.gl + H3**.
- **DB:** **Postgres + PostGIS** (+ `h3-pg`) runtime; **Postgres RLS** multi-tenancy (`tenant_id`
  on every table). SQLite/CSV is an **import/load format only**, never the runtime store.
- **Exclusivity rule:** **exact geodesic distance** (`ST_DWithin` on `geography`) is the source of
  truth; hexes are visualization + saturation, NOT the rule.
- **Extensible site info:** `customer/site` has first-class columns (geog, address, vertical,
  exclusivity_radius_mi nullable, is_zone_on) **plus a JSONB `attributes` column** for arbitrary
  captured fields.
- **Auth:** pluggable identity interface (stub now) — swappable for the parent app's auth on embed.
- **Geocoding:** US Census Geocoder behind a `Geocoder` interface; results cached; paid fallback drop-in.
- **Hex resolution:** H3 res 9 (closest standard rung to 0.25 mi); per-viewport generation — the full
  national grid (~20–75M cells) is NEVER materialized.
- **ZIP overlay:** Census ZCTA as a toggleable vector-tile layer (ZCTA ≈ USPS ZIP, not identical).

## Data model sketch

- `tenant` — id, name.
- `site` (customer) — id, tenant_id, name, address, **geog (PostGIS Point)**, **vertical**,
  **exclusivity_radius_mi** (nullable; null/0 = zone off), **attributes JSONB**, timestamps.
- `vertical` — tenant-managed list (gas, grocery, restaurant, …) — extensible, not a fixed enum.
- `geocode_cache` — address → lat/lng.
- (reference, static/seeded) state capitals; metro CBSAs (pop ≥ ~250k); ZCTA tiles.

## Waves (vertical slices — each ships something usable)

1. **Map shell + data foundation** — Vite/React/TS; MapLibre CONUS basemap + deck.gl wired;
   Postgres+PostGIS schema (tenant, site w/ JSONB, geocode_cache); RLS isolation; pluggable auth
   stub; API-first backend skeleton. *Gates: architect-review, db-migration-reviewer.*
2. **Customers + geocoding** — manual add form + **CSV/SQLite bulk import** (batch geocode, dedup,
   error report); geocode via Census behind interface + cache; edit/move/delete; render pins.
   *Gates: code-reviewer, security-auditor (upload + external calls).*
3. **Exclusivity engine** — per-site radius picker (off/0.5/1/1.5/2/2.5/3); **exact-distance conflict
   detection** (`ST_DWithin`, bidirectional), block/warn UX; zone rendering (circles + hex fill).
   **⚠ per-vertical scoping — see Open Decision OD-1.** *Gates: architect-review, code-reviewer,
   performance-reviewer.*
4. **Area saturation** — H3 tessellation per viewport/region; per-cell coverage; saturation heatmap;
   aggregate by viewport/metro/ZIP; "open territory near here" prospecting. **Likely per-vertical
   (OD-1).** *Gates: performance-reviewer, code-reviewer.*
5. **Reference + filtering** — state capitals; metro CBSAs; **ZIP/ZCTA vector-tile toggle**;
   **filter sites by vertical** (+ color/icon by vertical); layer-toggle UI. *Gates: code-reviewer,
   ui-review.*
6. **Embed / harden (deferred)** — real auth provider against parent app; finalize API contract;
   AK/HI; true USPS ZIP boundaries if ZCTA insufficient. *Trigger: when parent-app integration is scoped.*

## Open decisions (defaulted so the build can proceed — revisit at the named wave)

- **OD-1 — per-vertical exclusivity (Wave 3).** *Default:* exclusivity is scoped **within a vertical**
  (two gas stations conflict; gas vs grocery does not). Conflict rule = `ST_DWithin(...) AND
  same vertical`. Saturation (Wave 4) is likewise **per-vertical**. Revisit before Wave 3 if you want
  global or per-vertical-configurable rules.
- **OD-2 — vertical taxonomy (Wave 1/5).** *Default:* tenant-managed extensible list (not a fixed enum).

## Assumed defaults

CONUS only (AK/HI → Wave 6) · web app · metro = CBSA pop ≥ ~250k (tunable) · customer add = manual
form + bulk import.
