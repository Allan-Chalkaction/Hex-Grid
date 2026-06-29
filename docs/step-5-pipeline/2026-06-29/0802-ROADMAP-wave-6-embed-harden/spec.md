# Feature Spec: Wave 6 — embed-harden (PARENT-AGNOSTIC subset)

**Status:** Draft
**Author:** AI-assisted (pm-spec agent, integrator step)
**Date:** 2026-06-29
**Slug:** embed-harden
**Ticket key:** HGW-6

## Summary
Harden hex-grid for later embedding in a parent app, building ONLY the parent-agnostic
readiness work. We formalize the identity/tenant seam W1 already shipped into stable,
supabase-js-free provider interfaces (Supabase stays the default reference impl),
publish a documented public API surface (barrel + contract doc), make the map honest
about AK/HI (aria-label only), and make the ZCTA source-kind self-describing. Every
change is additive over W1–W5; zero behavior change, no DB/RLS/migration surface.

## User Stories
- As a **future parent-app integrator**, I want a small, documented `AuthProvider`/`TenantProvider`
  contract that does NOT require a `@supabase/supabase-js` dependency, so I can plug in my own
  identity source by implementing two interfaces and calling one function.
- As a **future parent-app integrator**, I want a single import root (`src/lib`) and a contract
  doc enumerating what is stable to depend on, so I do not have to reverse-engineer the public surface.
- As a **screen-reader user**, I want the map's accessible name to say "United States" (not
  "continental United States"), so it is not falsely described as CONUS-only when AK/HI are pannable.
- As a **map user / operator**, I want the ZIP/ZCTA toggle to name its actual data source, so the
  overlay's accuracy ("ZCTA approximation" vs a true-USPS tileset) is not misrepresented.
- As a **hex-grid maintainer**, I want this hardening to leave every existing consumer and all
  W2–W5 tests untouched, so embed-readiness adds optionality without regression.

## Acceptance Criteria

- [ ] **AC-001.** Substantive: `src/lib/providers.ts` defines `AuthProvider` and `TenantProvider`
  interfaces whose method sets match EXACTLY what consumers use today — `AuthProvider`:
  `getSession`, `onAuthStateChange`, `signIn`, `signOut`; `TenantProvider`: `getActiveTenantId`.
  `listMemberships` is DELIBERATELY EXCLUDED (no consumer in `src/`). No speculative methods
  (refresh/getUser/MFA/tenant-switch). Verification: `vitest` interface-shape test asserting the
  Supabase default impl satisfies both interfaces (assignment compiles); `git grep -n 'listMemberships' src/lib/providers.ts` returns nothing.

- [ ] **AC-002.** Substantive (LOAD-BEARING, acceptance-critical — cto): the PUBLIC interface of
  `providers.ts` references NO `@supabase/supabase-js` type (`Session`, `Subscription`, `User`, …).
  A parent can implement the contract with zero supabase-js dependency. Verification:
  `git grep -nE "@supabase/supabase-js|\\bSession\\b|\\bSubscription\\b" -- src/lib/providers.ts`
  returns no match in the exported interface surface; `tsc --noEmit` clean; a vitest type test
  imports `AuthProvider`/`TenantProvider`/`AppSession` and constructs a fake impl WITHOUT importing supabase-js.

- [ ] **AC-003.** Substantive: provider-owned boundary shapes exist — a minimal `AppSession`
  (carrying `user.email: string | null`, the only field consumers read) and an unsubscribe callback
  type (`Unsubscribe = () => void`) returned wrapped as `{ unsubscribe: Unsubscribe }` so the
  existing `.unsubscribe()` call site keeps working. The Supabase reference impl maps supabase's
  `Session`/`Subscription` to these shapes at the seam. Verification: `vitest` asserts a fake
  `AuthProvider` returning an `AppSession` flows through unchanged; `tsc --noEmit` clean.

- [ ] **AC-004.** Substantive: `configureIdentity({ auth?, tenant? })` is the single injection point;
  calling it swaps the active provider(s), leaving the unspecified one on its default. No registry,
  no env/runtime provider SELECTION, no DI container. Verification: `vitest` —
  `configureIdentity({ auth: fakeAuth })` makes `authProvider()` return `fakeAuth` while
  `tenantProvider()` stays the Supabase default; a fake auth provider's `getSession` result is
  observed through the `auth.ts` free function after injection.

