# Roadmap (Phase W) — Wave 6: embed-harden (PARENT-AGNOSTIC subset)
Ticket key: HGW-6
Operator decision: build ONLY the parent-agnostic embed-readiness hardening; DEFER the actual parent binding (real auth provider impl + final API contract negotiation) until the parent app is scoped. Advisor-only funnel: cto-advisor -> architect-review -> ui-spec(if UI) -> pm-spec (last).

## IN scope (parent-agnostic)
- Harden the pluggable AUTH-PROVIDER seam: a clean documented AuthProvider/TenantProvider interface (W1 already shipped a pluggable seam — formalize it into a stable, swappable contract a parent can implement; keep the current Supabase impl as the default/reference provider behind the interface). Config/env-driven selection.
- Finalize + DOCUMENT the API contract surface: the public lib API the parent consumes (customers/conflicts/coverage/geocoder/supabaseClient). A stable, documented contract (types + a contract doc); no behavior change.
- AK/HI map coverage: the map is CONUS-bounded today ("continental United States"); allow AK/HI (view bounds/maxBounds + confirm capitals.json has Juneau/Honolulu); a config/flag if needed.
- ZCTA-vs-USPS as a CONFIG choice: the ZCTA overlay is already env-gated (VITE_ZCTA_TILES_URL) — document that pointing it at a true-USPS-boundary tileset is the supported path; make the toggle label/source-kind configurable if cheap.

## OUT (deferred until attach — trigger: parent-app integration scoped)
- Implementing the REAL parent auth provider (no parent exists). Final API-contract NEGOTIATION with the parent.
- Hosting/providing actual USPS or ZCTA tilesets.

## Built reality (W1-W5 merged to main)
- W1 auth/tenant seam: src/lib/{auth,tenant,supabaseClient}.ts; RLS keyed off auth_tenant_ids(). MapShell CONUS view.
- Public lib API: src/lib/{customers,conflicts,coverage,geocoder,csvImport,verticalStyle}.ts.
- W5: zctaSource.ts (env-gated VITE_ZCTA_TILES_URL), capitals.json (incl. AK/HI capitals), referenceLabelsLayer.

## Forks to resolve (pick-and-document)
- AuthProvider interface shape (what methods the parent must implement: getSession/getTenantIds/signIn/signOut?); keep Supabase as the reference impl.
- Where the API-contract doc lives (docs/ + exported barrel/types?).
- AK/HI: widen maxBounds to all-US vs a config flag; default.
- How much config seam vs documentation (cheap interface + doc, no over-engineering).

## Gates (skeleton + judgment): code-reviewer · architect-review (seam/contract) · + security-auditor (auth seam) · accessibility-auditor/ui-review if the map-bounds/UI changes.
