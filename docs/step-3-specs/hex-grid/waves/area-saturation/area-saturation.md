# Wave 4 — area-saturation (the hex payoff)

**Status:** plan-only.

**Ships:** a saturation heatmap — "how locked-up is this territory."

- H3 tessellation per viewport/region; per-cell coverage = in-any-zone (or overlap-weighted).
- Saturation heatmap layer (deck.gl H3HexagonLayer); aggregate by viewport / metro / ZIP.
- Prospecting view: "show open area near here."

**Likely per-vertical** (follows OD-1 from Wave 3): a per-vertical saturation heatmap.

**Gates:** performance-reviewer (per-viewport hex compute) · code-reviewer.

Depends on: Wave 3 (exclusivity-engine).
