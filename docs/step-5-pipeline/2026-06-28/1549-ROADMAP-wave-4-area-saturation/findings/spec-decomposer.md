# Spec-Decomposer — Wave 4 (area-saturation): 6 tickets
Graph: AS-T1[] → AS-T2[T1] → AS-T3[T2] → AS-T4[T3]; AS-T5[] (independent); AS-T6[T2,T4,T5]. Acyclic; all 30 ACs covered once.

| Ticket | Title | deps | ACs | gates |
|--------|-------|------|-----|-------|
| AS-T1 | effectiveRadiusMi helper + siteZonesLayer refactor + parity test | — | 001-003 | code-reviewer, performance-reviewer |
| AS-T2 | coverage.ts compute core (overlap-weighted, resolution clamp, cell-cap, bbox pre-filter, prospect rank) + h3-js | AS-T1 | 004-011,013,015,028,030 | code-reviewer, performance-reviewer |
| AS-T3 | saturationLayer + prospectLayer (H3HexagonLayer, Blues ramp, updateTriggers) | AS-T2 | 014,017 | code-reviewer, performance-reviewer, ui-review |
| AS-T4 | MapShell mount (under zones+pins) + debounced moveend recompute | AS-T3 | 012,018,019,020 | code-reviewer, performance-reviewer, ui-review |
| AS-T5 | SaturationPanel (selector/toggles/legend/aria-live summary) + index.css | — | 022-027,029 | code-reviewer, accessibility-auditor, ui-review |
| AS-T6 | App wiring — cells derivation + thread to MapShell+Panel + jump-to-open | AS-T2,AS-T4,AS-T5 | 016,021 | code-reviewer, performance-reviewer, accessibility-auditor, ui-review |

Notes: planned addition = saturationLayer.test.ts (AS-T3). No db-migration-reviewer/security-auditor (AC-030/ADR D6 — no migration/RPC/RLS). Only W3 source change = siteZonesLayer helper refactor (AS-T1). Standalone wave, no crossWavePrior.
