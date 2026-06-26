---
name: bypass-mode-prompt-authoring
description: Use when authoring bypass-mode tickets — paste-into-fresh-session prompts that drive direct orchestrator authority. Provides the autonomy framing, halt-protocol contract, and standard ticket structure. Triggers - "draft a ticket", "author a bypass ticket", "fresh-session prompt".
---

# Bypass-mode prompt authoring

Bypass-mode tickets are paste-into-fresh-session prompts. They differ from `/nimble` and `/orchestrated` tickets in that they expect the executing CC session to operate with direct orchestrator authority (per `core/rules/rules-bypass-mode.md`) rather than under an engine run. The prompt itself is the complete authoring brief — there is no run folder, no state file, no thin manifest.

This skill provides the canonical structure + autonomy framing so authored tickets calibrate consistently across sessions and operators.

## When to use it

- The user asks "draft a ticket" / "author a bypass ticket" / "write a fresh-session prompt".
- A planning pass has produced a wave decomposition and the next step is per-ticket prompt authoring.
- A claude-infra enhancement run is being decomposed (e.g., the 2026-05-08 enhancement plan).

## When NOT to use it

- `/nimble` ticket prompts (use the nimble template — that flow has its own state machine).
- `/orchestrated` wave plans (those are decomposed via `core/skills/feature-decomposition/` and handed to the wave planner).
- ADR-shaped decision documents (use ADR template).

## Standard 9-section template

Every bypass-mode ticket follows this structure:

```markdown
# {ID} — {one-line title}

> **Wave:** {A | B | C | E}
> **Track:** bypass (paste-into-fresh-session)
> **Estimated scope:** ~{LOC} across {N} files
> **Source plan:** {path-to-plan}#section
> **Source brief:** {section}

---

## Paste-target

Fresh CC session in `{repo-root}`. Confirm `pwd` matches and run `/bypass on` before pasting.

---

## Standing instructions

{The canonical autonomy framing — see "Canonical autonomy framing" below.}

---

## Context

{2-4 paragraphs: what the defect is, what the fix accomplishes, why now, evidence.}

---

## Files in scope

1. **`path/to/file`** — what changes.
2. ...

Cap: {N} files.

---

## Implementation

### Step 1 — ...

{Concrete steps with code blocks, file references, exact line numbers when known.}

---

## Acceptance criteria

| AC | Description | Verification |
|---|---|---|
| AC-1 | ... | ... |

> **Verification scope discipline (F-NEW-01).** The Verification column SHOULD specify commands at **CI scope**, not a narrow local-only subset. If CI runs e.g. `test-orchestrated-mode.sh` + `test-instrumentation.sh` + `test-wave-scaffold-ticket.sh` + 4 others, the Verification column should name the FULL CI battery (or at minimum the union of suites that touch the ticket's files) — not just "the tests I changed." The cost of a narrow local scope is pre-push CI failures of the "regression caught only at CI" shape (Wave D D7 surfaced this: a 7-suite local battery omitted `test-orchestrated-mode.sh` which CI ran, catching a phase-header regex regression that required a follow-up fix commit on PR #5). Implementer-judgment is fine for "which subset is sufficient" if explicitly justified in the READY FOR REVIEW message; silently narrowing scope is the failure mode this discipline targets.

---

## Out of scope

- Do NOT ...

---

## Halt protocol

{Per-ticket-specific halt criteria. References the canonical autonomy framing.}
```

## Canonical autonomy framing (verbatim — copy into every ticket)

```markdown
## Standing instructions

Operate autonomously throughout this ticket. You are the planner during execution, not an execution agent escalating decisions. Decide and proceed on:
- File-location questions, sub-task ordering, naming, formatting.
- Structural choices that don't propagate beyond the ticket.
- Mechanical workaround dispositions.
- Test-organization decisions that don't change coverage.
- Commit splitting/squashing within the ticket's commit budget.

Surface only when:
- The work meaningfully exceeds the prompt's scope estimate.
- You discover a defect outside the ticket's surface that warrants its own follow-up ticket.
- A genuine design fork emerges that wasn't anticipated in the prompt.
- You hit an authorization-required boundary (push, PR open, merge, force-push, secrets, destructive operations).

"Surface" means: end your message with a structured finding + proposed disposition, not a halt-and-wait. Default flow continues; the operator objects only if needed.

When done, end with: a one-line summary, the commit SHA(s) you wrote, and `READY FOR REVIEW`. Do not push.
```

## Halt-protocol tier framework

Bypass-mode tickets calibrate aggressively toward Tier 0/1 per ADR-014 (Wave C C1 — halt protocol as first-class concept). The four tiers:

