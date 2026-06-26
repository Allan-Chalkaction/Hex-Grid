# Agent Routing and Contextual Triggers

## Contextual Agent Triggers

**BEHAVIORAL** — no hook for contextual triggers (the orchestrator must invoke them).

When your work touches certain file patterns or domains, you MUST invoke the corresponding agents before marking the work complete. The specific file pattern → agent mappings are defined in each project's CLAUDE.md.

## Default Routing Rule

**HOOK-ENFORCED** — `require-track-selection.sh` (UserPromptSubmit) blocks any bare prompt that isn't carrying an explicit entry-mode marker, has no active run for the session, and isn't in bypass mode. The user must pick an entry mode before the orchestrator sees their prompt:

| Entry mode | When to use | What it does |
|------------|-------------|--------------|
| `/nimble`  | quick fix or single-feature work | light engine preset: explore → implement (worktree) → integrate (staleness-guarded) → batch-gate. A Workflow script drives the chain; no plan-steps, no per-turn phase machinery. |
| `/orchestrated <slug\|folder>` | a pre-decomposed wave (or a planned epic folder) needing CTO + spec + gates | heavy engine preset: cto → architect-pre → pm-spec → [ui-spec if has_ui] → [decompose] → explore → one-implementer wave-build (in-place; commit per ticket) → integrate (verification no-op) → batch-gate → [architect-final if crossWavePrior]. **Default epic build = all-waves-straight** (front-loaded, ADR-112 Wave 2); a PLANNED folder skips the advisory preamble + decompose (plan-detect, slice-once). |
| `/orchestrate-epic <epic-slug>` | **opt-in** interleave — re-plan each wave on prior waves' *built* reality | interleaved plan+build per wave (ADR-059; opt-in per ADR-062): roadmap wave N → build wave N → roadmap wave N+1 grounded on the built wave N → … on a shared epic branch (sets `crossWavePrior`). **Not the default epic build** — choose it only when each wave must ground on built reality; otherwise `/orchestrated <folder>` builds all waves straight. Skill: `core/skills/orchestrate-epic/SKILL.md`. |
| `/chain a,b,c` | operator-supplied custom agent chain | runs the ordered agent list on the engine under the shared autonomy contract + consolidated surface. |
| `/loop-task` | bounded, test-verifiable grind | scaffolds a PRD + progress log, caps iterations, hands off to the `ralph-loop` plugin. For get-the-suite-green / mechanical migrations — not design work. |
| `/resume` | resume an interrupted v2 run | manifest-driven resume of a nimble/orchestrated/chain run from its thin `run-manifest.json`. |
| `/bypass`  | just chat with the orchestrator | no run protocol, no implementer gating |
| `/sweep` | triage the ideas inbox + converge a jam | the **convergence door** (ADR-112 Wave 3): on-demand triage of `docs/step-1-ideas/` + shelves + chore lane, AND in-skill jam convergence (cluster → compose → fork-resolving thesis → vitality line → targeted move) + the `shape` promotion (`needs-shaping → ready-to-build`). Absorbed the retired `/idea-jam`/`/bulk-jam`/`/planner jam` jam roles. Full contract: `core/skills/sweep/SKILL.md`. |
| `/roadmap` | iterative epic→roadmap (Phase E) or wave→spec (Phase W) planning | autonomous-to-completion by default; `--attended` opts into round-by-round tuning halts. Advisor-tier only, no implementers; produces the wave specs `/orchestrated` consumes. Full contract: `core/rules/rules-advisory-modes.md` |
| `/planner [slug]` | repo-aware planning partner | drafts plans/specs/prompts/ADRs as files; routes into `/research`, `/roadmap`, feature-decomposition, adr; advisor-only. Full contract: `core/rules/rules-advisory-modes.md` |

`Track: Nimble` markers in the prompt body also satisfy the gate (used when tickets arrive from external systems).

**Nimble engine chain:** `explore → implement (worktree) → integrate (staleness-guarded) → batch-gate`.
The script dispatches each agent; the orchestrator persists the returned payload (`persist-run-artifacts.py`) and performs any consolidated halt. No spec-decomposer, no `plan-steps.json`, no per-step active-marking.

**Orchestrated engine chain:** `cto → architect-pre → pm-spec → [ui-spec if has_ui] → [decompose] → explore → one-implementer wave-build (in-place; commit per ticket in dependency order) → integrate (verification no-op) → batch-gate → [architect-final if crossWavePrior]`

