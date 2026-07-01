import { useCallback, useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import { MapboxOverlay } from '@deck.gl/mapbox';
import type { PickingInfo } from 'deck.gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { sitePinsLayer } from './sitePinsLayer';
import { siteZonesLayer } from './siteZonesLayer';
import { addZctaSource, setZctaVisible } from './zctaSource';
import { buildDeckLayers } from './deckLayers';
import { restrictedAreaLabel, type SiteGeo } from '../lib/customers';
import type { CoverageCell, LatLng, ViewportBounds } from '../lib/coverage';

/** The hovered pin lifted out of deck.gl picking: the site + pointer coords. */
interface PinHover {
  object: SiteGeo;
  x: number;
  y: number;
}

/**
 * The map shell (W1 reactive seam + W4 saturation mount + ZCTA overlay).
 *
 * Renders a MapLibre map centered on CONUS using the OpenFreeMap `liberty` style
 * (no API key) and mounts a deck.gl `MapboxOverlay`. The overlay is held in a
 * ref created ONCE on map init and PERSISTS across renders; on every data change
 * the overlay's layers are refreshed via `overlay.setProps(...)`.
 *
 * The reactive seam carries:
 *   - **Color-by-vertical pins gated by the multi-select** via the `sitePinsLayer`
 *     signature (`selectedVerticals` — empty => no pins).
 *   - **A `Site zones` toggle** (`showZones`, default on) — the W3 zone circles,
 *     conditionally spread (additive; no W3/W4 logic change).
 *   - **The ZCTA boundary overlay** mounted as a MapLibre-NATIVE source (beneath
 *     the whole deck overlay → ZIP below pins), env-gated + graceful-degrade.
 *
 * The analysis overlays are conditionally spread, so with them off the deck array
 * is byte-identical to the base composition (AC-019).
 */

export function MapShell({
  sites,
  conflictIds,
  cells = [],
  openCells = [],
  selectedVerticals = [],
  showHeatmap = false,
  showProspecting = false,
  showZones = true,
  showZcta = false,
  dataVersion = 0,
  resolution = 0,
  onViewportChange,
  flyToTarget = null,
}: {
  sites: SiteGeo[];
  conflictIds: Set<string>;
  cells?: CoverageCell[];
  openCells?: CoverageCell[];
  selectedVerticals?: string[];
  showHeatmap?: boolean;
  showProspecting?: boolean;
  showZones?: boolean;
  showZcta?: boolean;
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

  // The hovered site pin → the info card (CG hover card). Null = nothing hovered
  // (no card). Lifted from deck.gl picking; cleared when picking misses.
  const [pinHover, setPinHover] = useState<PinHover | null>(null);

  // Stable hover handler (deck fires it with the picking info on pointer move).
  // Stable identity (no deps) means including it in the reactive-layer effect's
  // deps below never adds an extra layer rebuild — the layers refresh only on
  // data/flag change, as before. Set the card on a real pick; clear otherwise.
  const handlePinHover = useCallback((info: PickingInfo): void => {
    if (info.picked && info.object) {
      setPinHover({ object: info.object as SiteGeo, x: info.x, y: info.y });
    } else {
      setPinHover(null);
    }
  }, []);

  // Keep the latest onViewportChange in a ref so the single `moveend` binding
  // (established once below) always calls the current callback WITHOUT rebinding
  // the listener every render (never per frame — AC-012).
  const onViewportChangeRef = useRef(onViewportChange);
  useEffect(() => {
    onViewportChangeRef.current = onViewportChange;
  }, [onViewportChange]);

  // The current ZCTA toggle, read in the once-only load handler (so the initial
  // visibility matches App state without re-binding the load listener).
  const showZctaRef = useRef(showZcta);
  useEffect(() => {
    showZctaRef.current = showZcta;
  }, [showZcta]);

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
    // the moment a vertical is chosen. RO-T5: also mount the ZCTA native source
    // (no-op when unconfigured) BENEATH the deck overlay and apply the current
    // ZIP visibility.
    map.on('load', () => {
      emitViewport();
      addZctaSource(map);
      setZctaVisible(map, showZctaRef.current);
    });

    return () => {
      if (debounceTimer) {
        clearTimeout(debounceTimer);
      }
      map.remove();
      mapRef.current = null;
      overlayRef.current = null;
    };
  }, []);

  // Reactive deck layer refresh — the load-bearing z-order via the pure builder
  // (AC-019). Conditional spread keeps first paint byte-identical to W4 when all
  // reference toggles are off. Never per frame — only on data / flag change.
  useEffect(() => {
    overlayRef.current?.setProps({
      layers: buildDeckLayers({
        sites,
        conflictIds,
        cells,
        openCells,
        selectedVerticals,
        showHeatmap,
        showProspecting,
        showZones,
        dataVersion,
        resolution,
        onSitePinHover: handlePinHover,
      }),
    });
  }, [
    sites,
    conflictIds,
    cells,
    openCells,
    selectedVerticals,
    showHeatmap,
    showProspecting,
    showZones,
    dataVersion,
    resolution,
    handlePinHover,
  ]);

  // RO-T5: flip the ZCTA native-layer visibility on toggle (MapLibre-native, not
  // the deck array). No-op when the layers are absent (unconfigured / pre-load).
  useEffect(() => {
    if (mapRef.current) {
      setZctaVisible(mapRef.current, showZcta);
    }
  }, [showZcta]);

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
    // A positioned wrapper so the absolutely-positioned hover card anchors to the
    // map bounds (deck.gl picking x/y are pixels relative to this surface). The
    // wrapper spans the same box the map container used to occupy.
    <div style={{ position: 'absolute', inset: 0 }}>
      <div
        ref={containerRef}
        // The map canvas is a known a11y-difficult surface; a11y is scoped to the
        // surrounding chrome. It is not a keyboard trap (focus passes through).
        // role="application" makes the aria-label reliably exposed (A11Y-011).
        role="application"
        aria-label="Map of the United States"
        style={{ position: 'absolute', inset: 0 }}
      />
      {/*
        The site hover card (CG hover card). A canvas-pin hover is inherently
        mouse-only; the accessible data path already exists (the Sites table +
        customer list expose name + radius), so this is a pure mouse convenience
        — same posture as the ZCTA click popup. It is aria-hidden + has
        pointer-events:none (CSS) so it never blocks deck picking and is invisible
        to keyboard/SR users. Offset a few px off the pointer; rendered only while
        something is hovered.
      */}
      {pinHover && (
        <div
          className="site-hover-card"
          aria-hidden="true"
          style={{ left: pinHover.x + 12, top: pinHover.y + 12 }}
        >
          <div className="site-hover-card__brand">
            {pinHover.object.customer_name}
          </div>
          <div className="site-hover-card__name">{pinHover.object.name}</div>
          {pinHover.object.address && (
            <div className="site-hover-card__address">
              {pinHover.object.address}
            </div>
          )}
          <div className="site-hover-card__radius">
            {restrictedAreaLabel(pinHover.object)}
          </div>
        </div>
      )}
    </div>
  );
}
