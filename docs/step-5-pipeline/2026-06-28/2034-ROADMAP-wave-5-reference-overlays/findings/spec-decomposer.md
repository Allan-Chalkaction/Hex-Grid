# Spec-Decomposer — Wave 5 (reference-overlays): 7 tickets
Graph: RO-T1[] → RO-T2[T1] ; RO-T3[] ; RO-T4[] ; RO-T5[T2,T3,T4] ; RO-T6[T1] ; RO-T7[T5,T6]. Acyclic; all 24 ACs once. Each source file owned by one ticket (no shared-sink collisions).

| Ticket | Title | deps | ACs | gates |
|--------|-------|------|-----|-------|
| RO-T1 | verticalStyle.ts palette + neutral fallback + tests | — | 001-003 | code-reviewer |
| RO-T2 | sitePinsLayer color-by-vertical + opt-in filter + tests | RO-T1 | 004-006 | code-reviewer |
| RO-T3 | capitals/metros JSON + referenceLabelsLayer (TextLayer) + tests | — | 007-011 | code-reviewer |
| RO-T4 | zctaSource.ts (env-gated, graceful degradation, click-to-zip) + tests + runbook ⚠️OP-DEP | — | 012-014 | code-reviewer |
| RO-T5 | MapShell mount (z-order: labels above pins, ZCTA below) + new props | RO-T2,RO-T3,RO-T4 | 019,020,023 | code-reviewer, ui-review |
| RO-T6 | SaturationPanel → "Map layers" panel (in-place) + index.css + tests | RO-T1 | 015,016,017 | code-reviewer, ui-review, accessibility-auditor |
| RO-T7 | App wiring + integration + wave code-review | RO-T5,RO-T6 | 018,021,022,024 | code-reviewer, ui-review |

Notes: no planned-files additions beyond spec. No db-migration/security gate (no migration/RPC/RLS; tile token env-only). RO-T4 operator-dependency: full ZIP render needs VITE_ZCTA_TILES_URL (runbook docs/zcta-tiles-setup.md); build verifies wiring + unset path. Project node-only → component verification via pure-logic/layer-config tests (no RTL harness — deferred).
