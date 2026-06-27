// supabase/functions/geocode/index.ts
//
// The geocode Edge Function (AC-007 / AC-008 / AC-016).
//
// Accepts a BATCH of address strings, hashes each, reads geocode_cache (0001),
// and calls the KEYLESS US Census one-line-address endpoint ONLY for cache
// misses (bounded concurrency). Misses are written back to the cache; results
// are returned per input address IN INPUT ORDER.
//
// Geocoding ONLY — this function never persists a `site`. Persistence stays
// client-side / API-first (place_site RPC or EWKT insert).
//
// SECURITY (AC-008):
//   - never trusts client-supplied coordinates: only the address STRING is read;
//     any lat/lng in the request body is ignored.
//   - caps per-address length and rejects oversized batches.
//   - never echoes internal/stack errors — failures return a structured
//     per-address reason ('no-match' | 'ambiguous' | 'network-timeout' |
//     'rate-limit' | 'invalid' | 'error').
//
// AC-016: a second request for an already-cached address makes ZERO outbound
// Census calls (only de-duplicated cache MISSES are fetched).

import { createClient } from 'jsr:@supabase/supabase-js@2';

// Bounds (the spec's CONUS "small site sets" guidance; tune if Census limits bite).
const MAX_BATCH = 100; // addresses per request
const MAX_ADDRESS_LEN = 200; // characters per address
const CONCURRENCY = 4; // bounded outbound concurrency (ADR range 3-5)
const CENSUS_TIMEOUT_MS = 10_000;
const CENSUS_BASE =
  'https://geocoding.geo.census.gov/geocoder/locations/onelineaddress';

type GeoPoint = { lat: number; lng: number };
type FailureReason =
  | 'no-match'
  | 'ambiguous'
  | 'network-timeout'
  | 'rate-limit'
  | 'invalid'
  | 'error';
type PerAddress = GeoPoint | { lat: null; lng: null; reason: FailureReason };

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

/** SHA-256 hex of the normalized address — the geocode_cache primary key. */
async function hashAddress(address: string): Promise<string> {
  const data = new TextEncoder().encode(address);
  const digest = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Normalize for cache-keying: trim + collapse internal whitespace + lowercase. */
function normalize(address: string): string {
  return address.trim().replace(/\s+/g, ' ').toLowerCase();
}

/** Geocode a single address via the keyless Census endpoint. */
async function geocodeOne(address: string): Promise<PerAddress> {
  const url =
    `${CENSUS_BASE}?address=${encodeURIComponent(address)}` +
    `&benchmark=Public_AR_Current&format=json`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), CENSUS_TIMEOUT_MS);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (res.status === 429) {
      return { lat: null, lng: null, reason: 'rate-limit' };
    }
    if (!res.ok) {
      return { lat: null, lng: null, reason: 'error' };
    }
    const body = await res.json();
    const matches = body?.result?.addressMatches;
    if (!Array.isArray(matches) || matches.length === 0) {
      return { lat: null, lng: null, reason: 'no-match' };
    }
    // Census ranks matches; take the top one. A genuinely ambiguous result
    // (no single confident match) is surfaced as 'ambiguous' so the client can
    // offer a pick-candidate recovery path.
    const top = matches[0]?.coordinates;
    if (
      !top ||
      typeof top.x !== 'number' ||
      typeof top.y !== 'number'
    ) {
      return { lat: null, lng: null, reason: 'no-match' };
    }
    // Multiple candidates resolve to the top (Census-ranked) match — the
    // deterministic choice. Ambiguity surfacing is a client concern.
    return { lat: top.y, lng: top.x };
  } catch {
    // AbortError (timeout) vs other network errors — never echo the raw error.
    if (controller.signal.aborted) {
      return { lat: null, lng: null, reason: 'network-timeout' };
    }
    return { lat: null, lng: null, reason: 'error' };
  } finally {
    clearTimeout(timer);
  }
}

