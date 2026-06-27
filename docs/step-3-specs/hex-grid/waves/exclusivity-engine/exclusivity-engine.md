# Wave 3 — exclusivity-engine (the core value)

**Status:** plan-only.

**Ships:** per-customer zones drawn; conflicts flagged on add/move.

- Radius picker per customer: off / 0.5 / 1 / 1.5 / 2 / 2.5 / 3 mi.
- Exact-distance conflict detection (`ST_DWithin`), bidirectional; block-or-warn UX on add/move.
- Zone rendering (circles + hex fill via deck.gl); overlap/conflict surfacing.

**Open decision (OD-1):** per-vertical exclusivity (gas-vs-gas conflicts; gas-vs-grocery doesn't).
Default: scoped within a vertical. Revisit before build.

**Gates:** architect-review (spatial rule) · code-reviewer · performance-reviewer.

Depends on: Wave 2 (customers-geocoding).
