# wave-pm-spec invocation template — orchestrated mode (wave-level, v2)

**Used by:** `core/config/phases/orchestrated/w-pm-spec.md`
**Agent invoked:** `@pm-spec`
**Template substitutions:** `${wave_slug}`, `${wave_run_dir}`
**Scope:** `wave_protocol_version == 2` only.

The orchestrator interpolates the substitutions and passes the resulting prompt to `@pm-spec`. Mirrors `core/gate-prompts/pm-spec.md` (per-ticket) but with **wave-level scope**: the input is the wave-cto-evaluation matrix + N ticket prompts; the output is a single `wave-spec.md` containing per-ticket AC briefs.

ADR-015 § Q-D2 Step 2 is the binding contract.

---

## Prompt body (sent to pm-spec)

You are writing a wave-level spec at the start of an orchestrated-mode wave. This replaces per-ticket `t-spec` for v2 waves; you produce per-ticket AC briefs for ALL tickets in one batched pass.

**Wave:** ${wave_slug}
**Wave run dir:** ${wave_run_dir}

### Inputs (read in order)

1. **`${wave_run_dir}/wave-cto-evaluation.md`** — the wave-level CTO evaluation. Contains the per-ticket verdict matrix (Recommendation / Rationale / Risk flags / ADR citations per ticket) PLUS cross-ticket coupling notes. The verdicts are the contract: GO tickets get full ACs; SIMPLIFY tickets use the simplified scope from the matrix; DEFER/NO-GO tickets are skipped (those are handled by the orchestrator before w-pm-spec dispatch — they may not appear in the manifest's selectable set).
2. **(If present) `${wave_run_dir}/wave-cto-override.md`** — operator's OVERRIDE response if the wave-cto verdict was MIXED and they chose OVERRIDE. The override scope is authoritative; the original `wave-cto-evaluation.md` is preserved verbatim for audit but is no longer the binding scope.
3. **`${wave_run_dir}/wave-manifest.json`** — the canonical ticket list. Use the per-ticket `description` fields as the spec seed for each ticket.
4. **Per-ticket `prompt.md` files** under `${wave_run_dir}/tickets/*/prompt.md` IF scaffolded. The manifest `description` field is the primary source; per-ticket prompt.md (when present) is supplementary context.
5. **Cited ADRs** — `docs/decisions/ADR-*.md` files referenced in any ticket's description, in `wave-cto-evaluation.md`'s ADR-citations sections, or in the wave manifest. Read each ADR's specification (acceptance criteria, scope, design patterns) and ensure your per-ticket AC briefs do not contradict the ADR.

### Output

Write `${wave_run_dir}/wave-spec.md` containing:

1. **Wave summary** — one paragraph restating the wave's theme and goal.
2. **Cross-ticket dependency declarations** — explicit list of which AC in ticket K depends on which AC in ticket K-M. Mirrors the cross-ticket coupling notes from `wave-cto-evaluation.md` but at AC granularity. Use the format:

   ```
   ## Cross-ticket dependencies
   
   - T-002.AC-003 depends on T-001.AC-005 (T-001 must ship the schema migration before T-002's data layer can validate)
   - T-005.R-002 depends on T-003.AC-001 (T-003's ADR-amendment governs T-005's implementation)
   ```

3. **Per-ticket AC briefs** — one section per ticket (in manifest order), structured exactly like the per-ticket `spec.md` shape but inlined as a sub-section:

   ```
   ## Per-ticket AC briefs
   
   ### TICKET-KEY: <key>
   
   #### One-line summary
   <what this ticket builds, in one sentence>
   
   #### Acceptance criteria
   - AC-001: <atomic, testable, given/when/then>
   - AC-002: ...
   
   #### Requirements
   - R-001: <non-functional or behavioral expectation>
   - R-002: ...
   
   #### Cross-ticket dependencies (if any)
   <bullet list pointing to entries in the wave-level cross-ticket-dependencies section>
   
   #### Open questions
   <items the orchestrator/user must resolve before t-implement>
   
   #### Out-of-scope
   <explicit list of nearby concerns this ticket does NOT address>
   
   #### ADR alignment
   <per-ADR list of AC/R atoms operationalizing the ADR; flag divergences>
   ```

4. **Files in scope (wave-level summary)** — union of all tickets' planned_files. The orchestrator's `w-pm-spec.md` Step 7-equivalent (planned-files reconciliation) will diff this against the manifest's per-ticket `planned_files` arrays — the wave-level analog of the per-ticket A4 reconciliation.

### Scope discipline (the binding contract)

- **Wave scope, not feature scope.** This wave is one of many in a build. Stay inside the boundaries the manifest + wave-cto-evaluation defined.
- **Honor the wave-CTO's per-ticket guidance.** If wave-cto said "T-003: SIMPLIFY: drop X to ship Y first," ticket T-003's AC brief should NOT include X. If GO without modifications, take the manifest description at face value.
- **Mirror cross-ticket coupling explicitly.** The wave-level cto's coupling notes must surface as cross-ticket dependency declarations at AC granularity. This is the design-time half of cross-ticket coherence (ADR-015 Constraint C1).
- **No invented per-ticket requirements.** If a requirement is not in the manifest description or implied by the wave-cto's scope, do not add it. Surface as "Open question" or "Out-of-scope" in the per-ticket section.

### Verdict-line discipline

This template does NOT require a `Recommendation:` or `CONSENSUS:` line — wave-pm-spec produces a structured spec, not a verdict. The orchestrator's `w-pm-spec.md` Step 4 runs an orchestrator-side spec-completeness check (no agent dispatch) and writes the `COMPLETENESS: COMPLETE | GAP` verdict to a separate file.

If you need to surface a wave-level blocker that prevents writing a useful spec (e.g., the wave-cto-evaluation is internally inconsistent), write it as the FIRST section of `wave-spec.md` under a `## BLOCKED: <reason>` heading. The orchestrator's `w-pm-spec.md` phase doc detects this first-section sentinel and halts before w-cto-consensus.

### One-shot remediation

If the orchestrator re-invokes you with a "wave-spec-completeness gap" message, the prompt will include the gap list across one or more tickets. Address each gap in `wave-spec.md`; do NOT rewrite from scratch — preserve the AC-NNN / R-NNN numbering you already established within each per-ticket section.
