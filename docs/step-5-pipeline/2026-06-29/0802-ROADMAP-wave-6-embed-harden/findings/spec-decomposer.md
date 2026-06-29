# Spec-Decomposer — Wave 6 (embed-harden, parent-agnostic): 4 tickets
Graph: EH-T1[] → EH-T2[T1] ; EH-T3[] ; EH-T4[]. Acyclic; all 15 ACs once. Disjoint files (no shared-sink).

| Ticket | Title | deps | ACs | gates |
|--------|-------|------|-----|-------|
| EH-T1 | Identity/Tenant provider seam (providers.ts, supabase-js-free boundary, configureIdentity, delegators, AuthGate type-delta) | — | 001-007,014,015 | code-reviewer, architect-review, security-auditor |
| EH-T2 | Public API surface — src/lib/index.ts barrel + docs/embed-contract.md | EH-T1 | 008,013 | code-reviewer, architect-review |
| EH-T3 | ZCTA source-kind label — zctaSourceLabel() + vite-env.d.ts + toggle label | — | 009,010,011 | code-reviewer, accessibility-auditor |
| EH-T4 | AK/HI honesty — MapShell aria-label "continental United States"→"United States" | — | 012 | code-reviewer, accessibility-auditor |

Notes: planned additions = providers.test.ts (named in spec), index.test.ts (AC-008 import test), zctaSource.test.ts (spec "extend"). NO db-migration-reviewer (no DB surface). Node-only → pure-logic/type-conformance/grep, no component render. Load-bearing = EH-T1 supabase-js-free boundary (AC-002). Over-engineering line enforced (no registry/DI/selection/flag/maxBounds).
