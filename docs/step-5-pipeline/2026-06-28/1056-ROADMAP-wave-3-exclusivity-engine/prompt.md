# Roadmap (Phase W) — Wave 3: exclusivity-engine
Ticket key: HGW-3

Graduate the plan-only fat skeleton (docs/step-3-specs/hex-grid/waves/exclusivity-engine/exclusivity-engine.md)
into a build-ready wave spec + ADR + per-ticket prompts. Advisor-only planning (no implementers, no source).
Funnel: cto-advisor -> architect-review (spatial rule) -> ui-spec -> pm-spec (integrator, last).

## Locked operator decisions (from kickoff)
- OD-1 conflict scope = WITHIN-VERTICAL (gas-vs-gas conflicts; gas-vs-grocery does not). Vertical lives on
  customer (W2 customer.attributes carries a 'vertical'; architect decides column vs jsonb).
- Radius grain = PER-SITE: use the `exclusivity_radius_mi` column reserved on `site` in W2's 0001/0002.
  Radius picker per site: off / 0.5 / 1 / 1.5 / 2 / 2.5 / 3 mi.
- Approach = plan & spec first (this run), then build in a later /orchestrated run.

## Depends on (built reality)
- W1: PostGIS multi-tenant schema, site (geog), RLS keyed off auth_tenant_ids(), map shell (deck.gl/MapLibre).
- W2: customer (brand) 1->N site, per-site geocoding, site_geo view, place_site RPC, CustomerList/Form UI,
  sitePinsLayer. exclusivity_radius_mi reserved on site (Wave 3 owns this grain).
