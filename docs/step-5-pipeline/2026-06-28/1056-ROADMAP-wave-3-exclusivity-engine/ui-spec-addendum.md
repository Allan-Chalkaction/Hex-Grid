# UI Specification Addendum: Exclusivity Engine (Wave 3)

**Feature:** exclusivity-engine
**Date:** 2026-06-28
**Spec:** docs/step-3-specs/hex-grid/waves/exclusivity-engine/exclusivity-engine.md
**ADR:** docs/step-5-pipeline/2026-06-28/1056-ROADMAP-wave-3-exclusivity-engine/adr.md (ADR-003)
**Token Mode:** project-tokens (plain semantic CSS classes + literal hex in `src/index.css` — NOT Tailwind, NOT CSS custom properties)

> **Token vocabulary (binding for this repo).** Same contract as the W2 addendum.
> This project uses **plain semantic CSS classes** in `src/index.css` with
> **literal hex values** (`#1a73e8`, `#b00020`, `#555`, `#ddd`, `#1558b0`,
> `#137333`). There is no Tailwind, no utility classes, no CSS custom-property
> token layer. Do NOT introduce Tailwind utilities, `bg-*`/`text-*` classes, CSS
> variables, or arbitrary inline hex in TSX. Add new visual rules as **named
> semantic classes** in `src/index.css` and reference them by `className` —
> mirror the existing `.geo-status*` / `.field` / `.confirm-dialog` conventions
> exactly. The deck.gl layers (`sitePinsLayer.ts` / the new `siteZonesLayer.ts`)
> are the one place RGBA arrays are authored in TS — they mirror the existing
> `[21, 88, 176]` literal in `sitePinsLayer.ts` and are NOT inline CSS.

---

## 0. Visual Context (what this wave adds)

W3 builds on the W2 surface unchanged: a full-bleed MapLibre map (`MapShell`,
absolute `inset:0`) with deck.gl pins, and one floating left panel
(`.site-panel`, `width:22rem`) holding `CustomerForm` (add) and `CustomerList`
(CRUD). The aesthetic stays *minimal floating glass panels over a map* — no
cards, no grid, no component library.

W3 adds exactly four visible things, all built from the W2 vocabulary:

1. A **per-site exclusivity-radius `<select>`** in the `CustomerList` `SiteRow`.
2. A **customer-vertical `<select>`** (controlled value set) on `CustomerForm`
   (add) and a new `CustomerRow` edit affordance (existing customers).
3. A **conflict warn dialog** (native `<dialog>`, reusing the W2 A11Y-002
   confirm pattern) on add/move.
4. **Translucent circle zones** on the map (a second deck.gl `ScatterplotLayer`
   below the pins), recolored when a zone is in conflict, plus a **zone-status
   indicator** (word + glyph + color) in each `SiteRow` carrying the accessible,
   non-color-alone signal.

The visual job is to extend the established idiom — `.geo-status` word+glyph+color,
`.field` form groups, `.confirm-dialog`, the literal-hex palette, the
0.25/0.5/0.75/1rem rhythm — **without inventing a new design language**.

---

## 1. Component Selection

Everything is native HTML styled by semantic classes. Reuse the W2 vocabulary:

| UI element | What to render | Reuse / new |
|---|---|---|
| Per-site radius picker | `<select>` inside a `.field` (label via `useId`) | reuse `.field` + `.field select`; new `.radius-picker` wrapper for inline layout |
| Customer vertical picker | `<select>` inside a `.field` (label via `useId`) | reuse `.field` + `.field select` |
| Vertical edit on existing customer | `.field-inline` reveal (Edit → select + Save/Cancel), mirroring `SiteRow` edit-address | reuse `.field-inline`, `.btn-secondary` |
| Conflict warn dialog | native `<dialog>` with `showModal()`, real buttons, ESC cancels, focus returns to trigger | reuse `.confirm-dialog` (the W2 A11Y-002 pattern from `CustomerList`) |
| Conflict list inside the dialog | `<ul>` of conflicting sites (brand, site, distance) | new `.conflict-list` |
| Zone-status indicator (in `SiteRow`) | `<span className="zone-status zone-status--{off\|clear\|conflict}">` glyph + word | new `.zone-status*` classes (mirror `.geo-status*`) |
| Conflict detail (which neighbors) | `.helper-text` line or `<details>` listing conflicting brands | reuse `.helper-text` |
| Map zone circles | deck.gl `ScatterplotLayer` (`radiusUnits:'meters'`) via `siteZonesLayer(sites, conflictIds)` | new `siteZonesLayer.ts` |

