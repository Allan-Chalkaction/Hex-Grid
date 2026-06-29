# ADR-006: Embed-Harden (Parent-Agnostic) — Formalize the Identity/Tenant Seam Behind Stable Provider Interfaces (Supabase as Reference Impl); Public API Barrel + Contract Doc; AK/HI via Truthful aria-label (No maxBounds Exists); ZCTA Source-Kind Label as Config; No Migration

**Status:** Proposed
**Date:** 2026-06-29
**Feature:** embed-harden (Wave 6 — PARENT-AGNOSTIC subset)
**Spec:** docs/step-3-specs/hex-grid/waves/embed-harden/embed-harden.md
**Builds on:** ADR-001 (foundation + pluggable-auth seam), ADR-002 (customers-geocoding), ADR-003 (exclusivity W3), ADR-004 (saturation W4), ADR-005 (reference-overlays W5)

## Context

W6's operator decision is **binding and load-bearing**: build only the *parent-agnostic* embed-readiness hardening. No parent application exists yet, so we do NOT implement a real parent identity provider and do NOT negotiate a final API contract. We **formalize** the seam W1 already shipped (`auth.ts`/`tenant.ts` are documented as the single place touching `supabase.auth`), **document** the public surface a parent will consume, make the map honest about AK/HI, and make the ZCTA source-kind self-describing. Every change is read/additive over W1–W5; RLS is untouched.

Built reality that constrains the design (verified by view):
- **`auth.ts`** exports four free functions, all consumed by `AuthGate.tsx` only: `getSession`, `onAuthStateChange`, `signIn`, `signOut`. It is the sole `supabase.auth` caller.
- **`tenant.ts`** exports `getActiveTenantId` (consumed only by `customers.ts:upsertCustomer`) and `listMemberships` (**no consumer anywhere in `src/`**).
- **`geocoder.ts`** already demonstrates the target pattern: an exported `Geocoder` *interface* + a single `defaultGeocoder` value consumers depend on by type, never by class.
- **`MapShell.tsx`** sets `center:[-98.5795,39.8283], zoom:4` and `aria-label="Map of the continental United States"` — but **sets no `maxBounds`**. There is no restrictive bound to widen or remove; AK/HI are already reachable by panning. The CONUS claim is purely (a) the initial framing and (b) the aria-label string.
- **`capitals.json`** already includes `Juneau` (AK) and `Honolulu` (HI) — no data change needed.
- **`zctaSource.ts`** is env-gated on `VITE_ZCTA_TILES_URL`, exposing `zctaTilesUrl()`/`zctaConfigured()`/`addZctaSource`/`setZctaVisible`/`resolveZcta5`. No source-KIND label exists.
- **No `src/lib/index.ts` barrel** exists. `vite-env.d.ts` declares only the two Supabase vars — **not even `VITE_ZCTA_TILES_URL`** (a pre-existing typing gap).

## Decision

Five parent-agnostic decisions, each minimal-and-honest (matching real usage, not a speculative superset):

1. **Identity/Tenant seam → stable provider interfaces, Supabase as the default/reference impl, one injection point — consumers unchanged.**
2. **Public API surface → a barrel `src/lib/index.ts` + a contract doc `docs/embed-contract.md`; types/functions enumerated with stability tiers; zero behavior change.**
3. **AK/HI → truthful `aria-label` (always-on, no flag); confirm no `maxBounds` restricts; capitals already cover AK/HI.**
4. **ZCTA source-kind → add `VITE_ZCTA_SOURCE_LABEL` (+ `zctaSourceLabel()` helper); document the true-USPS path.**
5. **No migration.** RLS keys off `membership`/`auth_tenant_ids()`; the provider swap never touches the DB.

