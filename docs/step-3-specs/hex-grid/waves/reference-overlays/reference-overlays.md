# Wave 5 — reference-overlays (Reference layers + vertical filtering)

**Status:** ready-to-build (graduated 2026-06-28 via /roadmap Phase W). Plan artifacts:
`docs/step-5-pipeline/2026-06-28/2034-ROADMAP-wave-5-reference-overlays/` (spec.md = 24 ACs, adr.md = ADR-005, ui-spec-addendum.md, findings/).

**Ships:** state-capital + metro label layers, vertical filtering + color-by-vertical of site pins, a toggleable ZIP/ZCTA overlay (graceful-degradation), all under one consolidated "Map layers" panel.

## Locked decisions (ADR-005 + cto SIMPLIFY)
- **Capitals (static 50) + metros (CBSA≥250k ~110-180) = repo JSON** (`src/data/{capitals,metros}.json`) → deck.gl TextLayer (white sdf halos for legibility; metros min-zoom ~5 + CollisionFilterExtension; labels above pins). No fetch, no key.
- **Per-vertical color palette** (`src/lib/verticalStyle.ts`, `VERTICAL_COLORS` over `VERTICAL_OPTIONS` + neutral fallback) — distinct from W3 conflict-red / W4 saturation-blue / prospect-green. Color-by-vertical always-on on pins + a vertical color legend.
- **ONE shared `selectedVertical`** (existing W4 state) drives BOTH saturation AND an opt-in "show only this vertical" pin filter. NO second vertical control.
- **ZIP/ZCTA = MapLibre native vector source** (below pins), env-gated `VITE_ZCTA_TILES_URL`; **graceful degradation** — toggle native-disabled + "Configure a ZCTA source" note when unset; click→ZCTA-code popup when set. ⚠️ **Operator dependency:** full ZIP render needs an operator-provided tileset URL (self-hosted PMTiles runbook in `docs/zcta-tiles-setup.md`); the build verifies the wiring + the disabled path.
- **Consolidated panel** — in-place refactor `SaturationPanel` → "Map layers": shared vertical select + filter checkbox, Reference/Analysis `<fieldset>` toggle groups, collapsible vertical color legend, KEEP the W4 saturation legend + aria-live summary + jump + a11y contract. Left CRUD panel untouched.
- No migration / no DB surface. New layers are pure functions in the conditional-spread overlay; first paint byte-identical when toggles off.

## Scope
- **IN:** verticalStyle palette; color-by-vertical + opt-in pin filter; capitals/metros JSON + TextLayers; ZCTA native source + graceful degradation + click-to-zip wiring; MapShell mount (labels above pins, ZCTA below); consolidated "Map layers" panel; App wiring.
- **OUT (operator follow-up):** provisioning/hosting the actual ZCTA tileset (`VITE_ZCTA_TILES_URL` → PMTiles); icon-glyph pins (labels-only MVP).

## Tickets (7 — see reference-overlays-prompts.md)
RO-T1 verticalStyle palette → RO-T2 pin color+filter ; RO-T3 capitals/metros+labels ; RO-T4 ZCTA source ; RO-T5 MapShell mount ← {T2,T3,T4} ; RO-T6 "Map layers" panel ← T1 ; RO-T7 App wiring ← {T5,T6}. Acyclic. 24 ACs (AC-001..024).

## Gates
code-reviewer (every ticket) · ui-review (stacked-layer legibility — the named gate) · + accessibility-auditor on the panel ticket. **No db-migration/security gate** (no migration/RPC/RLS; tile token env-only).

## Depends on
Independent of W2-4 DATA, but extends the W1/W3/W4 map + panel CODE (MapShell overlay, sitePinsLayer, SaturationPanel, App lifted state, VERTICAL_OPTIONS). Build off main (W1-W4 merged).

## Open follow-ups carried forward
ZCTA tileset provisioning + PMTiles hosting (operator); icon-glyph pins; component-test (RTL/jsdom) harness (still deferred — project is node-only).
