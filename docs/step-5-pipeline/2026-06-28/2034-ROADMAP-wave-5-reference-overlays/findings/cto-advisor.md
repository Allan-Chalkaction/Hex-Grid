# CTO Advisory — Wave 5 (reference-overlays) · Recommendation: SIMPLIFY (GO, trimmed) · Confidence: High
Map-population/orientation serving the core mission; capitals+metros+vertical-filter are low-risk extensions of existing patterns. Built reality uses a KEYLESS tile source (OpenFreeMap liberty, MapShell:76) — binding precedent.

## Fork dispositions
- **ZIP/ZCTA overlay = the load-bearing operator dependency.** No robust free keyless HOSTED ZCTA vector-tile endpoint; full ~33k-polygon GeoJSON rejected (MB-scale, main-thread stall). Build with graceful degradation (architect): env-var source (VITE_ZCTA_TILES_URL), default self-hosted PMTiles (Census TIGER ZCTA5 → tippecanoe → public bucket); toggle DISABLED + "configure a ZCTA source" when unset. FLAG: full ZIP verification needs the operator to provide a tileset URL.
- **Capitals (50) + metros (CBSA≥250k ~110-180): static repo JSON** (src/data/*.json, <25KB) → deck.gl TextLayer.
- **Vertical filter: ONE shared selectedVertical** drives BOTH W4 saturation AND the pin filter — NO second vertical control. Color/icon-by-vertical (stable palette over VERTICAL_OPTIONS) + legend.
- **Layer-toggle UI: ONE consolidated panel** — repurpose the W4 SaturationPanel → "Map layers" with overlay toggles (capitals/metros/zones/saturation/prospecting/ZIP) sectioned; left CRUD panel untouched. Avoid panel/control proliferation (the main design-debt risk).
- Scope: all four buildable now (ZIP degrades gracefully); no migration; no DB surface.

Effort Medium (3-5d). Risk concentrated in ZIP tile source (handled via degradation). Preserve the W4 a11y contract through the panel refactor.
