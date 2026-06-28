import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import { createHash } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { hasDb, adminClient } from '../helpers/integration';

// AC-016 — "a repeated geocode of the same address makes ZERO outbound Census
// calls; the second call is served from geocode_cache."
//
// The geocode Edge Function (supabase/functions/geocode/index.ts) is cache-first:
// it normalizes + SHA-256-hashes each address, reads geocode_cache by
// address_hash, fetches the keyless US Census ONLY on a miss, then writes the
// result back. The cache is DELIBERATELY tenant-shared (no tenant_id — 0001).
//
// This suite proves the cache-first contract over the REAL local Supabase stack
// + the live `geocode` function. The definitive "zero Census call" proof is the
// SENTINEL test: we overwrite the cached row with coords Census could never
// return, then assert the function returns those exact coords — only possible if
// it read the cache and skipped the outbound call.
//
// CALLER / AUTH (load-bearing — verified against this local stack):
//   * geocode_cache RLS (0001: geocode_cache_read / geocode_cache_insert) is
//     `to authenticated using (auth.uid() is not null)`. The function forwards
//     the CALLER's JWT to its cache reads + writes, so the cache-first path only
//     engages for a caller whose role can read/write geocode_cache. A bare
//     anon-key call (role=anon, no auth.uid()) is denied by that RLS and so
//     misses + hits Census on EVERY call — the cache never engages.
//   * The function gateway has verify_jwt=true and validates with the legacy
//     HS256 JWT secret. signInWithPassword on this stack issues ES256 (asymmetric
//     signing-keys) user tokens, which the gateway rejects ("Invalid JWT"). So a
//     real signed-in user token cannot pass the gateway here, and JWT_SECRET is
//     not exported by the integration run command (no token minting available).
//   * Therefore the suite calls with SERVICE_ROLE_KEY: it is HS256 (gateway
//     accepts it) and its role bypasses RLS on geocode_cache, so the function's
//     cache read + write engage exactly as they do for an authenticated app user.
//     The cache-first proof (sentinel) is independent of which role read the row.

const API_URL = process.env.API_URL ?? '';
const ANON_KEY = process.env.ANON_KEY ?? '';
const SERVICE_ROLE_KEY = process.env.SERVICE_ROLE_KEY ?? '';

// --- Replicate the Edge Function's cache-key derivation EXACTLY. ---
// Source: supabase/functions/geocode/index.ts
//   normalize()   L68-70: trim + collapse internal whitespace + lowercase
//   hashAddress() L59-65: SHA-256 over the UTF-8 bytes, lowercase hex
// (node's createHash with 'utf8' input matches Deno's TextEncoder + crypto.subtle
// SHA-256 + hex byte-join byte-for-byte). If this replication were wrong, the
// SENTINEL test would target a different row, the function would MISS, and Census
// would return the real coords (!= sentinel) — so the sentinel test is itself the
// proof that the hash matches.
function normalize(address: string): string {
  return address.trim().replace(/\s+/g, ' ').toLowerCase();
}
function hashAddress(address: string): string {
  return createHash('sha256').update(normalize(address), 'utf8').digest('hex');
}

// A distinctive REAL address: the live Census MISS path resolves to true coords
// (~38.9 / ~-77.0), which are clearly distinct from the sentinel below — so a
// cache HIT returning the sentinel is unambiguous proof of the cache-first path.
const TEST_ADDRESS = '1600 Pennsylvania Avenue NW, Washington, DC 20500';
const TEST_HASH = hashAddress(TEST_ADDRESS);

// Coords Census would NEVER return for the test address (mid-ocean off Africa).
const SENTINEL = { lat: 1.2345678, lng: 2.3456789 };

interface PerAddress {
  lat: number | null;
  lng: number | null;
  reason?: string;
}

async function postGeocode(body: unknown): Promise<Response | null> {
  try {
    return await fetch(`${API_URL}/functions/v1/geocode`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: ANON_KEY,
        // SERVICE_ROLE_KEY — see CALLER / AUTH note above.
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      },
      body: JSON.stringify(body),
    });
  } catch {
    // Endpoint unreachable (edge_runtime down / connection refused).
    return null;
  }
}

