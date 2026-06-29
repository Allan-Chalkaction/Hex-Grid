import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabaseClient';
import {
  authProvider,
  registerDefaultAuthProvider,
  type AppSession,
  type AuthProvider,
  type SignInResult,
  type Unsubscribe,
} from './providers';

/**
 * The identity seam (AC-007; Wave 6 EH-T1).
 *
 * This module is the SINGLE place in the app that touches `supabase.auth`. Every
 * consumer (AuthGate, App, …) goes through the free functions below — no other
 * module calls `supabase.auth` directly. Wave 6 makes the "ONLY this file changes
 * when the parent swaps identity" promise mechanically real: the free functions
 * are now THIN DELEGATORS to the active `AuthProvider` (resolved from
 * `providers.ts`), and the Supabase implementation is defined here as
 * `supabaseAuthProvider` and SELF-REGISTERED as the default at module load. An
 * app that never calls `configureIdentity` is byte-identical to before — the
 * delegator adds exactly one default-registered indirection hop (AC-005/006/014).
 *
 * The provider boundary is supabase-js-free (AC-002): this impl maps supabase's
 * native session/subscription shapes to the provider-owned `AppSession` /
 * `{ unsubscribe }` shapes AT the seam, so a parent can implement `AuthProvider`
 * with no supabase-js dependency. RLS authority is unchanged (it keys off
 * `membership`, resolved in `tenant.ts`, not the identity source — AC-015).
 */

// Re-export the provider-owned boundary shapes so consumers import them from the
// seam (`AuthGate` types its local state with `AppSession` from here).
export type { AppSession, SignInResult } from './providers';

/** Map a supabase session to the provider-owned `AppSession` (AC-003). */
function toAppSession(session: Session | null): AppSession | null {
  return session ? { user: { email: session.user.email ?? null } } : null;
}

/**
 * The Supabase reference `AuthProvider` — the default impl. It maps the
 * supabase-js shapes to the provider-owned boundary shapes at the seam.
 */
const supabaseAuthProvider: AuthProvider = {
  async getSession(): Promise<AppSession | null> {
    const { data } = await supabase.auth.getSession();
    return toAppSession(data.session);
  },

  async signIn(email: string, password: string): Promise<SignInResult> {
    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password,
    });
    return {
      session: toAppSession(data.session),
      error: error ? error.message : null,
    };
  },

  async signOut(): Promise<void> {
    await supabase.auth.signOut();
  },

  onAuthStateChange(
    callback: (session: AppSession | null) => void,
  ): { unsubscribe: Unsubscribe } {
    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      callback(toAppSession(session));
    });
    return { unsubscribe: () => subscription.unsubscribe() };
  },
};

// Self-register as the default at module load (import side-effect). Loading this
// module (or the `./` barrel, which imports it) resolves the seam to Supabase
// with no `configureIdentity` call (AC-005).
registerDefaultAuthProvider(supabaseAuthProvider);

/** Return the current session (or `null` if signed out). Delegates (AC-006). */
export function getSession(): Promise<AppSession | null> {
  return authProvider().getSession();
}

/** Sign in with email + password. Delegates to the active provider (AC-006). */
export function signIn(email: string, password: string): Promise<SignInResult> {
  return authProvider().signIn(email, password);
}

/** Sign the current user out. Delegates to the active provider (AC-006). */
export function signOut(): Promise<void> {
  return authProvider().signOut();
}

/**
 * Subscribe to auth-state changes. The callback fires with the current session
 * (or `null` on sign-out). Returns `{ unsubscribe }` so the existing call site
 * keeps working. Delegates to the active provider (AC-006).
 */
export function onAuthStateChange(
  callback: (session: AppSession | null) => void,
): { unsubscribe: Unsubscribe } {
  return authProvider().onAuthStateChange(callback);
}
