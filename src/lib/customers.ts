import { supabase } from './supabaseClient';
import { getActiveTenantId } from './tenant';
import {
  defaultGeocoder,
  type Geocoder,
  type GeocodeFailureReason,
} from './geocoder';

/**
 * The manual-add write path (AC-009 / AC-021).
 *
 * `createCustomerWithSites` upserts the customer by `(tenant_id, name)`,
 * geocodes EACH site through the `Geocoder` seam BEFORE persisting, and inserts
 * each site via the `place_site` security-invoker RPC (the deterministic
 * default persistence path — AC-021; the Edge Function geocodes ONLY).
 *
 * Client/CSV-supplied coordinates are NEVER trusted: only the address string is
 * geocoded. A site whose address fails to geocode is persisted UN-geocoded and
 * flagged (`status: 'failed'`), never silently dropped.
 */

/** A row in the `site_geo` view — the read shape for the map + list surfaces. */
export interface SiteGeo {
  id: string;
  customer_id: string;
  name: string;
  address: string | null;
  lat: number | null;
  lng: number | null;
  // Wave 3 (EX-T1/EX-T2): the zone-render + conflict-key fields appended to the
  // 0003 site_geo view. Additive — existing readers (sitePinsLayer) are
  // unaffected. `vertical` is joined from the owning customer (the conflict key
  // lives on customer, not site).
  exclusivity_radius_mi: number | null;
  is_zone_on: boolean;
  vertical: string | null;
  // Appended to the 0005 site_geo view — the owning customer's brand name, joined
  // from `customer.name` (like `vertical`, the brand-side fields live on the
  // joined customer, not the site). Powers the map hover card's brand line.
  customer_name: string;
}

/** One site to create under a customer. `name` defaults to `address` if absent. */
export interface SiteInput {
  name?: string;
  address: string;
}

export interface CreateCustomerInput {
  customerName: string;
  attributes?: Record<string, unknown>;
  /**
   * The customer's vertical token (EX-T3 / AC-019) — written to the
   * `customer.vertical` COLUMN (the conflict key), NOT to `attributes`. `null` /
   * omitted = no vertical (the explicit "Select vertical…" state).
   */
  vertical?: string | null;
  /**
   * Per-customer exclusivity scope (EX-T7 / CR-001). `false` (default) =
   * competitor-only: a brand does NOT conflict with its own sites. `true` opts
   * into same-brand territory protection. Written to `customer.self_conflict`.
   */
  selfConflict?: boolean;
  sites: SiteInput[];
}

/**
 * The controlled customer-vertical value set (EX-T3 / AC-019). Lowercase tokens
 * stored in `customer.vertical`; the label is the human-facing option text. A
 * controlled list makes "two customers share a vertical" reliable (string
 * equality is the conflict key); the column stays `text` so the list can grow
 * without a migration.
 */
export const VERTICAL_OPTIONS: ReadonlyArray<{ value: string; label: string }> =
  [
    { value: 'gas', label: 'Gas / convenience' },
    { value: 'grocery', label: 'Grocery' },
    { value: 'pharmacy', label: 'Pharmacy' },
    { value: 'qsr', label: 'Quick-service restaurant (QSR)' },
    { value: 'restaurant', label: 'Restaurant' },
    { value: 'fitness', label: 'Fitness' },
    { value: 'automotive', label: 'Automotive' },
    { value: 'banking', label: 'Banking' },
    { value: 'hotel', label: 'Hotel / lodging' },
  ];

/** Human label for a stored vertical token (falls back to the raw token). */
export function verticalLabel(token: string | null): string {
  if (!token) {
    return '';
  }
  return VERTICAL_OPTIONS.find((o) => o.value === token)?.label ?? token;
}

/**
 * The hover-card label for a site's restricted-area (exclusivity) radius (the CG
 * map hover card). A site with NO active zone — `is_zone_on` false, or a null /
 * non-positive `exclusivity_radius_mi` — has no restricted area. Otherwise the
 * radius renders in miles with float artifacts + trailing zeros stripped:
 * 0.5 → "0.5 mi", 1 → "1 mi", 1.5 → "1.5 mi", 3 → "3 mi". Mirrors the locked-off
 * semantic the radius write path uses (updateSiteRadius: null/"Off" = no zone).
 * Pure (no I/O) so it unit-tests in the node env. Accepts a structural subset of
 * SiteGeo so any zone-bearing row (or a test fixture) satisfies it.
 */
export function restrictedAreaLabel(site: {
  exclusivity_radius_mi: number | null;
  is_zone_on: boolean;
}): string {
  const mi = site.exclusivity_radius_mi;
  if (!site.is_zone_on || mi == null || mi <= 0) {
    return 'No restricted area';
  }
  // parseFloat(toFixed(2)) collapses 2.50 → "2.5" and 1.0 → "1" without a
  // locale-formatter dependency (the radii are small fixed-step miles).
  return `${parseFloat(mi.toFixed(2))} mi`;
}

