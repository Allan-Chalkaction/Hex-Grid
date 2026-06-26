---
name: bulk-jam
description: "TOMBSTONE — fully retired (ADR-112). Convergence → /sweep; transcript-capture → /idea-ingest. Run /sweep to cluster+converge the inbox into jams, or /idea-ingest to capture ideas from a discussion."
user_invocable: true
---

# /bulk-jam — RETIRED (split into /sweep + /idea-ingest)

`/bulk-jam` carried two roles; both have moved (ADR-112):

- **Convergence** (cluster + compose + jam-per-cluster) → **`/sweep`** (ADR-112 Wave 3). Run `/sweep` and
  answer the `new-cluster` / `ingest-to-jam` verdicts; convergence happens in-skill (`core/skills/sweep/SKILL.md`
  § "Jam convergence").
- **Transcript-capture** (`--ingest`: segment a transcript/paste/session-log → dedup → confirm gate → write)
  → **`/idea-ingest`** (ADR-112 Wave 5 / Open Question #2, resolved standalone). Run `/idea-ingest <ref>`.
  The segmentation + dedup helper docs moved back to `core/skills/idea-ingest/{segmentation-prompt,dedup-rules}.md`.

(History: ADR-081 had merged `/idea-ingest` + `/bulk-idea-jam` into `/bulk-jam`; ADR-112 split it back out so
capture and convergence each live at their own door. The `bulk-jam-plan.py` cluster-plan script is unrelated to
this skill's retirement and is untouched.)
