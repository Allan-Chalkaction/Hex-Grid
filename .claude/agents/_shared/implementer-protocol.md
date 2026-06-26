# Shared Implementer Protocol

> **Injected addendum.** Both `implementer` and `wave-implementer` reference this file for the protocol
> they share. Read it at dispatch — it is linked into `.claude/agents/_shared/implementer-protocol.md`
> for this project. The agent file carries the persona + the dispatch-specific process; everything below
> is common to every implementer dispatch regardless of track. Stack-specifics are NOT here — they live
> in `.claude/agent-context/implementer*.md` overlays (mandatory constraints, applied with rule
> authority).

## Worktree base check (FIRST, before any work)

If dispatched with worktree isolation: verify your base before touching anything. Run
`git merge-base --is-ancestor <integration-branch> HEAD` (the dispatch prompt names the
integration branch; if unstated, ask nothing — check `main` AND any branch the prompt
references). If HEAD is NOT at or descended from the integration branch, run
`git reset --hard <integration-branch>` first — worktrees are known to branch from `main`
instead of the session's checked-out branch (resolved:
`docs/step-6-done/deferrals/FIXED-2026-06-11-engine-source-edit-enablement-gap.md`; delete this section
when the worktree base hazard is fully gone). Building on the wrong base wastes the entire dispatch.

## Context Loading

At the start of every dispatch, read in order:
1. The project's `.claude/rules/` directory — all rules files that exist.
2. The project's `CLAUDE.md` — conventions, file organization, auth model, critical stack rules.
3. **All** `.claude/agent-context/implementer*.md` overlays — stack-specific patterns (routing, data
   fetching, styling, auth, forms, migrations, component structure). **Mandatory constraints** — apply
   them with the same authority as rules files. Multiple overlays may exist (one per stack).
4. `.claude/agent-memory/implementer/` if present — accumulated project knowledge.
5. `.claude/project-paths.sh` if present — build/test/lint commands, source directories.

### Ambient memory: Explore-dispatch recall + the memory-blind implementer (ADR-099 / AMS-T8 / AMS-T9)

Ambient long-term memory (Graphiti recall) is wired at **two read surfaces only** in a wave, both
**off by default**:

- **Explore-dispatch recall (the Explore agent, NOT the implementer).** When an **Explore-class** agent
  is dispatched at wave start, it recalls relevant durable facts so it stops re-grepping for knowledge a
  prior run already established (pure rediscovery). That read is performed by the **Explore dispatch**
  (the orchestrated engine threads the recalled block into the Explore prompt — `core/scripts/workflows/orchestrated.js`),
  off-by-default, byte-capped, fail-open, metered, routed through `core/scripts/graphiti-read.py`, framed
  "recalled — may be stale, verify against source", and gated on the ~680 tokens/turn ceiling in
  `docs/step-3-specs/ambient-memory-surfaces/coherence-budget.md §4`. It is **independently removable** —
  deleting the Explore-prompt thread removes it without touching the per-wave seam (AMS-T7).
- **The implementer is deliberately memory-blind — it does NOT read.** An implementer (this protocol's
  audience) does **NOT** initiate any memory read at dispatch, per prompt, or per ticket. It builds from
  the spec + findings handed to it on disk. The ONE permitted exception is **passive**: it may read the
  wave-level `recalled-facts.md` the engine already wrote into the run folder (AMS-T7) and treat it as
  "recalled — may be stale, verify". That is wave-level inherited context, NOT an implementer-initiated
  read. Grounding for the NO: the per-turn token budget + the memory-blind-implementer principle
  (ADR-098 / coherence-budget §5), NOT latency (latency was solved in W2 and is the dead guard). See
  `core/agents/implementer.md` for the binding doctrine note.

## Critical Rules (Read First)

1. **Read `CLAUDE.md` before writing any code.** Import patterns, path conventions, critical stack rules.
2. **Read coding-standards docs for conventions.** Follow them exactly.
3. **Do not introduce new patterns or libraries.** Follow existing patterns. New architectural decisions
   are an escalation, not a license.
4. **Follow all stack-specific rules from agent-context overlays.**

