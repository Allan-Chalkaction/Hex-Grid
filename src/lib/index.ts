/**
 * Public API barrel for hex-grid's embeddable library surface (Wave 6 — EH-T2;
 * ADR-006 / AC-008).
 *
 * This is the SINGLE import root a parent app depends on. It is a PURE re-export
 * (no behavior, no side-effect of its own beyond loading the modules below).
 * Importing this barrel loads `./auth` and `./tenant`, whose Supabase reference
 * impls self-register as the defaults at module load — so `src/lib` resolves the
 * identity seam to Supabase with no `configureIdentity` call (AC-005/008).
 *
 * Stability tiers (ADR-006 D2):
 *   - STABLE (depend on these): `customers`, `conflicts`, `coverage`, `geocoder`,
 *     and `identity` (the `AuthProvider`/`TenantProvider` interfaces +
 *     `configureIdentity` + the auth/tenant free functions).
 *   - INTERNAL (do NOT depend on): the `supabase` client re-export below — present
 *     for app bootstrap only, NOT a parent-stable dependency.
 *
 * The contract is described in `docs/embed-contract.md` (a reference contract,
 * not negotiated). See that doc for the per-symbol stability + env vars.
 */

// ── Stable: customer + site CRUD, conflict detection, coverage/saturation,
//    and geocoding. Pure re-exports of the existing public surface. ──────────
export * from './customers';
export * from './conflicts';
export * from './coverage';
export * from './geocoder';

// ── Stable: the identity/tenant seam — the provider interfaces, the single
//    injection point + accessors, and the auth/tenant free functions consumers
//    call. Enumerated (not `export *`) so the internal register-* helpers stay
//    off the public surface and the `AppSession`/`SignInResult` re-export from
//    `./auth` does not collide with `./providers` (AC-008). ──────────────────
export type {
  AppSession,
  AuthProvider,
  TenantProvider,
  Unsubscribe,
  SignInResult,
} from './providers';
export { configureIdentity, authProvider, tenantProvider } from './providers';
export { getSession, signIn, signOut, onAuthStateChange } from './auth';
export { getActiveTenantId, listMemberships } from './tenant';
export type { Membership } from './tenant';

// ── Internal: the Supabase client singleton. Re-exported for app bootstrap
//    only; it is NOT part of the parent-stable surface and may change without
//    notice (ADR-006 D2). ─────────────────────────────────────────────────────
/** @internal — app bootstrap only; not part of the parent-stable surface. */
export { supabase } from './supabaseClient';
