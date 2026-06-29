# metros.json — provenance

**Vintage:** 2020 (U.S. Census Bureau Core-Based Statistical Area delineations +
2020 decennial / 2020 population estimates).

**Filter:** Metropolitan Statistical Areas (CBSAs) with total population
**≥ 250,000** (2020). 129 entries.

**Fields per row:** `{ name, lat, lng, pop }`
- `name` — CBSA title (principal-cities form, e.g. "Dallas-Fort Worth-Arlington").
- `lat` / `lng` — an approximate central coordinate for the metro's primary city
  (label-anchor only; this is reference geography for a `TextLayer`, not a precise
  centroid).
- `pop` — 2020 total population (rounded to the published estimate).

**Why static-bundled:** capitals + metros are reference geography, not tenant
data — no fetch, no key, no migration. A decennial refresh (the next CBSA
delineation / census) is a JSON edit, not a code change (see ADR-005 D2 + the
Wave-5 spec "Out of Scope" decennial-refresh note).

**Capitals (`capitals.json`):** the 50 U.S. state capitals (`{ name, state, lat,
lng }`), one per state, public/static coordinates.

> JSON forbids comments, so this sibling `.md` is the provenance carrier
> (AC-008 accepts a `metros.source.md` or a leading `_meta` row; this file is the
> chosen carrier).
