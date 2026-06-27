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
}

/** One site to create under a customer. `name` defaults to `address` if absent. */
export interface SiteInput {
  name?: string;
  address: string;
}

export interface CreateCustomerInput {
  customerName: string;
  attributes?: Record<string, unknown>;
  sites: SiteInput[];
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
): Promise<string> {
  const tenantId = await getActiveTenantId();
  if (!tenantId) {
    throw new Error('No active tenant — cannot create a customer.');
  }

  const { data, error } = await supabase
    .from('customer')
    .upsert(
      { tenant_id: tenantId, name, attributes },
      { onConflict: 'tenant_id,name' },
    )
    .select('id')
    .single();

  if (error || !data) {
    throw new Error(error?.message ?? 'Failed to upsert customer.');
  }
  return data.id as string;
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
