import { supabase } from './supabaseClient';
import {
  registerDefaultTenantProvider,
  tenantProvider,
  type TenantProvider,
} from './providers';

/**
 * Tenant-context resolver (AC-007; Wave 6 EH-T1).
 *
 * Tenant resolution is a SEPARATE step from the identity source: given an
 * authenticated session, resolve the active `tenant_id` from the `membership`
 * table. RLS auto-scopes the `membership` read to the current user (the
 * `membership_self_select` policy), so this returns only the caller's own
 * memberships. Keeping this distinct from `auth.ts` is what lets the identity
 * provider be swapped without touching tenancy: the table policies key off
 * `membership`, which this resolver reads, not off the identity source (AC-015).
 *
 * Wave 6 formalizes the seam: `getActiveTenantId` is now a THIN DELEGATOR to the
 * active `TenantProvider`, and the Supabase implementation is defined here as
 * `supabaseTenantProvider` and SELF-REGISTERED as the default at module load.
 * `listMemberships` stays a PLAIN HELPER (no consumer) — it is DELIBERATELY
 * EXCLUDED from the `TenantProvider` interface (AC-001).
 */

export interface Membership {
  user_id: string;
  tenant_id: string;
  role: string;
}

/**
 * The Supabase reference `TenantProvider` — the default impl. Resolves the
 * active tenant from `membership` (RLS-scoped to the current user); returns the
 * first membership's `tenant_id` (W1 binds one tenant per dev user), or `null` if
 * the user has no membership / is not authenticated.
 */
const supabaseTenantProvider: TenantProvider = {
  async getActiveTenantId(): Promise<string | null> {
    const { data, error } = await supabase
      .from('membership')
      .select('tenant_id')
      .limit(1);

    if (error || !data || data.length === 0) {
      return null;
    }
    return data[0].tenant_id;
  },
};

// Self-register as the default at module load (import side-effect). Loading this
// module (or the `./` barrel, which imports it) resolves the seam to Supabase
// with no `configureIdentity` call (AC-005).
registerDefaultTenantProvider(supabaseTenantProvider);

/**
 * Resolve the active tenant id for the current authenticated user. Delegates to
 * the active provider (AC-006/007).
 */
export function getActiveTenantId(): Promise<string | null> {
  return tenantProvider().getActiveTenantId();
}

/**
 * List all memberships visible to the current user (RLS-scoped to self). A plain
 * helper — NOT part of the `TenantProvider` interface (no consumer; AC-001).
 */
export async function listMemberships(): Promise<Membership[]> {
  const { data, error } = await supabase
    .from('membership')
    .select('user_id, tenant_id, role');

  if (error || !data) {
    return [];
  }
  return data as Membership[];
}
