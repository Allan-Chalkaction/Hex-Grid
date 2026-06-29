# Run Log — Wave 5 (reference-overlays) · HGW-5
**Status: DONE on wave branch `feature/wave-reference-overlays` (8 ahead of main, off main directly).** typecheck/lint/build clean, full suite green (65 W3+W4 + 54 W5 = 119). NO migration/backend.

## Shipped (8 tickets)
RO-T1 verticalStyle palette · RO-T2 sitePinsLayer color-by-vertical + opt-in filter · RO-T3 capitals/metros JSON + referenceLabelsLayer (TextLayer) · RO-T4 zctaSource (env-gated graceful-degradation + click-to-zip) + runbook · RO-T5 MapShell mount (z-order labels>pins, ZCTA<pins) · RO-T6 SaturationPanel → "Map layers" consolidated panel · RO-T7 App wiring · RO-T8 batch-gate remediation.

## Gates → dispositions (ADR-105)
code-reviewer APPROVE · spec-conformance 22/24 CONFORMS (AC-018 untested/RTL + AC-023 resolved by ui-review PASS) · ui-review PASS (legibility gate) · accessibility-auditor PASS. APPLIED CR-001 + ui-M1 + A11Y-001/002 (RO-T8). DEFERRED CR-002/003/004, AC-018 RTL harness, L1 (deferrals-log.md). No db-migration/security gate.

## Operator dependency (carried forward)
ZIP/ZCTA overlay ships with graceful degradation: provide `VITE_ZCTA_TILES_URL` (self-hosted PMTiles — runbook docs/zcta-tiles-setup.md) to activate live ZIP tiles + click-to-zip; until then the ZIP toggle is disabled with a configure note. Other three layers work with zero setup.

## Next operator action
Push feature/wave-reference-overlays + wave→main PR (off main, not stacked).
