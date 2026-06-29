# Wave 6 — embed-harden (parent-agnostic) — per-ticket build prompts

Build in dependency order. Full detail: run-folder spec.md (15 ACs), adr.md (ADR-006), findings/cto-advisor.md. NO migration/backend/DB surface. Project node-only (no jsdom/RTL) — verify via pure-logic/type-conformance/grep, never component render. Honor the over-engineering line: NO registry/DI/provider-selection/flag/maxBounds.

Graph: EH-T1 → EH-T2 ; EH-T3 (leaf) ; EH-T4 (leaf).

## EH-T1 — Identity/Tenant provider seam (load-bearing) · deps: [] · AC-001..007,014,015 · code-reviewer, architect-review, security-auditor
Create `src/lib/providers.ts`:
- `AuthProvider` (getSession/onAuthStateChange/signIn/signOut) + `TenantProvider` (getActiveTenantId) — EXACTLY what AuthGate/customers consume today; NO speculative methods. EXCLUDE `listMemberships` from TenantProvider (no consumer; stays a plain helper in tenant.ts) (AC-001).
- **Public interface references NO @supabase/supabase-js type** (no Session/Subscription/User at the boundary): define `AppSession` = `{ user: { email: string | null } }` (only field any consumer reads), `Unsubscribe = () => void`, onAuthStateChange returns `{ unsubscribe }` so the existing call site works (AC-002/003). A parent must build a fake impl WITHOUT supabase-js.
- `configureIdentity({auth?,tenant?})` single injection point (swaps active provider(s), leaves the other on default) + `authProvider()`/`tenantProvider()` accessors. NO registry/DI/env-selection (AC-004).
Supabase default impls (`supabaseAuthProvider` in auth.ts, `supabaseTenantProvider` in tenant.ts) self-register at module load → no configureIdentity call = Supabase defaults, byte-identical to today (AC-005); the Supabase auth impl maps supabase Session/Subscription → AppSession/{unsubscribe} at the seam (AC-003).
Refactor `src/lib/auth.ts`: getSession/onAuthStateChange/signIn/signOut become THIN DELEGATORS calling `authProvider().<m>()` (invoked, not re-implemented) (AC-006); re-export AppSession. `src/lib/tenant.ts`: getActiveTenantId delegates to `tenantProvider()`; listMemberships stays a helper; tenant resolution still reads membership (AC-007/015).
`src/components/AuthGate.tsx`: TYPE-ONLY delta — swap supabase `Session` import for `AppSession` from ../lib/auth; `useState<AppSession|null>`. The functional imports, `session.user.email` read, `subscription.unsubscribe()` ALL stay identical (AC-006).
Security (AC-015): no widening of client identity/tenant assertions — RLS authority stays membership/auth_tenant_ids(); preserve anon-key/env discipline; no new secret/DB/migration/RLS/.sql.
No-regression (AC-014): one default-registered indirection hop; all W2-5 tests pass unchanged, tsc clean, AuthGate login works via Supabase default.
Tests `src/lib/providers.test.ts` (pure/type, no render): Supabase default satisfies both interfaces (assignment compiles); a fake impl constructs WITHOUT supabase-js; configureIdentity swap (fake auth → authProvider() returns fake, tenant stays default; fake getSession observed via the auth.ts free fn); default-resolution (no configure → Supabase, delegator doesn't throw); no-leak grep `git grep -nE '@supabase/supabase-js|\bSession\b|\bSubscription\b' -- src/lib/providers.ts` → no match in exported surface.

## EH-T2 — Public API surface: barrel + contract doc · deps: [EH-T1] · AC-008,013 · code-reviewer, architect-review
`src/lib/index.ts` (AC-008): barrel re-exporting the stable surface — customers/conflicts/coverage/geocoder/identity (the provider interfaces + configureIdentity + the auth.ts/tenant.ts free fns from EH-T1); re-export `supabase` marked `@internal`. Pure re-export, no behavior. Import the Supabase default impls so loading src/lib guarantees self-registration. Stability tiers (ADR-006 D2): the five = stable; supabase = internal.
`docs/embed-contract.md` (AC-013): describe WHAT EXISTS (no behavior change) — the AuthProvider/TenantProvider interfaces; the public lib API + stability tiers; env vars (VITE_ZCTA_TILES_URL, VITE_ZCTA_SOURCE_LABEL, Supabase vars); the AK/HI note; the true-USPS ZCTA path (xref docs/zcta-tiles-setup.md). MUST self-label "reference contract, not negotiated"; flag signIn/signOut as the reference/dev-login arm a parent may stub; note listMemberships exported-but-internal.
Tests `src/lib/index.test.ts` (planned addition; node): import createCustomerWithSites/findConflicts/computeSaturation/defaultGeocoder/configureIdentity + the AuthProvider type through ../lib; grep supabase re-export annotated internal; grep "reference...not negotiated" in the doc.

## EH-T3 — ZCTA source-kind label (leaf) · deps: [] · AC-009,010,011 · code-reviewer, accessibility-auditor
`src/components/zctaSource.ts` (AC-009): add `zctaSourceLabel()` → VITE_ZCTA_SOURCE_LABEL when set else "ZCTA approximation" (mirror the zctaTilesUrl()/zctaConfigured() env-read precedent).
`src/vite-env.d.ts` (AC-011): declare BOTH VITE_ZCTA_TILES_URL (closing the pre-existing gap — read today, undeclared) AND VITE_ZCTA_SOURCE_LABEL, alongside the Supabase vars; tsc clean, no any-typed import.meta.env for these.
`src/components/SaturationPanel.tsx` (AC-010): the ZIP/ZCTA toggle label consumes `zctaSourceLabel()` (e.g. "ZIP boundaries (ZCTA approximation)") instead of the hardcoded string; the htmlFor/aria-describedby wiring UNCHANGED.
Tests `src/components/zctaSource.test.ts` (extend; node): zctaSourceLabel() unset→"ZCTA approximation", set→"USPS ZIP"; existing SaturationPanel.test.ts stays green; grep the toggle consumes the helper.

## EH-T4 — AK/HI honesty (leaf) · deps: [] · AC-012 · code-reviewer, accessibility-auditor
`src/components/MapShell.tsx` (AC-012): change the map aria-label to "Map of the United States" (remove "continental"). DO NOT add maxBounds; DO NOT change center/zoom:4; no data change; role="application" unchanged. Verify: `git grep -n 'aria-label="Map of the United States"' src/components/MapShell.tsx` matches AND `git grep -nE 'continental|maxBounds' src/components/MapShell.tsx` returns nothing.
