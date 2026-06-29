import maplibregl from 'maplibre-gl';

/**
 * ZCTA (ZIP-boundary) overlay — MapLibre-native vector source (RO-T4 —
 * AC-012/013/014). NOT a deck.gl MVTLayer (ADR-005 D1): the basemap is already
 * MapLibre vector, so a native source is idiomatic, gets GPU tile rendering, and
 * provides `queryRenderedFeatures` click-picking for free; the fill/line sit
 * BENEATH the deck.gl overlay (ZIP below pins) automatically.
 *
 * **Operator dependency (FLAGGED).** The tileset URL is read ONLY from
 * `VITE_ZCTA_TILES_URL` (rules-security — token rides in the env URL, never
 * hardcoded/committed). When unset, every entry point is a NO-OP: no source, no
 * request, no console error, no layout shift — the panel renders the ZIP toggle
 * `disabled` with a helper note (the graceful-degrade path). Live tile rendering
 * + the click popup are unverifiable locally without a provisioned source; the
 * build verifies the configured WIRING + the unset/disabled path. Runbook:
 * `docs/zcta-tiles-setup.md`.
 */

/** The MapLibre source id + the two style-layer ids. */
const SOURCE_ID = 'zcta-src';
const FILL_LAYER = 'zcta-fill';
const LINE_LAYER = 'zcta-line';

/**
 * The vector-tile source-layer name. Pin it to what the operator's tippecanoe
 * build emits (`-l zcta` in the runbook). A single constant keeps it adjustable
 * for a third-party tileset without touching the wiring.
 */
const ZCTA_SOURCE_LAYER = 'zcta';

/**
 * The ZCTA5 id-property key, pinned to the common TIGER-built names, with a
 * 5-digit-property probe fallback (the key varies by tileset — ADR-005 Risk).
 */
const ZCTA5_KEYS = ['ZCTA5CE20', 'GEOID20', 'ZCTA5CE10', 'GEOID10'] as const;

/** The configured tileset URL (env-only), or undefined. */
export function zctaTilesUrl(): string | undefined {
  return import.meta.env.VITE_ZCTA_TILES_URL || undefined;
}

/** True iff `VITE_ZCTA_TILES_URL` is configured (drives the toggle enable). */
export function zctaConfigured(): boolean {
  return !!import.meta.env.VITE_ZCTA_TILES_URL;
}

/**
 * The human label for the configured ZCTA source kind (EH-T3 / AC-009). Returns
 * `VITE_ZCTA_SOURCE_LABEL` when set (e.g. `"USPS ZIP"` for a true-USPS tileset),
 * else the honest default `"ZCTA approximation"` (Census ZCTA boundaries are an
 * APPROXIMATION of USPS ZIP areas). Mirrors the `zctaTilesUrl()`/`zctaConfigured()`
 * env-read precedent.
 */
export function zctaSourceLabel(): string {
  return import.meta.env.VITE_ZCTA_SOURCE_LABEL || 'ZCTA approximation';
}

/**
 * Resolve a feature's ZCTA5 zip from its properties: try the pinned keys first,
 * then probe for the first 5-digit property value. Returns null when none found
 * (the click is then a silent no-op).
 */
export function resolveZcta5(
  props: Record<string, unknown> | null | undefined,
): string | null {
  if (!props) {
    return null;
  }
  const asZip = (v: unknown): string | null => {
    if (typeof v === 'string' && /^\d{5}$/.test(v)) {
      return v;
    }
    if (typeof v === 'number' && /^\d{5}$/.test(String(v))) {
      return String(v);
    }
    return null;
  };
  for (const k of ZCTA5_KEYS) {
    const z = asZip(props[k]);
    if (z) {
      return z;
    }
  }
  for (const v of Object.values(props)) {
    const z = asZip(v);
    if (z) {
      return z;
    }
  }
  return null;
}

/**
 * Add the ZCTA vector source + `zcta-fill`/`zcta-line` style layers (initially
 * hidden) and bind the click-to-zip handler. NO-OP when unconfigured (AC-012) or
 * the style is not yet loaded (call from `map.on('load')`); idempotent (returns
 * if the source already exists). The fill is near-invisible (a click target, not
 * a tint); the line is a subtle zoom-interpolated neutral grey (AC-013).
 */
export function addZctaSource(map: maplibregl.Map): void {
  if (!zctaConfigured()) {
    return; // graceful degrade — no source, no request, no error.
  }
  if (!map.isStyleLoaded()) {
    return; // caller mounts on load; a too-early call is a safe no-op.
  }
  if (map.getSource(SOURCE_ID)) {
    return; // already mounted (idempotent across re-renders).
  }

  map.addSource(SOURCE_ID, {
    type: 'vector',
    url: zctaTilesUrl(),
  });

  const fillLayer: maplibregl.AddLayerObject = {
    id: FILL_LAYER,
    type: 'fill',
    source: SOURCE_ID,
    'source-layer': ZCTA_SOURCE_LAYER,
    layout: { visibility: 'none' },
    paint: {
      'fill-color': '#6b7280',
      'fill-opacity': 0.04,
    },
  };
  const lineLayer: maplibregl.AddLayerObject = {
    id: LINE_LAYER,
    type: 'line',
    source: SOURCE_ID,
    'source-layer': ZCTA_SOURCE_LAYER,
    layout: { visibility: 'none' },
    paint: {
      'line-color': '#6b7280',
      'line-opacity': ['interpolate', ['linear'], ['zoom'], 4, 0.25, 8, 0.5],
      'line-width': ['interpolate', ['linear'], ['zoom'], 4, 0.4, 10, 1],
    },
  };
  map.addLayer(fillLayer);
  map.addLayer(lineLayer);

  // Click-to-zip: query the fill layer at the click point. When the layer is
  // hidden (toggle off) MapLibre returns no features → a silent no-op (AC-014).
  map.on('click', (e) => {
    const features = map.queryRenderedFeatures(e.point, {
      layers: [FILL_LAYER],
    });
    const zip = resolveZcta5(features[0]?.properties as Record<string, unknown>);
    if (!zip) {
      return;
    }
    new maplibregl.Popup({ closeButton: true })
      .setLngLat(e.lngLat)
      .setHTML(`<span class="zcta-popup">ZIP <strong>${zip}</strong></span>`)
      .addTo(map);
  });
}

/**
 * Flip the ZCTA fill+line `visibility` (cheaper than add/remove). NO-OP when the
 * layers are absent (unconfigured / not yet mounted) — AC-013.
 */
export function setZctaVisible(map: maplibregl.Map, on: boolean): void {
  const v = on ? 'visible' : 'none';
  for (const id of [FILL_LAYER, LINE_LAYER]) {
    if (map.getLayer(id)) {
      map.setLayoutProperty(id, 'visibility', v);
    }
  }
}
