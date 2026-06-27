import { supabase } from './supabaseClient';

/**
 * Tenant-context resolver (AC-007).
 *
 * Tenant resolution is a SEPARATE step from the identity source: given an
 * authenticated session, resolve the active `tenant_id` from the `membership`
 * table. RLS auto-scopes the `membership` read to the current user (the
 * `membership_self_select` policy), so this returns only the caller's own
 * memberships. Keeping this distinct from `auth.ts` is what lets the identity
 * provider be swapped without touching tenancy: the table policies key off
 * `membership`, which this resolver reads, not off the identity source.
 */

export interface Membership {
  user_id: string;
  tenant_id: string;
  role: string;
}

/**
 * Resolve the active tenant id for the current authenticated user.
 *
 * Returns the first membership's `tenant_id` (W1 binds one tenant per dev user),
 * or `null` if the user has no membership / is not authenticated.
 */
export async function getActiveTenantId(): Promise<string | null> {
  const { data, error } = await supabase
    .from('membership')
    .select('tenant_id')
    .limit(1);

  if (error || !data || data.length === 0) {
    return null;
  }
  return data[0].tenant_id;
}

/** List all memberships visible to the current user (RLS-scoped to self). */
export async function listMemberships(): Promise<Membership[]> {
  const { data, error } = await supabase
    .from('membership')
    .select('user_id, tenant_id, role');

  if (error || !data) {
    return [];
  }
  return data as Membership[];
}
