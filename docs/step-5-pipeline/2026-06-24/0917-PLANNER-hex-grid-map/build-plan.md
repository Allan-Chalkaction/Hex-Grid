# Build plan — hex-grid epic (wave decomposition)

**Status:** planner draft v1 · 2026-06-24
Greenfield epic, ~6 waves. Each wave is a vertical slice that **ships something usable**. Foundation
first; the novel/risky parts (exclusivity engine, saturation) ride on top of a solid base. Reference
overlays are independent and can move earlier if you want orientation sooner.

---

## Wave 1 — Map shell + data foundation
**Ships:** the app loads, MapLibre renders CONUS with a deck.gl overlay wired, you're in a (stub)
tenant, an empty tenant-scoped customer list exists.
- React + Vite + TypeScript scaffold; MapLibre basemap; deck.gl layer plumbing.
- Postgres + PostGIS schema: `tenant`, `customer` (geog point, radius, is-zone-on), `geocode_cache`.
- Postgres RLS tenant isolation; `tenant_id` everywhere.
- **Pluggable auth seam** (stub identity now; interface the parent app can implement later).
- API-first backend skeleton (the territory service + a thin client).
- *Gates:* @architect-review (foundation), @db-migration-reviewer (schema + RLS).

## Wave 2 — Customers + geocoding (CRUD)
**Ships:** add/import customers, see them as pins.
- Manual add-customer form → geocode (Census, behind `Geocoder` interface) → persist → pin.
- CSV bulk import: parse → batch geocode → dedup → persist, with a results/errors report.
- Edit / move / delete; geocode cache so re-adds are free.
- *Gates:* @code-reviewer; @security-auditor (file upload + external geocode calls).

## Wave 3 — Exclusivity engine (the core value)
**Ships:** per-customer zones drawn; conflicts flagged on add/move.
- Radius picker per customer: off / 0.5 / 1 / 1.5 / 2 / 2.5 / 3 mi.
- **Exact-distance conflict detection** (`ST_DWithin`), bidirectional; block-or-warn UX on add/move.
- Zone rendering (circles + hex fill via deck.gl); overlap/conflict surfacing in the UI.
- *Gates:* @architect-review (the spatial rule), @code-reviewer, @performance-reviewer (query cost at scale).

## Wave 4 — Area saturation (the hex payoff)
**Ships:** a saturation heatmap — "how locked-up is this territory."
- H3 tessellation per viewport/region; per-cell coverage = in-any-zone (or overlap-weighted).
- Saturation heatmap layer (deck.gl H3HexagonLayer); aggregate by viewport / metro / ZIP.
- Prospecting view: "show open area near here."
- *Gates:* @performance-reviewer (per-viewport hex compute), @code-reviewer.

## Wave 5 — Reference overlays
**Ships:** capitals, metros, and the toggleable ZIP overlay.
- State capitals (static 50) + metro CBSAs (pop-thresholded) as label layers.
- **ZIP/ZCTA vector-tile overlay** with a toggle ("click a box and see zip codes").
- Layer-toggle UI for all overlays.
- *Gates:* @code-reviewer; @ui-review (legibility of stacked layers).
- *Note:* independent of W2–W4 — pull earlier if you want the map populated sooner.

## Wave 6 — Embed / harden (deferred until you attach it)
**Ships:** ready to mount inside the parent application.
- Implement the real auth provider against the parent app; finalize API contract.
- AK/HI if needed; true USPS ZIP boundaries if the ZCTA approximation isn't enough.
- *Trigger:* when the parent-app integration is actually scoped.

---

## Recommended entry path

This is **epic-scale** (multiple subsystems, real architecture decisions) — not a single `/nimble`
run. Two viable routes:

1. **`/roadmap` (Phase E) → then `/orchestrated` per wave** — *recommended.* Formalizes this draft
   into the canonical `roadmap.md` + per-wave specs through the advisor funnel (cto → architect →
   ui-spec → pm-spec), with the ADRs above authored at plan time. Highest rigor for a greenfield
   epic with load-bearing architecture.
2. **`/orchestrated` straight into Wave 1** — faster start; the cto/architect/pm funnel runs inside
   the wave. Good if you want to see the map shell stand up before formalizing the whole roadmap.

**Open decision before either:** confirm **R1 (exact-distance exclusivity)** and **R2
(Postgres + PostGIS)** from `architecture-brief.md` — both are load-bearing and I picked them for you.
Everything else is settled or a safe default.
