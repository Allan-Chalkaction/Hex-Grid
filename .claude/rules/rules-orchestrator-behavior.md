# Orchestrator Behavioral Rules

These rules govern how the orchestrator (main Claude Code session) behaves across all projects.

---

## Orchestrator NEVER Writes Source Code

**HOOK-ENFORCED** — `block-source-edits.sh` blocks Edit/Write on application source files from the orchestrator.

The orchestrator MUST delegate all application source code changes to implementer agents. No exceptions for "simple" changes. The orchestrator-permitted paths are explicitly enumerated below.

### Orchestrator-permitted paths

The only paths the orchestrator may directly edit are:

- `docs/**` — documentation, ADRs, build principles, session logs, pipeline run artifacts
- `core/rules/**` — rules files (claude-infra's own rule definitions)
- `core/agents/**` — agent definitions
- `core/skills/**` — skill definitions
- `core/commands/**` — slash commands
- `core/config/**` — workflow phase config, gate matrix, etc.
- `core/gate-prompts/**` — gate prompt templates
- `core/hooks/**` — hook scripts
- `core/scripts/**` — utility scripts (`test-*.sh`, `wave-manifest.py`, etc.)
- `CLAUDE.md` — project-level CLAUDE.md
- `.claude/settings*.json` — project settings
- `.claude/agent-context/**` — project-specific agent context overlays

Caveat: `block-active-runs-edits.sh` blocks `Edit|Write` on `.claude/agent-memory/active-runs/*.json` even though the path falls under the broader `.claude/` umbrella. Orchestrator state-file mutations MUST use Bash + `jq` + `tmp` + `mv` (the `block-active-runs-edits.sh` hook does not match Bash).

### Application source files are NOT orchestrator-permitted

Source files in consumer-project paths (`src/`, `app/`, `apps/`, `client/`, `server/`, `lib/`, `packages/`, language-specific extensions like `*.ts`, `*.tsx`, `*.py`, `*.go`, `*.rs`, `*.swift`, `*.kt`, `*.sql` outside the `core/**` infrastructure paths above) are NOT in the permitted list. The orchestrator MUST delegate edits to those paths to an implementer agent — even for "small obvious" changes — except when bypass mode is active.

**Bypass mode lifts the source-file restriction** for small, obvious changes (~10 lines or less, no specialist context required). See `core/rules/rules-bypass-mode.md` for the full authority contract. The orchestrator-permitted paths above remain the defaults for non-source paths regardless of bypass status.

### Hook contract

`block-source-edits.sh` enforces a two-tier check (orchestrated session, no worktree):

1. **Bypass short-circuit.** If `.claude/agent-memory/bypass-active.json` has `enabled: true`, exit 0 (allow). Bypass is the unrestricted-mode escape hatch.
2. **claude-infra path allowlist.** If the file path matches `*/core/{scripts,hooks,agents,rules,skills,commands,config,gate-prompts}/*`, exit 0 (allow). These are claude-infra's own infrastructure paths.
3. **Source-extension blocklist.** If the file path has a source extension (`.ts`, `.tsx`, `.js`, `.jsx`, `.css`, `.scss`, `.sql`, `.astro`, `.svelte`, `.vue`, `.py`, `.go`, `.rs`) AND the cwd is the main repo (not a worktree) AND no active plan step exists, exit 2 (block).
4. **Default.** Anything else, exit 0 (allow).

## Mandatory Exploration Before Implementation

**HOOK-ENFORCED** — `require-protocol.sh` requires at least one completed Explore agent before any implementer-tier dispatch (the per-track arm checks `completed_agents[]`). **Applies to nimble and orchestrated engine runs.** Bypass mode short-circuits the hook.

Under the v2 engine the **Workflow script's explore step** dispatches the Explore agent(s) — the orchestrator does not hand-drive exploration in its own turn. The exploration step is part of `core/scripts/workflows/{nimble,orchestrated}.js`; the engine satisfies CHECK 5 by completing it before the implement step.

## fable-stays-light

**HOOK-ENFORCED** — `block-fable-dispatch.sh` (PreToolUse:Agent) gates model tier at dispatch.

- Delegated/analysis/retrieval passes floor at **sonnet**: an unpinned or pinless dispatch is blocked; an absent dispatch model resolves to the child's frontmatter `model:` pin.
- **Fable is dispatch-banned** — an explicit Fable model param is blocked unconditionally; a frontmatter Fable pin is allowlisted only for the `examiner` agent-type seat (type-keyed `{examiner}`, never pin-detected).

ADR-099 (governing); ADR-095 (examiner seat survives its temporary Opus repin).

### Examiner-dispatch telemetry — every examiner dispatch ledgers (ADR-088 D4)

**BINDING.** EVERY examiner dispatch appends ONE line to `docs/step-3-specs/_fable-spend.jsonl` — including
an orchestrator-internal examiner dispatch that does NOT route through the `/examine` skill. There is no
"untracked" examiner seat: if you dispatch an examiner outside `/examine`, you append the ledger line
yourself at the dispatch site. REUSE the `/examine` O_APPEND snippet VERBATIM (`core/skills/examine/SKILL.md`
§d, lines 67–76) — do NOT re-author the JSON. The nine ADR-088 D4 fields are FIXED
(`{ts, agent, target, in_tokens, out_tokens, cache_create, cache_read, session, verdict, over_envelope}`,
no additions). Token COUNTS only — never message content. `jq -nc` is load-bearing (CR-001): it guarantees
a valid JSON line regardless of quotes/backslashes in `$TARGET`. Single-line O_APPEND (`>>`, ADR-085 D4) —
never read-modify-write, never `_w()`. The ledger is born on first dispatch (do not pre-create an empty one).

```bash
TS="$(date -u +%FT%TZ)"
OVER=false; if [ "$IN_TOKENS" -gt 90000 ] || [ "$OUT_TOKENS" -gt 4000 ]; then OVER=true; fi
# jq -nc guarantees a valid JSON line regardless of quotes/backslashes in $TARGET (CR-001)
jq -nc --arg ts "$TS" --arg target "$TARGET" --arg session "$SESSION" --arg verdict "$VERDICT" \
  --argjson in_tokens "$IN_TOKENS" --argjson out_tokens "$OUT_TOKENS" \
  --argjson cache_create "$CACHE_CREATE" --argjson cache_read "$CACHE_READ" --argjson over "$OVER" \
  '{ts:$ts,agent:"examiner",target:$target,in_tokens:$in_tokens,out_tokens:$out_tokens,cache_create:$cache_create,cache_read:$cache_read,session:$session,verdict:$verdict,over_envelope:$over}' \
  >> docs/step-3-specs/_fable-spend.jsonl
```

ADR-088 D4 (schema + the every-dispatch-ledgers rule); ADR-085 D4 (single-line O_APPEND). As of this wave
there are ZERO non-`/examine` examiner-dispatch sites — the snippet is made available + documented here so
any future internal dispatch instruments correctly with no re-authoring.

## No plan-steps / decomposition under the engine

There is no `plan-steps.json`. Neither `/nimble` nor `/orchestrated` produces one; the Workflow script *is* the plan — dependency order, parallelism, and per-ticket dispatch live in the script, and durable state is the thin manifest (`run-manifest.py`, `tickets[]`).

- **Nimble** dispatches a single `implementer` in a worktree from `spec.md`/`prompt.md` + the exploration findings, then a staleness-guarded integrate — no decompose, no plan-steps, no per-step loop.
- **Orchestrated** may run an optional `[decompose]` step *inside the script* to split a wave into tickets, then a one-implementer-per-wave build — engine-internal, not a hook-gated artifact.

---

## Scope and Intent Clarification

**BEHAVIORAL** — no hook.

### Never assume the simpler interpretation

When the user's prompt contains ambiguous references, MUST ask which item(s) they mean before acting.

### Never unilaterally reduce scope

When you believe work exceeds nimble scope, present that as a **recommendation with reasoning**, not a decision. The user decides scope.

### When the user says "fix that" — scope to everything they described

If the user described multiple problems and says "fix that," the default interpretation is **all of it**.

### Track classification is a recommendation

You may recommend a track (nimble vs. orchestrated) with reasoning, but do NOT defer work without the user's agreement.

---

## Working Style

- Present 2-3 options with tradeoffs — don't assume the "simple" approach
- Ask before choosing between architectural approaches
- Do not start implementing until the user explicitly says to proceed (exception: when operating within an active engine run (`/nimble`, `/orchestrated`, `/chain`) or an injected advisory/loop mode, follow the run's flow / injected instructions — those override this rule)
- Do not offer to commit unless asked
- Be direct and concise — lead with the key point

---

## Phase-prompt forward-narration discipline (B5)

**BEHAVIORAL** — no hook.

Phase docs MUST NOT end with informational forward-narration ("the next inject will fire X," "I'll dispatch @Y next," "the verdict is the next halt"). Such narration ends the message turn and reads as a halt to the operator, even when no action is needed.

This discipline now applies to the orchestrator's **surface/halt messages** (the engine computes the surface; the orchestrator performs the single consolidated halt — ADR-036). Such a message MUST end with one of:
- The disposition just made (the canonical case).
- An explicit `**Status:** <one-line, no-action-needed labeled>` if forward-state is genuinely informative for the operator.
- The canonical consolidated-halt message (ADR-036 surface contract) when the run actually halts.

Documentation of advancement mechanism in "Advancement signal" sections is NOT forward-narration — it's scope documentation. Leave those alone.

`/loop`-driven autonomous runs are exempt from the no-forward-narration rule — forward-narration is the mechanism by which CC self-paces in `/loop`.

This discipline is a component of ADR-014's halt protocol (Wave C C1).

---

## Context Management

- Use `/compact` proactively at ~70% context usage
- When compacting, preserve: current feature slug, plan location, completed vs. remaining work
- When context fills (~60%), write a checkpoint doc

---

## Session Closeout

Before ending any implementation session, check:
- New pattern established? Document it
- Architecture decision with tradeoffs? Write ADR
- New critical rule discovered? Add to CLAUDE.md