Do NOT pull in any UI dependency. W3 adds **no new visual package** (H3/`h3-js`
hex fill is deferred per ADR Decision 5).

---

## 2. Layout & Spacing

Stay on the repo's `0.25rem / 0.5rem / 0.75rem / 1rem` scale. No arbitrary values.

| Element | Rule |
|---|---|
| Radius picker wrapper (`.radius-picker`) | `display:inline-flex; align-items:center; gap:0.5rem` (inline within the `.site-item` row) |
| Radius `<select>` padding | inherits `.field select` (`padding:0.5rem; font-size:1rem`) — but see §7 compact note |
| Zone-status indicator | inherits `.geo-status` metrics (`gap:0.5rem; font-size:0.875rem; font-weight:600`) |
| Vertical `<select>` | inherits `.field select`; field gap `0.25rem` label→control, `margin-bottom:1rem` between fields |
| Conflict dialog padding | reuse `.confirm-dialog` default; if styling, `1rem 1.25rem` |
| Conflict dialog max-width | `28rem` (matches the W2 dialog guidance) |
| Conflict list (`.conflict-list`) item gap | `0.25rem` vertical |
| Dialog action row | reuse `.row-actions` (`gap:0.5rem; flex-wrap:wrap`) |
| Conflict detail helper line | reuse `.helper-text` (`margin:0.25rem 0`) |

The radius picker and zone-status both live **inline in the existing `.site-item`
flex row** (which already does `flex-wrap:wrap; gap:0.5rem`) — they wrap naturally
on the 22rem panel without new layout scaffolding.

---

## 3. Typography Hierarchy

No new type scale. Match W2:

| Role | Element | Size | Weight | Color |
|---|---|---|---|---|
| Panel heading | `<h2>` | `1.1rem` | default bold | inherit |
| Customer name | `<strong>` | `1rem` | `600` | inherit |
| Site name | `.site-name` | `1rem` | `600` | inherit |
| Body / list text | `<li>`, `<p>` | `1rem` | `400` | inherit |
| Field label (radius, vertical) | `<label>` | `1rem` | `400` | inherit |
| Select text | `<select>` | `1rem` | `400` | inherit |
| Zone-status word | `.zone-status` span | `0.875rem` | `600` | per status (§4/§6) |
| Conflict detail / helper | `.helper-text` | `0.875rem` | `400` | `#555` |
| Dialog body text | `<p>` in dialog | `1rem` | `400` | inherit |
| Error text | `.form-error` | `1rem` | `600` | `#b00020` |

`1rem` stays the body baseline (this is a desktop tool — the "dashboard text-sm"
guidance does not apply to this rem-based repo, per the W2 decision).

---

## 4. Color Token Usage

**No new hex this wave.** Every color is drawn from the W2-verified palette;
contrast bars carry over from the W2 addendum (re-stated here for the new uses).

| Purpose | Value | Bar | Result |
|---|---|---|---|
| Zone-status "Conflict" text | `#b00020` | 4.5:1 text | PASS (~7:1 on white) |
| Zone-status "Exclusive/OK" text | `#137333` | 4.5:1 text | PASS (~5.9:1 on white) |
| Zone-status "No zone" text | `#555` | 4.5:1 text | PASS (~7.5:1 on white) |
| Conflict detail / helper text | `#555` | 4.5:1 text | PASS |
| Error text | `#b00020` | 4.5:1 text | PASS |
| Focus outline (all new controls) | `#1a73e8` | 3:1 non-text | PASS (inherits global `:focus-visible`) |

**Map zone circles (graphical objects — 3:1 bar, NOT text):**

| Zone state | Stroke RGBA | Fill RGBA | Bar | Result |
|---|---|---|---|---|
| Non-conflict | `[21, 88, 176, 200]` (`#1558b0`) | `[21, 88, 176, 38]` (~0.15 α) | 3:1 graphical on light basemap | PASS (stroke carries it) |
| Conflict | `[176, 0, 32, 220]` (`#b00020`) | `[176, 0, 32, 46]` (~0.18 α) | 3:1 graphical | PASS |

