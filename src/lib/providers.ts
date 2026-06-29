/**
 * Identity / Tenant provider seam (Wave 6 — EH-T1; ADR-006 / AC-001..007,014,015).
 *
 * This module is the LOAD-BEARING parent-agnostic boundary hex-grid exposes for
 * later embedding. Its PUBLIC interface references ZERO supabase-js type — a
 * parent app can implement `AuthProvider` / `TenantProvider` with no supabase
 * dependency at all. The Supabase reference implementations live in `auth.ts` /
 * `tenant.ts`; they map the supabase-js shapes to the provider-owned shapes
 * below AT the seam, and self-register as the defaults at module load (import
 * side-effect). An app that never calls `configureIdentity` therefore behaves
 * byte-identically to today.
 *
 * Over-engineering line (cto SIMPLIFY / ADR-006): NO provider registry, NO
 * env/runtime provider SELECTION, NO DI container, NO speculative interface
 * superset. One default impl per role + one `configureIdentity` injection point
 * (swap-by-code-edit at bootstrap). The membership-list helper is deliberately
 * EXCLUDED from `TenantProvider` (no consumer) — it stays a plain helper in
 * `tenant.ts`.
 */

/**
 * The minimal session shape consumers read. `AuthGate` reads only
 * `session.user.email`, so the contract stays minimal-honest — widen only when a
 * real consumer needs more, not speculatively (AC-003).
 */
export interface AppSession {
  user: { email: string | null };
}

/** The handle returned by `onAuthStateChange` so callers can detach (AC-003). */
export type Unsubscribe = () => void;

/** Result of a sign-in attempt: `error` is `null` on success (AC-002/003). */
export interface SignInResult {
  session: AppSession | null;
  error: string | null;
}

/**
 * The identity contract — EXACTLY the four methods consumers use today (via
 * `AuthGate` → `auth.ts`). No speculative methods (refresh/getUser/MFA). The
 * boundary types are all provider-owned (AC-001/002/003).
 */
export interface AuthProvider {
  /** Return the current session (or `null` if signed out). */
  getSession(): Promise<AppSession | null>;
  /** Sign in with email + password; `error` is a friendly string or `null`. */
  signIn(email: string, password: string): Promise<SignInResult>;
  /** Sign the current user out. */
  signOut(): Promise<void>;
  /**
   * Subscribe to auth-state changes. The callback fires with the current session
   * (or `null` on sign-out). Returns `{ unsubscribe }` so the existing call site
   * keeps working.
   */
  onAuthStateChange(
    callback: (session: AppSession | null) => void,
  ): { unsubscribe: Unsubscribe };
}

/**
 * The tenant-context contract — only `getActiveTenantId` (the sole consumed
 * method, reached via `customers.ts`). The membership-list helper is DELIBERATELY
 * EXCLUDED (no consumer in `src/`) — it stays a plain helper in `tenant.ts`
 * (AC-001/007).
 */
export interface TenantProvider {
  /** Resolve the active tenant id for the current user (`null` if none). */
  getActiveTenantId(): Promise<string | null>;
}

// Module-level provider holders. The `default*` slots are filled by the Supabase
// reference impls at module load (self-registration via import side-effect); the
// `active*` slots are set ONLY by an explicit `configureIdentity` call.
// Resolution is `active ?? default` — so configuring overrides, and not
// configuring falls through to the registered Supabase default.
let defaultAuthProvider: AuthProvider | null = null;
let defaultTenantProvider: TenantProvider | null = null;
let activeAuthProvider: AuthProvider | null = null;
let activeTenantProvider: TenantProvider | null = null;

/**
 * Register the default auth provider (INTERNAL — called by the Supabase reference
 * impl in `auth.ts` at module load so loading `src/lib` resolves the seam with no
 * explicit configuration). Not part of the parent-facing surface (AC-005).
 */
export function registerDefaultAuthProvider(provider: AuthProvider): void {
  defaultAuthProvider = provider;
}

/** Register the default tenant provider (INTERNAL — see above) (AC-005). */
export function registerDefaultTenantProvider(provider: TenantProvider): void {
  defaultTenantProvider = provider;
}

/**
 * The SINGLE injection point. A parent app calls this ONCE at bootstrap to swap
 * in its own identity and/or tenant source; an unspecified role stays on its
 * default. No registry, no env selection, no DI container (AC-004).
 */
export function configureIdentity(config: {
  auth?: AuthProvider;
  tenant?: TenantProvider;
}): void {
  if (config.auth) {
    activeAuthProvider = config.auth;
  }
  if (config.tenant) {
    activeTenantProvider = config.tenant;
  }
}

/** Resolve the active auth provider (explicit override ?? Supabase default). */
export function authProvider(): AuthProvider {
  const provider = activeAuthProvider ?? defaultAuthProvider;
  if (!provider) {
    throw new Error(
      'No AuthProvider registered. Import `./auth` (or the `./` barrel) to ' +
        'register the Supabase default, or call configureIdentity().',
    );
  }
  return provider;
}

/** Resolve the active tenant provider (explicit override ?? Supabase default). */
export function tenantProvider(): TenantProvider {
  const provider = activeTenantProvider ?? defaultTenantProvider;
  if (!provider) {
    throw new Error(
      'No TenantProvider registered. Import `./tenant` (or the `./` barrel) to ' +
        'register the Supabase default, or call configureIdentity().',
    );
  }
  return provider;
}