/** Per-site outcome surfaced to the form for the geocode-status UI (AC-012). */
export interface SiteOutcome {
  name: string;
  address: string;
  status: 'geocoded' | 'failed';
  reason: GeocodeFailureReason | null;
  siteId: string | null;
}

export interface CreateCustomerResult {
  customerId: string;
  sites: SiteOutcome[];
}

/**
 * Upsert a customer by `(tenant_id, name)` and return its id. Reused by the CSV
 * import (CG-T5) to collapse duplicate brand names within a tenant to one row.
 */
export async function upsertCustomer(
  name: string,
  attributes: Record<string, unknown> = {},
  vertical: string | null = null,
  selfConflict: boolean = false,
): Promise<string> {
  const tenantId = await getActiveTenantId();
  if (!tenantId) {
    throw new Error('No active tenant — cannot create a customer.');
  }

  // Non-destructive dedup (CR-001): look the customer up by (tenant_id, name)
  // first and INSERT only on a miss. The dedup path NEVER updates an existing
  // customer's attributes/vertical — a caller that supplies none (e.g. the CSV
  // import) must not clobber a value a prior add already stored. To change an
  // existing customer's vertical, use updateCustomerVertical (the edit path).
  const existing = await supabase
    .from('customer')
    .select('id')
    .eq('tenant_id', tenantId)
    .eq('name', name)
    .maybeSingle();
  if (existing.error) {
    throw new Error(existing.error.message);
  }
  if (existing.data) {
    return existing.data.id as string;
  }

  const { data, error } = await supabase
    .from('customer')
    .insert({
      tenant_id: tenantId,
      name,
      attributes,
      vertical,
      self_conflict: selfConflict,
    })
    .select('id')
    .single();

  if (error || !data) {
    // A concurrent insert may have created the row between our lookup and our
    // insert; fall back to the now-existing row rather than failing.
    const retry = await supabase
      .from('customer')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('name', name)
      .maybeSingle();
    if (retry.data) {
      return retry.data.id as string;
    }
    throw new Error(error?.message ?? 'Failed to upsert customer.');
  }
  return data.id as string;
}

/**
 * WGS84 bounds check shared by the move / manual-coordinates recovery UIs and
 * `updateSiteLocation` (CR-002 / SA-005): finite numbers with lat ∈ [-90, 90]
 * and lng ∈ [-180, 180].
 */
export function isValidLatLng(lat: number, lng: number): boolean {
  return (
    Number.isFinite(lat) &&
    Number.isFinite(lng) &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180
  );
}

/**
 * Persist one site under a customer via the `place_site` RPC. A null point
 * persists the site un-geocoded (geog null). Returns the new site id.
 */
export async function placeSite(
  customerId: string,
  name: string,
  address: string,
  point: { lat: number; lng: number } | null,
): Promise<string> {
  const { data, error } = await supabase.rpc('place_site', {
    p_customer_id: customerId,
    p_name: name,
    p_address: address,
    p_lat: point ? point.lat : null,
    p_lng: point ? point.lng : null,
  });
  if (error || !data) {
    throw new Error(error?.message ?? 'Failed to persist site.');
  }
  return data as string;
}

/**
 * Update a site's location (move-site, and the manual-coords recovery path for a
 * failed geocode — AC-012/AC-015). API-first via PostgREST using EWKT; PostGIS
 * accepts the EWKT string on the `geog` column. Passing a null point clears it.
 */
export async function updateSiteLocation(
  siteId: string,
  point: { lat: number; lng: number } | null,
): Promise<void> {
  // SA-005: validate inside the helper so it is safe regardless of caller —
  // reject out-of-range / non-finite coords rather than building malformed EWKT.
  if (point && !isValidLatLng(point.lat, point.lng)) {
    throw new Error(
      'Invalid coordinates: latitude must be -90 to 90 and longitude -180 to 180.',
    );
  }
  const { error } = await supabase
    .from('site')
    .update({
      geog: point ? `SRID=4326;POINT(${point.lng} ${point.lat})` : null,
    })
    .eq('id', siteId);
  if (error) {
    throw new Error(error.message);
  }
}

/**
 * Rename a site (the Sites-table inline edit). API-first PostgREST update on the
 * `site` base table, RLS-scoped by `site_tenant_update` (0001). `site.name` is
 * NOT NULL (0001:34), so an empty/whitespace name is rejected BEFORE the write —
 * the same trim-then-guard posture the manual-add path uses to default a blank
 * name to the address. This is a pure name write; it never touches location.
 */
export async function updateSiteName(
  siteId: string,
  name: string,
): Promise<void> {
  const trimmed = name.trim();
  if (!trimmed) {
    throw new Error('Site name is required.');
  }
  const { error } = await supabase
    .from('site')
    .update({ name: trimmed })
    .eq('id', siteId);
  if (error) {
    throw new Error(error.message);
  }
}