The translucent **fill** is decorative; the **stroke** carries the 3:1
graphical-object distinction against the OpenFreeMap `liberty` light basemap.
Both stroke hues reuse the existing pin/error literals — no new color introduced.
**Conflict differentiation is never color-alone:** the authoritative,
SR-readable non-color signal lives in the `SiteRow` **zone-status word+glyph**
(§6); the map color + thicker conflict stroke (§10) are reinforcement only.

Surface layering is unchanged: map canvas → translucent zone circles → pins →
floating white panel → near-black text → `#555` muted.

---

## 5. Per-Site Radius Picker (item 1 — detail)

**Control:** a native `<select>` (NOT a custom segmented control). Eight options
on a tiny value set is exactly the native `<select>` sweet spot — keyboard-native,
SR-announced, zero custom JS, and `.field select` is already styled. A segmented
radiogroup would be custom code with no benefit at this option count.

**Placement:** inline in the `CustomerList` `SiteRow`, in **view mode**
(persistent, not behind an edit reveal) — it is the core W3 quick action.
Render it in the existing `.site-item` flex row, after the geo-status and the
new zone-status, wrapped in `.radius-picker`.

**Label + a11y:** `const radiusId = useId();` →
`<label htmlFor={radiusId}>Zone radius</label>` + `<select id={radiusId}>`.
The label is real visible text (short — "Zone radius"). Inherits the global
`:focus-visible` outline.

**Options + value mapping** (off plus the locked set off/0.5/1/1.5/2/2.5/3 mi):

| Option label | `<option value>` | Writes `site.exclusivity_radius_mi` |
|---|---|---|
| Off (no zone) | `""` (empty) | `null` |
| 0.5 mi | `"0.5"` | `0.5` |
| 1 mi | `"1"` | `1` |
| 1.5 mi | `"1.5"` | `1.5` |
| 2 mi | `"2"` | `2` |
| 2.5 mi | `"2.5"` | `2.5` |
| 3 mi | `"3"` | `3` |

**Read:** initialize the select value from `site.exclusivity_radius_mi`
(`null` → `""` = Off). The `SiteGeo` type gains `exclusivity_radius_mi`,
`is_zone_on`, `vertical` per the ADR — the select binds to `exclusivity_radius_mi`.

**Write:** on `change`, call the ADR's `updateSiteRadius(site.id, mi | null)`
helper (empty string → `null`), then `onChanged()` so the map zone redraws/recolors
and the list re-fetches. During the in-flight write, swap to a disabled state and
a brief `.helper-text aria-live="polite"` note ("Saving radius…"); on error show a
`role="alert" .form-error` inline (mirror the `SiteRow` save patterns).

**Off semantics (per ADR Decision 6):** Off ⇒ `exclusivity_radius_mi = null` ⇒
no circle drawn for this site (§10) and zone-status shows "No zone" (§6). A
zero/off site still appears in a *neighbor's* conflict (it can intrude another's
zone) — so an Off site can still show a "Conflict" zone-status. `is_zone_on`
(default true) is a separate master toggle the predicate already folds in; W3's
picker does NOT expose it — Off is expressed via the radius `null`.

---

## 6. Customer Vertical Picker (item 2 — detail)

