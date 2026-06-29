# Roadmap (Phase W) — Wave 4: area-saturation
Ticket key: HGW-4

Graduate the plan-only skeleton (docs/step-3-specs/hex-grid/waves/area-saturation/area-saturation.md) into
a build-ready wave spec + ADR + per-ticket prompts. Advisor-only (no implementers, no source).
Funnel: cto-advisor -> architect-review -> ui-spec -> pm-spec (integrator, last).

## Ships (skeleton)
- H3 tessellation per viewport/region; per-cell coverage = in-any-zone (or overlap-weighted).
- Saturation heatmap layer (deck.gl H3HexagonLayer); aggregate by viewport / metro / ZIP.
- Prospecting view: "show open area near here."
- Likely per-vertical (follows OD-1 / W3 within-vertical).

## Built reality (W1+W2+W3 — all shipped/merged)
- W1: PostGIS multi-tenant (site.geog geography + GIST), RLS keyed off auth_tenant_ids(), deck.gl/MapLibre map shell.
- W2: customer 1->N site, per-site geocoding, site_geo view, place_site RPC, CustomerList/Form, sitePinsLayer.
- W3: per-site exclusivity_radius_mi + is_zone_on, customer.vertical, conflicts_at/site_conflicts security_invoker
  RPCs (within-vertical, max(A,B) ST_DWithin), siteZonesLayer (circles), conflictIds derivation in App,
  per-customer self_conflict toggle. site_geo exposes exclusivity_radius_mi/is_zone_on/vertical.

## Defensible forks to pick-and-document (ADR-054) — surface in the presentation
- Coverage metric: in-any-zone (boolean "is this cell inside any active zone") vs overlap-weighted (density).
- Compute location: client-side h3-js per viewport vs server-side (PostGIS h3 ext / RPC). THIS is the
  load-bearing architecture + the named performance gate — architect recommends with rationale.
- Scope/MVP: viewport heatmap only vs + prospecting ("open area near here") vs + metro/ZIP aggregation
  (NOTE: ZIP overlay is Wave 5 reference-overlays — likely defer ZIP). cto may SIMPLIFY.
- Per-vertical: per-vertical saturation (vertical selector) vs combined all-verticals. Default per-vertical (OD-1).

## Gates (skeleton): performance-reviewer (per-viewport hex compute) · code-reviewer.
