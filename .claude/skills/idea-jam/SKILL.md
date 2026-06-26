---
name: idea-jam
description: "TOMBSTONE — convergence role absorbed into /sweep (ADR-112 Wave 3). Cluster + compose + converge a jam: run /sweep and answer ingest-to-jam / new-cluster. Regenerate the ideas INDEX: python3 core/scripts/idea-map.py."
user_invocable: true
---

# /idea-jam — RETIRED (convergence absorbed into /sweep)

Replaced by `/sweep` (ADR-112 Wave 3, PEC-T8/T9). The jam convergence path — cluster → compose → converge a
fork-resolving thesis → write the vitality line → targeted move — now lives **in-skill in `/sweep`** (see
`core/skills/sweep/SKILL.md` § "Jam convergence"). There is no separate convergence door.

**What to run instead:**

- **Cluster + converge a jam** (the old full `/idea-jam <slug>` path, and the `--cluster-only` /
  `--compose-only` grouping+grounding passes) → run **`/sweep`** and answer the `ingest-to-jam` /
  `new-cluster` verdicts; `/sweep` converges the cluster in-skill, preserving the `jam-` prefix and the
  kebab-validated slug. The `shape` verdict promotes a `needs-shaping/` capture to `ready-to-build/` first.
- **Regenerate `docs/step-1-ideas/INDEX.md`** (the old `--map-refresh`) → `python3 core/scripts/idea-map.py`
  (the renderer is unchanged; `--print` / `--check` pass through).

The underlying `idea-map.py` renderer and the `jam-`-prefixed workspace contract are unchanged. This stub is
kept as a discoverability pointer (ADR-081 tombstone convention).
