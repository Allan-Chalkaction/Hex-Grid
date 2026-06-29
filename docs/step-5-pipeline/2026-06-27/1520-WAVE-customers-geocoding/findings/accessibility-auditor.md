# Accessibility Audit — Wave 2 (customers-geocoding) · WCAG 2.2 AA

**Verdict: PASS_WITH_CONDITIONS** · 6 UI files + CSS. W1 AuthGate pattern (useId, role=alert, native elements) consistently applied. Color non-color-alone throughout. 1 High, 4 Medium, 6 Low.

## A11Y-001 — Focus dropped on SiteRow inline edit/move mode switch — HIGH · WCAG 2.4.3 / 3.2.2 · `_criterion_match_: none` · APPLY
`CustomerList.tsx:270-356`. Activating Edit/Move unmounts the action block; focus falls to body/header "Sign out". Keyboard user must re-traverse from top.
**Remediation:** `useEffect` keyed on mode → `.focus()` the first revealed input.

## A11Y-002 — Delete uses `window.confirm()` with generic OK/Cancel labels — MEDIUM · WCAG 2.4.6; spec §8 AC-015 · APPLY
`CustomerList.tsx:139-157`. Spec requires native `<dialog>` with descriptive buttons; "OK" for delete is a label/purpose mismatch; confirm() blocks thread.
**Remediation:** native `<dialog>` "Delete customer"/"Cancel", showModal focus, ESC cancels, focus restore.

## A11Y-003 — Conditional `aria-live="polite"` regions not pre-seeded — MEDIUM · WCAG 4.1.3 · APPLY
`CustomerForm.tsx:183-199`, `CustomerImport.tsx:120-179`. Progress/results live regions mount conditionally → inconsistent SR announcement (NVDA/JAWS). (role=alert errors are fine.)
**Remediation:** render containers unconditionally, toggle content.

## A11Y-004 — No `<main>` landmark in authenticated shell — MEDIUM · WCAG 2.4.1 / 1.3.1 · APPLY
`App.tsx:48-62`. Primary forms live in `<aside role=complementary>`; no main landmark for skip/rotor nav. W2 modified App.tsx → in scope.
**Remediation:** wrap primary content in `<main>`.

## A11Y-005 — Import result rows show raw outcome identifiers, not labels+glyphs — MEDIUM · spec §7 AC-013 · APPLY
`CustomerImport.tsx:155-168` renders `{r.outcome}` (e.g. "geocode-failed") not `⚠ Geocode failed`. SR hears identifiers; glyph omitted.
**Remediation:** map outcome→{label,glyph} mirroring SiteOutcomeRow.

## Low (palette/type/IDs) — APPLY (cosmetic)
- A11Y-006 `.geo-status--ok` `#146c2e`→spec `#137333` (`index.css:189`) — passes contrast, off-palette.
- A11Y-007 `.report-row--skipped-duplicate/--missing-required-column` `#7a5b00`→`#555`/`#b00020` (`index.css:242-244`).
- A11Y-008 failed glyph `✗`→spec `⚠` (`CustomerForm.tsx:325`).
- A11Y-009 `.helper-text` `0.85rem`→`0.875rem` (`index.css:118`).
- A11Y-010 progress bar hardcoded `id`→`useId()` (`CustomerImport.tsx:122-124`).
- A11Y-011 map `<div>` aria-label needs `role="application"`/`img` to be reliably exposed (`MapShell.tsx:59-67`).

Map non-map data path: CONFIRMED present (CustomerList renders all site data keyboard-navigable; failed-geocode sites listed). WCAG 1.1.1 satisfied.
Recommendation: add `eslint-plugin-jsx-a11y`.

**Condition before ship:** A11Y-001. Recommended this wave: A11Y-002/003/004/005.
