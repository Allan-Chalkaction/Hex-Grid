import { supabase } from './supabaseClient';

/**
 * The geocoding seam (AC-006), following W1's R5 pluggable-seam pattern
 * (`auth.ts` / `tenant.ts`): export the INTERFACE consumers depend on plus a
 * single concrete implementation constructed ONCE at the seam. Consumers
 * (`customers.ts`, `csvImport.ts`) depend on the `Geocoder` type and the shared
 * `defaultGeocoder` value — never on the concrete class by name — so the
 * provider can later be swapped without touching a consumer.
 */

export interface GeoPoint {
  lat: number;
  lng: number;
}

/** Why an address could not be geocoded (drives the per-site recovery UI). */
export type GeocodeFailureReason =
  | 'no-match'
  | 'ambiguous'
  | 'network-timeout'
  | 'rate-limit'
  | 'invalid'
  | 'error';

/** A per-address result carrying the failure class when `point` is null. */
export interface GeocodeResult {
  point: GeoPoint | null;
  reason: GeocodeFailureReason | null;
}

/**
 * The seam contract. `geocode` is the AC-006 core contract
 * (`(addresses: string[]) => Promise<({lat,lng}|null)[]>`, input-order);
 * `geocodeDetailed` adds the per-address failure class consumers need to render
 * the four geocode-status recovery paths (AC-012).
 */
export interface Geocoder {
  geocode(addresses: string[]): Promise<(GeoPoint | null)[]>;
  geocodeDetailed(addresses: string[]): Promise<GeocodeResult[]>;
}

/** Shape of one element of the Edge Function's `results` array. */
type EdgeResult =
  | { lat: number; lng: number }
  | { lat: null; lng: null; reason: GeocodeFailureReason };

/**
 * The Census-backed implementation: invokes the `geocode` Edge Function
 * (CG-T2), which does cache-first batch geocoding and returns one result per
 * input address IN INPUT ORDER. Constructed once below as `defaultGeocoder`.
 */
class EdgeGeocoder implements Geocoder {
  async geocodeDetailed(addresses: string[]): Promise<GeocodeResult[]> {
    if (addresses.length === 0) {
      return [];
    }

    const { data, error } = await supabase.functions.invoke('geocode', {
      body: { addresses },
    });

    if (error || !data || !Array.isArray((data as { results?: unknown }).results)) {
      // Whole-batch failure: surface a uniform 'error' per address so callers
      // still get an input-order array and can flag every site.
      return addresses.map(() => ({ point: null, reason: 'error' as const }));
    }

    const results = (data as { results: EdgeResult[] }).results;
    return addresses.map((_addr, i) => {
      const r = results[i];
      if (r && typeof r.lat === 'number' && typeof r.lng === 'number') {
        return { point: { lat: r.lat, lng: r.lng }, reason: null };
      }
      const reason =
        r && 'reason' in r && r.reason ? r.reason : ('error' as const);
      return { point: null, reason };
    });
  }

  async geocode(addresses: string[]): Promise<(GeoPoint | null)[]> {
    const detailed = await this.geocodeDetailed(addresses);
    return detailed.map((r) => r.point);
  }
}

/**
 * The single concrete geocoder instance. Consumers import THIS (typed as the
 * `Geocoder` interface) — not the `EdgeGeocoder` class — keeping the seam
 * swappable.
 */
export const defaultGeocoder: Geocoder = new EdgeGeocoder();
