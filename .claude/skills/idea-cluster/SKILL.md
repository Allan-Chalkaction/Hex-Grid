---
name: idea-cluster
description: "TOMBSTONE — clustering moved to /sweep (ADR-081 → ADR-112 Wave 3). Smart-cluster + converge the inbox: run /sweep."
user_invocable: true
---

# /idea-cluster — RETIRED (clustering now in /sweep)

Replaced by `/sweep` (ADR-081 absorbed it into `/idea-jam`; ADR-112 Wave 3 moved convergence to `/sweep`).
The smart-clustering gate (ADR-056) is now `/sweep`'s in-skill convergence — run `/sweep` and answer the
`new-cluster` / `ingest-to-jam` verdicts.

(ADR-081; tombstone — delete after one release.)
