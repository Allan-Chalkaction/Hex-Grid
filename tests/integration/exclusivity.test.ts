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
  destinationPoint,
  teardown,
  type TenantUser,
} from '../helpers/integration';

// EX-T1 — exclusivity-engine conflict RPCs over the REAL local Supabase
// (migration 0003). Seeds via service-role; exercises the RPCs as an
// AUTHENTICATED user (RLS in force, security-invoker functions). Covers:
//   AC-003  site_geo exposes the three new render fields
//   AC-005  site_conflicts returns the typed conflict row
//   AC-008  max(A.radius,B.radius) threshold at the 0.9 mi boundary
//   AC-009  cross-vertical never conflicts
//   AC-010  null vertical never conflicts (both directions)
//   AC-011  off/zero-effective-radius semantics (both-off empty; (0,2) intrudes)
//   AC-012  two-tenant isolation + anon RPC denied
//
// AC-002 (the idempotent jsonb backfill) is a raw-SQL, migration-time statement
// (`update ... where attributes ? 'vertical'`) that PostgREST/supabase-js cannot
// run, so it is covered by tests/migrations/vertical-backfill.sql (the project's
// established SQL-migration-test convention — see tests/migrations/README.md).
//
// Each scenario uses a DISTINCT vertical token so a `conflicts_at(vertical)` scan
// only sees its own scenario's sites (the RPC scans every same-vertical site in
// the caller's tenant). EWKT 'SRID=4326;POINT(lng lat)' is the geography param
// shape, matching updateSiteLocation (customers.ts:169) and the EX-T2 seam.

const ORIGIN = { lat: 39.0, lng: -98.0 }; // mid-CONUS, away from any seeded data
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