/** Geocode a single address, returning the per-address result (or undefined). */
async function geocodeOne(address: string): Promise<{
  status: number;
  result: PerAddress | undefined;
}> {
  const res = await postGeocode({ addresses: [address] });
  if (!res) return { status: 0, result: undefined };
  const body = await res.json().catch(() => ({}));
  return { status: res.status, result: body?.results?.[0] };
}

/** Delete the cache row for the test address (service-role; RLS-bypassed). */
async function deleteTestRow(admin: SupabaseClient): Promise<void> {
  await admin
    .from('geocode_cache')
    .delete()
    .eq('address_hash', TEST_HASH)
    .then(undefined, () => undefined);
}

describe.skipIf(!hasDb)('AC-016 geocode cache-first (zero Census on hit)', () => {
  let admin: SupabaseClient;
  let reachable = false;

  beforeAll(async () => {
    admin = adminClient();
    // Reachability probe: empty batch returns 200 with NO Census call. Anything
    // other than 200 (null=threw, 404=not served, 503=edge_runtime down, 401=auth
    // misconfig) => skip with a clear message rather than producing confusing
    // assertion failures (mirrors the describe.skipIf(!hasDb) self-skip ethos).
    const probe = await postGeocode({ addresses: [] });
    reachable = probe !== null && probe.status === 200;
    // Start from a known-clean slate so the miss test exercises a real miss.
    await deleteTestRow(admin);
  });

  afterAll(async () => {
    // Never leave the sentinel (or any test row) behind — keeps reruns clean and
    // prevents a poisoned cache row leaking into other suites / app usage.
    if (admin) await deleteTestRow(admin);
  });

  it('miss → populates the cache from Census (positive path)', async (ctx) => {
    if (!reachable) {
      ctx.skip();
      return;
    }
    // Ensure a genuine miss.
    await deleteTestRow(admin);

    const { status, result } = await geocodeOne(TEST_ADDRESS);
    expect(status).toBe(200);
    // A plausible real result (not a failure reason, finite + in-range coords).
    expect(result).toBeDefined();
    expect(result?.reason).toBeUndefined();
    expect(typeof result?.lat).toBe('number');
    expect(typeof result?.lng).toBe('number');
    expect(Number.isFinite(result?.lat)).toBe(true);
    expect(Number.isFinite(result?.lng)).toBe(true);
    expect(result!.lat!).toBeGreaterThanOrEqual(-90);
    expect(result!.lat!).toBeLessThanOrEqual(90);
    expect(result!.lng!).toBeGreaterThanOrEqual(-180);
    expect(result!.lng!).toBeLessThanOrEqual(180);
    // Not the sentinel — this is a real Census result.
    expect(result!.lat!).not.toBe(SENTINEL.lat);

    // The cache row now exists for this hash (the function wrote it back).
    const { data, error } = await admin
      .from('geocode_cache')
      .select('address_hash, lat, lng')
      .eq('address_hash', TEST_HASH)
      .maybeSingle();
    expect(error).toBeNull();
    expect(data).not.toBeNull();
    expect(data?.address_hash).toBe(TEST_HASH);
    expect(typeof data?.lat).toBe('number');
    expect(typeof data?.lng).toBe('number');
  });

  it('hit → served from cache, ZERO Census call (sentinel proof)', async (ctx) => {
    if (!reachable) {
      ctx.skip();
      return;
    }
    // OVERWRITE the cached row with coords Census could never return. If the
    // function called Census it would return the real DC coords; returning the
    // sentinel proves it read the cache and made zero outbound calls.
    const { error: upErr } = await admin.from('geocode_cache').upsert(
      {
        address_hash: TEST_HASH,
        address: normalize(TEST_ADDRESS),
        lat: SENTINEL.lat,
        lng: SENTINEL.lng,
        provider: 'sentinel',
      },
      { onConflict: 'address_hash' },
    );
    expect(upErr).toBeNull();

    const { status, result } = await geocodeOne(TEST_ADDRESS);
    expect(status).toBe(200);
    expect(result).toBeDefined();
    expect(result?.reason).toBeUndefined();
    // EXACT sentinel match — the definitive AC-016 proof (no Census round-trip).
    expect(result?.lat).toBe(SENTINEL.lat);
    expect(result?.lng).toBe(SENTINEL.lng);
  });
});
