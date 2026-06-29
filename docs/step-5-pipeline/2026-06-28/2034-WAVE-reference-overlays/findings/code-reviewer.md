# Code Review — Wave 5 (reference-overlays) · Verdict: APPROVE
7 commits, all load-bearing constraints hold: env-only ZCTA (no hardcoded URL/token), MapLibre-native (no MVTLayer), palette avoids reserved triples, conditional-spread → W4-identical-when-off (deckLayers.test), sitePinsLayer signature change consumed everywhere, no W3/W4 regression, W4 a11y preserved. 54/54 W5 tests. Findings advisory:
- CR-001 (nit, APPLY) buildDeckLayers exported without explicit return type (deckLayers.ts:54) — add `: Layer[]`.
- CR-002 (suggest, DEFER) panel a11y verified by source-string assertions not RTL render (project node-only) — standalone test-infra (jsdom/RTL).
- CR-003 (suggest, DEFER) `zoom` in the deck-rebuild effect rebuilds all layers per moveend (MapShell ~160-195); functionally fine (debounced, deck diffs by id) — isolate the metro-gate effect later.
- CR-004 (nit, DEFER) metros.json has duplicate un-suffixed labels (Springfield ×3 etc.) — JSON-only state-suffix later.
