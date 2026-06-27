import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { MapboxOverlay } from '@deck.gl/mapbox';
import 'maplibre-gl/dist/maplibre-gl.css';
import { sitePinsLayer } from './sitePinsLayer';
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
export function MapShell({ sites }: { sites: SiteGeo[] }) {
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

    // Created with an empty-DATA pin layer (not an empty `layers` array); the
    // reactive effect below immediately populates it from `sites`.
    const overlay = new MapboxOverlay({
      layers: [sitePinsLayer([])],
    });
    overlayRef.current = overlay;
    map.addControl(overlay);

    return () => {
      map.remove();
      mapRef.current = null;
      overlayRef.current = null;
    };
  }, []);

  // Reactive layer refresh: rebuild the pin layer whenever `sites` changes.
  useEffect(() => {
    overlayRef.current?.setProps({ layers: [sitePinsLayer(sites)] });
  }, [sites]);

  return (
    <div
      ref={containerRef}
      // The map canvas is a known a11y-difficult surface; a11y is scoped to the
      // surrounding chrome. It is not a keyboard trap (focus passes through).
      aria-label="Map of the continental United States"
      style={{ position: 'absolute', inset: 0 }}
    />
  );
}
