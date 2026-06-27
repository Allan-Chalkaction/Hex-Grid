import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  hasDb,
  adminClient,
  anonClient,
  createTenantUser,
  seedCustomer,
  seedSite,
  signedInClient,
  teardown,
  type TenantUser,
} from '../helpers/integration';

// AC-005 — the "Critical" deferred verification: two-tenant RLS isolation over
// the REAL local Supabase. Seeds via service-role; exercises RLS per-user via an
// anon-key client + signInWithPassword; asserts each user sees ONLY their own
// tenant's rows and an unauthenticated client sees ZERO.
describe.skipIf(!hasDb)('AC-005 two-tenant RLS isolation', () => {
  let admin: SupabaseClient;
  let userA: TenantUser;
  let userB: TenantUser;
  let custA: string;
  let custB: string;
  let siteA: string;
  let siteB: string;

  beforeAll(async () => {
    admin = adminClient();
    userA = await createTenantUser(admin, 'A');
    userB = await createTenantUser(admin, 'B');
    custA = await seedCustomer(admin, userA.tenantId, 'Acme-A');
    custB = await seedCustomer(admin, userB.tenantId, 'Beta-B');
    siteA = await seedSite(admin, userA.tenantId, custA, 'A-Site-1', 40.71, -74.01);
    siteB = await seedSite(admin, userB.tenantId, custB, 'B-Site-1', 34.05, -118.24);
  });

  afterAll(async () => {
    await teardown(admin, [userA, userB]);
  });

  it('user A sees ONLY tenant A customers (zero of B)', async () => {
    const cli = await signedInClient(userA);
    const { data, error } = await cli.from('customer').select('id');
    expect(error).toBeNull();
    const ids = (data ?? []).map((r) => r.id);
    expect(ids).toContain(custA);
    expect(ids).not.toContain(custB);
    expect(ids).toHaveLength(1);
  });

  it('user A sees ONLY tenant A sites in site_geo (zero of B)', async () => {
    const cli = await signedInClient(userA);
    const { data, error } = await cli.from('site_geo').select('id');
    expect(error).toBeNull();
    const ids = (data ?? []).map((r) => r.id);
    expect(ids).toContain(siteA);
    expect(ids).not.toContain(siteB);
    expect(ids).toHaveLength(1);
  });

  it('user B sees ONLY tenant B customers + sites (zero of A)', async () => {
    const cli = await signedInClient(userB);
    const { data: custs } = await cli.from('customer').select('id');
    const custIds = (custs ?? []).map((r) => r.id);
    expect(custIds).toEqual([custB]);

    const { data: sites } = await cli.from('site_geo').select('id');
    const siteIds = (sites ?? []).map((r) => r.id);
    expect(siteIds).toEqual([siteB]);
  });

  it('an unauthenticated (anon, no session) client sees ZERO customers and sites', async () => {
    const cli = anonClient();
    const { data: custs } = await cli.from('customer').select('id');
    expect(custs ?? []).toHaveLength(0);
    const { data: sites } = await cli.from('site_geo').select('id');
    expect(sites ?? []).toHaveLength(0);
  });
});
