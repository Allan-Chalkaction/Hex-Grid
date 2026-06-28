import { supabase } from './supabaseClient';

/**
 * The exclusivity-conflict seam (EX-T2 / AC-013).
 *
 * Two thin wrappers over the 0003 `security_invoker` conflict RPCs. These are
 * the ONLY call sites for `conflicts_at` / `site_conflicts` in the app — every
 * consumer (CustomerForm add, CustomerList move, App conflict-id derivation)
 * goes through this seam and never calls `supabase.rpc` directly. The RPCs
 * pure-report: they never block a write; the UI owns the warn-with-confirm
 * disposition.
 *
 * Mirrors the `geocoder.ts` / `customers.ts` seam style (typed return, errors
 * surfaced as thrown `Error`s).
 */

/** A conflict row as returned by `conflicts_at` / `site_conflicts` (0003). */
export interface Conflict {
  site_id: string;
  site_name: string;
  customer_id: string;
  customer_name: string;
  distance_mi: number;
  radius_mi: number | null;
}

/**
 * Same-vertical conflicts for a PROSPECTIVE point (add + move preview) via the
 * `conflicts_at` primitive. The point is passed as EWKT
 * `'SRID=4326;POINT(lng lat)'` — exactly the shape `updateSiteLocation`
 * (customers.ts:169) builds for the `geog` column. A null `vertical` or a
 * null/zero `radiusMi` never conflicts (the RPC predicate); `excludeId` excludes
 * a site from its own results on a move.
 *
 * EX-T7 / CR-001: `customerId` is the prospective customer's id — passed as
 * `p_customer_id` so the 0004 predicate can suppress a brand's OWN sibling
 * sites unless that customer opts in via `self_conflict`. A null `customerId`
 * (a brand-new-customer add) behaves as cross-customer (correct — a brand-new
 * customer has no existing same-customer sites).
 */
export async function findConflicts(
  point: { lng: number; lat: number },
  radiusMi: number | null,
  vertical: string | null,
  excludeId: string | null,
  customerId: string | null,
): Promise<Conflict[]> {
  const { data, error } = await supabase.rpc('conflicts_at', {
    p_geog: `SRID=4326;POINT(${point.lng} ${point.lat})`,
    p_radius_mi: radiusMi,
    p_vertical: vertical,
    p_exclude_id: excludeId,
    p_customer_id: customerId,
  });
  if (error) {
    throw new Error(error.message);
  }
  return (data ?? []) as Conflict[];
}

/**
 * Conflicts for an ALREADY-PERSISTED site (list / move surfaces) via the
 * `site_conflicts` wrapper, which folds in the site's own geog / effective
 * radius / vertical and excludes self.
 */
export async function findSiteConflicts(siteId: string): Promise<Conflict[]> {
  const { data, error } = await supabase.rpc('site_conflicts', {
    p_site_id: siteId,
  });
  if (error) {
    throw new Error(error.message);
  }
  return (data ?? []) as Conflict[];
}
