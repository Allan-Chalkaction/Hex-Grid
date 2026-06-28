import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { MapboxOverlay } from '@deck.gl/mapbox';
import 'maplibre-gl/dist/maplibre-gl.css';
import { sitePinsLayer } from './sitePinsLayer';
import { siteZonesLayer } from './siteZonesLayer';
import type { SiteGeo } from '../lib/customers';

/**
 * The map shell (AC-004 / AC-010 — reactive data seam).
 *
 * Renders a MapLibre map centered on CONUS using the OpenFreeMap `liberty` style
 * (no API key) and mounts a deck.gl `MapboxOverlay` carrying the `sitePinsLayer`.
 *
 * The overlay is held in a ref created ONCE on map init and PERSISTS across
 * renders. On every `sites` change the overlay's layers are refreshed via
 * `overlay.setProps(...)`, so a newly-added/geocoded site (or an edit/move)
 * re-renders its pin without a full page reload. The empty placeholder overlay
 * from W1 is gone — pins come from the lifted `sites` state owned by `App`.
 */
export function MapShell({
  sites,
  conflictIds,
}: {
  sites: SiteGeo[];
  conflictIds: Set<string>;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const overlayRef = useRef<MapboxOverlay | null>(null);

  // Create the map + overlay ONCE.
  useEffect(() => {
    if (!containerRef.current || mapRef.current) {
      return;
    }

    const map = new maplibregl.Map({
      container: containerRef.current,
      style: 'https://tiles.openfreemap.org/styles/liberty',
      center: [-98.5795, 39.8283], // CONUS centroid
      zoom: 4,
    });
    mapRef.current = map;

    // Created with empty-DATA layers (zones under pins; not an empty `layers`
    // array); the reactive effect below immediately populates them from `sites`.
    const overlay = new MapboxOverlay({
      layers: [siteZonesLayer([], new Set()), sitePinsLayer([])],
    });
    overlayRef.current = overlay;
    map.addControl(overlay);

    return () => {
      map.remove();
      mapRef.current = null;
      overlayRef.current = null;
    };
  }, []);

  // Reactive layer refresh: rebuild BOTH layers whenever `sites` or the derived
  // `conflictIds` change (zones under pins; AC-021/AC-024 passive recolor). Never
  // per frame — only on data change.
  useEffect(() => {
    overlayRef.current?.setProps({
      layers: [siteZonesLayer(sites, conflictIds), sitePinsLayer(sites)],
    });
  }, [sites, conflictIds]);

  return (
    <div
      ref={containerRef}
      // The map canvas is a known a11y-difficult surface; a11y is scoped to the
      // surrounding chrome. It is not a keyboard trap (focus passes through).
      // role="application" makes the aria-label reliably exposed (A11Y-011).
      role="application"
      aria-label="Map of the continental United States"
      style={{ position: 'absolute', inset: 0 }}
    />
  );
}