- [ ] **AC-005.** Substantive: with NO `configureIdentity` call, the seam resolves to the Supabase
  default impls (the impls self-register at module load via import side-effect; the barrel imports
  them so loading `src/lib` guarantees registration) — an app that never configures behaves
  byte-identically to today. Verification: `vitest` calls `authProvider()`/`tenantProvider()` with no
  prior `configureIdentity` and asserts the Supabase reference instances; a delegator called before
  any explicit config does not throw.

- [ ] **AC-006.** Substantive (wire-to-consumer — mandatory): `auth.ts` keeps exporting
  `getSession`/`onAuthStateChange`/`signIn`/`signOut` as thin delegators that ACTUALLY CALL
  `authProvider().<m>()` (not re-implement), and `AuthGate.tsx` reaches them on the real path. The
  delegators are invoked, not merely defined. Verification: `git grep -nE 'authProvider\\(\\)\\.' src/lib/auth.ts`
  shows each delegator's call site; a `vitest` test injecting a fake provider then calling the
  `auth.ts` `getSession` export asserts the fake's method fired; `AuthGate.tsx` line-3 named import
  from `../lib/auth` is unchanged (`git grep -n "from '../lib/auth'" src/components/AuthGate.tsx`).

- [ ] **AC-007.** Substantive (wire-to-consumer): `tenant.ts` keeps `getActiveTenantId` as a
  delegator that calls `tenantProvider().getActiveTenantId()`, and `customers.ts` reaches it
  unchanged. `customers.ts` import + call site is byte-identical to pre-wave. Verification:
  `git grep -nE 'tenantProvider\\(\\)\\.getActiveTenantId' src/lib/tenant.ts` shows the call site;
  `git diff` on `src/lib/customers.ts` shows no change to its `getActiveTenantId` import/call;
  `vitest` asserts a fake `TenantProvider` flows through the `tenant.ts` `getActiveTenantId` export.

- [ ] **AC-008.** Substantive: a NEW barrel `src/lib/index.ts` re-exports the stable public surface
  (`customers`, `conflicts`, `coverage`, `geocoder`, `identity` = the provider interfaces +
  `configureIdentity` + the `auth.ts`/`tenant.ts` free functions), and re-exports `supabase` marked
  `@internal`. Pure re-export, no behavior. Verification: `vitest`/`tsc` import test resolving
  representative symbols from `../lib` (`createCustomerWithSites`, `findConflicts`,
  `computeSaturation`, `defaultGeocoder`, `configureIdentity`, `AuthProvider`); `git grep -n 'internal' src/lib/index.ts`
  confirms the `supabase` re-export is annotated internal.

- [ ] **AC-009.** Substantive: `zctaSourceLabel()` (NEW in `zctaSource.ts`) returns
  `VITE_ZCTA_SOURCE_LABEL` when set, else the default string `"ZCTA approximation"` — mirroring the
  existing `zctaTilesUrl()`/`zctaConfigured()` env-read precedent. Verification: `vitest` with
  `VITE_ZCTA_SOURCE_LABEL` unset returns `"ZCTA approximation"`; set to `"USPS ZIP"` returns `"USPS ZIP"`.

- [ ] **AC-010.** Substantive (UI delta — toggle label): the ZIP/ZCTA toggle label in
  `SaturationPanel.tsx` reads accurately using `zctaSourceLabel()` (e.g. "ZIP boundaries (ZCTA
  approximation)") instead of the hardcoded `"ZIP / ZCTA boundaries"`, so the label reflects the
  configured source kind. The associated `<label htmlFor>`/`aria-describedby` wiring is unchanged.
  Verification: `git grep -n 'zctaSourceLabel' src/components/SaturationPanel.tsx` shows the call;
  the existing `SaturationPanel.test.ts` stays green; manual: toggle label renders the helper's value.

- [ ] **AC-011.** Substantive: `src/vite-env.d.ts` declares BOTH `VITE_ZCTA_TILES_URL` (closing the
  pre-existing typing gap — read in `zctaSource.ts` today but undeclared) and the new
  `VITE_ZCTA_SOURCE_LABEL`, alongside the existing Supabase vars. Verification:
  `git grep -nE 'VITE_ZCTA_TILES_URL|VITE_ZCTA_SOURCE_LABEL' src/vite-env.d.ts` shows both;
  `tsc --noEmit` clean (no `any`-typed `import.meta.env` access for these vars).

