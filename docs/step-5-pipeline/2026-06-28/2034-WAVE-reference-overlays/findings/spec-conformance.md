# Spec-Conformance — Wave 5 · Verdict: DRIFT (22 CONFORMS, 1 DRIFT, 1 INCONCLUSIVE; coverage complete)
All 24 ACs claimed/built. AC-013/014/020 CONFORMS-for-wiring (ZCTA live render operator-dependent — VITE_ZCTA_TILES_URL; wiring + unset/disabled path verified). 
- AC-018 (DRIFT, low, _criterion_match_:none, DEFER) App five useState defaults CONFORM by inspection (App.tsx:92-96 exact) but untested (no jsdom/RTL) — the sole testable AC w/o direct automated coverage; indirect via deckLayers + AC-022 grep. → component-test harness deferral.
- AC-023 (INCONCLUSIVE → RESOLVED by the parallel ui-review pass: PASS, no Critical legibility) — enabling code conforms (halos, opaque pins, palette separation, subtle ZCTA); legibility-checklist.md in run folder.
Stale-grep notes (behavior holds): AC-022 capitals/metros now mounted via the extracted deckLayers.buildDeckLayers (MapShell calls it); AC-019 logic in deckLayers.ts (unit-tested).
