# Wave 5 stacked-layer legibility checklist (for @ui-review — AC-023)

Run the app with **capitals + metros + pins + zones + saturation all on** (and a
configured `VITE_ZCTA_TILES_URL` if available), then confirm the four legibility
checks below. The z-order is fixed by `buildDeckLayers` (deckLayers.ts):
ZCTA (MapLibre-native, bottom) → wash → prospect → zones → pins → metro labels →
capital labels (top).

1. **Label halos** — capitals (`[40,40,40]` 13px bold) and metros (`[85,85,85]`
   11px) carry a 2px white sdf halo and stay readable over the basemap, over a
   colored pin, and over the saturation wash. Capitals read as the bolder/darker
   tier; capitals win a collision over an overlapping metro.
2. **Pin crispness** — pins are opaque per-vertical fills with a 1px white stroke
   above the translucent zones/wash; they stay crisp and never read as a conflict
   (red), a saturation bucket (blue), or a prospect cell (green).
3. **Palette ↔ reserved separation** — no vertical pin color is confusable with
   conflict-red / saturation-blue / prospect-green (the palette excludes those
   triples by construction — verticalStyle.test.ts AC-002).
4. **ZIP subtlety** — `zcta-fill` (~0.04 opacity) + `zcta-line` (zoom-interpolated
   faint `#6b7280`) stay subtle: pins, zones, wash, and labels all read above it,
   and the basemap reads through the fill. (Operator-dependent: requires a
   provisioned `VITE_ZCTA_TILES_URL`; otherwise the ZIP toggle is disabled and
   this check is N/A until provisioning.)

> Operator-dependency note: live ZCTA tile rendering + the click-to-zip popup are
> unverifiable locally without `VITE_ZCTA_TILES_URL`. The build verifies the
> wiring + the unset/disabled path (zctaSource.test.ts). See
> `docs/zcta-tiles-setup.md`.
