---
description: Scan for undocumented architectural decisions or create a new ADR
---

# /adr — the single ADR entry point (wraps @adr-scanner; ADR-081)

`/adr` is the **only documented entry point** for ADR discovery + drafting. Its scan mode runs in a
read-only subagent: **dispatch `@adr-scanner`** to perform the work — do NOT attempt the scan yourself.
The `adr-scanner` agent is intentionally not on the routing surface (ADR-081); reach it through this skill.

**Dispatch (scan mode):** invoke the agent via Claude Code's native syntax —

```
@adr-scanner scan the codebase for undocumented architectural decisions and generate draft ADRs
```

Specific decision or area to document (if any): $ARGUMENTS

If a specific decision is described, instruct `@adr-scanner` to create a formal ADR for it. Otherwise,
instruct it to scan the codebase for undocumented architectural decisions. Either way, the agent does the
work and you persist its draft ADRs to `docs/decisions/`.

## ADR number allocation (binding)

When the adr-scanner (or the orchestrator) needs to allocate a new ADR number, it MUST claim the number atomically via `python3 core/scripts/claim-id.py adr <slug>` — NEVER read-max-then-write (the ADR-061 collision: two sessions both scanned for max, both wrote `ADR-061-*.md`, content was lost in the rename-back fix). `claim-id.py adr` uses POSIX `O_EXCL` against a slug-independent `ADR-NNN.lock` sentinel so concurrent claims with different slugs still get different numbers. Binding contract: ADR-072.