- **Tier 0 — no fork, proceed.** The decision is convergent given context (the spec, the prompt, the repo's existing pattern, or a prior decision specifies the disposition unambiguously). No mention.
- **Tier 1 — pass-through disclosure.** Decided X, proceeding. The next message reports the disposition. No halt.
- **Tier 2 — halt with default.** Type B halt: announce decision + default; continue unless operator objects. Operator response is optional.
- **Tier 3 — halt and wait.** Type A halt: real fork; operator must answer.

**Default-to-Tier-3 anchor (P-013):** when uncertain about which tier applies, default to Tier 3. The cost of an unnecessary surface is small; the cost of silent-wrong-disposition is large.

Examples:

- "Stale worktree from prior ticket → fold into next t-commit cleanup" → **Tier 0** (convergent given t-commit's existing cleanup discipline).
- "Choosing between two branches when both work" → **Tier 1** (pass-through with brief rationale; operator may redirect).
- "File-cap exceeded by deletion-cascade carve-out" → **Tier 2** (halt with default APPLY-CARVE-OUT; operator may reject).
- "CTO returns SIMPLIFY on ambitious feature" → **Tier 3** (real strategic fork; operator must direct).

## Worked example — small surgical ticket

A complete reference ticket for a minor portability fix:

```markdown
# X1 — example helper portability fix

> **Wave:** A
> **Track:** bypass
> **Estimated scope:** ~20-30 LOC across 1 file

---

## Paste-target

Fresh CC session in `~/Desktop/Development/projects-active/new-claude-infra/`. `/bypass on` first.

---

## Standing instructions

Operate autonomously. End with `READY FOR REVIEW` and commit SHA(s); do not push. Halt only for: scope overrun, related-defect discovery, or authorization boundary.

---

## Context

`core/scripts/example-helper.sh` calls `python3 core/scripts/wave-manifest.py` with a relative path on lines 78 and 96. From a consumer-project cwd this fails. Fix: self-locate via `${BASH_SOURCE[0]}` traversal.

---

## Files in scope

1. **`core/scripts/example-helper.sh`** — modify path resolution.

Cap: 1 file.

---

## Implementation

### Step 1 — Self-locate

Add at top of script after `set -euo pipefail`:

\`\`\`bash
INFRA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_ROOT="$(dirname "$INFRA_ROOT")"
WAVE_MANIFEST_PY="${INFRA_ROOT}/core/scripts/wave-manifest.py"
\`\`\`

### Step 2 — Replace invocations

Lines 78, 96: `python3 core/scripts/wave-manifest.py` → `python3 "$WAVE_MANIFEST_PY"`.

---

## Acceptance criteria

| AC | Description | Verification |
|---|---|---|
| AC-1 | Helper succeeds from consumer-project cwd | New synthetic test |
| AC-2 | Helper succeeds from claude-infra cwd (regression) | Same test, positive control |

---

## Out of scope

- Do NOT modify `wave-manifest.py`.
- Do NOT change unrelated paths.

---

## Halt protocol

Halt for: BASH_SOURCE traversal doesn't work. Otherwise proceed.
```

## Authoring checklist

Before declaring a ticket draft READY FOR REVIEW:

- [ ] All 9 sections present.
- [ ] Files in scope ≤ 10.
- [ ] Acceptance criteria are testable (verification column non-empty).
- [ ] **Verification commands cover CI scope, not just local-narrow** (F-NEW-01). If the implementer's local battery is a strict subset of CI's, the prompt either lists the FULL CI battery in the Verification column OR explicitly authorizes a narrower local subset with justification (e.g., "test-orchestrated-mode.sh excluded from local run because the change doesn't touch phase docs; surface as Tier 1 disclosure in READY FOR REVIEW").
- [ ] Out of scope explicitly enumerates the obvious-but-rejected adjacent work.
- [ ] Halt protocol distinguishes DO-halt from DO-NOT-halt cases.
- [ ] Standing instructions block is verbatim (do not paraphrase).
- [ ] Dependencies on other tickets are explicit (Depends on X note at the bottom).
- [ ] Scope estimate (LOC + file count) is realistic — under-estimating produces scope-overrun halts.

## Cross-references

- **Bypass authority contract:** `core/rules/rules-bypass-mode.md`.
- **Halt protocol ADR:** `docs/decisions/ADR-014-halt-protocol.md` (Wave C C1).
- **Tier 3 anchor (P-013):** `docs/build-principles.md`.
- **Sample tickets:** `docs/step-2-planning/2026-05-08-claude-infra-enhancement-tickets/` (the canonical batch authored against this skill's structure).

## Adding to this skill

When a recurring authoring pattern emerges across multiple ticket batches, extend the template here. Per **P-015** (recurrence-watch discipline), wait for the third instance before adding — first instance is one example, second drafts the addition, third applies it. Keep the canonical autonomy framing block short; long is better moved to ADR territory.
