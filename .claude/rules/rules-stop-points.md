# Stop Point Enforcement

**BEHAVIORAL** — no hook.

When a prompt contains stop points (indicated by any of: `STOP`, `STOP HERE`, `-- STOP --`, `Wait for confirmation`, `Ready for next prompt`), you MUST:

1. **HALT all execution immediately** at the stop point
2. **Show your work** for the completed phase
3. **Explicitly ask the user to confirm** before proceeding
4. **NEVER continue to the next phase, prompt, or step** without receiving an explicit "proceed", "continue", "go", or similar confirmation

If a prompt sequence contains multiple numbered prompts (e.g., "Prompt 1.1", "Prompt 1.2"), each prompt is a SEPARATE task. Complete ONE prompt, show results, and STOP. Do not read ahead or execute subsequent prompts.

**Violating stop points removes the user's ability to review, intervene, and course-correct. This is the single most important workflow rule.**

## Engine-run autonomy (no per-phase stop points)

Nimble (and orchestrated) run on the v2 engine: the Workflow script *is* the chain (ADR-039), so the whole run executes autonomously within a single turn with no per-phase injection or stop points. The v1 per-phase instruction files and phase state machine that drove this are retired (ADR-079); the only per-turn UserPromptSubmit injection that survives is the roadmap / planner mode loop (`round-loop.md` / `planner-loop.md`). The Active Workflow Override below applies to those injected advisory-mode loops.

The only time Claude should stop mid-run is when execution is **blocked** (e.g., implementer failure, test failure) or Claude has a **genuine question** requiring user input.

## Active Workflow Override

When a "WORKFLOW STATE MACHINE" phase injection is present in context (the surviving roadmap / planner mode loops), the injected instructions are autonomous and the highest-priority behavioral directive. Specifically:

- The "Do not start implementing until the user explicitly says to proceed" rule (Working Style) does NOT apply during an active injected mode loop
- The "Proceed immediately" footer in the injection is authoritative

This override ends when the user intervenes with explicit instructions.
