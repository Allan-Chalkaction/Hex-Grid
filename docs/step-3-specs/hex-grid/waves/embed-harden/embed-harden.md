# Wave 6 — embed-harden (parent-agnostic subset)

**Status:** ready-to-build (graduated 2026-06-29 via /roadmap Phase W; PARENT-AGNOSTIC subset only). Plan artifacts:
`docs/step-5-pipeline/2026-06-29/0802-ROADMAP-wave-6-embed-harden/` (spec.md = 15 ACs, adr.md = ADR-006, findings/).

**Ships:** the parent-agnostic embed-readiness hardening — formalized identity seam, documented API contract, AK/HI honesty, ZCTA source-kind label. The actual parent binding stays **deferred until attach**.

## Locked decisions (ADR-006 + cto SIMPLIFY)
- **Identity/Tenant provider seam** — `src/lib/providers.ts`: `AuthProvider` (getSession/onAuthStateChange/signIn/signOut) + `TenantProvider` (getActiveTenantId) interfaces matching real usage (excludes unused `listMemberships`); `configureIdentity({auth,tenant})` single injection point; Supabase = default/reference impl; auth.ts/tenant.ts delegate → **consumers unchanged**. Mirror the geocoder.ts interface+default precedent.
- **LOAD-BEARING:** the provider interfaces leak **no supabase-js types** at the public boundary — provider-owned `AppSession {user:{email}}` + `{unsubscribe}` so a parent implements the contract without supabase-js. (AuthGate gets a type-only `Session→AppSession` delta.)
- **API contract** — barrel `src/lib/index.ts` (stable: customers/conflicts/coverage/geocoder/identity; supabase `@internal`) + `docs/embed-contract.md` (describes what EXISTS; self-labels "reference, not negotiated").
- **AK/HI** — MapShell has **no maxBounds** (already pannable; capitals.json has Juneau/Honolulu); the only change is the aria-label "continental United States" → "United States". No flag.
- **ZCTA-vs-USPS** — `VITE_ZCTA_SOURCE_LABEL` + `zctaSourceLabel()` (default "ZCTA approximation"); SaturationPanel toggle consumes it; declare `VITE_ZCTA_TILES_URL` (pre-existing gap) + the new var in `vite-env.d.ts`; document the true-USPS path.
- **No migration / no DB surface** (RLS keys off membership/auth_tenant_ids(), independent of identity source).

## Anti-patterns (the over-engineering line — do NOT build)
No provider registry/plugin/DI container; no env/runtime provider SELECTION; no speculative interface superset; no AK/HI flag; no maxBounds/hot-swap.

## Scope
- **IN:** providers.ts seam + delegators + AppSession boundary; barrel + contract doc; aria-label; ZCTA label helper + env decl.
- **OUT (deferred until attach — trigger: parent integration scoped):** real parent auth provider impl; final API-contract negotiation; tileset hosting (ZCTA/USPS).

## Tickets (4 — see embed-harden-prompts.md)
EH-T1 provider seam (load-bearing) → EH-T2 barrel + contract doc ; EH-T3 ZCTA label (leaf) ; EH-T4 AK/HI aria-label (leaf). Graph: T2←T1; T3,T4 independent. 15 ACs (AC-001..015).

## Gates
code-reviewer (all) · architect-review (EH-T1/T2 seam+contract) · security-auditor (EH-T1 auth seam) · accessibility-auditor (EH-T3/T4 labels). **No db-migration-reviewer** (no DB surface).

## Depends on
Waves 1–5 (merged). Refactors the W1 auth/tenant seam + adds docs/bounds/labels — read/additive, no W2-5 regression.

## Open follow-ups carried forward (the deferred parent-binding wave)
Real parent auth provider implementation; final API-contract negotiation; ZCTA/USPS tileset provisioning — all triggered when the parent-app integration is actually scoped.
