import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import { MapboxOverlay } from '@deck.gl/mapbox';
import 'maplibre-gl/dist/maplibre-gl.css';
import { sitePinsLayer } from './sitePinsLayer';
import { siteZonesLayer } from './siteZonesLayer';
import { saturationLayer, prospectLayer } from './saturationLayer';
import type { SiteGeo } from '../lib/customers';
import type { CoverageCell, LatLng, ViewportBounds } from '../lib/coverage';

/**
 * The map shell (W1 AC-004/AC-010 reactive seam + W4 AS-T4 saturation mount).
 *
 * Renders a MapLibre map centered on CONUS using the OpenFreeMap `liberty` style
 * (no API key) and mounts a deck.gl `MapboxOverlay`. The overlay is held in a
 * ref created ONCE on map init and PERSISTS across renders; on every data change
 * the overlay's layers are refreshed via `overlay.setProps(...)`.
 *
 * Wave 4 extends the reactive layer array with the saturation WASH +
 * prospecting outlines mounted UNDER the W3 zones + pins (z-order is
 * load-bearing — AC-018/019), conditionally omitted so first paint is
 * byte-identical to W3 when no vertical is chosen / a toggle is off (AC-020).
 * It also adds the single debounced `moveend` viewport seam (AC-012) that drives
 * App's viewport-bounded recompute, and an optional `flyToTarget` ease for the
 * AS-T6 "jump to nearest open area" action.
 */
export function MapShell({
  sites,
  conflictIds,
  cells = [],
  openCells = [],
  selectedVertical = null,
  showHeatmap = false,
  showProspecting = false,
  dataVersion = 0,
  resolution = 0,
  onViewportChange,
  flyToTarget = null,
}: {
  sites: SiteGeo[];
  conflictIds: Set<string>;
  cells?: CoverageCell[];
  openCells?: CoverageCell[];
  selectedVertical?: string | null;
  showHeatmap?: boolean;
  showProspecting?: boolean;
  dataVersion?: number;
  resolution?: number;
  onViewportChange?: (
    bounds: ViewportBounds,
    zoom: number,
    center: LatLng,
  ) => void;
  flyToTarget?: LatLng | null;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const overlayRef = useRef<MapboxOverlay | null>(null);

  // Keep the latest onViewportChange in a ref so the single `moveend` binding
  // (established once below) always calls the current callback WITHOUT rebinding
  // the listener every render (never per frame — AC-012).
  const onViewportChangeRef = useRef(onViewportChange);
  useEffect(() => {
    onViewportChangeRef.current = onViewportChange;
  }, [onViewportChange]);

  // Create the map + overlay ONCE; bind the single debounced viewport seam.
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

    // Created with empty-DATA W3 layers (zones under pins); the reactive effect
    // below immediately populates them and conditionally prepends the W4 wash.
    const overlay = new MapboxOverlay({
      layers: [siteZonesLayer([], new Set()), sitePinsLayer([])],
    });
    overlayRef.current = overlay;
    map.addControl(overlay);

    // AC-012: a SINGLE debounced (~200 ms) `moveend` binding emits the current
    // viewport (bounds + zoom + center). The recompute it triggers lives in App
    // — never in a render body / per-frame callback.
    let debounceTimer: ReturnType<typeof setTimeout> | null = null;
    const emitViewport = (): void => {
      const b = map.getBounds();
      const c = map.getCenter();
      onViewportChangeRef.current?.(
        { west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() },
        map.getZoom(),
        { lat: c.lat, lng: c.lng },
      );
    };
    const handleMoveEnd = (): void => {
      if (debounceTimer) {
        clearTimeout(debounceTimer);
      }
      debounceTimer = setTimeout(emitViewport, 200);
    };
    map.on('moveend', handleMoveEnd);
    // Emit once after the initial load so App has a viewport to compute against
    // the moment a vertical is chosen.
    map.on('load', emitViewport);

    return () => {
      if (debounceTimer) {
        clearTimeout(debounceTimer);
      }
      map.remove();
      mapRef.current = null;
      overlayRef.current = null;
    };
  }, []);

  // Reactive layer refresh (zones under pins; the W4 wash under both). Conditional
  // spread (AC-020): the saturation wash only when the heatmap is on AND a
  // vertical is chosen; the prospect outlines only when prospecting is on AND a
  // vertical is chosen — omitted ENTIRELY otherwise, so first paint == W3. Never
  // per frame — only on data / flag change.
  useEffect(() => {
    const trigger = { selectedVertical, dataVersion, resolution };
    overlayRef.current?.setProps({
      layers: [
        ...(showHeatmap && selectedVertical ? [saturationLayer(cells, trigger)] : []),
        ...(showProspecting && selectedVertical ? [prospectLayer(openCells, trigger)] : []),
        siteZonesLayer(sites, conflictIds),
        sitePinsLayer(sites),
      ],
    });
  }, [
    sites,
    conflictIds,
    cells,
    openCells,
    selectedVertical,
    showHeatmap,
    showProspecting,
    dataVersion,
    resolution,
  ]);

  // AS-T6 hook: ease to a requested target (the nearest open cell centroid).
  useEffect(() => {
    if (flyToTarget && mapRef.current) {
      mapRef.current.easeTo({
        center: [flyToTarget.lng, flyToTarget.lat],
        duration: 600,
      });
    }
  }, [flyToTarget]);

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