### Component Structure
```
src/
  lib/
    providers.ts   # NEW — AuthProvider/TenantProvider interfaces + active-provider registry + configureIdentity() (the single injection point)
    auth.ts        # EDIT — define supabaseAuthProvider; keep the 4 free functions as thin delegators to the active provider
    tenant.ts      # EDIT — define supabaseTenantProvider; keep getActiveTenantId as a delegator
    index.ts       # NEW — public API barrel (re-export + stability annotations)
  components/
    zctaSource.ts  # EDIT — add zctaSourceLabel() reading VITE_ZCTA_SOURCE_LABEL (default "ZCTA approximation")
    MapShell.tsx   # EDIT — aria-label only: "…continental United States" -> "…United States"
  vite-env.d.ts    # EDIT — declare VITE_ZCTA_TILES_URL + VITE_ZCTA_SOURCE_LABEL (close the typing gap)
docs/
  embed-contract.md  # NEW — the parent-facing contract: provider interfaces, public API surface, env vars, AK/HI + ZCTA notes
```

### Data Model / Migration
**None.** No table, view, column, RPC, RLS policy, or index. RLS authorizes off the `membership` table (`auth_tenant_ids()`), which is independent of the identity *source* — swapping the `AuthProvider` cannot change a single policy. `db-migration-reviewer` gate not required (matches the skeleton's gate list).

### D1 — Identity/Tenant provider interfaces (the load-bearing call)

Define interfaces that match **exactly what consumers use today** — no speculative methods.

```typescript
// src/lib/providers.ts
import type { Session, Subscription } from '@supabase/supabase-js';

export interface SignInResult { session: Session | null; error: string | null; }

export interface AuthProvider {
  getSession(): Promise<Session | null>;
  onAuthStateChange(cb: (session: Session | null) => void): Subscription;
  signIn(email: string, password: string): Promise<SignInResult>;  // reference/dev-login arm — see note
  signOut(): Promise<void>;
}

export interface TenantProvider {
  getActiveTenantId(): Promise<string | null>;
}

// The single injection point. Defaults to the Supabase impls; a parent calls this
// ONCE at bootstrap to swap in its own identity source. No registry plugin system.
let activeAuth: AuthProvider;
let activeTenant: TenantProvider;
export function configureIdentity(p: { auth?: AuthProvider; tenant?: TenantProvider }): void {
  if (p.auth) activeAuth = p.auth;
  if (p.tenant) activeTenant = p.tenant;
}
export function authProvider(): AuthProvider { return activeAuth; }
export function tenantProvider(): TenantProvider { return activeTenant; }
```

**Mechanism — consumers do NOT change.** `auth.ts` keeps exporting `getSession`/`onAuthStateChange`/`signIn`/`signOut` as thin delegators to `authProvider()`, and registers `supabaseAuthProvider` as the default; `tenant.ts` keeps `getActiveTenantId` delegating to `tenantProvider()` and registers `supabaseTenantProvider`. `AuthGate.tsx` and `customers.ts` import the same named functions they import today — zero consumer churn. This is the W1 promise made swappable: "when the parent swaps identity, only this seam changes." Default registration happens at module load (the supabase impls self-register), so an app that never calls `configureIdentity` behaves byte-identically to today.

**`signIn`/`signOut` flagged (honesty over speculation):** they belong to the interface because the *current* consumer (`AuthGate`'s dev login) calls them. A parent-hosted provider that owns its own login UI will likely stub these as no-ops. The contract doc MUST state they are the **reference/dev-login arm**, not a requirement a parent must meaningfully implement.

**`listMemberships` is deliberately EXCLUDED from `TenantProvider`** — it has no consumer in `src/`. Putting an unused method in the must-implement interface is exactly the speculative superset the operator decision forbids. It stays as a plain Supabase helper in `tenant.ts` (and may be marked `@internal`/experimental in the barrel).

### D2 — Public API surface: barrel + contract doc

**Recommended:** a barrel `src/lib/index.ts` re-exporting the public surface, **plus** a prose contract at `docs/embed-contract.md`. The barrel gives a parent one import root and one place stability is asserted; the doc gives prose + env vars + stability tiers. No behavior change — pure formalization.

Enumerated public surface, with stability tiers (`stable` = a parent may depend on it; `internal` = may change):
- **customers** (`stable`): `SiteGeo`, `SiteInput`, `CreateCustomerInput`, `CreateCustomerResult`, `SiteOutcome`, `VERTICAL_OPTIONS`, `verticalLabel`, `createCustomerWithSites`, `upsertCustomer`, `placeSite`, `updateSiteLocation`, `updateSiteAddress`, `updateCustomerVertical`, `updateCustomerSelfConflict`, `updateSiteRadius`, `deleteCustomer`, `isValidLatLng`.
- **conflicts** (`stable`): `Conflict`, `findConflicts`, `findSiteConflicts`.
- **coverage** (`stable`): `computeSaturation`, `coverageForCells`, `rankOpenCells`, `effectiveRadiusMi`, `resolutionForZoom`, `haversineMi`, and the `LatLng`/`ViewportBounds`/`CoverageCell`/`SaturationResult`/`ComputeSaturationParams` types.
- **geocoder** (`stable`): `Geocoder`, `GeoPoint`, `GeocodeResult`, `GeocodeFailureReason`, `defaultGeocoder`.
- **identity** (`stable`): `AuthProvider`, `TenantProvider`, `SignInResult`, `configureIdentity`; the `auth.ts`/`tenant.ts` free functions.
- **client** (`internal`): `supabase` (re-exported but marked internal — a parent should prefer the typed functions over raw PostgREST).

### D3 — AK/HI map coverage

**Recommended mitigation: aria-label fix only, always-on, no flag.** Change `MapShell.tsx`'s `aria-label` from `"Map of the continental United States"` to `"Map of the United States"`. There is **no `maxBounds` to widen or remove** (verified) — AK/HI are already pannable, and `capitals.json` already renders Juneau/Honolulu. The CONUS framing (`center`/`zoom:4`) is the correct *default* viewport (the data is CONUS-centric); a user pans to AK/HI on demand. The only thing falsely excluding AK/HI is the aria-label string.

**Alternatives if a fit-to-all-US default is later wanted:** add a `fitBounds` to an all-US bbox on load — rejected now because it zooms out far enough to shrink the common CONUS workflow, for no parent-agnostic benefit. A config flag is over-engineering: the aria-label is simply being made truthful, which has no behavioral toggle to gate.

### D4 — ZCTA-vs-USPS source-kind as config

**Recommended:** add `VITE_ZCTA_SOURCE_LABEL` (default `"ZCTA approximation"`) and a `zctaSourceLabel()` helper in `zctaSource.ts`; surface that label on the ZIP toggle so the UI reads "ZCTA approximation" vs "USPS ZIP" correctly. The tileset URL stays env-only (`VITE_ZCTA_TILES_URL`, unchanged). Document in `docs/embed-contract.md` (cross-ref the existing `docs/zcta-tiles-setup.md`) that pointing the URL at a true-USPS-boundary tileset **and** setting the label to "USPS ZIP" is the supported path. Hosting tilesets stays OUT (deferred until attach, per the skeleton). This is mostly documentation + one cheap helper + one type decl.

### Key Patterns
- **Provider interface + single default value:** follow `geocoder.ts` verbatim (interface `Geocoder` + `defaultGeocoder`); `providers.ts` generalizes it to a swappable registry with one config point.
- **Env-gated config:** follow `zctaSource.ts:zctaConfigured()`/`zctaTilesUrl()` for `zctaSourceLabel()`.
- **Barrel:** standard `index.ts` re-export; annotate stability in JSDoc.

## Consequences

### Benefits
- A parent can later swap identity by implementing two small interfaces and calling `configureIdentity` once — no consumer, no RLS, no DB change. The W1 seam promise becomes mechanically real and testable.
- One documented import root + contract doc removes guesswork about what is stable to depend on.
- The map stops mis-claiming CONUS-only; the ZIP overlay self-describes its accuracy.

### Tradeoffs
- A thin indirection (free function → active provider) is added to `auth.ts`/`tenant.ts`. Accepted: it is one hop, default-registered, and keeps every consumer untouched.
- The contract is **provisional** — the real parent may need shape changes. That is the explicit deferral; the doc must say "reference contract, not negotiated."

### Risks
- **Over-engineering creep** (the named risk). Mitigation: interfaces match exactly today's consumed methods; `listMemberships` excluded; no plugin registry, no AK/HI flag, no provider hot-swap machinery.
- **Default-registration ordering** (a delegator called before the supabase default registers). Mitigation: register the default at module top-level (import side-effect), not lazily; the barrel imports the impls so loading `src/lib` guarantees registration. Add a unit test asserting the free functions resolve to the supabase default with no `configureIdentity` call.

## Implementation Notes

### Migration Safety
No migration. Nothing to reverse, backfill, or deploy DB-side.

### Testing Strategy
- **Unit:** `providers.ts` — default resolution without `configureIdentity`; `configureIdentity({auth})` swaps only auth and leaves tenant on the default; a fake `AuthProvider` flows through the `auth.ts` free functions. `zctaSourceLabel()` default + override.
- **Integration/manual:** `AuthGate` still logs in via the supabase default (no regression); barrel imports resolve; `tsc` clean after `vite-env.d.ts` additions.
- **Regression guard:** confirm `AuthGate.tsx` and `customers.ts` import lines are unchanged (consumer-churn = a design failure here).

### Performance Considerations
Negligible — one indirection per auth/tenant call (these are already network-bound). No new render, layer, or query.

## Alternatives Considered

### Inject the provider via React context / props
Rejected: `auth.ts`/`tenant.ts` are framework-agnostic lib modules consumed outside React (`customers.ts`). A module-level registry + `configureIdentity` keeps the seam usable from any caller and matches the existing `defaultGeocoder` precedent. Context would force every consumer to change — the opposite of the goal.

### Make `AuthProvider` a broad superset (refresh, getUser, MFA, listMemberships, multi-tenant switch)
Rejected as the explicit over-engineering trap: no consumer uses those, and we cannot honestly design a parent contract with no parent. Ship the minimal honest interface; widen it when the parent is scoped (the deferred OUT-scope work).

### Add `maxBounds`/fitBounds for AK/HI now
Rejected: no bound restricts AK/HI today, and a fit-to-all-US default degrades the common CONUS workflow. The truthful aria-label is the whole honest change.

## Spec Issues Found

### Blockers (must fix before implementation)
- None. Every read path is existing/RLS-scoped; this wave adds no new data read. AK/HI data (capitals) and the env-config "write path" (operator-supplied) both exist. Read/write symmetry holds.

### Recommendations (should fix)
- **Pre-existing typing gap:** `vite-env.d.ts` does not declare `VITE_ZCTA_TILES_URL` (read in `zctaSource.ts` today). Fold its declaration in alongside the new `VITE_ZCTA_SOURCE_LABEL` so the env surface is fully typed.
- **Contract doc must label itself provisional** — a "reference, not negotiated" banner so a future implementer does not treat it as frozen.

### Notes (FYI for implementer)
- The skeleton's "widen view/maxBounds" phrasing assumes a bound exists; it does not. Implement D3 as the aria-label change only and note the absence in the PR.
- `signIn`/`signOut` are the dev-login arm; mark them clearly in the contract so a parent-hosted login isn't forced to implement them meaningfully.
- `listMemberships` is currently dead in `src/` — keep it exported (it may serve a future tenant-switcher) but out of the provider interface and marked `internal` in the barrel.
- security-auditor should review the seam (auth surface) per the skeleton gate list; there is no new secret or RLS change to audit, only the indirection.
