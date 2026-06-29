# Wave 3 — exclusivity-engine (the core value)

**Status:** ready-to-build (graduated 2026-06-28 via /roadmap Phase W). Plan artifacts:
`docs/step-5-pipeline/2026-06-28/1056-ROADMAP-wave-3-exclusivity-engine/` (spec.md = 24 ACs, adr.md = ADR-003, ui-spec-addendum.md, findings/).

**Ships:** per-site exclusivity zones drawn as circles; within-vertical conflicts flagged (warn-with-confirm) on add/move.

## Locked decisions
- **Radius grain = PER-SITE.** `site.exclusivity_radius_mi` (already physically exists, 0001:38). Picker off / 0.5 / 1 / 1.5 / 2 / 2.5 / 3 mi (off = null = no zone).
- **Conflict scope = WITHIN-VERTICAL** (OD-1 resolved). Vertical promoted to a real `customer.vertical text` column (+ index) with idempotent backfill from `attributes->>'vertical'`. **A customer vertical PICKER is in scope** — without a vertical, conflicts never fire.
- **Threshold = bidirectional `max(A.radius, B.radius)`** point-in-zone (NOT A+B), via `ST_DWithin(geography, meters)`, 1 mi = 1609.344 m.
- **Detection = `security_invoker` RPCs** (`conflicts_at`, `site_conflicts`) that PURE-REPORT; the UI owns disposition. Tenant-scoped by RLS via invoker semantics.
- **Disposition = WARN-with-confirm** on add/move (reuse the W2 native `<dialog>` pattern); non-blocking override. Hard-block enforcement DEFERRED.
- **Rendering = circles only** (deck.gl ScatterplotLayer, `radiusUnits:'meters'`), drawn under the site pins; conflict vs clear shown word+glyph+color (non-color-alone). **H3 hex-fill DEFERRED to Wave 4** (cto SIMPLIFY — it's W4's payload).

## Scope
- **IN:** migration 0003 (customer.vertical + backfill; recreate site_geo +exclusivity_radius_mi/is_zone_on/vertical; the two RPCs + grants); conflicts.ts seam; SiteGeo type extension; per-site radius picker; customer vertical picker; conflict warn-confirm on add + move; circle zone rendering + conflictIds derivation + conflict surfacing in CustomerList.
- **OUT (→ Wave 4 / later):** H3 hex-fill rendering; hard-block (server-enforced) disposition; area-saturation aggregation.

## Tickets (6 — see exclusivity-engine-prompts.md)
EX-T1 migration+RPCs+tests → EX-T2 lib seam → EX-T3 vertical picker → EX-T4 radius picker → EX-T5 zones+conflictIds+map → EX-T6 warn-confirm dialog.
Graph: T1 → T2 → {T3 → T4} → T5 → T6 (acyclic). 24 ACs (AC-001..024) covered.

## Gates
architect-review (spatial rule) · code-reviewer · performance-reviewer · + security-auditor & db-migration-reviewer on EX-T1 (migration/RPC) · accessibility-auditor & ui-review on the UI tickets (W2 precedent).

## Depends on
Wave 1 (PostGIS schema, site.geog + GIST, RLS, map shell) · Wave 2 (customer 1→N site, geocoding, site_geo, place_site, CustomerList/Form, sitePinsLayer, vitest harness from CG-T10).

## Open follow-ups carried forward
Hard-block enforcement (server-side, TOCTOU-safe); H3 hex-fill (W4); controlled vertical value-set governance.