**`"Execute directly"`** is NOT a routing marker — it waives advisory phases but NOT the engine's exploration step.

**Multiple runs per session:** New work mid-session gets a new run — new run folder, new thin manifest.

**Single-agent shortcut:** Claude Code's native `@<agent-name>` syntax invokes an agent directly (e.g., `@code-reviewer review src/auth.ts`). The track-selection gate skips `@`-prefixed prompts. Implementer-tier agents (`implementer`, `wave-implementer`) are still blocked by `require-protocol.sh` unless bypass is active or the engine has marked a run in-progress — run `/bypass` first if you want to invoke them off-track.

**System-level enforcement (two hooks):**
1. `require-track-selection.sh` (UserPromptSubmit) blocks bare new-work prompts until an entry mode is chosen.
2. `require-protocol.sh` (PreToolUse:Agent) — once inside a run — gates implementer agents per the run's `track`: it requires a run state file, that at least one Explore agent has completed, and (per track) the engine's in-progress invariants. Bypass mode short-circuits the protocol checks. Both hooks read local files only — unfakeable.

---

## Agent Routing Table

| User Says | Use |
|-----------|-----|
| "Is this secure?" / "Security review" | security-auditor |
| "Check accessibility" / "A11y audit" | accessibility-auditor |
| "Performance review" / "Why is it slow?" | performance-reviewer |
| "UI spec" / "Visual requirements" | ui-spec |
| "UI review" / "Does this look right?" | ui-review |
| "Review this code" / "PR review" | code-reviewer |
| "Write tests" / "Generate tests for" | qa-tester |
| "What could go wrong?" / "Pre-mortem" | cto-advisor |
| "Document this" | docs-writer |
| "Review migration" | db-migration-reviewer |
| "Audit dependencies" | dependency-auditor |
| "Build [feature]" | Full build (`/orchestrated`) — see the orchestrated engine chain above |
| "Use the implementer" / "Send this to X" / "Have [agent] look at this" | `@<agent-name> <payload>` (Claude Code native; run `/bypass` first if invoking an implementer cold) |
| "Gate this batch" | `/batch-gate` skill |
| "Batch UI tweaks" | `/batch-ui-tweaks` skill |
| "What's left to QA?" | `/qa-status` skill |
| "Merge these branches" / "Bring my worktrees back" / "Land these features" | `/merge-orchestrator` skill |
| "Will these branches conflict?" / "Conflict scan" / "Check overlap before merging" | `@merge-conflict-scanner` |
| "Re-gate after merge" / "Verify the merge didn't break anything" | `/post-merge-gate` skill |

---

## Persisting report-class `@`-agent output

**HOOK-ENFORCED** (ADR-080 D2 — amends ADR-050). The off-engine `@<agent>` shortcut scaffolds no run
folder, so a high-signal report (audit verdict, security finding, code review) would evaporate into chat.
The capture is now a deterministic PostToolUse arm in `core/hooks/sync-artifacts-post-agent.sh`: on Agent
completion where the agent is **report-class**, **no active-run state file exists** for the session, and the
output is non-trivial, the hook scaffolds `docs/step-5-pipeline/YYYY-MM-DD/HHMM-AUDIT-<agent>/` and writes
`findings/<agent>.md` (fail-open; idempotent). **The report-class agent list's source of truth is that hook
(`REPORT_CLASS_AGENTS`)** — not this file. Engine runs persist via `persist-run-artifacts.py` (ADR-036) and
are skipped by the arm's active-run check.

## Ad-Hoc Audits

Some agents are better run periodically across the full app rather than as per-change gates.

### Accessibility Audit (Full App)

**Trigger:** User requests ("run a11y audit", "WCAG sweep") or periodic cadence
**Agent:** accessibility-auditor
**Scope:** All UI surfaces
**Output:** `docs/step-5-pipeline/YYYY-MM-DD/HHmm-AUDIT-accessibility/findings/accessibility-auditor.md`

### Merge Conflict Scan (Multi-Branch)

**Trigger:** User requests ("scan these branches", "will these conflict?", "what's the merge order?") or as the first step of `/merge-orchestrator`
**Agent:** merge-conflict-scanner
**Scope:** Two or more feature branches against a base ref
**Output:** `docs/step-5-pipeline/YYYY-MM-DD/HHmm-AUDIT-merge-scan/findings/merge-conflict-scanner.md` (ad-hoc) or `{merge_run_dir}/findings/merge-conflict-scanner.md` (inside `/merge-orchestrator`)
