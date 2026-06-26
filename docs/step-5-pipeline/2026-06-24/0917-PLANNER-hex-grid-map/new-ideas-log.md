# New-ideas log (round 3+) — running capture

Operator is dumping more ideas. Capturing each verbatim-ish, slotting into a wave, flagging
cross-cutting impacts. Nothing here is decided yet — these feed the next plan revision.

---

## Idea 1 — Filter sites by Vertical

**Operator:** "filter sites by Vertical (vertical = type of business: gas, grocery, restaurant…)."

- **What it adds:** a `vertical` attribute on each customer/site (gas, grocery, restaurant, …;
  likely a managed/extensible list per tenant), plus a **filter UI** (show/hide by vertical) and
  probably color/icon-by-vertical on the map.
- **Slots into:** primarily **Wave 5 (reference/overlays + filtering UI)** for the filter control;
  the `vertical` field itself lands in the **Wave 1** data model so everything downstream has it.
- **⚠ Cross-cutting impact on Wave 3 (exclusivity):** exclusivity is very likely **per-vertical** —
  the conflict rule becomes `ST_DWithin(...) AND same vertical`. Two gas stations conflict; a gas
  station and a grocery don't. This changes the core engine.
  - **Open question (Wave 3 time, not now):** is exclusivity scoped *within a vertical* (gas-vs-gas
    only), *global* (any customer vs any), or *configurable per vertical* (some verticals exclusive,
    some not; maybe even cross-vertical rules like "no restaurant within 1mi of another restaurant
    OR a grocery")?
  - Also affects **saturation (Wave 4)**: saturation likely becomes *per-vertical* ("how saturated
    is this area for gas stations") — a per-vertical heatmap, not one global one.
- **Decision flags raised:** vertical-scoped exclusivity (Wave 3); per-vertical saturation (Wave 4);
  vertical taxonomy management (tenant-defined list vs fixed enum).

---

## Idea 2 — A SQLite DB to load up customer sites (+ flexible site info)

**Operator:** "should we have a SQLite DB we can load up the customer sites? It'll have the sites
and corresponding info — vertical and anything else we want to capture."

- **Lands on:** decision **R2 (database)** — directly questions the Postgres+PostGIS recommendation.
- **Planner take (grounded):** the *runtime* DB should stay **Postgres + PostGIS** because the locked
  decisions demand it:
  - **Multi-tenant (D4):** SQLite = single-file, coarse write-lock, no real RLS → poor multi-tenant fit.
  - **Geospatial:** exclusivity wants `ST_DWithin`; SQLite's SpatiaLite works but is clunkier and
    weaker for the H3/saturation work.
  - **Attach-to-another-app (D4):** almost always a server DB, not a file.
- **Where SQLite DOES fit (keep the idea):**
  1. **Import/load container** — a SQLite file (or CSV) is a fine *source* for Wave 2 bulk-import.
     "Load up the sites" = the import flow, not the runtime store.
  2. **Local dev** — acceptable for an early local loop if desired.
- **Schema note from "anything else we want to capture":** give `customer/site` a flexible **JSONB
  `attributes` column** (Postgres) so arbitrary site fields are captured without a migration each
  time. (Plus first-class columns for the load-bearing ones: vertical, radius, geog, address.)
- **Decision flag:** confirm **R2 = Postgres + PostGIS runtime** (recommended) vs genuinely prefer
  SQLite/SpatiaLite (would mean revisiting multi-tenant + the spatial engine). Plus: adopt the JSONB
  `attributes` pattern for extensible site info (recommended).