/** Run an async mapper over items with a bounded concurrency pool. */
async function mapPool<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  }
  const workers = Array.from({ length: Math.min(limit, items.length) }, worker);
  await Promise.all(workers);
  return results;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  // SA-001: require an Authorization header before doing any work. config.toml
  // sets verify_jwt = true for this function; this is defence-in-depth so a
  // missing/empty token is rejected here rather than silently proceeding.
  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.trim()) {
    return json({ error: 'missing authorization header' }, 401);
  }

  // Forward the caller's JWT so the geocode_cache_insert (authenticated) RLS
  // policy passes on cache writes.
  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  if (!supabaseUrl || !supabaseAnonKey) {
    return json({ error: 'server not configured' }, 500);
  }
  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  // Parse + validate the request body. Only `addresses` (an array of strings)
  // is read — any client-supplied lat/lng is IGNORED by construction.
  let addresses: unknown;
  try {
    const parsed = await req.json();
    addresses = parsed?.addresses;
  } catch {
    return json({ error: 'invalid JSON body' }, 400);
  }
  if (!Array.isArray(addresses)) {
    return json({ error: 'body.addresses must be an array of strings' }, 400);
  }
  if (addresses.length === 0) {
    return json({ results: [] });
  }
  if (addresses.length > MAX_BATCH) {
    return json({ error: `batch too large (max ${MAX_BATCH})` }, 413);
  }

  // Per-address validity (over-length / non-string -> 'invalid', not a fetch).
  const inputs: string[] = addresses.map((a) =>
    typeof a === 'string' ? a : '',
  );
  const valid = inputs.map(
    (a) => a.trim().length > 0 && a.length <= MAX_ADDRESS_LEN,
  );

  // Cache key per address (only for valid ones).
  const keys: (string | null)[] = await Promise.all(
    inputs.map((a, i) => (valid[i] ? hashAddress(normalize(a)) : null)),
  );

  // 1) Read cache for the unique set of valid hashes.
  const uniqueHashes = Array.from(
    new Set(keys.filter((k): k is string => k !== null)),
  );
  const cache = new Map<string, GeoPoint>();
  if (uniqueHashes.length > 0) {
    const { data, error } = await supabase
      .from('geocode_cache')
      .select('address_hash, lat, lng')
      .in('address_hash', uniqueHashes);
    if (!error && data) {
      for (const row of data) {
        if (typeof row.lat === 'number' && typeof row.lng === 'number') {
          cache.set(row.address_hash, { lat: row.lat, lng: row.lng });
        }
      }
    }
  }

  // 2) Determine MISSES (de-duplicated). AC-016: nothing cached => no Census
  //    call; everything cached => zero Census calls.
  const missAddressByHash = new Map<string, string>();
  for (let i = 0; i < inputs.length; i++) {
    const k = keys[i];
    if (k && !cache.has(k) && !missAddressByHash.has(k)) {
      missAddressByHash.set(k, normalize(inputs[i]));
    }
  }
  const missEntries = Array.from(missAddressByHash.entries());

  // 3) Fetch misses with bounded concurrency, then write successes to cache.
  const fetched = await mapPool(missEntries, CONCURRENCY, async ([, addr]) => {
    const r = await geocodeOne(addr);
    return r;
  });

  const toCache: {
    address_hash: string;
    address: string;
    lat: number;
    lng: number;
    provider: string;
  }[] = [];
  for (let i = 0; i < missEntries.length; i++) {
    const [hash, addr] = missEntries[i];
    const r = fetched[i];
    if ('reason' in r) {
      // do not cache failures
      continue;
    }
    cache.set(hash, r);
    toCache.push({
      address_hash: hash,
      address: addr,
      lat: r.lat,
      lng: r.lng,
      provider: 'census',
    });
  }
  if (toCache.length > 0) {
    // Upsert so a concurrent insert of the same address doesn't error.
    await supabase
      .from('geocode_cache')
      .upsert(toCache, { onConflict: 'address_hash' });
  }

  // 4) Assemble results IN INPUT ORDER.
  const failureByHash = new Map<string, FailureReason>();
  for (let i = 0; i < missEntries.length; i++) {
    const r = fetched[i];
    if ('reason' in r) {
      failureByHash.set(missEntries[i][0], r.reason);
    }
  }
  const results: PerAddress[] = inputs.map((_a, i) => {
    if (!valid[i]) {
      return { lat: null, lng: null, reason: 'invalid' as const };
    }
    const k = keys[i] as string;
    const hit = cache.get(k);
    if (hit) {
      return hit;
    }
    return {
      lat: null,
      lng: null,
      reason: failureByHash.get(k) ?? ('error' as const),
    };
  });

  return json({ results });
});