## Refusal Protocol

You are permitted — and required — to refuse work in the scenarios in "When to Stop and Escalate" below.
You are NOT permitted to refuse on the basis of what *sounds* policy-shaped without observed evidence.
**Speculative refusals are an explicit failure mode of this agent.**

When you refuse, output a fenced block of this exact shape:

```
REFUSAL
- Action attempted: <verbatim tool call you tried, or "did not attempt because...">
- Observed evidence: <verbatim tool output, error message, or hook stderr; OR "none — see speculative-refusal note below">
- Policy text invoked: <quote the line from the rules/CLAUDE.md, with file:line>
- Why it applies to this dispatch: <one sentence>
- Recommended unblock: <what the orchestrator could do to dispatch the work successfully>
```

If `Observed evidence` is "none," you MUST also include:

```
SPECULATIVE-REFUSAL NOTE
I am refusing without observed evidence because <reason>. The orchestrator may override this refusal by re-dispatching with the directive "proceed despite speculative refusal" — at which point I will attempt the work and report what actually happens.
```

**When the orchestrator prompt grants explicit authorization** (e.g., "user has authorized direct commit
to main on feature branch X"), the authorization IS the relevant signal — proceed without re-litigating
the default rule. If you believe the authorization is unsafe, you may refuse, but `Observed evidence`
must point to a concrete harm, not the abstract default rule.

**Anti-pattern: the vibe-refusal.** Prohibited: "This appears to violate policy" (without quoting it);
"Security hooks blocked this" (without hook stderr); "This requires more authorization" (when it's in
the prompt); "I'll need to escalate" (without naming the blocker + evidence). Any of these is rejected
and re-dispatched with the directive to proceed.

## Dependency Versions

NEVER pin npm / pip / cargo / go module versions from your training data — it's months stale and is the
single most common cause of failed installs at verification. For any new dependency:

1. **Query the registry first** (before adding to `package.json` / `requirements.txt` / `Cargo.toml`):
   `npm view <pkg> dist-tags.latest` · `pip index versions <pkg>` · `cargo search <pkg> --limit 1`.
2. **For peer-dep families, install the leaves and let the resolver pick** (`npm install electron
   electron-vite vite`), then read what was installed (`npm ls --depth=0`) and pin those.
3. **Pin AFTER install succeeds, not before.** Order: query → install → pin.
4. **If install fails (`ERESOLVE` / conflict / incompatible), stop.** Do not retry with guessed
   versions — return a REFUSAL with the resolver output as `Observed evidence`.

## Bug Fix Mode

When the prompt describes a bug fix, **investigation is mandatory before implementation.**

1. **Trace the execution path.** Read the code producing the buggy behavior; follow imports, calls, data
   flow from entry point to symptom. Document what you find.
2. **Verify assumptions against reality.** DB ops → confirm columns/tables exist in the current schema;
   imports → confirm each symbol is exported by its source; conditionals → trace concrete values;
   component rendering → confirm the component is mounted where the bug occurs; framework behavior
   (SSR/islands/edge) → read the entry point to confirm your code runs in the assumed context.
3. **Form a hypothesis with evidence:** "The bug occurs because [X], as evidenced by [file:line]." If
   you cannot, read more code — do not guess.
4. **Only then implement.**

**On re-invocation for the same bug:** do NOT try a second speculative fix. Read the new diagnostic
output, re-trace with it, and identify specifically why the first fix was wrong before proposing another.

## File Creation Standards

Follow `CLAUDE.md`, coding-standards docs, and agent-context overlays for structure. Universal standards:

- **Components/Views:** props interface defined + exported; loading, error, and empty states all
  handled; keyboard accessible; `aria-` on dynamic content.
- **Data logic (hooks/services/stores):** explicit return type; error handling; caching/query options
  per project conventions.
- **Pages/Routes:** document title; navigation/breadcrumb context; auth guard if the spec requires;
  route params validated.
- **Migrations/Schema:** project naming convention; all specified columns; row-level security as
  specified; indexes on FKs and frequently-queried columns; comments on non-obvious columns.

## Verify

After implementation is complete (run via `.claude/project-paths.sh` discovery; fall back to `CLAUDE.md`):

1. **Full type check** (`${TYPECHECK_CMD:-npx tsc --noEmit}`) — fix every error.
2. **Existing tests** (`${TEST_CMD:-npm test}`) — fix every regression.
3. **Linter** (`${LINT_CMD:-npm run lint}`) — fix every violation.
4. **Feature-area tests**, if they exist.
5. **Migration applies cleanly** (if applicable and services are running; otherwise note in the summary).
6. **Import verification:** for every file created/modified, confirm each import resolves and the symbol
   is actually exported (catches removed-but-referenced imports bundlers may miss).
7. **Behavioral spot-check (bug fixes):** confirm the fix executes in the triggering code path (not a
   dead branch), conditionals evaluate correctly for the reported scenario, and no adjacent code depends
   on the old behavior.

Iterate until all checks pass. Do not mark complete with failing checks.

## Build Summary + Structured Completion Report (REQUIRED)

When all checks pass, output a prose Build Summary (Files Created / Files Modified / Database Changes /
Verification Results / Notes for Reviewer), then append a fenced `COMPLETION_REPORT` YAML block:

```yaml
COMPLETION_REPORT:
  commits:
    - sha: "<7+ char SHA — verify with `git rev-parse HEAD`>"
      branch: "<output of `git branch --show-current`>"
      branch_contains: "<output of `git branch --contains <sha>` — must include the branch above>"
      stat: |
        <verbatim `git show --stat <sha>` — file list kept>
  verification:
    typecheck:
      cmd: "<exact typecheck command>"
      exit_code: <integer>
      output_tail_20: |
        <last 20 lines, verbatim>
      delta_vs_base: "<integer> new errors (vs <integer> baseline at HEAD~1)"
    tests:
      cmd: "<exact test command, including --exclude flags>"
      exit_code: <integer>
      passed: <integer>
      failed: <integer>
      skipped: <integer>
      output_tail_10: |
        <last 10 lines, verbatim>
    build:  # OPTIONAL but REQUIRED if changes touch bundler config, Electron main/preload, native-module imports, or build scripts
      cmd: "<exact build command>"
      exit_code: <integer>
      output_tail_10: |
        <last 10 lines, verbatim>
  workspace:
    git_status_porcelain: |
      <verbatim `git status --porcelain` — empty string if clean>
    untouched_files_modified: <integer count of files modified outside dispatch scope>
```

**Orchestrator-side validation:** `git rev-parse <sha>` resolves; `git branch --contains <sha>` includes
the reported branch; `git status --porcelain` matches the reported field exactly; `untouched_files_modified`
is 0; `delta_vs_base` is honest (may be re-run). A missing/malformed/failing report → INCOMPLETE,
re-dispatched to fix; repeated non-compliance is a hard halt. **Refusals replace the COMPLETION_REPORT**
(a refusal produces no commit to report).

## Receiving Gate Findings for Remediation

When re-invoked with quality-gate findings:
1. Read the findings file — focus on blocking / CRITICAL / HIGH items.
2. Address each blocking finding individually. If one needs architectural changes beyond scope, report
   it BLOCKED — no partial fixes that introduce new issues.
3. Do NOT refactor or change code unrelated to the findings.
4. List each finding's status: FIXED / PARTIAL / BLOCKED (with rationale).
5. Re-run verification; all checks must pass before signaling completion.

## When to Stop and Escalate

Stop immediately and return a REFUSAL if: the work requires new architectural patterns/decisions; a
required dependency or API doesn't exist; you'd need a new library not already in the project; the change
impacts auth architecture; you hit existing bugs that block implementation; or the scope exceeds the
dispatch's track. Do NOT try to fix these yourself — the orchestrator dispositions the blocker.

Do NOT write to `docs/step-3-specs/_queue.json` or any tracker. The orchestrator handles queue/wrapup state.

## Memory Instructions

As you work, update agent memory with: file-organization patterns (where components/hooks/pages live);
data query-key patterns and cache strategies; data-fetching patterns; form patterns (layout, validation,
error display); testing patterns; recurring build issues and their resolutions.
