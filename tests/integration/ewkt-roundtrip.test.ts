import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  hasDb,
  adminClient,
  createTenantUser,
  seedCustomer,
  signedInClient,
  teardown,
  type TenantUser,
} from '../helpers/integration';

// AC-021 / CR-003 — the empirical answer to the deferred seam question: does an
// EWKT location written through the PostgREST layer round-trip back through the
// `site_geo` view? Both paths run as an AUTHENTICATED user (RLS in force), the way
// `createCustomerWithSites` (RPC insert) and `updateSiteLocation` (PostgREST
// .update with EWKT) do in src/lib/customers.ts.
describe.skipIf(!hasDb)('AC-021 / CR-003 EWKT round-trip via PostgREST', () => {
  let admin: SupabaseClient;
  let user: TenantUser;
  let customerId: string;
  let cli: SupabaseClient;

  beforeAll(async () => {
    admin = adminClient();
    user = await createTenantUser(admin, 'EW');
    customerId = await seedCustomer(admin, user.tenantId, 'RoundTrip Co');
    cli = await signedInClient(user);
  });

  afterAll(async () => {
    await teardown(admin, [user]);
  });

  it('INSERT via place_site RPC round-trips lat/lng through site_geo', async () => {
    const lat = 40.7128;
    const lng = -74.006;
    const { data: siteId, error } = await cli.rpc('place_site', {
      p_customer_id: customerId,
      p_name: 'Insert Site',
      p_address: '123 Main St',
      p_lat: lat,
      p_lng: lng,
    });
    expect(error).toBeNull();
    expect(siteId).toBeTruthy();

    const { data: row, error: readErr } = await cli
      .from('site_geo')
      .select('lat,lng')
      .eq('id', siteId)
      .single();
    expect(readErr).toBeNull();
    expect(row?.lat).toBeCloseTo(lat, 5);
    expect(row?.lng).toBeCloseTo(lng, 5);
  });

  // The UNVERIFIED path CR-003 was deferred over: an EWKT string written via a
  // PostgREST `.update()` (NOT raw SQL) — exactly updateSiteLocation's mechanism.
  it('UPDATE via PostgREST .update() with EWKT round-trips (CR-003)', async () => {
    // Arrange: a site to update (via the RPC, with placeholder coords).
    const { data: siteId, error: insErr } = await cli.rpc('place_site', {
      p_customer_id: customerId,
      p_name: 'Update Site',
      p_address: '1 First Ave',
      p_lat: 1,
      p_lng: 1,
    });
    expect(insErr).toBeNull();

    // Act: persist a new location the way updateSiteLocation does — EWKT through
    // the REST layer.
    const newLat = 40.7484;
    const newLng = -73.9857;
    const { error: upErr } = await cli
      .from('site')
      .update({ geog: `SRID=4326;POINT(${newLng} ${newLat})` })
      .eq('id', siteId);
    expect(upErr).toBeNull();

    // Assert: site_geo reflects the EWKT update.
    const { data: row, error: readErr } = await cli
      .from('site_geo')
      .select('lat,lng')
      .eq('id', siteId)
      .single();
    expect(readErr).toBeNull();
    expect(row?.lat).toBeCloseTo(newLat, 5);
    expect(row?.lng).toBeCloseTo(newLng, 5);
  });
});
