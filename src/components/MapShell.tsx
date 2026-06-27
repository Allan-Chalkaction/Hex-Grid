import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { MapboxOverlay } from '@deck.gl/mapbox';
import 'maplibre-gl/dist/maplibre-gl.css';

/**
 * The map shell (AC-004).
 *
 * Renders a MapLibre map centered on CONUS using the OpenFreeMap `liberty` style
 * (no API key required) and mounts a deck.gl `MapboxOverlay` (the `@deck.gl/mapbox`
 * interop) as a MapLibre control. The overlay carries one empty placeholder layer
 * — it proves the deck.gl pipeline is wired without rendering any W1 data. Must
 * mount with no console errors.
 */
export function MapShell() {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);

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

    // deck.gl interop: one empty placeholder layer proves the pipeline (AC-004).
    const overlay = new MapboxOverlay({ layers: [] });
    map.addControl(overlay);

    return () => {
      map.remove();
      mapRef.current = null;
    };
  }, []);

  return (
    <div
      ref={containerRef}
      // The map canvas itself is a known a11y-difficult surface; W1 scopes a11y to
      // the surrounding chrome. It is not a keyboard trap (focus passes through).
      aria-label="Map of the continental United States"
      style={{ position: 'absolute', inset: 0 }}
    />
  );
}
