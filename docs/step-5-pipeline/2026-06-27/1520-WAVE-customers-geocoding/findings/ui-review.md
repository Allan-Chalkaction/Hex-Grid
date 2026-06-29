# UI Review — Wave 2 (customers-geocoding)

**Verdict: FAIL** · iteration 1. Functionally faithful + a11y-strong (SiteList cleanly superseded, reactive deck.gl pin seam matches §9, useId labels, role=alert, global :focus-visible preserved). FAIL is for **design-token drift**: off-scale spacing/type + off-palette hex. No color deviation fails contrast — but token discipline (§2/§3/§4/§10) is exactly what this gate catches. 1 High, 7 Medium, 4 Low.

**Context WARNING:** no `.claude/agent-context/ui-review*.md` overlay, no project CLAUDE.md; audited against the UI Spec Addendum + `index.css`.

## H-1 — Pervasive off-scale spacing & font-size values — HIGH · §2+§3 · `_criterion_match_: none` · APPLY
Scale is 0.25/0.5/1rem, body 1rem, helper 0.875rem. Off-scale: `.panel-section` margin 1.5rem (`:106`), `.field` margin 0.75rem (`:125`), `.field` input font 0.95rem + padding 0.4rem (`:132-133`), `.helper-text` 0.85rem (`:117`), `.site-rows` gap 0.75rem (`:145`), button padding 0.4rem 0.7rem + font 0.9rem (`:162`), `.geo-status` gap 0.35rem (`:177`).
**Fix:** snap all to scale (1rem margins, 1rem input font, 0.875rem helper, 0.5rem gaps, 0.5rem 0.6rem button padding).

## M-1 — Geocoded-green `#146c2e`→spec `#137333` (`:189,:232`) · APPLY
## M-2 — Import amber `#7a5b00` off-palette; skipped→`#555`, missing-column→`#b00020` (`:241-244`) · APPLY
## M-3 — Invented gray surface tier `.recovery #f6f6f6`/`#e2e2e2`/`#eee` (`:199-200,228,255,262`); §4 forbids — standardize borders on `#ddd` · APPLY
## M-4 — `.geo-status` no font-size → renders 1rem; spec 0.875rem (`:173-178`) · APPLY
## M-5 — Three surfaces stacked in one 18rem `.site-panel` (`App.tsx:52-59`); §10 anti-pattern, `.field-inline` cramped — use `<dialog>` for forms or widen to 22rem · APPLY (forks with A11Y-002)
## M-6 — Delete confirm `window.confirm()` not native `<dialog>` (`CustomerList.tsx:140`) · APPLY (same as A11Y-002)
## M-7 — Submit buttons lack `cursor: pointer` (`CustomerForm.tsx:178`, `CustomerImport.tsx:115`) · APPLY

## Low · L-1 glyph deviations (✗/⏳ vs ⚠/…); L-2 "Located/No location" vs "Geocoded/Failed"; L-3 sitePinsLayer radiusMinPixels 4 vs spec 6 + 3-tuple fill color (harmless); L-4 orphan `.site-list h2` rule. Optional polish.

Token compliance: no-hardcoded-colors-in-TSX PASS; no-arbitrary-values FAIL (H-1, M-1/2/3); referenced-tokens-exist PASS; hover-states FAIL (M-7); focus-visible PASS.

All findings are CSS/markup remediable in one low-risk pass (concrete before/after list retained from agent run).
