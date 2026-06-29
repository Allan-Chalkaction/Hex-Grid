# Accessibility Audit — Wave 4 · WCAG 2.2 AA · Verdict: PASS_WITH_CONDITIONS
SaturationPanel correct: useId on all 3 controls, native-only, aria-live polite summary, legend swatches aria-hidden + real numeric labels, native disabled, jump announces. W3 dialogs/focus intact (no regression). 2 findings (none blocking):
- A11Y-001 (MED, APPLY, WCAG 1.4.1) legend gated `!noVertical && showHeatmap` → if heatmap off + prospecting on, green open-cell outlines render with NO legend key. Fix: `showLegend = !noVertical && (showHeatmap || showProspecting)`.
- A11Y-002 (LOW, APPLY, WCAG 4.1.3) aria-live summary pre-populated on mount ("Select a vertical…") vs the W3 empty-seed pattern → may auto-announce on VoiceOver. Seed empty when noVertical (or make the no-selection hint static non-live).
Contrast all PASS. Recommend eslint-plugin-jsx-a11y (open since W2).
