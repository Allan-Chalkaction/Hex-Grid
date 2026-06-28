import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Shared fixtures for the live-DB integration tests (AC-005, AC-021/CR-003).
//
// These tests build their OWN supabase clients from process.env — they NEVER
// import the app singleton (`src/lib/supabaseClient.ts`), which reads
// import.meta.env.VITE_* and is browser-shaped. The local Supabase keys are
// exported into the env by the run command (see tests/README.md).

const API_URL = process.env.API_URL ?? '';
const SERVICE_ROLE_KEY = process.env.SERVICE_ROLE_KEY ?? '';
const ANON_KEY = process.env.ANON_KEY ?? '';

/**
 * True when the local Supabase env is present. Integration suites gate on this
 * (`describe.skipIf(!hasDb)`) so `npm test` does not hard-fail in a no-DB env.
 */
export const hasDb = Boolean(API_URL && SERVICE_ROLE_KEY && ANON_KEY);

/** A service-role client: bypasses RLS — used ONLY to seed + teardown. */
export function adminClient(): SupabaseClient {
  return createClient(API_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

/** A fresh anon-key client with NO session (exercises the unauthenticated path). */
export function anonClient(): SupabaseClient {
  return createClient(API_URL, ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

export interface TenantUser {
  tenantId: string;
  userId: string;
  email: string;
  password: string;
}

/**
 * Seed a tenant + a confirmed auth user + a membership binding them. Uses the
 * service-role client (RLS bypassed). Emails are unique per call so reruns never
 * collide.
 */
export async function createTenantUser(
  admin: SupabaseClient,
  label: string,
): Promise<TenantUser> {
  const sfx = `${label}-${crypto.randomUUID().slice(0, 8)}`;
  const { data: tenant, error: te } = await admin
    .from('tenant')
    .insert({ name: `tenant-${sfx}` })
    .select('id')
    .single();
  if (te || !tenant) throw new Error(`seed tenant failed: ${te?.message}`);

  const email = `cg-t10-${sfx}@example.test`;
  const password = `pw-${crypto.randomUUID()}`;
  const { data: created, error: ue } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (ue || !created.user) throw new Error(`seed user failed: ${ue?.message}`);

  const { error: me } = await admin
    .from('membership')
    .insert({ user_id: created.user.id, tenant_id: tenant.id });
  if (me) throw new Error(`seed membership failed: ${me.message}`);

  return { tenantId: tenant.id, userId: created.user.id, email, password };
}

/**
 * Seed one customer (service-role) and return its id. The optional `vertical`
 * (Wave 3, EX-T1) writes the new `customer.vertical` column directly — the
 * conflict key used by the `conflicts_at` / `site_conflicts` RPCs.
 */
export async function seedCustomer(
  admin: SupabaseClient,
  tenantId: string,
  name: string,
  vertical?: string | null,
): Promise<string> {
  const row: Record<string, unknown> = { tenant_id: tenantId, name };
  if (vertical !== undefined) row.vertical = vertical;
  const { data, error } = await admin
    .from('customer')
    .insert(row)
    .select('id')
    .single();
  if (error || !data) throw new Error(`seed customer failed: ${error?.message}`);
  return data.id as string;
}

/**
 * Seed one site (service-role) with a real location via EWKT so it materializes
 * in the `site_geo` view. Returns the new site id.
 *
 * `opts` (Wave 3, EX-T1) sets the exclusivity-zone fields used by the conflict
 * predicate: `radiusMi` → `site.exclusivity_radius_mi` (null = off), `isZoneOn`
 * → `site.is_zone_on` (defaults true in the DB when omitted).
 */
export async function seedSite(
  admin: SupabaseClient,
  tenantId: string,
  customerId: string,
  name: string,
  lat: number,
  lng: number,
  opts: { radiusMi?: number | null; isZoneOn?: boolean } = {},
): Promise<string> {
  const row: Record<string, unknown> = {
    tenant_id: tenantId,
    customer_id: customerId,
    name,
    address: name,
    geog: `SRID=4326;POINT(${lng} ${lat})`,
  };
  if (opts.radiusMi !== undefined) row.exclusivity_radius_mi = opts.radiusMi;
  if (opts.isZoneOn !== undefined) row.is_zone_on = opts.isZoneOn;
  const { data, error } = await admin
    .from('site')
    .insert(row)
    .select('id')
    .single();
  if (error || !data) throw new Error(`seed site failed: ${error?.message}`);
  return data.id as string;
}

/**
 * Geodesic destination point: from (lat,lng), travel `distanceMi` miles along
 * `bearingDeg` (0 = north, 90 = east). Spherical-earth haversine destination
 * formula (R = 3958.7613 mi). For the few-mile separations the spatial tests use
 * this matches PostGIS `geography` ST_Distance (a spheroid) to well under 1% —
 * far inside the radius-boundary margins the AC-008/011 cases assert against.
 */
export function destinationPoint(
  lat: number,
  lng: number,
  distanceMi: number,
  bearingDeg: number,
): { lat: number; lng: number } {
  const R = 3958.7613;
  const d = distanceMi / R;
  const brng = (bearingDeg * Math.PI) / 180;
  const lat1 = (lat * Math.PI) / 180;
  const lng1 = (lng * Math.PI) / 180;
  const lat2 = Math.asin(
    Math.sin(lat1) * Math.cos(d) +
      Math.cos(lat1) * Math.sin(d) * Math.cos(brng),
  );
  const lng2 =
    lng1 +
    Math.atan2(
      Math.sin(brng) * Math.sin(d) * Math.cos(lat1),
      Math.cos(d) - Math.sin(lat1) * Math.sin(lat2),
    );
  return { lat: (lat2 * 180) / Math.PI, lng: (lng2 * 180) / Math.PI };
}

/** A fresh anon client signed in as the given user (role = authenticated). */
export async function signedInClient(user: TenantUser): Promise<SupabaseClient> {
  const client = anonClient();
  const { error } = await client.auth.signInWithPassword({
    email: user.email,
    password: user.password,
  });
  if (error) throw new Error(`sign-in failed for ${user.email}: ${error.message}`);
  return client;
}

/**
 * Robust teardown: delete tenants (cascades customer/site/membership) and auth
 * users. Swallows individual failures so a partial setup still cleans up and
 * reruns stay green.
 */
export async function teardown(
  admin: SupabaseClient,
  users: TenantUser[],
): Promise<void> {
  for (const u of users) {
    await admin
      .from('tenant')
      .delete()
      .eq('id', u.tenantId)
      .then(undefined, () => undefined);
  }
  for (const u of users) {
    await admin.auth.admin
      .deleteUser(u.userId)
      .then(undefined, () => undefined);
  }
}