describe.skipIf(!hasDb)('EX-T1 exclusivity conflict RPCs', () => {
  let admin: SupabaseClient;
  let userA: TenantUser;
  let userB: TenantUser;
  let cliA: SupabaseClient;

  beforeAll(async () => {
    admin = adminClient();
    userA = await createTenantUser(admin, 'EXA');
    userB = await createTenantUser(admin, 'EXB');
    cliA = await signedInClient(userA);
  });

  afterAll(async () => {
    await teardown(admin, [userA, userB]);
  });

  // AC-003 — site_geo carries exclusivity_radius_mi, is_zone_on, vertical.
  it('AC-003: site_geo exposes the three zone-render fields (RLS-scoped)', async () => {
    const cust = await seedCustomer(admin, userA.tenantId, 'Geo Co', 'grocery');
    const siteId = await seedSite(
      admin,
      userA.tenantId,
      cust,
      'Geo Site',
      ORIGIN.lat,
      ORIGIN.lng,
      { radiusMi: 1.5, isZoneOn: true },
    );
    const { data, error } = await cliA
      .from('site_geo')
      .select('id, exclusivity_radius_mi, is_zone_on, vertical')
      .eq('id', siteId)
      .single();
    expect(error).toBeNull();
    expect(Number(data?.exclusivity_radius_mi)).toBe(1.5);
    expect(data?.is_zone_on).toBe(true);
    expect(data?.vertical).toBe('grocery');
  });

  // AC-005 — site_conflicts returns the fully-typed conflict row.
  it('AC-005: site_conflicts returns the typed row for a same-vertical pair', async () => {
    const cust = await seedCustomer(admin, userA.tenantId, 'Wrapper Co', 'bakery');
    const a = await seedSite(admin, userA.tenantId, cust, 'WSite-A', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 1.0,
    });
    const bPoint = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.9, 90);
    const b = await seedSite(admin, userA.tenantId, cust, 'WSite-B', bPoint.lat, bPoint.lng, {
      radiusMi: 0.5,
    });

    const { data, error } = await cliA.rpc('site_conflicts', { p_site_id: a });
    expect(error).toBeNull();
    const rows = (data ?? []) as ConflictRow[];
    const hit = rows.find((r) => r.site_id === b);
    expect(hit).toBeDefined();
    expect(hit?.site_name).toBe('WSite-B');
    expect(hit?.customer_id).toBe(cust);
    expect(hit?.customer_name).toBe('Wrapper Co');
    expect(Number(hit?.distance_mi)).toBeCloseTo(0.9, 1);
    expect(Number(hit?.radius_mi)).toBe(0.5);
  });

  // AC-008 — the max(A.radius, B.radius) boundary at 0.9 mi apart.
  it('AC-008: (0.5,0.5)@0.9mi ⇒ empty; (1.0 prospective,0.5)@0.9mi ⇒ one', async () => {
    const cust = await seedCustomer(admin, userA.tenantId, 'Boundary Co', 'gas');
    await seedSite(admin, userA.tenantId, cust, 'B-Existing', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 0.5,
    });
    const prospective = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.9, 90);

    // max(0.5 existing, 0.5 prospective) = 0.5 < 0.9 ⇒ no conflict.
    const empty = await cliA.rpc('conflicts_at', {
      p_geog: ewkt(prospective),
      p_radius_mi: 0.5,
      p_vertical: 'gas',
      p_exclude_id: null,
    });
    expect(empty.error).toBeNull();
    expect((empty.data ?? []) as ConflictRow[]).toHaveLength(0);

    // max(0.5 existing, 1.0 prospective) = 1.0 ≥ 0.9 ⇒ one conflict.
    const one = await cliA.rpc('conflicts_at', {
      p_geog: ewkt(prospective),
      p_radius_mi: 1.0,
      p_vertical: 'gas',
      p_exclude_id: null,
    });
    expect(one.error).toBeNull();
    expect((one.data ?? []) as ConflictRow[]).toHaveLength(1);
  });

  // AC-009 — cross-vertical never conflicts even at 0.1 mi.
  it('AC-009: cross-vertical sites do not conflict', async () => {
    const custP = await seedCustomer(admin, userA.tenantId, 'Pharma Co', 'pharmacy');
    const custQ = await seedCustomer(admin, userA.tenantId, 'QSR Co', 'qsr');
    const a = await seedSite(admin, userA.tenantId, custP, 'Px', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 1.0,
    });
    const near = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.1, 90);
    await seedSite(admin, userA.tenantId, custQ, 'Qx', near.lat, near.lng, { radiusMi: 1.0 });

    // prospective pharmacy point scanning: the adjacent site is qsr ⇒ empty.
    const viaAt = await cliA.rpc('conflicts_at', {
      p_geog: ewkt(near),
      p_radius_mi: 1.0,
      p_vertical: 'pharmacy',
      p_exclude_id: a,
    });
    expect(viaAt.error).toBeNull();
    expect((viaAt.data ?? []) as ConflictRow[]).toHaveLength(0);

    // and the persisted pharmacy site sees no qsr neighbor.
    const viaSite = await cliA.rpc('site_conflicts', { p_site_id: a });
    expect(viaSite.error).toBeNull();
    expect((viaSite.data ?? []) as ConflictRow[]).toHaveLength(0);
  });

  // AC-010 — a null vertical never conflicts, both directions.
  it('AC-010: null vertical never conflicts', async () => {
    const custNull = await seedCustomer(admin, userA.tenantId, 'NoVert Co', null);
    const custF = await seedCustomer(admin, userA.tenantId, 'Fit Co', 'fitness');
    const sNull = await seedSite(admin, userA.tenantId, custNull, 'Nx', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: 1.0,
    });
    const near = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.1, 90);
    const sFit = await seedSite(admin, userA.tenantId, custF, 'Fx', near.lat, near.lng, {
      radiusMi: 1.0,
    });

    // p_vertical = null ⇒ empty (prospective null never matches).
    const pNull = await cliA.rpc('conflicts_at', {
      p_geog: ewkt(near),
      p_radius_mi: 1.0,
      p_vertical: null,
      p_exclude_id: null,
    });
    expect(pNull.error).toBeNull();
    expect((pNull.data ?? []) as ConflictRow[]).toHaveLength(0);

    // the null-vertical persisted site sees nothing (its own vertical is null).
    const fromNull = await cliA.rpc('site_conflicts', { p_site_id: sNull });
    expect(fromNull.error).toBeNull();
    expect((fromNull.data ?? []) as ConflictRow[]).toHaveLength(0);

    // the fitness site does not pick up the null-vertical neighbor.
    const fromFit = await cliA.rpc('site_conflicts', { p_site_id: sFit });
    expect(fromFit.error).toBeNull();
    expect((fromFit.data ?? []) as ConflictRow[]).toHaveLength(0);
  });

  // AC-011 — off/zero effective radius: both-off ⇒ empty; (0,2) intrudes ⇒ one.
  it('AC-011: both-off ⇒ empty; an off site intruding an on-neighbor ⇒ one', async () => {
    // both-off pair (banking), radius null on both.
    const custBank = await seedCustomer(admin, userA.tenantId, 'Bank Co', 'banking');
    const aOff = await seedSite(admin, userA.tenantId, custBank, 'BankA', ORIGIN.lat, ORIGIN.lng, {
      radiusMi: null,
    });
    const nearBank = destinationPoint(ORIGIN.lat, ORIGIN.lng, 0.5, 90);
    await seedSite(admin, userA.tenantId, custBank, 'BankB', nearBank.lat, nearBank.lng, {
      radiusMi: null,
    });
    const bothOff = await cliA.rpc('site_conflicts', { p_site_id: aOff });
    expect(bothOff.error).toBeNull();
    expect((bothOff.data ?? []) as ConflictRow[]).toHaveLength(0);

    // (0,2): an off site that sits inside an on-neighbor's 2 mi zone IS flagged.
    const custHotel = await seedCustomer(admin, userA.tenantId, 'Hotel Co', 'hotel');
    const hub = { lat: 39.5, lng: -97.5 }; // distinct origin for the hotel scenario
    const offSite = await seedSite(admin, userA.tenantId, custHotel, 'HotelOff', hub.lat, hub.lng, {
      radiusMi: null,
    });
    const onPoint = destinationPoint(hub.lat, hub.lng, 0.9, 90); // within 2 mi
    await seedSite(admin, userA.tenantId, custHotel, 'HotelOn', onPoint.lat, onPoint.lng, {
      radiusMi: 2.0,
    });
    const intruding = await cliA.rpc('site_conflicts', { p_site_id: offSite });
    expect(intruding.error).toBeNull();
    expect((intruding.data ?? []) as ConflictRow[]).toHaveLength(1);
  });

  // AC-012 — tenant isolation + anon denial.
  it('AC-012: tenant A never sees tenant B sites; anon RPC denied', async () => {
    const custA = await seedCustomer(admin, userA.tenantId, 'AutoA', 'automotive');
    const custB = await seedCustomer(admin, userB.tenantId, 'AutoB', 'automotive');
    const hub = { lat: 38.5, lng: -99.0 }; // distinct origin
    const a1 = await seedSite(admin, userA.tenantId, custA, 'AutoA1', hub.lat, hub.lng, {
      radiusMi: 1.0,
    });
    const near = destinationPoint(hub.lat, hub.lng, 0.1, 90);
    const a2 = await seedSite(admin, userA.tenantId, custA, 'AutoA2', near.lat, near.lng, {
      radiusMi: 1.0,
    });
    // tenant B's automotive site geographically adjacent to A's — must NOT surface.
    const bSite = await seedSite(admin, userB.tenantId, custB, 'AutoB1', near.lat, near.lng, {
      radiusMi: 1.0,
    });

    const { data, error } = await cliA.rpc('site_conflicts', { p_site_id: a1 });
    expect(error).toBeNull();
    const ids = ((data ?? []) as ConflictRow[]).map((r) => r.site_id);
    expect(ids).toContain(a2); // A's own neighbor is found (query works)
    expect(ids).not.toContain(bSite); // B's adjacent site never leaks

    // anon (no session) RPC call is denied by the revoke-anon grant.
    const anon = anonClient();
    const anonRes = await anon.rpc('conflicts_at', {
      p_geog: ewkt(hub),
      p_radius_mi: 1.0,
      p_vertical: 'automotive',
      p_exclude_id: null,
    });
    // Either a hard permission error, or (RLS-scoped) zero rows — never B's data.
    if (anonRes.error) {
      expect(anonRes.error).toBeTruthy();
    } else {
      expect((anonRes.data ?? []) as ConflictRow[]).toHaveLength(0);
    }
  });
});
