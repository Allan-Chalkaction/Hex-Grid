# Autonomous Decisions Log — Wave 4 (area-saturation)
Basis: ADR-105. Bypass active. Gates: code-reviewer APPROVE · spec-conformance CONFORMS (30/30) · performance-reviewer perf-gate PASS · ui-review PASS · a11y PASS_WITH_CONDITIONS. No load-bearing forks.

## ✅ APPLY — remediated (AS-T7, commit b1225aa)
- A11Y-001 (MED) legend now shows when heatmap OR prospecting active (was heatmap-only → green outlines keyless).
- A11Y-002 (LOW) aria-live summary empty-seeded on mount; "Select a vertical…" now static text (W3 pattern).
- PR-002 (perf) rankOpenCells gated to showProspecting (jump-to-open computes on demand — behavior preserved).
- PR-003 (nit) saturationLayer redundant filter kept w/ defensive-contract comment (test path needs it).

## ⏸️ DEFER — logged
- PR-001 h3-js (~150kB gz) code-split behind first vertical selection (opt-in feature; author-discretion, no perf budget).
- code-reviewer CR-001/002/003 (DISMISS — ADR-sanctioned / spec-mandated string).
- ui-review LOW (legend=A11Y-001 fixed; Open swatch solid vs outline; panel rhythm spec-prescribed).
- eslint-plugin-jsx-a11y (open since W2).

## Disposition: no halt. All judgment-class auto-disposed + logged + continued.
