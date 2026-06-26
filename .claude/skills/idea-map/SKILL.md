---
name: idea-map
description: "TOMBSTONE — INDEX render is a direct script call (ADR-081 → ADR-112 Wave 3). Regenerate the INDEX: python3 core/scripts/idea-map.py."
user_invocable: true
---

# /idea-map — RETIRED (call the renderer directly)

The INDEX render was absorbed into `/idea-jam --map-refresh` (ADR-081); `/idea-jam` is now retired
(ADR-112 Wave 3). To regenerate `docs/step-1-ideas/INDEX.md`, call the renderer directly:
`python3 core/scripts/idea-map.py` (`--print` / `--check` pass through; the renderer is unchanged).

(ADR-081; tombstone — delete after one release.)
