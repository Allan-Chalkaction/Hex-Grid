# CTO Advisory — Wave 6 (embed-harden, parent-agnostic) · Recommendation: SIMPLIFY · Confidence: High
Build the four parent-agnostic items NOW (genuine standalone value) but constrain auth-seam work to a thin interface-extraction + contract doc — NOT a provider-selection/DI/registry abstraction (no parent exists to justify machinery; YAGNI). Effort Small (1-2d). Debt: REDUCES.

## First-cut scope (the floor)
1. **Auth/Tenant interface lift** — extract `AuthProvider` (getSession/signIn/signOut/onAuthStateChange) + `TenantProvider` (getActiveTenantId/listMemberships) interfaces mirroring the existing functions; keep Supabase as the single default impl behind them (mirror geocoder.ts interface+defaultGeocoder). **LOAD-BEARING: remove the leaked supabase-js types (Session, Subscription) at the boundary** — replace with provider-owned shapes (AppSession/identity + an unsubscribe callback) so a parent can implement WITHOUT a supabase-js dep. This is the acceptance-critical part.
2. **Contract doc** (docs/embed-contract.md) — describe the public lib API the parent consumes (customers/conflicts/coverage/geocoder/supabaseClient + the two provider interfaces) as a description of WHAT EXISTS (types + behavior, no behavior change); optional barrel re-export for discoverability.
3. **AK/HI coverage** — widen the map view to all-US (default, NOT a flag — flag is extra surface for no benefit); update the role=application aria-label off "continental United States". capitals.json already has Juneau/Honolulu.
4. **ZCTA config doc** — document that pointing VITE_ZCTA_TILES_URL at a true-USPS-boundary tileset is the supported path; make the source-kind/label configurable only if one-line.

## Do NOT build (over-engineering line)
No runtime/env provider SELECTION, no registry, no DI — one default, swap-by-code-edit at attach (as auth.ts header already promises). No API-shape negotiation against an imagined parent (document existing). No AK/HI flag (default all-US).

## Gate priming
security-auditor: verify the interface extraction does NOT widen client identity/tenant assertions — RLS must still key off membership/auth_tenant_ids(), not the new interface; preserve anon-key/env discipline. No migration/DB surface.