**Control:** a native `<select>` bound to a **controlled value set** (replaces
the W2 free-text "Vertical (optional)" `<input>` that wrote `attributes.vertical`).
A controlled list makes "two customers share a vertical" reliable — the whole
conflict key depends on string equality (ADR Recommendation: "Define the vertical
value set").

**Recommended starter value set** (stored lowercase-token in `customer.vertical
text`; the option label is human, the `value` is the stable token):

| Option label | `<option value>` |
|---|---|
| Select vertical… (no vertical) | `""` → writes `null` |
| Gas / convenience | `"gas"` |
| Grocery | `"grocery"` |
| Pharmacy | `"pharmacy"` |
| Quick-service restaurant (QSR) | `"qsr"` |
| Fitness | `"fitness"` |
| Automotive | `"automotive"` |
| Banking | `"banking"` |
| Hotel / lodging | `"hotel"` |

Keep the list small and stable; the column stays `text` (per ADR) so it can grow
without a migration. The empty option (`""` → `null`) is the explicit
"no vertical" state.

**Placement — add (`CustomerForm`):** replace the existing free-text vertical
field (lines 152–160) with this select, keeping the same `verticalId = useId()`
label association. Label: "Vertical". Wire the chosen token into the customer
create path (`customer.vertical` column, not `attributes`, per ADR Decision 1).

**Placement — edit (existing customers, `CustomerList` `CustomerRow`):** add an
"Edit vertical" affordance to `CustomerRow`, mirroring the `SiteRow`
edit-address reveal: view mode shows the current vertical as a labeled value plus
an "Edit vertical" `<button className="btn-secondary">`; clicking reveals a
`.field-inline` with the select + "Save"/"Cancel" `<button>`s. On save, write
`customer.vertical` and `onChanged()`. Move focus to the select on reveal (the
W2 `firstFieldRef` / A11Y-001 pattern).

**Existing customers with empty/backfilled vertical:** the 0003 backfill seeds
`vertical` from `attributes->>'vertical'` where present; anything still null
displays as **"No vertical set"** in `.helper-text`, and the select defaults to
the empty "Select vertical…" option. Because a null vertical can never conflict
(ADR predicate), surface a one-line muted hint next to it:
*"Set a vertical to enable conflict detection."* (`.helper-text`, `#555`). This
makes the inert-feature failure mode (ADR Risk) visible rather than silent.

---

## 7. Conflict Warn UX on Add/Move (item 3 — detail)

**Policy (locked):** WARN-with-confirm, **non-blocking override** — the RPC
pure-reports; the UI decides. The user can always proceed. Scope the modal warn
to **add and move** (the locked default); a radius change recolors zones
passively (no modal — see §11 note).

**Pattern:** reuse the W2 A11Y-002 native-`<dialog>` confirm pattern verbatim
(`CustomerList` `requestDelete`/`confirmDelete`): `dialogRef.current?.showModal()`,
real `<button>`s, ESC cancels, `onClose` returns focus to the trigger via a ref.
Reuse `className="confirm-dialog"`.

**What the dialog says.** Heading (`<h2>` or `<strong>`, referenced by
`aria-labelledby`): **"Exclusivity conflict"**. Body: one line of context, then a
`.conflict-list` `<ul>` — one `<li>` per conflicting existing site, each stating
the three required facts:

> This site falls within the exclusivity zone of **{N}** same-vertical site(s):
> - **{customer_name}** — {site_name} · {distance_mi} mi · {vertical}

`distance_mi` rounds to one decimal (e.g. "0.8 mi"); `vertical` shows the human
label for the shared token. Pull these straight from the `conflicts_at` /
`site_conflicts` RPC result rows (`customer_name`, `site_name`, `distance_mi`,
`radius_mi`).

**Buttons (`.row-actions` in the dialog):**
- Add flow: **"Add anyway"** (`.btn-danger` — the override, styled like the W2
  destructive confirm) + **"Cancel"** (`.btn-secondary`).
- Move flow: **"Move anyway"** (`.btn-danger`) + **"Cancel"** (`.btn-secondary`).

**Focus / ESC / role semantics:**
- `showModal()` gives the dialog `role="dialog"` + `aria-modal` natively; set
  `aria-labelledby` to the heading id (`useId`).
- **Default focus on "Cancel"** (the safe, non-overriding choice) so a reflexive
  Enter does not silently override a conflict. Proceeding is a deliberate click.
- **ESC = Cancel** (native dialog behavior) = abort the add/move; nothing persists.
- `onClose` returns focus to the trigger: the form **submit button** (add) or the
  **"Save location" button** (move).

**Proceed-anyway vs cancel — the data flow:**
- **Add:** geocode → if a point resolves, call
  `findConflicts(point, newRadius ?? null, customerVertical, null)` **before**
  `place_site`. Conflicts → show dialog. "Add anyway" → proceed with `place_site`
  (persist + the W2 outcome report). "Cancel" → do **not** persist that site;
  surface a `.helper-text` note ("Add cancelled — conflict not overridden").
  (No vertical ⇒ `findConflicts` returns empty ⇒ no dialog, add proceeds.)
- **Move:** on "Save location", compute the new point → `findConflicts(point,
  thisSite.radius, thisCustomer.vertical, thisSite.id)` (self excluded via
  `p_exclude_id`). Conflicts → dialog. "Move anyway" → `updateSiteLocation` then
  `onChanged()`. "Cancel" → stay in move mode, no write.
- **Multi-site add (`CustomerForm` repeatable rows):** run the check per
  prospective site; if any conflict, present **one consolidated dialog** that
  groups conflicts under each conflicting prospective site. "Add anyway" proceeds
  with all; "Cancel" aborts the whole submit. (Documented simplification — see
  Deviation Log.)

**In-flight:** while `findConflicts` runs, swap the trigger label
("Checking exclusivity…") and disable it (mirror the W2 "Adding & geocoding…"
disabled-with-label-swap).

---

## 8. Zone Rendering on the Map (item 4 — detail)

**New layer:** `siteZonesLayer(sites, conflictIds: Set<string>)` returns a deck.gl
`ScatterplotLayer` keyed `'site-zones'`, mirroring `sitePinsLayer.ts`:

- `data`: sites that are **located AND have an effective zone** — `lat != null &&
  lng != null && is_zone_on && exclusivity_radius_mi != null &&
  exclusivity_radius_mi > 0`. Off/null-radius sites get **no circle**.
- `getPosition: (d) => [d.lng, d.lat]`.
- `radiusUnits: 'meters'`, `getRadius: (d) => d.exclusivity_radius_mi * 1609.344`
  (the ADR meters conversion — viz == the geodesic `ST_DWithin` semantic).
- `stroked: true`, `filled: true`, `lineWidthUnits: 'pixels'`.
- **Coloring keyed on conflict state** (`conflictIds.has(d.id)`):
  - non-conflict → `getFillColor: [21,88,176,38]`, `getLineColor: [21,88,176,200]`,
    `getLineWidth: 1`.
  - conflict → `getFillColor: [176,0,32,46]`, `getLineColor: [176,0,32,220]`,
    **`getLineWidth: 2`** (the thicker stroke is a secondary, non-color cue).
- `pickable: false` (the pins own picking; zones are passive fills).

**Conflict-id derivation (NOT a view column — per ADR Decision 5):** conflict
state is pairwise/dynamic. On data change, derive `conflictIds` from the RPC —
`site_conflicts(site_id)` for a recently changed site (add/move), or an on-demand
whole-tenant pass for full coloring; collect every `site_id` that appears in any
result into the `Set`. Recompute on data change, **never per frame** (ADR perf).

**Layering / z-order:** in `MapShell`, mount both layers and pass the array to
`overlay.setProps`:

```
overlay.setProps({ layers: [siteZonesLayer(sites, conflictIds), sitePinsLayer(sites)] })
```

deck.gl renders array order bottom→top: **zones first (under), pins last (on
top)** — circles never occlude their pins. Extend the existing reactive effect in
`MapShell` (lines 55–57) to rebuild both layers on `sites` / `conflictIds` change.

**Off state:** filtered out of `data` ⇒ no circle (the site still shows its pin).

---

## 9. Conflict Surfacing in CustomerList (item 5 — detail)

Each `SiteRow` gains a **zone-status indicator** mirroring the W2 geo-status
word+glyph+color pattern (this is the accessible, non-color-alone conflict signal
the map color reinforces). Add `.zone-status*` classes to `src/index.css`,
cloned from `.geo-status` metrics.

Render: `<span className="zone-status zone-status--X"><span className="geo-glyph"
aria-hidden="true">{glyph}</span> {word}</span>` — the **word is real text**
(SR-announced); the glyph is `aria-hidden`.

| State | Condition | Word | Glyph (aria-hidden) | Class color |
|---|---|---|---|---|
| No zone | radius null/off | "No zone" | `○` | `#555` (`.zone-status--off`) |
| Exclusive | radius set, not in `conflictIds` | "Exclusive {mi} mi" | `✓` | `#137333` (`.zone-status--clear`) |
| Conflict | site_id ∈ `conflictIds` | "Conflict ({N})" | `⚠` | `#b00020` (`.zone-status--conflict`) |

`{N}` is the conflict count from the RPC. Below a conflicting row, render the
neighbor detail in `.helper-text` (or a `<details><summary>` for compactness),
e.g. *"Conflicts with Brand X — Site A (0.8 mi)."* — the same facts as the
dialog, persistently visible in the list. This keeps the conflict fully legible
without opening any modal, and is the SR path for map conflicts (the map canvas
is `role="application"`, a11y scoped to the chrome — W2 A11Y-011).

Place the zone-status in the `.site-item` row alongside the existing geo-status
(both wrap on the 22rem panel).

---

## 10. States, Keyboard & Screen-Reader Behavior (item 6)

**Loading.**
- List load: reuse the W2 `LoadState` machine ("Loading customers…").
- Conflict computation in-flight (whole-tenant or per-site pass): show
  zone-status as a neutral **"Checking…"** (`.zone-status--off` styling, `#555`)
  with `aria-live="polite"` until results resolve — never flash a false "Exclusive".
- Radius/vertical write in-flight: disable the control + `.helper-text`
  `aria-live="polite"` ("Saving radius…" / "Saving vertical…").
- Conflict check in add/move: trigger label swap + disabled ("Checking
  exclusivity…").

**Empty.**
- No customers → existing "No customers yet." A customer with no vertical → "No
  vertical set" + the enable-hint (§6).
- A site with radius Off → "No zone" zone-status; no map circle.
- No conflicts anywhere → every located+zoned site shows "Exclusive {mi} mi";
  zones render blue; no dialogs fire.

**Conflict.**
- Map: red translucent circle + thicker red stroke for every `conflictIds` member.
- List: "Conflict (N)" zone-status (red, ⚠) + neighbor detail.
- On add/move: the warn dialog (§7).

**No-conflict.** Blue zone circle; "Exclusive {mi} mi" (green, ✓); add/move
proceeds with no dialog.

**Keyboard.**
- Radius `<select>`, vertical `<select>`: native keyboard (Tab to focus, arrows /
  type-ahead to choose, Enter/Space to open). Inherit the global `:focus-visible`
  (`2px #1a73e8`, 2px offset) — do not override.
- Conflict dialog: native `<dialog>` focus trap; Tab cycles within; ESC cancels;
  focus returns to the trigger on close (`onClose` + ref). Default focus on
  "Cancel".
- Every interactive element is a real `<select>`/`<button>` — no `<div onClick>`
  (W2 AC-020).

**Screen reader.**
- Each new `<select>` has a `<label htmlFor={useId()}>` — no orphan controls.
- Zone-status announces the **word** ("Conflict", "Exclusive 1.5 mi", "No zone");
  the glyph is `aria-hidden`.
- Conflict detail is real text in the row (and in the dialog), so map-only color
  is never the sole carrier of conflict state.
- Status/note regions use `aria-live="polite"`; errors use `role="alert"` +
  `.form-error` (W2 pattern).

**Color contrast.** All text colors (`#b00020`, `#137333`, `#555`) clear AA
(≥4.5:1) on white — verified in W2. The map circle strokes (`#1558b0`, `#b00020`)
clear the 3:1 graphical-object bar on the light basemap; conflict adds a
non-color thicker-stroke cue. The `#1a73e8` focus ring is the non-text 3:1
component color (do not "fix" it — W2 F-002).

---

## 11. Anti-Patterns (Do NOT do)

- No Tailwind utilities / `bg-*`/`text-*` / CSS variables — plain semantic CSS
  classes + literal hex only. Add `.zone-status*`, `.radius-picker`,
  `.conflict-list` to `src/index.css`.
- No new arbitrary hex — reuse `#b00020`, `#137333`, `#555`, `#1558b0`, `#ddd`.
  The deck.gl RGBA arrays reuse the same literals (`[21,88,176]`, `[176,0,32]`).
- No conflict signalled by **color alone** — the `SiteRow` zone-status word+glyph
  is the authoritative SR signal; map color is reinforcement (+ thicker conflict
  stroke as a non-color map cue).
- No free-text vertical — use the controlled `<select>` value set (string
  equality is the conflict key).
- No `<div onClick>` and no custom segmented control where a native `<select>`
  serves — keep it native and keyboard-free-for-free.
- No hard-blocking the add/move on conflict — the locked policy is
  WARN-with-confirm, non-blocking override.
- No modal on a **radius change** — a radius change recolors zones passively
  (recompute `conflictIds` + redraw); only add/move opens the warn dialog
  (locked scope).
- No drawing a circle for an Off/null-radius site; no zone circle on top of its
  pin (zones render under pins).
- No conflict-state **view column** — derive `conflictIds` from the RPC on data
  change (conflict is pairwise/dynamic; a static column is instantly stale).
- No H3 hexes — circles only this wave (H3 fill deferred, ADR Decision 5).
- No removing/weakening the global `:focus-visible` outline; no per-element focus
  override.
- No inline `style={{…}}` in TSX (the `MapShell` canvas is the sole exception);
  deck.gl layer props are TS config, not inline CSS.

---

## 12. Reference Patterns

Codebase north-star files — read before implementing; they ARE the quality bar:

- `src/components/CustomerList.tsx` — the `SiteRow` view/edit/move state machine
  (radius picker + zone-status slot in here), and the **A11Y-002 native-`<dialog>`
  confirm** (`requestDelete`/`confirmDelete`, `onClose` focus return) — **copy
  this dialog pattern verbatim** for the conflict warn dialog.
- `src/components/CustomerForm.tsx` — the `useId` label association, `role="alert"`
  errors, disabled-with-label-swap submit; the free-text vertical field to be
  replaced by the controlled `<select>`; the A11Y-001 focus-on-reveal pattern for
  the vertical edit.
- `src/components/sitePinsLayer.ts` — the `ScatterplotLayer` factory to mirror for
  `siteZonesLayer.ts` (RGBA-literal coloring, located-filter, layer id).
- `src/components/MapShell.tsx` — the reactive `overlay.setProps({layers:[…]})`
  seam (lines 55–57) to extend with `[siteZonesLayer, sitePinsLayer]`.
- `src/index.css` — `.geo-status*` / `.field` / `.field-inline` / `.confirm-dialog`
  / the literal-hex palette. Add the new `.zone-status*` / `.radius-picker` /
  `.conflict-list` rules here in the same style.

No external dashboard north-star — this is a deliberately minimal plain-CSS app;
the W1/W2 files are the standard.

---

## Deviation Log

| Area | What was missing in spec/ADR | Default applied |
|---|---|---|
| Vertical value set | ADR recommends "define the value set" but leaves it open (gas/grocery/…) | Chose an 8-item starter set (gas, grocery, pharmacy, qsr, fitness, automotive, banking, hotel) stored as lowercase tokens in `customer.vertical text`; empty option = no vertical. |
| Radius control type | Locked picker values, but select vs segmented unspecified | Native `<select>` (8 options; keyboard/SR-native; `.field select` already styled). |
| Vertical edit surface | Prompt says "CustomerForm + edit" but no edit location for existing customers | Add an "Edit vertical" reveal to `CustomerRow` mirroring the `SiteRow` edit-address pattern. |
| Conflict dialog default focus | A11Y-002 pattern reused, but which button is focused unspecified | Default focus on "Cancel" (safe, non-overriding); ESC = Cancel = abort. |
| Map conflict color a11y | Map is `role="application"`; color alone is inaccessible | Conflict is carried accessibly by the `SiteRow` zone-status word+glyph + a persistent `.helper-text` neighbor detail; map color + thicker stroke are reinforcement. |
| Multi-site add conflicts | One add can create several conflicting sites; flow unspecified | One consolidated dialog grouping conflicts under each prospective site; "Add anyway" proceeds with all, "Cancel" aborts the submit. |
| Radius-change conflict surfacing | Locked warn scope is "add/move"; radius change not named | Radius change recolors zones passively (recompute `conflictIds` + redraw) — no modal; modal warn stays scoped to add/move. |
| Zone circle alpha/stroke values | ADR specifies translucent fill + stroke but no exact RGBA | Non-conflict `#1558b0` fill α38 / stroke α200 w1; conflict `#b00020` fill α46 / stroke α220 w2 — reusing existing literals; strokes clear the 3:1 graphical bar. |
| `is_zone_on` exposure | ADR keeps it as a separate master toggle | W3 picker does NOT expose `is_zone_on`; "Off" is expressed via `exclusivity_radius_mi = null` (the locked off semantic). |
