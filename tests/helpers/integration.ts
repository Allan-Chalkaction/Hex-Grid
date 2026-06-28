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

/** Seed one customer (service-role) and return its id. */
export async function seedCustomer(
  admin: SupabaseClient,
  tenantId: string,
  name: string,
): Promise<string> {
  const { data, error } = await admin
    .from('customer')
    .insert({ tenant_id: tenantId, name })
    .select('id')
    .single();
  if (error || !data) throw new Error(`seed customer failed: ${error?.message}`);
  return data.id as string;
}

/**
 * Seed one site (service-role) with a real location via EWKT so it materializes
 * in the `site_geo` view. Returns the new site id.
 */
export async function seedSite(
  admin: SupabaseClient,
  tenantId: string,
  customerId: string,
  name: string,
  lat: number,
  lng: number,
): Promise<string> {
  const { data, error } = await admin
    .from('site')
    .insert({
      tenant_id: tenantId,
      customer_id: customerId,
      name,
      address: name,
      geog: `SRID=4326;POINT(${lng} ${lat})`,
    })
    .select('id')
    .single();
  if (error || !data) throw new Error(`seed site failed: ${error?.message}`);
  return data.id as string;
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