- [ ] **AC-012.** Substantive: `MapShell.tsx`'s map `aria-label` reads "Map of the United States"
  (the word "continental" removed); NO `maxBounds` is added and the `center`/`zoom:4` default
  viewport is unchanged (AK/HI are already pannable; `capitals.json` already carries Juneau/Honolulu —
  no data change). Verification:
  `git grep -n 'aria-label="Map of the United States"' src/components/MapShell.tsx` matches AND
  `git grep -nE 'continental|maxBounds' src/components/MapShell.tsx` returns nothing.

- [ ] **AC-013.** Substantive: a NEW `docs/embed-contract.md` documents WHAT EXISTS (no behavior
  change): the `AuthProvider`/`TenantProvider` interfaces, the public lib API surface
  (customers/conflicts/coverage/geocoder/identity + `supabase` as internal) with stability tiers, the
  env vars (`VITE_ZCTA_TILES_URL`, `VITE_ZCTA_SOURCE_LABEL`, the Supabase vars), the AK/HI note, and
  the true-USPS ZCTA path (cross-ref `docs/zcta-tiles-setup.md`). It self-labels "reference contract,
  not negotiated" and flags `signIn`/`signOut` as the reference/dev-login arm a parent-hosted login
  need not meaningfully implement. Verification: `git grep -niE 'reference.*not negotiated' docs/embed-contract.md`
  matches; manual read confirms each enumerated section is present.

- [ ] **AC-014.** Substantive (no-regression): all W2–W5 vitest suites pass unchanged, `tsc --noEmit`
  is clean, and no consumer's runtime behavior changes (the seam is one default-registered indirection
  hop). `AuthGate.tsx` login still works via the Supabase default; `customers.ts` upsert path
  unaffected. Verification: `npm run typecheck` (or `tsc --noEmit`) clean; `npm run test` green;
  `git diff --stat` shows changes confined to the files-in-scope list (no W2–W5 logic files touched).

- [ ] **AC-015.** Substantive (security priming): the interface extraction does NOT widen client-side
  identity/tenant assertions — RLS still authorizes off `membership`/`auth_tenant_ids()`, independent
  of the identity source; anon-key/env discipline preserved; no new secret, no DB/migration/RLS file.
  Verification: `git diff --name-only` contains NO file under `supabase/migrations/` or `*.sql`;
  `git grep -nE 'auth_tenant_ids|membership' src/lib/tenant.ts` shows the tenant resolution still
  reads `membership` (unchanged); `@security-auditor` review of the seam confirms no widened assertion.

## Scope

### In Scope (Phase 1)
- Extract `AuthProvider`/`TenantProvider` interfaces + `configureIdentity` single injection point in
  a new `providers.ts`, with provider-owned (supabase-js-free) boundary shapes; Supabase as the
  default/reference impl; `auth.ts`/`tenant.ts` become thin delegators.
- Public API barrel `src/lib/index.ts` + prose contract `docs/embed-contract.md` (description only).
- AK/HI honesty: aria-label string change in `MapShell.tsx`.
- ZCTA source-kind: `VITE_ZCTA_SOURCE_LABEL` + `zctaSourceLabel()` helper; toggle label consumes it;
  document the true-USPS path. Declare both ZCTA env vars in `vite-env.d.ts`.

### Out of Scope (Future — deferred until parent-app integration is scoped)
- **The real parent auth/tenant provider implementation** — no parent exists; only the contract +
  Supabase reference impl ship now. Interim: the Supabase default is the sole impl; a parent swaps by
  implementing the two interfaces and calling `configureIdentity` once at bootstrap (swap-by-code-edit).
- **Final API-contract negotiation** with the parent — the contract doc is explicitly provisional
  ("reference, not negotiated"); shape changes happen when the parent is scoped.
- **Hosting/providing actual USPS or ZCTA tilesets** — the operator supplies `VITE_ZCTA_TILES_URL`
  (and sets the label to "USPS ZIP") per `docs/zcta-tiles-setup.md` when ready.