export interface SiteUpdateOutcome {
  status: 'geocoded' | 'failed';
  reason: GeocodeFailureReason | null;
}

/**
 * Edit a site's address: re-geocode the new address through the seam, then
 * update the address + location (AC-015). API-first via PostgREST (EWKT). A
 * failed re-geocode clears the location and is reported so the UI can flag it.
 */
export async function updateSiteAddress(
  siteId: string,
  address: string,
  geocoder: Geocoder = defaultGeocoder,
): Promise<SiteUpdateOutcome> {
  const [result] = await geocoder.geocodeDetailed([address]);
  const { error } = await supabase
    .from('site')
    .update({
      address,
      geog: result.point
        ? `SRID=4326;POINT(${result.point.lng} ${result.point.lat})`
        : null,
    })
    .eq('id', siteId);
  if (error) {
    throw new Error(error.message);
  }
  return {
    status: result.point ? 'geocoded' : 'failed',
    reason: result.point ? null : result.reason,
  };
}

/**
 * Set an existing customer's vertical (EX-T3 / AC-019 — the edit path). API-first
 * PostgREST update on the `customer` base table, RLS-scoped by
 * `customer_tenant_update` (0002). The picker's empty "Select vertical…" option
 * passes `null` (clears the vertical → the customer can no longer conflict).
 */
export async function updateCustomerVertical(
  customerId: string,
  vertical: string | null,
): Promise<void> {
  const { error } = await supabase
    .from('customer')
    .update({ vertical })
    .eq('id', customerId);
  if (error) {
    throw new Error(error.message);
  }
}

/**
 * Set an existing customer's exclusivity scope (EX-T7 / CR-001 — the edit path).
 * API-first PostgREST update on the `customer` base table, RLS-scoped by
 * `customer_tenant_update` (0002). `false` = competitor-only (a brand does NOT
 * conflict with its own sites); `true` = also protect this brand's own sites
 * from each other.
 */
export async function updateCustomerSelfConflict(
  customerId: string,
  selfConflict: boolean,
): Promise<void> {
  const { error } = await supabase
    .from('customer')
    .update({ self_conflict: selfConflict })
    .eq('id', customerId);
  if (error) {
    throw new Error(error.message);
  }
}

/**
 * Set a site's exclusivity radius in miles (EX-T2 / AC-015). API-first PostgREST
 * update on the `site` base table, RLS-scoped by `site_tenant_update` (0001).
 * The radius picker's "Off" passes `null` — the locked off semantic (no zone,
 * no circle; the site can still intrude a neighbor's zone). This is a pure
 * radius write; conflict detection lives in the pure-reporting RPC seam
 * (`conflicts.ts`), recomputed by the UI on data change.
 */
export async function updateSiteRadius(
  siteId: string,
  mi: number | null,
): Promise<void> {
  const { error } = await supabase
    .from('site')
    .update({ exclusivity_radius_mi: mi })
    .eq('id', siteId);
  if (error) {
    throw new Error(error.message);
  }
}

/**
 * Delete a customer; the `site.customer_id` FK `on delete cascade` (0002)
 * removes its sites in the database (AC-015).
 */
export async function deleteCustomer(customerId: string): Promise<void> {
  const { error } = await supabase
    .from('customer')
    .delete()
    .eq('id', customerId);
  if (error) {
    throw new Error(error.message);
  }
}

/**
 * Manual-add: upsert the customer, geocode every site (one batch call through
 * the seam — the geocoder IS invoked per site, AC-009), then persist each site.
 * Returns per-site outcomes for the status UI.
 */
export async function createCustomerWithSites(
  input: CreateCustomerInput,
  geocoder: Geocoder = defaultGeocoder,
): Promise<CreateCustomerResult> {
  const customerId = await upsertCustomer(
    input.customerName,
    input.attributes ?? {},
    input.vertical ?? null,
    input.selfConflict ?? false,
  );

  // site.name is NOT NULL (0001:34): default an absent name to the address.
  const sites = input.sites.map((s) => ({
    name: s.name && s.name.trim() ? s.name.trim() : s.address,
    address: s.address,
  }));

  // Geocode the address STRING for every site BEFORE insert (AC-009). CSV/client
  // lat/lng is never read here — only the address.
  const geocoded = await geocoder.geocodeDetailed(sites.map((s) => s.address));

  const outcomes: SiteOutcome[] = [];
  for (let i = 0; i < sites.length; i++) {
    const { name, address } = sites[i];
    const g = geocoded[i];
    const siteId = await placeSite(customerId, name, address, g.point);
    outcomes.push({
      name,
      address,
      status: g.point ? 'geocoded' : 'failed',
      reason: g.point ? null : g.reason,
      siteId,
    });
  }

  return { customerId, sites: outcomes };
}
