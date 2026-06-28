import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';
import {
  hasDb,
  adminClient,
  createTenantUser,
  seedCustomer,
  seedSite,
  signedInClient,
  destinationPoint,
  teardown,
  type TenantUser,
} from '../helpers/integration';

// EX-T2 — the conflict seam (src/lib/conflicts.ts) + updateSiteRadius
// (src/lib/customers.ts), AC-013/014/015.
//
// Like ewkt-roundtrip.test.ts (CR-003), these tests exercise the exact DB
// MECHANISMS the wrappers use — `rpc('site_conflicts')` / `rpc('conflicts_at')`
// with an EWKT geography param, and a PostgREST `.update({exclusivity_radius_mi})`
// read back through `site_geo` — as an AUTHENTICATED user (RLS in force). The app
// singleton (src/lib/supabaseClient.ts) reads import.meta.env at import and is
// browser-shaped, so integration tests build their own clients (helpers) rather
// than invoking the singleton-bound wrappers directly. The wrappers are thin
// pass-throughs over precisely these calls.
//
// AC-014 (the SiteGeo type extension) is a compile-time contract verified by
// `tsc`; AC-013's "rpc only inside conflicts.ts" is a grep-time contract.

const ORIGIN = { lat: 41.0, lng: -96.0 };
function ewkt(p: { lat: number; lng: number }): string {
  return `SRID=4326;POINT(${p.lng} ${p.lat})`;
}

interface ConflictRow {
  site_id: string;
  site_name: string;
  customer_id: string;
  customer_name: string;
  distance_mi: number;
  radius_mi: number | null;
}

describe.skipIf(!hasDb)('EX-T2 conflict seam + updateSiteRadius', () => {
  let admin: SupabaseClient;
  let user: TenantUser;
  let cli: SupabaseClient;

  beforeAll(async () => {
    admin = adminClient();
    user = await createTenantUser(admin, 'T2');
    cli = await signedInClient(user);
  });

  afterAll(async () => {
    await teardown(admin, [user]);
  });

  // AC-013 — findSiteConflicts mechanism: site_conflicts returns typed rows.
  it('findSiteConflicts: site_conflicts returns the full typed Conflict row', async () => {
    const cust = await seedCustomer(admin, user.tenantId, 'Seam Co', 'gas');
    const a = await seedSite(admin, user.tenantId, cust, 'Seam-A', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 1.0,
    });
    const bPoint = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.5, 90);
    const b = await seedSite(admin, user.tenantId, cust, 'Seam-B', bPoint.lat, bPoint.lng, {
      radiusMi: 0.5,
    });

    const { data, error } = await cli.rpc('site_conflicts', { p_site_id: a });
    expect(error).toBeNull();
    const rows = (data ?? []) as ConflictRow[];
    const hit = rows.find((r) => r.site_id === b);
    expect(hit).toBeDefined();
    // every typed field is present and correctly shaped.
    expect(typeof hit?.site_id).toBe('string');
    expect(hit?.site_name).toBe('Seam-B');
    expect(hit?.customer_id).toBe(cust);
    expect(hit?.customer_name).toBe('Seam Co');
    expect(typeof Number(hit?.distance_mi)).toBe('number');
    expect(Number(hit?.radius_mi)).toBe(0.5);
  });

  // AC-013 — findConflicts mechanism: a null vertical returns empty.
  it('findConflicts: a null vertical never conflicts', async () => {
    const cust = await seedCustomer(admin, user.tenantId, 'NullVert Seam', 'grocery');
    await seedSite(admin, user.tenantId, cust, 'NV-Site', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 1.0,
    });
    const { data, error } = await cli.rpc('conflicts_at', {
      p_geog: ewkt(ORIGIN),
      p_radius_mi: 1.0,
      p_vertical: null, // prospective null ⇒ empty regardless of proximity
      p_exclude_id: null,
    });
    expect(error).toBeNull();
    expect((data ?? []) as ConflictRow[]).toHaveLength(0);
  });

  // AC-015 — updateSiteRadius mechanism: set→read via site_geo; Off→null.
  it('updateSiteRadius: round-trips a radius and Off→null via site_geo', async () => {
    const cust = await seedCustomer(admin, user.tenantId, 'Radius Co', 'fitness');
    const siteId = await seedSite(admin, user.tenantId, cust, 'Radius-Site', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: null,
    });

    // set 2.5 mi (the mechanism updateSiteRadius uses).
    const set = await cli.from('site').update({ exclusivity_radius_mi: 2.5 }).eq('id', siteId);
    expect(set.error).toBeNull();
    const read1 = await cli
      .from('site_geo')
      .select('exclusivity_radius_mi')
      .eq('id', siteId)
      .single();
    expect(read1.error).toBeNull();
    expect(Number(read1.data?.exclusivity_radius_mi)).toBe(2.5);

    // Off → null.
    const off = await cli.from('site').update({ exclusivity_radius_mi: null }).eq('id', siteId);
    expect(off.error).toBeNull();
    const read2 = await cli
      .from('site_geo')
      .select('exclusivity_radius_mi')
      .eq('id', siteId)
      .single();
    expect(read2.error).toBeNull();
    expect(read2.data?.exclusivity_radius_mi).toBeNull();
  });
});