- No `maxBounds`/`fitBounds`, no AK/HI flag, no provider-selection/registry/DI machinery (see
  Anti-Patterns).

### Files in scope
- `src/lib/providers.ts` — *create*
- `src/lib/index.ts` — *create*
- `src/lib/auth.ts` — *modify* (define `supabaseAuthProvider`; free functions become delegators; re-export `AppSession`)
- `src/lib/tenant.ts` — *modify* (define `supabaseTenantProvider`; `getActiveTenantId` becomes a delegator; `listMemberships` stays as a plain helper, excluded from the interface)
- `src/components/MapShell.tsx` — *modify* (aria-label only)
- `src/components/zctaSource.ts` — *modify* (add `zctaSourceLabel()`)
- `src/components/SaturationPanel.tsx` — *modify* (toggle label uses `zctaSourceLabel()`)
- `src/components/AuthGate.tsx` — *modify* (type-only delta: `Session` import → `AppSession` from `../lib/auth`; named functional imports + logic unchanged — see Data Lifecycle / Open questions)
- `src/vite-env.d.ts` — *modify* (declare both ZCTA env vars)
- `docs/embed-contract.md` — *create*
- Test files (implementer's choice by convention, colocated `*.test.ts`): `src/lib/providers.test.ts` — *create*; extend `src/components/zctaSource` tests for `zctaSourceLabel()`.

## Technical Notes

### Existing Patterns to Reuse
- **`geocoder.ts` (verified):** exported `Geocoder` interface + a single `defaultGeocoder` value
  consumers depend on by type. `providers.ts` generalizes this to a swappable seam with one config
  point — same spirit, no class-by-name dependency.
- **`zctaSource.ts:zctaConfigured()`/`zctaTilesUrl()` (verified):** env-read helper precedent for
  `zctaSourceLabel()`.
- **`auth.ts` header (verified):** already documents "ONLY this file changes when the parent swaps
  identity" — this wave makes that promise mechanically real and testable.

### New Components Needed
- `providers.ts` — interfaces, provider-owned shapes (`AppSession`, `Unsubscribe`), module-level
  active-provider holders, `configureIdentity`, `authProvider()`/`tenantProvider()` accessors.
- `index.ts` — public barrel.
- `docs/embed-contract.md` — provisional parent-facing contract doc.

### Data Lifecycle
This wave reads no new data entity; it formalizes existing seams. For completeness:

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| Session / identity | Supabase Auth (reference impl) via `auth.ts` seam | end user (login) / future parent provider | existing `AuthGate` dev login; provider swap is OUT (deferred) | exists |
| Active tenant id | `membership` table via `tenant.ts` (RLS-scoped) | seeded W1 (one tenant per dev user) | existing W1 membership seeding | exists |
| ZCTA tileset | `VITE_ZCTA_TILES_URL` env (operator-supplied) | operator | env config + `docs/zcta-tiles-setup.md`; hosting OUT | exists (config) |
| ZCTA source label | `VITE_ZCTA_SOURCE_LABEL` env, default `"ZCTA approximation"` | operator | env config; documented in `docs/embed-contract.md` | in-scope (helper + decl) |

`AppSession` boundary note: `AuthGate.tsx` is the only auth consumer and reads only `session.user.email`
and `subscription.unsubscribe()`. `AppSession` is therefore minimal (`{ user: { email: string | null } }`);
the unsubscribe is returned as `{ unsubscribe: () => void }` to preserve the existing call site.

### Database Changes
**None.** No table, column, view, RPC, index, RLS policy, or migration. RLS authorizes off
`membership`/`auth_tenant_ids()`, independent of the identity *source* — swapping `AuthProvider`
cannot change a policy. Data classification: unchanged (auth/tenant data already governed by W1 RLS).
`db-migration-reviewer` gate not required.

### API / Edge Functions
None new. The barrel re-exports the existing public lib surface; the `geocode` Edge Function is
unchanged.

### Security Considerations
- The interface extraction MUST NOT widen client-side identity/tenant assertions. RLS remains the
  authority (server-side, `membership`/`auth_tenant_ids()`); the provider only supplies an
  identity/tenant *value*, never an authorization decision (AC-015).
- Anon-key/env discipline preserved: `VITE_*` vars stay in env (the ZCTA token rides in the URL env,
  never hardcoded) — same posture as W5.
- `security-auditor` gate per the skeleton: review the seam (auth surface). No new secret, no RLS
  change — only an indirection hop to audit.

### Accessibility Requirements
- `MapShell.tsx` aria-label becomes truthful ("Map of the United States"); `role="application"`
  exposure unchanged (A11Y-011 preserved).
- `SaturationPanel.tsx` toggle: the `<label htmlFor>` association and the `aria-describedby` disabled
  helper note are PRESERVED; only the visible label text incorporates `zctaSourceLabel()` (AC-010).
- No new interactive surface; no focus-management or keyboard changes. No `accessibility-auditor`
  gate required beyond confirming the two string changes (skeleton: a11y/ui-review only if bounds/UI
  change materially — they do not).

## Anti-Patterns (over-engineering guard — DO NOT BUILD)
Honor the cto SIMPLIFY verdict and ADR-006's named over-engineering risk. The following are
explicitly OUT and any of them appearing is a design failure:
- **No provider registry / plugin system / DI container.** One default impl, one `configureIdentity`
  injection point. Swap-by-code-edit at attach.
- **No env/runtime provider SELECTION machinery** (no `VITE_AUTH_PROVIDER`-style switch).
- **No speculative interface superset** — no `refresh`/`getUser`/MFA/multi-tenant-switch;
  `listMemberships` EXCLUDED from `TenantProvider` (no consumer).
- **No AK/HI flag, no `maxBounds`/`fitBounds`.** The aria-label string is the whole honest change.
- **No API-shape negotiation against an imagined parent.** The contract doc DESCRIBES what exists.
- **No provider hot-swap / multi-active-provider** logic.

## Open questions / assumptions
- **AuthGate type-only delta (assumption — proceeding).** ADR-006's D1 code sketch imported
  `Session`/`Subscription` into `providers.ts`; the cto's LOAD-BEARING override forbids that. Since
  `AuthGate.tsx` types its local state with supabase's `Session` and reads `session.user.email`,
  making the boundary supabase-js-free necessitates a single type-only line change in `AuthGate`
  (swap the `Session` type import for `AppSession` from `../lib/auth`; `useState<AppSession | null>`).
  **Assumption:** "consumers do not change" is honored at the FUNCTIONAL level — the named
  `../lib/auth` function imports, the `session.user.email` read, and `subscription.unsubscribe()` call
  all stay identical; only the type annotation moves. This is the minimal grounded resolution and the
  acceptance-critical AC-002 takes precedence.
- **Toggle label exact wording (assumption).** Rendered as "ZIP boundaries ({zctaSourceLabel()})"
  unless the implementer finds a more natural composition; the binding requirement is that it consume
  the helper (AC-010), not the exact phrasing.
- **`AppSession` field set (assumption).** Minimal-honest: only `user.email` (the sole consumed
  field). If a later consumer needs more, widen then — not now.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-006 (embed-harden) | prompt / adr.md | AC-001..AC-015 (all five decisions D1–D5) | **D1 code sketch** imported `Session`/`Subscription` into `providers.ts`; this spec forbids supabase-js types in the public interface (AC-002) and adds provider-owned `AppSession`/`Unsubscribe` shapes | cto-advisor SIMPLIFY marked the supabase-js-free boundary LOAD-BEARING / acceptance-critical; the integrator encodes the cto override over the ADR draft's illustrative sketch. ADR-006's decision INTENT (minimal honest interface, geocoder precedent) is preserved |
| ADR-001 (foundation + pluggable-auth seam) | adr.md | AC-006/AC-007 (seam made swappable, consumers unchanged) | none | the W1 seam promise becomes mechanically real |
| ADR-005 (reference-overlays W5) | adr.md | AC-009/AC-011 (ZCTA env + label, typing-gap closure) | none | extends the existing env-gated ZCTA pattern |

## Dependencies
- Builds on W1–W5 (merged to main): `src/lib/{auth,tenant,supabaseClient,geocoder,customers,conflicts,coverage}.ts`,
  `src/components/{AuthGate,MapShell,zctaSource,SaturationPanel}.tsx`, `src/data/capitals.json`,
  `src/vite-env.d.ts`.
- No external service or new integration. The future parent provider + USPS/ZCTA tileset hosting are
  the deferred OUT-scope triggers (parent-app integration scoped).
