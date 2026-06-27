import type { Session, Subscription } from '@supabase/supabase-js';
import { supabase } from './supabaseClient';

/**
 * The identity seam (AC-007).
 *
 * This module is the SINGLE place in the app that touches `supabase.auth`. Every
 * consumer (AuthGate, App, …) goes through these functions — no other module
 * calls `supabase.auth` directly. When the parent application later swaps in its
 * own identity provider, ONLY this file changes; the database RLS policies never
 * change because they key off the `membership` table (resolved in `tenant.ts`),
 * not the identity source.
 */

/** Result of a sign-in attempt: `error` is `null` on success. */
export interface SignInResult {
  session: Session | null;
  error: string | null;
}

/** Return the current session (or `null` if signed out). */
export async function getSession(): Promise<Session | null> {
  const { data } = await supabase.auth.getSession();
  return data.session;
}

/** Sign in with email + password. Returns a friendly error string on failure. */
export async function signIn(
  email: string,
  password: string,
): Promise<SignInResult> {
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  });
  return { session: data.session, error: error ? error.message : null };
}

/** Sign the current user out. */
export async function signOut(): Promise<void> {
  await supabase.auth.signOut();
}

/**
 * Subscribe to auth-state changes. The callback fires with the current session
 * (or `null` on sign-out). Returns the `Subscription` so callers can unsubscribe.
 */
export function onAuthStateChange(
  callback: (session: Session | null) => void,
): Subscription {
  const {
    data: { subscription },
  } = supabase.auth.onAuthStateChange((_event, session) => {
    callback(session);
  });
  return subscription;
}
