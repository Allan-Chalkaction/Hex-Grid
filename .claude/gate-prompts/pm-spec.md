# pm-spec invocation template — orchestrated mode (per-ticket)

**Used by:** `core/config/phases/orchestrated/t-spec.md`
**Agent invoked:** `@pm-spec`
**Template substitutions:** `${ticket_key}`, `${ticket_run_dir}`, `${wave_slug}`, `${wave_run_dir}`

**Substitution mapping** (template name ↔ source):
- `${ticket_key}` ← state file `ticket_key`
- `${ticket_run_dir}` ← wave manifest `tickets[current_ticket].ticket_run_dir`
- `${wave_slug}` ← state file `slug`
- `${wave_run_dir}` ← state file `run_dir`

The orchestrator interpolates the substitutions and passes the resulting prompt to `@pm-spec`. The agent reads the named input files, writes the named output file, and follows the per-ticket scope guardrails below.

---

## Prompt body (sent to pm-spec)

You are writing a spec for a single orchestrated-mode ticket inside a wave.

**Ticket key:** ${ticket_key}
**Wave:** ${wave_slug}
**Ticket run dir:** ${ticket_run_dir}

### Inputs (read in order)

1. **`${ticket_run_dir}/prompt.md`** — the ticket's user-facing description. This is the spec seed; everything in here is in scope.
2. **`${ticket_run_dir}/cto-evaluation.md`** — the CTO's evaluation of this ticket (recommendation + rationale + scope guidance). The CTO returned `Recommendation: GO` (the orchestrator advanced past the gate). If the original verdict was SIMPLIFY/DEFER/NO-GO and the user picked OVERRIDE, also read `${ticket_run_dir}/user-override.md` if present and treat the override scope as authoritative; the original `cto-evaluation.md` is preserved verbatim for audit but is no longer the binding scope.
3. **Wave context (read selectively):** `${wave_run_dir}/wave-manifest.json` for ticket dependencies and the broader wave's purpose. Do NOT read other tickets' `prompt.md` or `spec.md` — your scope is bounded to this ticket. Cross-ticket reasoning is the orchestrator's job (ADR-009).
4. **Cited ADRs** — `docs/decisions/ADR-*.md` files referenced in `${ticket_run_dir}/prompt.md`, in `${ticket_run_dir}/cto-evaluation.md`'s "ADR alignment" section, or in the wave manifest. Read each ADR's specification (acceptance criteria, scope, design patterns) and ensure your spec's ACs and scope sections do not contradict the ADR.

### Output

Write `${ticket_run_dir}/spec.md` containing:

1. **One-line summary** — what this ticket builds, in one sentence.
2. **Acceptance criteria (AC-NNN)** — atomic, testable, given/when/then shape. Each criterion must be verifiable post-implementation by a typecheck pass, a test, or a one-shot manual check. Number sequentially: AC-001, AC-002, ...
3. **Requirements (R-NNN)** — non-functional or behavioral expectations not captured by AC (e.g. "must not regress feature X", "must remain byte-additive vs file Y"). Number sequentially.
4. **Open questions** — things you cannot answer from the inputs that the orchestrator (or the user) needs to resolve before t-consensus advances.
5. **Out-of-scope** — explicit list of nearby concerns this ticket does NOT address. Each entry should name the concern and (where known) the future ticket that owns it.
6. **ADR alignment** — for each ADR cited in the inputs, list the AC/R atoms that operationalize the ADR's specification, and any AC/R atoms that diverge from the ADR (with rationale). If divergence exists, surface in the section so the t-consensus phase can adjudicate (the choice is "tighten the spec to match ADR" vs "revise the ADR to match spec"). If no ADRs are cited, write "No ADRs cited; alignment check N/A" and continue.

### Scope discipline (the binding contract)

- **Ticket scope, not feature scope.** This ticket is one of N tickets in a wave. Stay inside the boundaries the prompt + CTO evaluation defined.
- **Honor the CTO's guidance.** If the CTO said "SIMPLIFY: drop X to ship Y first," your spec should NOT include X. If GO without modifications, take the prompt at face value.
- **Mirror existing patterns where they exist.** If the ticket touches a code surface that has a known pattern (cite the file:line), the spec should require following that pattern.
- **No invented requirements.** If a requirement is not in the prompt or implied by the CTO's scope, do not add it. Surface as "Open question" or "Out-of-scope" instead.

### Verdict-line discipline

This template does NOT require a `Recommendation:` or `CONSENSUS:` line — pm-spec produces a structured spec, not a verdict. The orchestrator advances on `spec.md` written + spec-completeness check passing.

If you need to surface a blocker that prevents writing a useful spec, write it as the FIRST section of `spec.md` under a `## BLOCKED: <reason>` heading. The orchestrator's t-spec.md phase instruction detects this first-section sentinel and halts before t-consensus.

### One-shot remediation

If the orchestrator re-invokes you with a "spec-completeness gap" message, the prompt will include the gap list. Address each gap in `spec.md`; do NOT rewrite from scratch — preserve the AC-NNN / R-NNN numbering you already established.
