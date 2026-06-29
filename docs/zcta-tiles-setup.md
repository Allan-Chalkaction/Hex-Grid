# ZCTA tiles setup — operator runbook (Wave 5 reference-overlays)

The ZIP / ZCTA boundary overlay renders from a **MapLibre-native vector source**
read from the `VITE_ZCTA_TILES_URL` env var. CC cannot fabricate or host a tile
source, so this is an **operator dependency**: until you provision one, the ZIP
toggle ships **disabled with a helper note** (graceful degrade) — the capitals,
metros, and per-vertical pin layers all work with zero setup.

This runbook builds a self-hosted PMTiles archive from Census TIGER ZCTA5 and
points the env var at it. (Alternative: point `VITE_ZCTA_TILES_URL` at any
third-party ZCTA vector tileset's TileJSON — any token rides in that URL via the
env var; **never** commit it.)

## 1. Get the source geometry

Download the Census TIGER/Line ZCTA5 (2020) shapefile:

- <https://www2.census.gov/geo/tiger/TIGER2020/ZCTA520/tl_2020_us_zcta520.zip>

Unzip → `tl_2020_us_zcta520.shp` (the national ZCTA5 polygons; the id property is
`ZCTA5CE20` — the key `zctaSource.ts` reads first, with `GEOID20` + a 5-digit
probe as fallbacks).

## 2. Build vector tiles with tippecanoe

[tippecanoe](https://github.com/felt/tippecanoe) (`brew install tippecanoe`)
turns the polygons into a `.pmtiles` archive. The `-l zcta` is **load-bearing**:
`zctaSource.ts` pins the source-layer name to `zcta`.

```bash
# Shapefile → GeoJSON (ogr2ogr ships with GDAL: brew install gdal)
ogr2ogr -t_srs EPSG:4326 -f GeoJSON zcta.geojson tl_2020_us_zcta520.shp

# GeoJSON → PMTiles (simplify low zooms; keep the ZCTA5CE20 property)
tippecanoe \
  -o zcta.pmtiles \
  -l zcta \
  -zg --drop-densest-as-needed \
  --coalesce-densest-as-needed \
  --extend-zooms-if-still-dropping \
  -y ZCTA5CE20 -y GEOID20 \
  zcta.geojson
```

## 3. Host it on an HTTP-Range-capable bucket

PMTiles serves tile ranges over HTTP Range requests, so the host MUST support
`Range:` (Supabase Storage public buckets, S3, R2, GCS, most CDNs do):

```bash
# Example: Supabase Storage public bucket
supabase storage cp zcta.pmtiles ss:///public/zcta.pmtiles
# → public URL, e.g. https://<project>.supabase.co/storage/v1/object/public/zcta.pmtiles
```

## 4. Set the env var

In `.env` (gitignored — never commit it):

```
VITE_ZCTA_TILES_URL=pmtiles://https://<project>.supabase.co/storage/v1/object/public/zcta.pmtiles
```

> The app uses the `pmtiles://` MapLibre protocol for a PMTiles archive. If you
> serve a classic TileJSON endpoint instead, set the plain `https://…/zcta.json`
> TileJSON URL. Either way the source-layer must be named `zcta` (or adjust the
> `ZCTA_SOURCE_LAYER` constant in `src/components/zctaSource.ts`).

Restart `vite` (env vars are read at build/serve start). `zctaConfigured()` now
returns true → the ZIP toggle enables. Toggle it on, click a boundary → a popup
reads "ZIP {zcta5}".

## 5. Verify

- ZIP toggle is **enabled** (not dimmed, no helper note).
- Toggling it shows a subtle grey boundary mesh **beneath** the pins/zones/wash.
- Clicking a boundary shows a "ZIP …" popup.
- Zooming the basemap still reads through the ~0.04 fill.

## Notes

- **Token discipline (rules-security):** any access token rides inside
  `VITE_ZCTA_TILES_URL`; it is never hardcoded in source and `.env` stays
  gitignored. `.env.example` documents only the variable name.
- **Decennial refresh:** rebuild from the next TIGER ZCTA vintage and re-upload —
  no code change.
- **Property-name drift:** if a third-party tileset uses a different ZCTA5 key,
  `resolveZcta5()` already probes for the first 5-digit property; add the exact
  key to `ZCTA5_KEYS` in `zctaSource.ts` for a direct hit.
