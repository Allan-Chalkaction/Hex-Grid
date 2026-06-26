#!/usr/bin/env python3
"""Wave manifest helpers for orchestrated-mode wave runs.

Reads a hand-written wave-spec plan (canonically
`docs/step-3-specs/{slug}/waves/{wave-slug}/{wave-slug}.md`, or any path you pass),
parses it into a
manifest dict that matches the orchestrated-mode wave schema, validates the
ticket graph (Kahn's checks mirroring core/agents/spec-decomposer.md Step 5d),
and writes it atomically to `${run_dir}/wave-manifest.json`.

Style: argparse-driven CLI, atomic write
via tmp + os.replace, defensive guards, all-stdlib (no third-party deps).

Wave manifest schema (definitive — V2-W1-T01; v2 fields added by D2 per ADR-015):

    {
        "wave_slug":        str,                # e.g. "mc-phase-b-wave-0"
        "wave_run_dir":     str,                # docs/step-5-pipeline/{date}/{HHmm}-WAVE-{slug}
        "wave_branch":      str,                # feature/wave-{slug} (derived from slug;
                                                # ticket branches are PEERS, not children —
                                                # see ticket_branch comment below + ADR-008)
        "wave_base_ref":    str | null,         # commit SHA at wave start; filled at setup phase
        "ui_addendum_path": str | null,         # docs/step-5-pipeline/.../ui-spec-addendum.md or null
        "current_ticket":   str | null,         # active ticket key, e.g. "T-005"

        # --- v2 fields (D2 / ADR-015 — additive; absent on v1 legacy manifests) ---
        "wave_protocol_version":                          int,        # 1 (legacy, default if absent) | 2 (wave-level pre-impl review, ADR-015)
                                                                      # | 3 (v2 + wave-end post-impl trio, ADR-026 + one-implementer-per-wave, ADR-028).
                                                                      # v3 is a superset of v2's wave-level pre-impl fields; the v3 deltas are
                                                                      # behavioral (phase docs + hook + gate prompts), not new manifest fields.
        "wave_cto_evaluation_path":                       str | null, # populated by w-cto (D3); null until then
        "wave_spec_path":                                 str | null, # populated by w-pm-spec (D3)
        "wave_cto_consensus_path":                        str | null, # populated by w-cto-consensus (D3)
        "max_wave_size":                                  int,        # default 12; preflight cap on len(tickets)
        "wave_manifest_at_wave_start_snapshot_path":      str | null, # populated by w-cto-consensus on completion
                                                                      # (D4 t-drift-check Check 4 reads it)
        "tickets": [
            {
                "key":                  str,        # required, e.g. "T-001"
                "title":                str,        # required
                "description":          str,        # required (multi-line spec seed)
                "ticket_run_dir":       str | null, # filled by t-cto when ticket activates
                "ticket_branch":        str,        # populated at preflight (write-from-plan):
                                                    # f"{wave_branch}--{key}", e.g.
                                                    # "feature/wave-mc-phase-b-wave-0--T-001".
                                                    # Double-dash separator avoids git-ref
                                                    # leaf/directory conflict — see ADR-008
                                                    # branching subsection.
                                                    # UNUSED under wave_protocol_version == 3:
                                                    # ADR-028's one-implementer-per-wave model has a
                                                    # single working surface (the implementer commits
                                                    # per ticket on the wave branch / one worktree),
                                                    # so per-ticket branches are obsolete for v3. The
                                                    # field is still populated for forward-compat /
                                                    # v2 parity but no v3 phase reads it. See ADR-013
                                                    # cross-reference note.
                "depends_on":           [str, ...], # ticket keys; sorted ascending; no dups
                "planned_files":        [str, ...], # non-empty
                "new_files":            [str, ...], # OPTIONAL; subset of planned_files; per ADR-017.
                                                    # Sorted ascending, no duplicates. Absent in
                                                    # manifest = legacy behavior (drift-check.sh
                                                    # Check 2 falls back to strict planned_files
                                                    # comparison). Empty list `[]` is distinct from
                                                    # absent — explicit declaration of "no NEW files."
                "gate_recommendations": [str, ...], # agent slugs
                "manual_review_required": bool,     # default true if absent in plan.
                                                    # Runtime semantic per ADR-018 (supersedes
                                                    # ADR-013's "always halt on true"): when true,
                                                    # the manual-review halt at t-review fires iff
                                                    # at least one finding's _criterion_match_ is
                                                    # in {crit-1, crit-2, crit-3}. Otherwise the
                                                    # flag is satisfied by PASS-THROUGH-SUMMARY
                                                    # and the ticket auto-advances to t-commit.
                                                    # Crit-4 / crit-5 fire regardless of flag.
                                                    # Planning-time disposition (when to set false
                                                    # for cosmetic-only tickets) is ADR-013;
                                                    # runtime halt-firing is ADR-018.
                # --- per-ticket v2 fields (D2 / ADR-015 — additive) ---
                "wave_cto_recommendation":  str | null, # GO | SIMPLIFY | DEFER | NO-GO | REVIEW-PER-TICKET; null until w-cto populates
                "wave_cto_simplification":  str | null, # populated when wave_cto_recommendation == "SIMPLIFY"
                "wave_consensus_status":    str | null, # CONSISTENT | DRIFTED | null
                "status": "pending" | "in-progress" | "amending" | "pending-amendment-applied" | "blocked" | "complete",
                "amendment_history": [
                    # from_ticket == self.key  =>  source-side record (self-amendment)
                    # from_ticket != self.key  =>  downstream record (amended by upstream)
                    { "from_ticket": str, "applied_at": str, "summary": str }
                ],
                "amendment_proposal": {     # V2-W2-T01: in-flight proposal awaiting human reply.
                    "detected_at":              str,            # ISO 8601 UTC
                    "actual_files_modified":    [str, ...],
                    "added_files":              [str, ...],
                    "removed_files":            [str, ...],
                    "delta_summary":            str,
                    "affected_downstream":      [str, ...],     # downstream ticket keys
                    "proposed_text_per_downstream": { str: str }  # downstream_key -> text
                } | None,                   # None when no amendment in flight
                "commit_sha":   str | null,
                "created_at":   str,    # ISO 8601 UTC
                "completed_at": str | null
            }
        ],
        "deferrals":    [],     # populated by V2-W3-T01
        "surface_log":  str     # "${wave_run_dir}/surface-log.md"
    }

Wave plan input format (parsed by parse_wave_plan):

    # Wave: {wave-slug}
    **Theme:** ...
    **Goal:** ...

    ## Tickets

    ### T-001: <title>
    - depends_on: []
    - planned_files: [path/a.ts, path/b.tsx]
    - new_files: [path/a.ts]            # OPTIONAL per ADR-017; subset of planned_files
    - gate_recommendations: [code-reviewer, security-auditor]
    - manual_review_required: true
    - description: |
        Multi-line ticket description / spec seed.

CLI subcommands:
    write-from-plan PLAN_PATH MANIFEST_PATH
        Parse a wave plan, validate, and atomically write the manifest.
        Exit 0 on success; exit 2 on parse/validate error (with stderr message).

    update-ticket-status MANIFEST_PATH TICKET_KEY STATUS [--field key=value ...]
        Atomically update a ticket's status (and optional extra fields).

    update-wave-field MANIFEST_PATH FIELD VALUE
        Atomically update a top-level wave field (e.g. wave_base_ref).

    next-ready-ticket MANIFEST_PATH
        Print the key of the next ticket whose depends_on are all complete and
        whose own status is pending. Prints empty string if none.

    validate MANIFEST_PATH
        Print validation errors line-by-line; exit 0 if clean, exit 2 if errors.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timezone


# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

ALLOWED_TICKET_STATUSES = {
    "pending",                      # never started
    "in-progress",                  # t-cto through t-commit running
    "amending",                     # source-side: set by apply_amendment_source
                                    # when a self-amendment lands. Persists from
                                    # apply through t-validate / t-review / t-commit;
                                    # t-commit transitions amending -> complete on
                                    # squash-merge. CR-006 iter-2: NO automatic
                                    # revert to "in-progress" — the prior comment
                                    # was misleading.
    "pending-amendment-applied",    # downstream: not yet started, prompt.md augmented;
                                    # eligible for find_next_ready_ticket alongside "pending"
    "blocked",
    "complete",
    "reverted",                     # V2-W4-T01: end-of-wave gate produced a
                                    # BLOCKING finding on this ticket's commit
                                    # and the user dispositioned REVERT. The
                                    # ticket's commit_sha is preserved for
                                    # traceability; the new revert SHA is set
                                    # via the optional reverted_in_commit field
                                    # (passed through update-ticket-status's
                                    # generic --field arg; no schema mutator).
}

# Ticket statuses that find_next_ready_ticket() considers eligible for selection.
# pending-amendment-applied is a sibling of pending — both denote "not yet started";
# the only difference is downstream's prompt.md has been amended.
SELECTABLE_TICKET_STATUSES = ("pending", "pending-amendment-applied")

ALLOWED_DEFERRAL_SEVERITIES = {"low", "medium", "high", "critical"}

# v2 / D2 / ADR-015: wave-level CTO recommendation enum, populated by w-cto
# at the per-ticket disposition matrix. Null is permitted (not yet populated).
ALLOWED_WAVE_CTO_RECOMMENDATIONS = {"GO", "SIMPLIFY", "DEFER", "NO-GO", "REVIEW-PER-TICKET"}

# v2 / D2 / ADR-015: wave-level consensus status enum, populated by w-cto-consensus.
ALLOWED_WAVE_CONSENSUS_STATUSES = {"CONSISTENT", "DRIFTED"}

# v2 / D2 / ADR-015: top-level wave-level fields required when
# wave_protocol_version == 2. Each may be null (not yet populated by the
# producing phase) but the field MUST be present in the manifest.
_V2_REQUIRED_WAVE_FIELDS = (
    "wave_cto_evaluation_path",
    "wave_spec_path",
    "wave_cto_consensus_path",
    "wave_manifest_at_wave_start_snapshot_path",
    "max_wave_size",
)

# v2 / D2 / ADR-015: per-ticket fields required when wave_protocol_version == 2.
# Each may be null until populated by w-cto / w-cto-consensus.
_V2_REQUIRED_TICKET_FIELDS = (
    "wave_cto_recommendation",
    "wave_cto_simplification",
    "wave_consensus_status",
)

# v2 / D2 / ADR-015: default max_wave_size for v2 waves when the plan does not
# explicitly set it. Per ADR-015 § Q-D4 — based on Stage 2 heuristic-floor
# estimate that 12 tickets is comfortably within Opus 1M with headroom.
_V2_DEFAULT_MAX_WAVE_SIZE = 12

# v3 / ADR-028: one-implementer-per-wave soft sizing limit. Under v3 a single
# implementer authors the whole wave in one continuous context, so the wave must
# fit one Opus-1M envelope — a tighter discipline than max_wave_size. Per ADR-028
# § Tripwire: 7-ticket waves are borderline; 10-ticket waves exceed 1M. This is a
# WARNING threshold (decompose-not-fragment tripwire), NOT a hard cap — the
# operator decides. write-from-plan emits a non-silent stderr warning when a v3
# wave's ticket count exceeds this; max_wave_size remains the hard cap.
_V3_IMPLEMENTER_CONTEXT_SOFT_LIMIT = 7

# Ticket key shape: 1+ uppercase letters, dash, 1+ digits or alphanumerics.
# Permissive enough to accept "T-001", "WAVE-005", "INFRA-019". Strict enough
# to reject prose that happens to start with "###".
# Uses \Z (absolute end) instead of $ to reject trailing-newline inputs at
# the regex layer — Python's $ matches before a final \n. Defense-in-depth
# alongside the manifest-membership lookup. SA-002 iter-2 fix; paired in
# wave-deferrals.py so both scripts share the tightened anchor.
TICKET_KEY_RE = re.compile(r"^[A-Z][A-Z0-9]*-[A-Z0-9]+\Z")

# Wave-slug shape (SA-001): lowercase, starts alphanumeric, then alnum / hyphen
# / underscore. Forbids '/' and '.' to prevent path traversal when the slug is
# interpolated into RUN_DIR / wave-plan paths / state-file paths.
# Uses \Z (absolute end) for consistency with TICKET_KEY_RE — Python's $
# matches before a final \n. SA-007 iter-2 polish; the call site already
# strips trailing whitespace, but the anchor should be tight at the regex
# layer too (defense-in-depth).
WAVE_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*\Z")

# Top-level wave-manifest fields safe to mutate via the update-wave-field CLI
# (SA-003). update_wave_field rejects any field name not in this allowlist;
# whole-section replacement (e.g. wiping `tickets` or `deferrals`) goes through
# their dedicated mutators or write_manifest.
MUTABLE_WAVE_FIELDS = {
    "wave_base_ref",
    "ui_addendum_path",
    "current_ticket",
    "surface_log",
}

# V2-W2-T01: required keys for tickets[i].amendment_proposal. Used by both
# validate() (defensive shape check) and set_amendment_proposal() (precondition
# check). The two consumers MUST share the same constant — having a local copy
# in either site silently drifts when fields are added (CR-002 iter-2 catch).
_AMENDMENT_PROPOSAL_REQUIRED_FIELDS = (
    "detected_at",
    "actual_files_modified",
    "added_files",
    "removed_files",
    "delta_summary",
    "affected_downstream",
    "proposed_text_per_downstream",
)


# --------------------------------------------------------------------------
# Atomic-write primitive (tmp + os.replace)
# --------------------------------------------------------------------------

def write_atomic(out_path, payload):
    """Write JSON to out_path atomically via tmp + os.replace.

    Uses indent=2 for human-readable manifests (manifests are inspected by
    humans, so multi-line indented JSON is preferred over a compact one-line form).
    """
    tmp_path = out_path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(payload, f, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp_path, out_path)


def read_manifest(manifest_path):
    with open(manifest_path, "r") as f:
        return json.load(f)


# --------------------------------------------------------------------------
# Plan-file parser
# --------------------------------------------------------------------------

def _split_list(value):
    """Parse a bracketed list literal: '[a, b, c]' -> ['a', 'b', 'c']. Empty '[]' -> []."""
    s = value.strip()
    if not (s.startswith("[") and s.endswith("]")):
        raise ValueError(
            f"expected list literal in [brackets], got: {value!r}"
        )
    inner = s[1:-1].strip()
    if not inner:
        return []
    parts = [p.strip() for p in inner.split(",")]
    return [p for p in parts if p]


def _parse_bool(value):
    s = value.strip().lower()
    if s in ("true", "yes", "1"):
        return True
    if s in ("false", "no", "0"):
        return False
    raise ValueError(f"expected bool, got: {value!r}")


def parse_wave_plan(plan_path):
    """Parse a wave plan markdown file into a manifest dict.

    Returns the dict; raises ValueError on parse failure or validation error.
    """
    if not os.path.isfile(plan_path):
        raise ValueError(f"wave plan file not found: {plan_path}")

    with open(plan_path, "r") as f:
        lines = f.read().split("\n")

    # Slug from first line: "# Wave: {slug}"
    slug = None
    for line in lines:
        m = re.match(r"^#\s+Wave:\s+(\S+)\s*$", line)
        if m:
            slug = m.group(1).strip()
            break
    if not slug:
        raise ValueError(
            "wave plan missing '# Wave: {slug}' header on first non-blank line"
        )

    # SA-001: reject slugs that would traverse the filesystem when interpolated
    # into RUN_DIR / wave-plan paths. The orchestrator-side SKILL.md may also
    # check this, but enforcing here closes the supply-chain vector (a malicious
    # plan file fetched from a shared spec repo) regardless of the call site.
    if not WAVE_SLUG_RE.match(slug):
        raise ValueError(
            f"wave plan slug {slug!r} is invalid: must match "
            f"{WAVE_SLUG_RE.pattern!r} (lowercase, no slashes, no dots, no leading hyphen)"
        )

    # v2 / D2 / ADR-015: optional plan headers that signal v2 protocol +
    # operator-overridable max_wave_size. Absent = legacy v1 (no v2 fields
    # written into the manifest). Format:
    #     **Protocol version:** 2
    #     **Max wave size:** 8
    # Both lines must appear before the '## Tickets' section. Order doesn't
    # matter; bad values raise ValueError early.
    wave_protocol_version = 1
    max_wave_size = None  # None means "not specified by plan; default at manifest-build"
    has_ui = False  # ADR-104: wave-level UI-surface flag (`**Has UI:**`); absent header => False (legacy-safe)
    for line in lines:
        if re.match(r"^##\s+Tickets\s*$", line):
            break
        m_pv = re.match(r"^\*\*Protocol version:\*\*\s*(\d+)\s*$", line)
        if m_pv:
            try:
                wave_protocol_version = int(m_pv.group(1))
            except ValueError:
                raise ValueError(
                    f"wave plan '**Protocol version:**' value not an integer: {m_pv.group(1)!r}"
                )
            if wave_protocol_version not in (1, 2, 3):
                raise ValueError(
                    f"wave plan '**Protocol version:**' must be 1, 2, or 3; got {wave_protocol_version}"
                )
            continue
        m_ms = re.match(r"^\*\*Max wave size:\*\*\s*(\d+)\s*$", line)
        if m_ms:
            try:
                max_wave_size = int(m_ms.group(1))
            except ValueError:
                raise ValueError(
                    f"wave plan '**Max wave size:**' value not an integer: {m_ms.group(1)!r}"
                )
            if max_wave_size < 1:
                raise ValueError(
                    f"wave plan '**Max wave size:**' must be >= 1; got {max_wave_size}"
                )
            continue
        # ADR-104: optional `**Has UI:** true|false` — the planning→build UI-surface carry. Parsed here,
        # carried at wave level, read by the /orchestrated dispatch as `hasUi`. Absent => False (legacy-safe).
        m_ui = re.match(r"^\*\*Has UI:\*\*\s*(true|false)\s*$", line, re.IGNORECASE)
        if m_ui:
            has_ui = (m_ui.group(1).lower() == "true")
            continue

    # Locate '## Tickets' section
    tickets_start_ix = None
    for i, line in enumerate(lines):
        if re.match(r"^##\s+Tickets\s*$", line):
            tickets_start_ix = i
            break
    if tickets_start_ix is None:
        raise ValueError("wave plan missing '## Tickets' section heading")

    # Walk from tickets_start_ix+1 onward; group lines into ticket blocks
    # delimited by '### KEY: title' headers.
    tickets = []
    current = None  # in-progress ticket dict
    desc_buffer = None  # list of description lines, or None
    desc_indent = None

    def _finalize_current():
        nonlocal current, desc_buffer, desc_indent
        if current is None:
            return
        if desc_buffer is not None:
            current["description"] = "\n".join(desc_buffer).rstrip()
        # Apply manual_review_required default if absent.
        current.setdefault("manual_review_required", True)
        # Defaults for fields not in the wave-plan format but required by schema.
        current.setdefault("depends_on", [])
        current.setdefault("planned_files", [])
        current.setdefault("gate_recommendations", [])
        current.setdefault("acceptance", [])  # ADR-103 W1: absent on legacy v1 plans; [] is the safe default.
        current.setdefault("description", "")
        tickets.append(current)
        current = None
        desc_buffer = None
        desc_indent = None

    for raw in lines[tickets_start_ix + 1:]:
        # If we hit another top-level ## section, stop ticket parsing.
        if re.match(r"^##\s+\S", raw) and not raw.startswith("### "):
            _finalize_current()
            break

        # Collecting description body?
        if desc_buffer is not None:
            stripped = raw.lstrip()
            indent_len = len(raw) - len(stripped)
            # Description ends when we hit a non-blank line at lower indent
            # than the description block, or when we hit a new ### header.
            if raw.strip() == "":
                desc_buffer.append("")
                continue
            if raw.startswith("### "):
                _finalize_current()
                # fall through to ticket-header handling below
            elif desc_indent is not None and indent_len < desc_indent:
                # CR-001: save buffered description BEFORE clearing — otherwise
                # any non-blank, non-`###` content at lower indent (a `##`
                # section, `<!--` HTML comment, or col-0 field line) silently
                # discards the accumulated description. Empirically caught
                # against `_template.md`'s trailing comment block.
                if desc_buffer and current is not None:
                    current["description"] = "\n".join(desc_buffer).rstrip()
                desc_buffer = None
                desc_indent = None
                # fall through to field-parsing below
            else:
                if desc_indent is None and stripped:
                    desc_indent = indent_len
                desc_buffer.append(raw[desc_indent:] if desc_indent and len(raw) >= desc_indent else stripped)
                continue

        m_header = re.match(r"^###\s+([A-Z][A-Z0-9]*-[A-Z0-9]+)\s*:\s*(.+?)\s*$", raw)
        if m_header:
            _finalize_current()
            current = {
                "key": m_header.group(1).strip(),
                "title": m_header.group(2).strip(),
            }
            continue

        if current is None:
            # Lines outside a ticket block are ignored (e.g. blank lines, prose).
            continue

        # Field line: '- field: value' or '- field: |' (description)
        m_field = re.match(r"^\s*-\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*:\s*(.*)$", raw)
        if not m_field:
            continue

        field, value = m_field.group(1).strip(), m_field.group(2).strip()

        if field == "depends_on":
            current["depends_on"] = _split_list(value)
        elif field == "planned_files":
            current["planned_files"] = _split_list(value)
        elif field == "new_files":
            # ADR-017: optional subset of planned_files. Set only when present
            # in the plan markdown so the absent-vs-empty distinction reaches
            # drift-check.sh's fallback boundary unchanged. Sorting is enforced
            # by validate(); the parser preserves authored order so validation
            # can surface unsorted-input errors.
            current["new_files"] = _split_list(value)
        elif field == "gate_recommendations":
            current["gate_recommendations"] = _split_list(value)
        elif field == "acceptance":
            # ADR-103 W1 / ADR-086 D4: the AC-NNN atom chain. roadmap.js renderWaveSchema now emits
            # '- acceptance: [AC-001, ...]'; parse it as a list (an unhandled field would fall to the
            # else branch below and be stored as the raw bracketed STRING, breaking the coverage set-diff).
            current["acceptance"] = _split_list(value)
        elif field == "manual_review_required":
            current["manual_review_required"] = _parse_bool(value)
        elif field == "description":
            if value == "|":
                desc_buffer = []
                desc_indent = None
            else:
                current["description"] = value
        else:
            # Unknown field — preserve as-is for forward compatibility.
            current[field] = value

    _finalize_current()

    if not tickets:
        raise ValueError(
            "wave plan has '## Tickets' section but no parseable ticket entries. "
            "Each ticket must start with a header of the form: "
            "'### KEY: <title>' where KEY matches "
            f"{TICKET_KEY_RE.pattern!r} (e.g. 'T-001', 'WAVE-005')."
        )

    # Build manifest
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    wave_run_dir = os.environ.get("WAVE_RUN_DIR_OVERRIDE", "")
    # The CLI passes wave_run_dir via the manifest path's parent directory;
    # populate it from the manifest target path when write-from-plan is invoked.
    # Wave branch — leaf ref under refs/heads/feature/. Ticket branches are
    # peers (NOT children) of the wave branch, separated by `--`. Native git
    # refs cannot have a leaf and a directory at the same path, so the
    # intuitive nested form `feature/wave-{slug}/T-NNN` is structurally
    # incompatible — see ADR-008 branching subsection.
    wave_branch = f"feature/wave-{slug}"

    manifest_tickets = []
    for t in tickets:
        # Sort + dedupe depends_on for determinism.
        deps = sorted(set(t.get("depends_on", [])))
        ticket_dict = {
            "key": t["key"],
            "title": t["title"],
            "description": t.get("description", ""),
            "ticket_run_dir": None,
            # Populated at preflight (here) so all phases (t-implement,
            # t-validate, t-review, t-commit) can read a deterministic
            # ticket branch name from the manifest. Shape: `{wave_branch}--{key}`.
            "ticket_branch": f"{wave_branch}--{t['key']}",
            "depends_on": deps,
            "planned_files": list(t.get("planned_files", [])),
            "gate_recommendations": list(t.get("gate_recommendations", [])),
            # ADR-103 W1 / ADR-086 D4: carry the AC-NNN atom chain into the manifest ticket. Parsed above but
            # previously dropped here (this dict has an explicit field set), which is the parser-path sever
            # that left graduated-spec tickets with acceptance=[] and defanged AC-COVERAGE.
            "acceptance": list(t.get("acceptance", [])),
            "manual_review_required": t.get("manual_review_required", True),
            "status": "pending",
            "amendment_history": [],
            "amendment_proposal": None,
            "commit_sha": None,
            "created_at": now,
            "completed_at": None,
        }
        # v2 / D2: initialize per-ticket wave-level fields when the plan declares
        # protocol v2 or v3. Producers (w-cto, w-cto-consensus) populate them at
        # runtime. v3 (ADR-026 + ADR-028) retains v2's wave-start pre-impl review,
        # so it carries the same per-ticket wave-level fields.
        if wave_protocol_version in (2, 3):
            for f in _V2_REQUIRED_TICKET_FIELDS:
                ticket_dict[f] = None
        # ADR-017: copy new_files through ONLY when the plan declared it. The
        # absent-vs-empty distinction is load-bearing — drift-check.sh Check 2
        # falls back to strict planned_files comparison when new_files is
        # absent on either side of a pair, but treats explicit `[]` as an
        # opt-in declaration of "this ticket creates no files."
        if "new_files" in t:
            ticket_dict["new_files"] = list(t["new_files"])
        manifest_tickets.append(ticket_dict)

    manifest = {
        "wave_slug": slug,
        "wave_run_dir": wave_run_dir,
        "wave_branch": wave_branch,
        "wave_base_ref": None,
        "ui_addendum_path": None,
        "current_ticket": None,
        "tickets": manifest_tickets,
        "deferrals": [],
        "surface_log": "",  # filled by caller using wave_run_dir
    }
    # v2 / D2: initialize top-level wave-level fields when plan declares v2 or v3.
    # v3 (ADR-026 + ADR-028) is a superset of v2's wave-level pre-impl structure;
    # the version is stored verbatim so downstream readers can branch on it.
    if wave_protocol_version in (2, 3):
        manifest["wave_protocol_version"] = wave_protocol_version
        manifest["wave_cto_evaluation_path"] = None
        manifest["wave_spec_path"] = None
        manifest["wave_cto_consensus_path"] = None
        manifest["wave_manifest_at_wave_start_snapshot_path"] = None
        manifest["max_wave_size"] = (
            max_wave_size if max_wave_size is not None else _V2_DEFAULT_MAX_WAVE_SIZE
        )
    # ADR-104: carry the wave-level UI-surface flag unconditionally (default False). The /orchestrated
    # dispatch reads manifest["has_ui"] and passes it as `hasUi` so the build's ui-spec/ui-review fire.
    manifest["has_ui"] = bool(has_ui)

    errors = validate(manifest)
    if errors:
        raise ValueError(
            "wave plan failed validation:\n  - " + "\n  - ".join(errors)
        )

    return manifest


# --------------------------------------------------------------------------
# Validation (mirrors core/agents/spec-decomposer.md:240-260 Step 5d)
# --------------------------------------------------------------------------

def validate(manifest):
    """Return a list of validation errors. Empty list = valid.

    Branches on `wave_protocol_version`. v1 (default if absent) runs the
    legacy rule set unchanged. v2 additionally requires the wave-level
    fields documented in the schema docstring (D2 / ADR-015).
    """
    errors = []

    if not isinstance(manifest, dict):
        return ["manifest is not a dict"]

    # v2 / D2: read protocol version (default 1 = legacy). Reject non-int / bad value.
    # v3 (ADR-026 + ADR-028) accepted as of the v3 substrate generation.
    wave_protocol_version = manifest.get("wave_protocol_version", 1)
    if not isinstance(wave_protocol_version, int) or wave_protocol_version not in (1, 2, 3):
        errors.append(
            f"wave_protocol_version must be 1, 2, or 3; got {wave_protocol_version!r}"
        )
        wave_protocol_version = 1  # fall through with legacy semantics

    tickets = manifest.get("tickets")
    if not isinstance(tickets, list):
        return ["manifest.tickets must be a list"]

    # v2 / D2: top-level wave-level field shape checks. v1 manifests skip
    # this block entirely — extra fields on a v1 manifest are tolerated
    # (forward-compat).
    if wave_protocol_version in (2, 3):
        for f in _V2_REQUIRED_WAVE_FIELDS:
            if f not in manifest:
                errors.append(f"wave_protocol_version={wave_protocol_version} but missing required field {f!r}")
        # max_wave_size: int >= 1 + preflight cap on len(tickets).
        mws = manifest.get("max_wave_size")
        if mws is not None:
            if not isinstance(mws, int) or mws < 1:
                errors.append(
                    f"max_wave_size must be a positive int; got {mws!r}"
                )
            elif len(tickets) > mws:
                errors.append(
                    f"wave has {len(tickets)} tickets but max_wave_size={mws}; "
                    f"reduce ticket count or raise max_wave_size in the plan "
                    f"('**Max wave size:**' header). Cap rationale: ADR-015 § Q-D4."
                )
        # Path fields: string | null (only when present; missing-field error already raised above).
        for f in ("wave_cto_evaluation_path", "wave_spec_path",
                  "wave_cto_consensus_path", "wave_manifest_at_wave_start_snapshot_path"):
            v = manifest.get(f)
            if v is not None and not isinstance(v, str):
                errors.append(
                    f"{f} must be a string or null; got {type(v).__name__}"
                )

    keys_seen = []
    keys_set = set()
    for i, t in enumerate(tickets):
        if not isinstance(t, dict):
            errors.append(f"tickets[{i}] is not a dict")
            continue

        key = t.get("key")
        if not isinstance(key, str) or not TICKET_KEY_RE.match(key):
            errors.append(
                f"tickets[{i}].key must match {TICKET_KEY_RE.pattern!r}; got {key!r}"
            )
            continue

        if key in keys_set:
            errors.append(f"duplicate ticket key: {key}")
        keys_set.add(key)
        keys_seen.append(key)

        # planned_files non-empty (per AC and rules-orchestrated-mode.md)
        pf = t.get("planned_files", [])
        if not isinstance(pf, list) or len(pf) == 0:
            errors.append(f"{key}: planned_files must be a non-empty list")

        # new_files (ADR-017): optional. When present, MUST be a list of strings,
        # subset of planned_files, sorted ascending, no duplicates. Absence is
        # permitted (legacy fallback in drift-check.sh Check 2 kicks in).
        if "new_files" in t:
            nf = t.get("new_files")
            if not isinstance(nf, list) or not all(isinstance(f, str) for f in nf):
                errors.append(
                    f"{key}: new_files must be a list of strings "
                    f"(got {type(nf).__name__})"
                )
            else:
                planned_set = set(pf) if isinstance(pf, list) else set()
                nf_set = set(nf)
                not_in_planned = sorted(nf_set - planned_set)
                if not_in_planned:
                    errors.append(
                        f"{key}: new_files must be a subset of planned_files; "
                        f"these entries are in new_files but not planned_files: "
                        f"{not_in_planned[:5]}"
                    )
                if len(nf) != len(nf_set):
                    errors.append(f"{key}: new_files contains duplicates")
                if nf != sorted(nf):
                    errors.append(f"{key}: new_files must be sorted ascending")

        # CR-004: description non-empty (spec seed for pm-spec at t-spec).
        # Defense-in-depth pairing with CR-001 — turns silent description-loss
        # into a loud validation failure if the parser ever regresses.
        desc = t.get("description", "")
        if not isinstance(desc, str) or not desc.strip():
            errors.append(f"{key}: description must be non-empty (spec seed for pm-spec)")

        # manual_review_required must be bool
        mrr = t.get("manual_review_required")
        if not isinstance(mrr, bool):
            errors.append(f"{key}: manual_review_required must be bool; got {type(mrr).__name__}")
        elif mrr is False:
            # C7 (ADR-013 carve-out widening): manual_review_required: false
            # is permitted only when ALL planned_files match the carve-out
            # filter (docs / tests / config / fixtures). Mixed tickets MUST
            # carry manual_review_required: true.
            non_carve_out = [
                f for f in t.get("planned_files", [])
                if isinstance(f, str) and not _matches_manual_review_carve_out(f)
            ]
            if non_carve_out:
                errors.append(
                    f"{key}: manual_review_required=false but planned_files contains "
                    f"non-carve-out paths: {non_carve_out[:5]}. "
                    f"Carve-out scope: docs / tests / config / fixtures only. "
                    f"See ADR-013 'Carve-out criteria'. "
                    f"Set manual_review_required: true OR remove the non-carve-out files."
                )

        # status must be a valid enum value
        st = t.get("status")
        if st not in ALLOWED_TICKET_STATUSES:
            errors.append(
                f"{key}: status must be one of {sorted(ALLOWED_TICKET_STATUSES)}; got {st!r}"
            )

        # depends_on must be a list of strings
        deps = t.get("depends_on", [])
        if not isinstance(deps, list):
            errors.append(f"{key}: depends_on must be a list; got {type(deps).__name__}")
            continue
        for d in deps:
            if not isinstance(d, str):
                errors.append(f"{key}: depends_on entries must be strings; got {d!r}")

        # No self-references
        if key in deps:
            errors.append(f"{key}: depends_on must not contain its own key (self-reference)")

        # No duplicate depends_on entries
        if len(deps) != len(set(deps)):
            errors.append(f"{key}: depends_on contains duplicate entries: {deps}")

        # amendment_proposal: optional dict with strict shape when present.
        # V2-W2-T01: persisted in-flight proposal so fresh-session resume can
        # re-surface; cleared on apply or reject.
        # CR-002 (iter-2): use the module-level _AMENDMENT_PROPOSAL_REQUIRED_FIELDS
        # constant rather than a local copy, so future field additions don't
        # silently drift between the helper and the validator.
        # SA-003 (iter-2): element-level TICKET_KEY_RE check on affected_downstream
        # entries and proposed_text_per_downstream keys — defense-in-depth against
        # a compromised manifest whose proposal carries traversal-shaped keys.
        ap = t.get("amendment_proposal")
        if ap is not None:
            if not isinstance(ap, dict):
                errors.append(
                    f"{key}: amendment_proposal must be a dict or null; got {type(ap).__name__}"
                )
            else:
                for f in _AMENDMENT_PROPOSAL_REQUIRED_FIELDS:
                    if f not in ap:
                        errors.append(
                            f"{key}.amendment_proposal: missing required field {f!r}"
                        )
                for list_field in ("actual_files_modified", "added_files",
                                   "removed_files", "affected_downstream"):
                    v = ap.get(list_field)
                    if v is not None and not isinstance(v, list):
                        errors.append(
                            f"{key}.amendment_proposal.{list_field} must be a list; "
                            f"got {type(v).__name__}"
                        )
                # SA-003: affected_downstream entries must be ticket-key-shaped.
                ad = ap.get("affected_downstream")
                if isinstance(ad, list):
                    for j, dk in enumerate(ad):
                        if not isinstance(dk, str) or not TICKET_KEY_RE.match(dk):
                            errors.append(
                                f"{key}.amendment_proposal.affected_downstream[{j}] "
                                f"must match {TICKET_KEY_RE.pattern!r}; got {dk!r}"
                            )
                ptpd = ap.get("proposed_text_per_downstream")
                if ptpd is not None and not isinstance(ptpd, dict):
                    errors.append(
                        f"{key}.amendment_proposal.proposed_text_per_downstream must be a dict; "
                        f"got {type(ptpd).__name__}"
                    )
                # SA-003: proposed_text_per_downstream keys must be ticket-key-shaped.
                if isinstance(ptpd, dict):
                    for dk in ptpd.keys():
                        if not isinstance(dk, str) or not TICKET_KEY_RE.match(dk):
                            errors.append(
                                f"{key}.amendment_proposal.proposed_text_per_downstream "
                                f"key must match {TICKET_KEY_RE.pattern!r}; got {dk!r}"
                            )

        # v2 / D2: per-ticket wave-level fields. Required-present (may be null).
        # v1 manifests skip this block — extra fields are tolerated forward-compat.
        if wave_protocol_version in (2, 3):
            for f in _V2_REQUIRED_TICKET_FIELDS:
                if f not in t:
                    errors.append(
                        f"{key}: wave_protocol_version={wave_protocol_version} but missing required field {f!r}"
                    )
            # wave_cto_recommendation enum check (null permitted).
            wcr = t.get("wave_cto_recommendation")
            if wcr is not None and wcr not in ALLOWED_WAVE_CTO_RECOMMENDATIONS:
                errors.append(
                    f"{key}: wave_cto_recommendation must be one of "
                    f"{sorted(ALLOWED_WAVE_CTO_RECOMMENDATIONS)} or null; got {wcr!r}"
                )
            # wave_consensus_status enum check (null permitted).
            wcs = t.get("wave_consensus_status")
            if wcs is not None and wcs not in ALLOWED_WAVE_CONSENSUS_STATUSES:
                errors.append(
                    f"{key}: wave_consensus_status must be one of "
                    f"{sorted(ALLOWED_WAVE_CONSENSUS_STATUSES)} or null; got {wcs!r}"
                )
            # wave_cto_simplification: string | null (no enum).
            wcsimp = t.get("wave_cto_simplification")
            if wcsimp is not None and not isinstance(wcsimp, str):
                errors.append(
                    f"{key}: wave_cto_simplification must be a string or null; "
                    f"got {type(wcsimp).__name__}"
                )

    # No orphan references
    for t in tickets:
        if not isinstance(t, dict):
            continue
        key = t.get("key")
        for d in t.get("depends_on", []) or []:
            if isinstance(d, str) and d not in keys_set:
                errors.append(f"{key}: depends_on references unknown ticket {d!r}")

    # Acyclic check (Kahn's algorithm).
    # A cycle exists iff Kahn's reduces to a non-empty in_degree set.
    if not any(e.endswith("(self-reference)") for e in errors):
        in_degree = {
            t["key"]: len(t.get("depends_on", []) or [])
            for t in tickets
            if isinstance(t, dict) and "key" in t
        }
        reverse_adj = defaultdict(list)
        for t in tickets:
            if not isinstance(t, dict) or "key" not in t:
                continue
            for d in t.get("depends_on", []) or []:
                if isinstance(d, str):
                    reverse_adj[d].append(t["key"])
        ready = [k for k, deg in in_degree.items() if deg == 0]
        processed = 0
        while ready:
            n = ready.pop(0)
            processed += 1
            for m in reverse_adj.get(n, []):
                if m in in_degree:
                    in_degree[m] -= 1
                    if in_degree[m] == 0:
                        ready.append(m)
        if processed != len(in_degree):
            unresolved = sorted(k for k, d in in_degree.items() if d > 0)
            errors.append(
                f"depends_on graph contains a cycle; unresolved tickets: {unresolved}"
            )

    # Wave-level NEW-NEW collision detector (ADR-017).
    # Two tickets cannot both NEW the same file. This is a planning-time error
    # caught before execution starts — the runtime drift-check.sh Check 2
    # catches the same class for post-write-from-plan amendments. Reported on
    # the second ticket that claims the path (in iteration order).
    new_owners = {}  # path -> ticket_key (first claimant)
    for t in tickets:
        if not isinstance(t, dict):
            continue
        tkey = t.get("key")
        for f in t.get("new_files", []) or []:
            if not isinstance(f, str):
                continue
            prior = new_owners.get(f)
            if prior is not None and prior != tkey:
                errors.append(
                    f"new_files collision: {f!r} appears in both "
                    f"{prior!r}.new_files and {tkey!r}.new_files "
                    f"(two tickets cannot both claim original creation; ADR-017)"
                )
            else:
                new_owners[f] = tkey

    # Deferrals: severity enum (placeholder — V2-W3-T01 builds the full schema)
    for i, d in enumerate(manifest.get("deferrals", []) or []):
        if not isinstance(d, dict):
            errors.append(f"deferrals[{i}] is not a dict")
            continue
        sev = d.get("severity")
        if sev is not None and sev not in ALLOWED_DEFERRAL_SEVERITIES:
            errors.append(
                f"deferrals[{i}].severity must be one of {sorted(ALLOWED_DEFERRAL_SEVERITIES)}; got {sev!r}"
            )

    return errors


# --------------------------------------------------------------------------
# Manifest mutation helpers
# --------------------------------------------------------------------------

def write_manifest(manifest, target_path):
    """Validate then atomically write the manifest."""
    errors = validate(manifest)
    if errors:
        raise ValueError(
            "manifest failed validation:\n  - " + "\n  - ".join(errors)
        )
    write_atomic(target_path, manifest)


def update_ticket_status(manifest_path, ticket_key, status, **fields):
    """Atomically update a single ticket's status (and optional extra fields).

    Reads -> mutates in memory -> validates -> atomically writes.
    Raises ValueError if ticket_key not found or validation fails.
    """
    if status not in ALLOWED_TICKET_STATUSES:
        raise ValueError(
            f"status must be one of {sorted(ALLOWED_TICKET_STATUSES)}; got {status!r}"
        )

    manifest = read_manifest(manifest_path)
    found = False
    for t in manifest.get("tickets", []):
        if t.get("key") == ticket_key:
            t["status"] = status
            for k, v in fields.items():
                t[k] = v
            found = True
            break
    if not found:
        raise ValueError(f"ticket {ticket_key!r} not found in manifest at {manifest_path}")
    write_manifest(manifest, manifest_path)


def update_wave_field(manifest_path, field, value):
    """Atomically update a top-level wave field (e.g. wave_base_ref, current_ticket).

    SA-003: only fields in MUTABLE_WAVE_FIELDS are accepted. Whole-section
    replacement (e.g. wiping `tickets` or `deferrals`) is intentionally NOT
    reachable through this CLI surface — those mutations go through
    update_ticket_status, the deferral CLI (V2-W3-T01), or write_manifest.
    """
    if field not in MUTABLE_WAVE_FIELDS:
        raise ValueError(
            f"field {field!r} is not in the mutable wave-field allowlist: "
            f"{sorted(MUTABLE_WAVE_FIELDS)}"
        )
    manifest = read_manifest(manifest_path)
    manifest[field] = value
    write_manifest(manifest, manifest_path)


def _matches_manual_review_carve_out(file_path):
    """Returns True if file_path matches ADR-013's manual_review_required:false carve-out.

    Carve-out filter (mechanical, no judgment) — C7 widened from cosmetic-only:
      - docs-only: docs/**, **/*.md, **/*.mdx, **/*.txt, **/*.adoc
      - test-only: **/*test*.{ts,tsx,js,jsx,py,go,rs}, **/__tests__/**, **/tests/**
      - config-only: **/*.{json,yml,yaml,toml}, .gitignore, .gitattributes,
                     .prettierrc*, .eslintrc*, tsconfig*.json, **/*.config.{ts,js,mjs}
      - fixture-only: **/fixtures/**, **/__fixtures__/**

    Mixed tickets (any source/CI/build/rules/ADR/skill file in planned_files)
    MUST carry manual_review_required: true. validate() rejects manifests that
    violate this rule.

    Full ADR contract: docs/decisions/ADR-013-wave-branching-and-manual-review.md.
    """
    import fnmatch
    PATTERNS = [
        # docs-only
        "docs/*", "docs/**/*", "*.md", "*.mdx", "*.txt", "*.adoc",
        "**/*.md", "**/*.mdx", "**/*.txt", "**/*.adoc",
        # test-only
        "**/*test*.ts", "**/*test*.tsx", "**/*test*.js", "**/*test*.jsx",
        "**/*test*.py", "**/*test*.go", "**/*test*.rs",
        "**/__tests__/*", "**/__tests__/**/*",
        "tests/*", "tests/**/*", "**/tests/*", "**/tests/**/*",
        # config-only
        "**/*.json", "**/*.yml", "**/*.yaml", "**/*.toml",
        "*.json", "*.yml", "*.yaml", "*.toml",
        ".gitignore", ".gitattributes",
        "**/.prettierrc*", "**/.eslintrc*", ".prettierrc*", ".eslintrc*",
        "**/tsconfig*.json", "tsconfig*.json",
        "**/*.config.ts", "**/*.config.js", "**/*.config.mjs",
        # fixture-only
        "**/fixtures/*", "**/fixtures/**/*",
        "**/__fixtures__/*", "**/__fixtures__/**/*",
    ]
    return any(fnmatch.fnmatch(file_path, p) for p in PATTERNS)


def find_next_ready_ticket(manifest):
    """Return the key of the next ready ticket, or None.

    Ready = own status in SELECTABLE_TICKET_STATUSES AND all depends_on entries
    are 'complete'. Tie-break: ascending order of ticket key.

    SELECTABLE_TICKET_STATUSES is ('pending', 'pending-amendment-applied') —
    the latter is a downstream ticket whose prompt.md was augmented by an
    upstream amendment (V2-W2-T01) but which has not yet been started.
    """
    status_by_key = {t["key"]: t.get("status", "pending") for t in manifest.get("tickets", [])}
    candidates = []
    for t in manifest.get("tickets", []):
        if t.get("status") not in SELECTABLE_TICKET_STATUSES:
            continue
        deps = t.get("depends_on", []) or []
        if all(status_by_key.get(d) == "complete" for d in deps):
            candidates.append(t["key"])
    if not candidates:
        return None
    return sorted(candidates)[0]


def find_stuck_tickets(manifest):
    """Return tickets in 'in-progress' state with no work-product evidence.

    A stuck ticket is one whose status is 'in-progress' but which lacks
    real phase artifacts. Three sub-shapes:

      1. ticket_run_dir is null/empty (status was set without scaffolding).
      2. ticket_run_dir is set but the directory does not exist on disk.
      3. ticket_run_dir exists but contains no findings/* files (no agent
         dispatch produced output).

    The canonical recovery is to reset the ticket to 'pending' and clear
    ticket_run_dir, so find_next_ready_ticket can pick it up cleanly. The
    orchestrator surfaces stuck tickets to the operator at session start
    via /orchestrated <slug> resume; the operator dispositions RESET / KEEP
    / INSPECT.

    Returns:
        list[dict]: per-stuck-ticket records with shape:
            {
              "key": "T-NNN",
              "reason": "<one-line>",
              "ticket_run_dir": "<path-or-empty>"
            }
        Sorted by ticket key (ascending). Empty if no stuck tickets.

    A3: paths in ticket_run_dir are evaluated as cwd-relative (the canonical
    case — orchestrated runs execute from the consumer-project cwd; ticket
    run dirs live under docs/step-5-pipeline/...). Pass an absolute path in the
    manifest if you need cwd-independence.
    """
    stuck = []
    for t in manifest.get("tickets", []):
        if t.get("status") != "in-progress":
            continue
        run_dir = t.get("ticket_run_dir") or ""
        if not run_dir:
            stuck.append({
                "key": t["key"],
                "reason": "ticket_run_dir empty",
                "ticket_run_dir": "",
            })
            continue
        if not os.path.isdir(run_dir):
            stuck.append({
                "key": t["key"],
                "reason": f"ticket_run_dir does not exist on disk: {run_dir}",
                "ticket_run_dir": run_dir,
            })
            continue
        findings_dir = os.path.join(run_dir, "findings")
        if not os.path.isdir(findings_dir):
            stuck.append({
                "key": t["key"],
                "reason": f"no findings/ subdirectory at {run_dir}",
                "ticket_run_dir": run_dir,
            })
            continue
        # Findings dir exists; check for any files (agent output or marker).
        try:
            entries = [e for e in os.listdir(findings_dir) if not e.startswith(".")]
        except OSError as e:
            stuck.append({
                "key": t["key"],
                "reason": f"findings/ unreadable: {e}",
                "ticket_run_dir": run_dir,
            })
            continue
        if not entries:
            stuck.append({
                "key": t["key"],
                "reason": "findings/ empty (no agent output)",
                "ticket_run_dir": run_dir,
            })
            continue
        # Has work product — not stuck.
    return sorted(stuck, key=lambda r: r["key"])


def find_tickets_for_file(manifest, file_path):
    """Return ticket keys whose planned_files contains file_path.

    V2-W4-T01: used by core/gate-prompts/end-of-wave-gates.md Step 5.1 to map a
    gate finding's `File:` field to the owning ticket(s). The orchestrator
    consults this helper FIRST to identify which committed ticket owns the
    affected source file; if it returns empty, the orchestrator falls back to
    `git log --follow` against the wave branch (Step 5.1 fallback A); if that
    is also empty, the finding is treated as UNATTRIBUTED (Step 5.1 fallback B).

    Matching semantics: exact string match against entries in tickets[i].planned_files.
    No glob expansion, no path normalization. The caller is expected to pass the
    repo-root-relative path the gate emitted in its `File:` field. v1 deliberately
    keeps this simple; if path-normalization becomes a real need (e.g., `./foo.py`
    vs `foo.py`), the helper grows then.

    Returns:
        list[str]: ticket keys, sorted ascending (deterministic), possibly empty.
    """
    matches = []
    for t in manifest.get("tickets", []):
        planned = t.get("planned_files", []) or []
        if file_path in planned:
            matches.append(t["key"])
    return sorted(matches)


# --------------------------------------------------------------------------
# Amendment helpers (V2-W2-T01)
# --------------------------------------------------------------------------
#
# Mid-execution amendment-and-propagation is orchestrator-driven (ADR-009):
# the orchestrator detects scope shifts after t-implement reports a
# COMPLETION_REPORT, scans downstream tickets for impact, drafts proposed
# amendment text in its own context, surfaces to a human, and applies on
# approval. Implementer agents stay scoped to their own ticket; cross-ticket
# reasoning is the orchestrator's job.
#
# These helpers are the producer-side and consumer-side primitives. The
# orchestrator-side flow lives in core/config/phases/orchestrated/
# t-implement.md (detect+surface) and t-validate.md (reply+apply).

def detect_amendment(manifest, ticket_key, actual_files_modified):
    """Compare actual files modified against tickets[i].planned_files.

    Returns an amendment descriptor dict
        {added_files, removed_files, actual_files_modified, delta_summary}
    when the diff is non-empty, else None.

    Raises ValueError if ticket_key is not found in the manifest or if
    actual_files_modified is not a list-like value.
    """
    if not isinstance(actual_files_modified, (list, tuple, set)):
        raise ValueError(
            f"actual_files_modified must be a list; got {type(actual_files_modified).__name__}"
        )
    actual = sorted(set(actual_files_modified))

    target = None
    for t in manifest.get("tickets", []):
        if t.get("key") == ticket_key:
            target = t
            break
    if target is None:
        raise ValueError(f"ticket {ticket_key!r} not found in manifest")

    planned = sorted(set(target.get("planned_files", []) or []))
    actual_set = set(actual)
    planned_set = set(planned)
    added = sorted(actual_set - planned_set)
    removed = sorted(planned_set - actual_set)

    if not added and not removed:
        return None

    parts = []
    if added:
        parts.append(f"added {len(added)} file(s): {', '.join(added)}")
    if removed:
        parts.append(f"removed {len(removed)} file(s): {', '.join(removed)}")
    delta_summary = f"{ticket_key}: " + "; ".join(parts)

    return {
        "added_files":           added,
        "removed_files":         removed,
        "actual_files_modified": actual,
        "delta_summary":         delta_summary,
    }


def amend_planned_files(manifest_path, ticket_key, new_files):
    """Append files to a ticket's planned_files (set semantics; sorted).

    Used by t-spec.md after pm-spec authorizes files not present in the
    original `planned_files`. This is a *planning* event, not a mid-execution
    *amendment* — the additions land in the manifest BEFORE t-implement runs,
    so the post-implement `detect_amendment` comparison doesn't surface these
    legitimate spec-time scope refinements as scope shifts.

    The distinction matters because amendment-and-propagation (ADR-009) flow
    is triggered on actual implementer scope shifts, not on planner / spec
    refinement. Without this helper the orchestrator would have to inline-edit
    the manifest with jq + tmp + mv, duplicating manifest-mutation discipline
    that already lives here (see also: update_ticket_status, update_wave_field).

    Idempotent: re-invoking with the same files is a no-op (set semantics).
    Returns the sorted list of files actually added (excluding duplicates and
    empty strings).

    Raises ValueError if ticket_key not found.
    """
    cleaned = [f.strip() for f in (new_files or []) if f and f.strip()]
    if not cleaned:
        return []

    manifest = read_manifest(manifest_path)
    found = False
    added = []
    for t in manifest.get("tickets", []):
        if t.get("key") == ticket_key:
            existing = list(t.get("planned_files", []) or [])
            existing_set = set(existing)
            for f in cleaned:
                if f not in existing_set:
                    existing_set.add(f)
                    added.append(f)
            t["planned_files"] = sorted(existing_set)
            found = True
            break
    if not found:
        raise ValueError(f"ticket {ticket_key!r} not found in manifest at {manifest_path}")
    if added:
        write_manifest(manifest, manifest_path)
    return sorted(set(added))


def amend_new_files(manifest_path, ticket_key, new_files):
    """Append files to a ticket's `new_files` (set semantics; sorted).

    Mirrors `amend_planned_files` for the ADR-017 NEW-vs-MODIFY discriminator.
    Used by `w-pm-spec.md` Step 8 when the orchestrator's disk-stat extension
    classifies a wave-spec-authored path as NEW (doesn't exist on disk at
    wave-spec authoring time). The added files MUST also be in `planned_files`
    — the helper does NOT auto-add them; the caller is expected to invoke
    `amend_planned_files` first (or hand-author planned_files to cover them).

    Idempotent: re-invoking with the same files is a no-op (set semantics).
    Returns the sorted list of files actually added (excluding duplicates and
    empty strings).

    Raises ValueError if ticket_key not found.
    """
    cleaned = [f.strip() for f in (new_files or []) if f and f.strip()]
    if not cleaned:
        return []

    manifest = read_manifest(manifest_path)
    found = False
    added = []
    for t in manifest.get("tickets", []):
        if t.get("key") == ticket_key:
            existing = list(t.get("new_files", []) or [])
            existing_set = set(existing)
            for f in cleaned:
                if f not in existing_set:
                    existing_set.add(f)
                    added.append(f)
            t["new_files"] = sorted(existing_set)
            found = True
            break
    if not found:
        raise ValueError(f"ticket {ticket_key!r} not found in manifest at {manifest_path}")
    if added:
        write_manifest(manifest, manifest_path)
    return sorted(set(added))


CASCADE_PATTERNS = (
    # Lockfiles — auto-regenerated when an upstream package.json changes.
    "pnpm-lock.yaml",
    "package-lock.json",
    "yarn.lock",
    "Cargo.lock",
    "Pipfile.lock",
    "poetry.lock",
    "composer.lock",
    "Gemfile.lock",
    "go.sum",
)
"""Filenames whose presence is mechanical when an upstream manifest changes.

If `pnpm-lock.yaml` is in `files_modified` and any `package.json` is in
`planned_files`, the lockfile change is a cascade — not scope expansion.
Same for the language-specific equivalents above.

This list is intentionally narrow: only literal lockfile filenames whose
modification is unambiguously triggered by another file in the same change.
Generated `.d.ts` files in `dist/` directories are NOT in this list because
their cascade relationship is project-specific (some projects check `.d.ts`
into source).
"""


def _is_cascade_class(path, planned_files_set, deletive_set):
    """Return True if `path` qualifies as a cascade-class (auto-included) file.

    A path qualifies when ANY of the following hold:
    - The basename matches a known lockfile pattern (CASCADE_PATTERNS) AND
      at least one corresponding manifest file (e.g., a sibling
      `package.json` for `pnpm-lock.yaml`) is in `planned_files_set`.
    - The path appears in `deletive_set` (purely deletive — caught by
      `deletive_files` per the deletion-cascade carve-out at
      `core/rules/rules-orchestrated-mode.md` § "Carve-out: deletion-cascade").

    Other heuristics (generated `.d.ts`, schema-derived files) are intentionally
    omitted from v1 to keep the auto-classification narrow. Future tickets can
    extend `CASCADE_PATTERNS` and the heuristics here if empirical drift surfaces
    additional categories.
    """
    if path in deletive_set:
        return True

    basename = path.rsplit("/", 1)[-1]
    if basename in CASCADE_PATTERNS:
        # Lockfile cascade is only legitimate when an upstream manifest is
        # also being changed. The mapping below is conservative — JS lockfiles
        # require a corresponding package.json or pnpm-workspace.yaml in
        # planned_files.
        lockfile_to_manifest = {
            "pnpm-lock.yaml":     ("package.json", "pnpm-workspace.yaml"),
            "package-lock.json":  ("package.json",),
            "yarn.lock":          ("package.json",),
            "Cargo.lock":         ("Cargo.toml",),
            "Pipfile.lock":       ("Pipfile",),
            "poetry.lock":        ("pyproject.toml",),
            "composer.lock":      ("composer.json",),
            "Gemfile.lock":       ("Gemfile",),
            "go.sum":             ("go.mod",),
        }
        manifests = lockfile_to_manifest.get(basename, ())
        for planned in planned_files_set:
            planned_basename = planned.rsplit("/", 1)[-1]
            if planned_basename in manifests:
                return True
        return False

    return False


def partition_files(files_modified, planned_files, deletive=None):
    """Partition `files_modified` into (chosen, cascade) per F-005a / A2.

    A file is `chosen` when the implementer made an explicit decision to
    include it (it appears in `planned_files` either as a literal path or
    as the result of authorized scope expansion).

    A file is `cascade` when its presence is mechanical — a derivative of
    other authorized changes (lockfile updates triggered by an upstream
    manifest change, deletion-cascade cleanup of test files for an
    authorized-deleted symbol, etc.). Cascade files do NOT count against
    the scope-cap (gate-inventory F-005 / A2 fix); the scope-cap exists
    to constrain implementer choices, not mechanical consequences.

    Args:
        files_modified: Iterable of file path strings the implementer modified.
        planned_files: Iterable of authorized paths from the wave manifest.
        deletive: Optional pre-computed set of paths from `deletive_files()`.
            If None, the deletion-cascade carve-out is not applied (callers
            that don't have a git diff context can skip it).

    Returns:
        (chosen, cascade) — both sorted lists; their union equals the input
        `files_modified` (deduplicated).
    """
    files_set = {p for p in (files_modified or []) if p}
    planned_set = {p for p in (planned_files or []) if p}
    deletive_set = set(deletive or [])

    chosen, cascade = [], []
    for path in sorted(files_set):
        if path in planned_set:
            chosen.append(path)
        elif _is_cascade_class(path, planned_set, deletive_set):
            cascade.append(path)
        else:
            chosen.append(path)
    return chosen, cascade


def deletive_files(file_paths, base_ref="HEAD~1", head_ref="HEAD"):
    """Return the subset of file_paths whose diff is purely deletive (zero additions).

    A file is "deletive" if its diff between base_ref..head_ref reports zero
    additions. Files with any additions, files not in the diff, and pure-rename
    diffs (status 'R...') are excluded. Binary files fall back to --name-status
    to check for the 'D' (deleted) status.

    The carve-out documented at core/rules/rules-orchestrated-mode.md
    "Carve-out: deletion-cascade" uses this helper to mechanically detect
    condition 1 (purely deletive). Conditions 2 (direct consequence of an
    in-manifest authorized deletion) and 3 (required to satisfy an in-spec
    AC) remain orchestrator-judgment.

    Args:
        file_paths: Iterable of file path strings to classify.
        base_ref: git ref for the diff base (default: HEAD~1).
        head_ref: git ref for the diff head (default: HEAD).

    Returns:
        Sorted list of file paths from file_paths that are purely deletive.

    Raises:
        subprocess.CalledProcessError: if the git command fails (e.g., bad refs).
    """
    file_set = {p for p in (file_paths or []) if p}
    if not file_set:
        return []

    cmd = ["git", "diff", "--numstat", f"{base_ref}..{head_ref}", "--"] + sorted(file_set)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)

    deletive = set()
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        adds, _dels, path = parts[0], parts[1], "\t".join(parts[2:])
        if path not in file_set:
            continue
        if adds == "0":
            deletive.add(path)
        elif adds == "-":
            # Binary file — additions/deletions not reported by numstat.
            # Check name-status: 'D' means deleted; anything else (M/A/R/C) is
            # not "purely deletive."
            ns = subprocess.run(
                ["git", "diff", "--name-status", f"{base_ref}..{head_ref}", "--", path],
                capture_output=True, text=True, check=True,
            )
            for nsline in ns.stdout.splitlines():
                nsparts = nsline.split("\t", 1)
                if len(nsparts) >= 2 and nsparts[0] == "D":
                    deletive.add(path)
                    break
    return sorted(deletive)


def scan_downstream_impact(manifest, amended_ticket_key):
    """Return the keys of downstream tickets impacted by an amendment.

    Downstream criteria (OR):
      - depends_on contains the amended_ticket_key
      - planned_files intersects the amended ticket's planned_files (post-amendment)

    The amended ticket itself is excluded. Tickets already at status 'complete'
    are excluded — there's no value in amending an implemented ticket
    in-place; amendments to those flow via the deferral ledger (ADR-010).

    Tickets at 'blocked' status are EXCLUDED (no point amending a closed
    ticket); 'pending', 'pending-amendment-applied', 'in-progress', and
    'amending' are all candidates.

    V2-W4-T01 CR-002 iter-2: 'reverted' is also EXCLUDED. A reverted ticket's
    commit is gone from the wave branch; amending it makes no sense and would
    cause find_next_ready_ticket to re-select it for implementer dispatch.
    A future ticket may add a 'reinstate-after-revert' flow if the need arises;
    until then, reverted is terminal for amendment-propagation purposes.

    Raises ValueError if amended_ticket_key is not found.
    """
    source = None
    for t in manifest.get("tickets", []):
        if t.get("key") == amended_ticket_key:
            source = t
            break
    if source is None:
        raise ValueError(f"ticket {amended_ticket_key!r} not found in manifest")

    source_files = set(source.get("planned_files", []) or [])
    affected = []
    for t in manifest.get("tickets", []):
        key = t.get("key")
        if key == amended_ticket_key:
            continue
        if t.get("status") in ("complete", "blocked", "reverted"):
            continue
        deps = set(t.get("depends_on", []) or [])
        if amended_ticket_key in deps:
            affected.append(key)
            continue
        their_files = set(t.get("planned_files", []) or [])
        if source_files & their_files:
            affected.append(key)
    return sorted(set(affected))


def apply_amendment_source(manifest_path, source_key, actual_files_modified, delta_summary):
    """Source-side amendment apply.

    - Unions tickets[source].planned_files with actual_files_modified.
    - Appends to tickets[source].amendment_history with from_ticket=source_key
      (self-marker — a record's from_ticket equal to its own ticket key signals
      a source-side self-amendment).
    - Status: in-progress -> amending (transient label until next phase
      advance, which the orchestrator's flow handles via t-validate).
    - Idempotent on the (from_ticket=source_key, summary=delta_summary) pair —
      calling twice with the same delta_summary is a no-op.

    Raises ValueError if source_key is not found, or if delta_summary is empty.
    """
    if not isinstance(actual_files_modified, (list, tuple, set)):
        raise ValueError(
            f"actual_files_modified must be a list; got {type(actual_files_modified).__name__}"
        )
    if not isinstance(delta_summary, str) or not delta_summary.strip():
        raise ValueError("delta_summary must be a non-empty string")

    manifest = read_manifest(manifest_path)
    target = None
    for t in manifest.get("tickets", []):
        if t.get("key") == source_key:
            target = t
            break
    if target is None:
        raise ValueError(f"ticket {source_key!r} not found in manifest")

    history = target.setdefault("amendment_history", [])
    for entry in history:
        if (
            entry.get("from_ticket") == source_key
            and entry.get("summary") == delta_summary
        ):
            return  # idempotent

    planned = list(target.get("planned_files", []) or [])
    target["planned_files"] = sorted(set(planned) | set(actual_files_modified))

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    history.append({
        "from_ticket": source_key,
        "applied_at":  now,
        "summary":     delta_summary,
    })

    if target.get("status") == "in-progress":
        target["status"] = "amending"

    write_manifest(manifest, manifest_path)


def apply_amendment_downstream(manifest_path, downstream_key, source_key, amendment_text):
    """Downstream-side amendment apply.

    - Appends amendment_text to ${ticket_run_dir}/prompt.md under
      `## Amendment from {source_key} ({UTC date})` heading.
    - Status: pending -> pending-amendment-applied (so find_next_ready_ticket
      still selects the ticket; t-cto re-reads the augmented prompt.md).
    - Appends to tickets[downstream].amendment_history with from_ticket=source_key.
    - Idempotent: scans the existing prompt.md for the same heading; skips
      append if already present.

    Raises ValueError on missing downstream_key, missing ticket_run_dir,
    missing prompt.md, or empty amendment_text.
    """
    if not isinstance(amendment_text, str) or not amendment_text.strip():
        raise ValueError("amendment_text must be a non-empty string")

    manifest = read_manifest(manifest_path)
    target = None
    for t in manifest.get("tickets", []):
        if t.get("key") == downstream_key:
            target = t
            break
    if target is None:
        raise ValueError(f"ticket {downstream_key!r} not found in manifest")

    ticket_run_dir = target.get("ticket_run_dir")
    if not ticket_run_dir:
        raise ValueError(
            f"ticket {downstream_key!r} has no ticket_run_dir; "
            "t-cto must populate it before downstream amendment applies"
        )

    # SA-002 path-traversal defense: realpath the ticket_run_dir and verify it
    # is contained under the realpath of the manifest's directory. A compromised
    # manifest with `ticket_run_dir: "/foo/bar/../../some/other/path"` would
    # otherwise resolve at open() and append amendment text outside the wave
    # run folder. The guard uses realpath (resolves symlinks + ..) and a
    # path-component-aware containment check.
    manifest_root = os.path.realpath(os.path.dirname(os.path.abspath(manifest_path)))
    real_run_dir = os.path.realpath(ticket_run_dir)
    if real_run_dir != manifest_root and not real_run_dir.startswith(manifest_root + os.sep):
        raise ValueError(
            f"ticket {downstream_key!r} ticket_run_dir {ticket_run_dir!r} resolves to "
            f"{real_run_dir!r}, which is outside the wave run directory "
            f"{manifest_root!r} — refusing to write outside the run scope"
        )

    prompt_path = os.path.join(real_run_dir, "prompt.md")
    if not os.path.isfile(prompt_path):
        raise ValueError(f"downstream prompt.md not found at {prompt_path}")

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    heading = f"## Amendment from {source_key} ({today})"

    with open(prompt_path, "r") as f:
        existing = f.read()
    if heading in existing:
        return  # idempotent

    block = f"\n\n{heading}\n\n{amendment_text.strip()}\n"
    with open(prompt_path, "a") as f:
        f.write(block)

    if target.get("status") == "pending":
        target["status"] = "pending-amendment-applied"

    history = target.setdefault("amendment_history", [])
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    summary = amendment_text.strip().split("\n", 1)[0][:200]
    history.append({
        "from_ticket": source_key,
        "applied_at":  now,
        "summary":     summary,
    })

    write_manifest(manifest, manifest_path)


def set_amendment_proposal(manifest_path, source_key, proposal):
    """Persist an in-flight amendment proposal on the source ticket.

    Validates the proposal dict shape before writing. Overwrites any existing
    proposal — the lifecycle (detected -> proposed -> applied/rejected) treats
    set_amendment_proposal as the canonical "proposed" transition; the
    apply_amendment_* and clear_amendment_proposal calls are the canonical
    "applied" / "rejected" transitions.

    The persistence is the load-bearing piece: if the orchestrator session
    halts between detection and the user's reply, a fresh-session resume
    re-reads this field and re-surfaces the same proposal.
    """
    if not isinstance(proposal, dict):
        raise ValueError(f"proposal must be a dict; got {type(proposal).__name__}")
    for f in _AMENDMENT_PROPOSAL_REQUIRED_FIELDS:
        if f not in proposal:
            raise ValueError(f"proposal missing required field {f!r}")

    manifest = read_manifest(manifest_path)
    target = None
    for t in manifest.get("tickets", []):
        if t.get("key") == source_key:
            target = t
            break
    if target is None:
        raise ValueError(f"ticket {source_key!r} not found in manifest")

    target["amendment_proposal"] = proposal
    write_manifest(manifest, manifest_path)


def clear_amendment_proposal(manifest_path, source_key):
    """Clear the in-flight amendment proposal on the source ticket.

    Idempotent: clearing an already-null proposal is a no-op.
    """
    manifest = read_manifest(manifest_path)
    target = None
    for t in manifest.get("tickets", []):
        if t.get("key") == source_key:
            target = t
            break
    if target is None:
        raise ValueError(f"ticket {source_key!r} not found in manifest")

    target["amendment_proposal"] = None
    write_manifest(manifest, manifest_path)


# --------------------------------------------------------------------------
# ADR-024 — Per-wave disposition-precedent memory (INFRA-026)
# --------------------------------------------------------------------------
# Per-wave halt-class-disposition cache. Populated at every halt-and-resume
# that resolves to a disposition; consumed by:
#   - Halt-template framing: "RECOMMENDED: <prior disposition>" pre-fill on
#     subsequent same-halt-class instances (per halt-templates.md).
#   - @resolver soft-prior: PRIOR_PRECEDENTS section in dispatch
#     prompt augments resolver's verdict with disagreement-must-address
#     binding (per core/agents/resolver.md).
#
# Schema (top-level wave field; additive — absence permitted):
#   precedent_cache: {
#     "<halt_class_key>": {
#       "first_seen_at": ISO 8601 UTC,
#       "first_seen_ticket": ticket_key,
#       "last_seen_at": ISO 8601 UTC,
#       "last_seen_ticket": ticket_key,
#       "disposition": str,    # verbatim operator reply text
#       "criterion_match": str,  # crit-1..crit-5
#       "instance_count": int,
#     },
#     ...
#   }
#
# halt_class_key derivation rule lives in halt-templates.md; each template
# declares its derivation per-template. Examples:
#   - "cto-simplify:T-030A"
#   - "review-discussion:cr-003-dismiss-without-citation"
#   - "wave-cto-disposition" (single-shot per wave; no per-ticket subkey)
#
# Cross-wave memory is explicitly out of scope; this cache is per-wave.

_PRECEDENT_CACHE_REQUIRED_FIELDS = (
    "first_seen_at",
    "first_seen_ticket",
    "last_seen_at",
    "last_seen_ticket",
    "disposition",
    "criterion_match",
    "instance_count",
)


def update_precedent(manifest_path, halt_class_key, disposition,
                     criterion_match, ticket_key):
    """Upsert a precedent cache entry on the wave manifest.

    First call for the halt_class_key: insert with instance_count=1, first_seen
    + last_seen both set to (ticket_key, now).
    Subsequent calls: increment instance_count, update last_seen_* + disposition
    + criterion_match (most-recent-wins on the prior). first_seen_* preserved.

    Atomic write via tmp + os.replace (mirrors write_atomic pattern).
    """
    if not isinstance(halt_class_key, str) or not halt_class_key.strip():
        raise ValueError("halt_class_key must be a non-empty string")
    if not isinstance(disposition, str):
        raise ValueError("disposition must be a string")
    valid_criteria = {"none", "crit-1", "crit-2", "crit-3", "crit-4", "crit-5"}
    if criterion_match not in valid_criteria:
        raise ValueError(
            f"criterion_match {criterion_match!r} must be one of {sorted(valid_criteria)}"
        )
    if not isinstance(ticket_key, str) or not TICKET_KEY_RE.match(ticket_key):
        raise ValueError(
            f"ticket_key {ticket_key!r} must match {TICKET_KEY_RE.pattern!r}"
        )

    manifest = read_manifest(manifest_path)
    cache = manifest.get("precedent_cache") or {}
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    existing = cache.get(halt_class_key)
    if existing is None:
        cache[halt_class_key] = {
            "first_seen_at": now,
            "first_seen_ticket": ticket_key,
            "last_seen_at": now,
            "last_seen_ticket": ticket_key,
            "disposition": disposition,
            "criterion_match": criterion_match,
            "instance_count": 1,
        }
    else:
        existing["last_seen_at"] = now
        existing["last_seen_ticket"] = ticket_key
        existing["disposition"] = disposition
        existing["criterion_match"] = criterion_match
        existing["instance_count"] = existing.get("instance_count", 1) + 1

    manifest["precedent_cache"] = cache
    write_manifest(manifest, manifest_path)


def read_precedent(manifest_path, halt_class_key):
    """Return the precedent cache entry for halt_class_key, or empty dict
    if absent. Read-only; does not mutate the manifest."""
    manifest = read_manifest(manifest_path)
    cache = manifest.get("precedent_cache") or {}
    return cache.get(halt_class_key) or {}


def list_precedents(manifest_path, ticket_filter=None):
    """Return all precedent cache entries as a list of {key, ...entry} dicts.
    If ticket_filter is non-empty, return only entries whose last_seen_ticket
    matches. Used by resolver dispatch prompt construction (ADR-024 soft-prior
    consumption).
    """
    manifest = read_manifest(manifest_path)
    cache = manifest.get("precedent_cache") or {}
    out = []
    for key, entry in cache.items():
        if ticket_filter and entry.get("last_seen_ticket") != ticket_filter:
            continue
        out.append({"halt_class_key": key, **entry})
    # Sort by first_seen_at for deterministic output.
    out.sort(key=lambda e: e.get("first_seen_at", ""))
    return out


# --------------------------------------------------------------------------
# v3 / ADR-028: wave-sizing tripwire (decompose, never fragment)
# --------------------------------------------------------------------------

def wave_sizing_warning(manifest):
    """Return a non-silent sizing-tripwire warning string for v3 waves, or None.

    Under wave_protocol_version == 3 a single implementer authors the entire wave
    in one continuous context (ADR-028). When the ticket count exceeds the
    one-implementer soft limit, the wave may not fit one Opus-1M envelope. Per
    ADR-028 § Tripwire the response is wave DECOMPOSITION (split into smaller
    waves), NEVER implementer fragmentation (multiple implementers in one wave),
    which would re-introduce the F-015 cross-ticket integration class at the seam.

    This is advisory (a tripwire signal surfaced to the operator), not a hard cap;
    max_wave_size remains the hard cap enforced in validate().
    """
    if manifest.get("wave_protocol_version") != 3:
        return None
    n = len(manifest.get("tickets", []))
    if n > _V3_IMPLEMENTER_CONTEXT_SOFT_LIMIT:
        return (
            f"Wave-sizing tripwire (ADR-028): this v3 wave has {n} tickets, above the "
            f"one-implementer soft limit of {_V3_IMPLEMENTER_CONTEXT_SOFT_LIMIT}. A single "
            f"implementer authors the whole wave in one context; {n} tickets may exceed the "
            f"1M envelope. If it does, DECOMPOSE the wave into smaller waves — do NOT fragment "
            f"the implementer (multiple implementers re-introduce the cross-ticket integration "
            f"bug class at the seam). See ADR-028 § Tripwire."
        )
    return None


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _cmd_write_from_plan(args):
    try:
        manifest = parse_wave_plan(args.plan_path)
    except ValueError as e:
        print(f"wave-manifest: parse error: {e}", file=sys.stderr)
        return 2

    # Derive wave_run_dir + surface_log from the manifest target path.
    # Convention: manifest at ${run_dir}/wave-manifest.json => run_dir = dirname.
    run_dir = os.path.dirname(os.path.abspath(args.manifest_path))
    manifest["wave_run_dir"] = run_dir
    manifest["surface_log"] = os.path.join(run_dir, "surface-log.md")

    try:
        write_manifest(manifest, args.manifest_path)
    except ValueError as e:
        print(f"wave-manifest: validation error: {e}", file=sys.stderr)
        return 2

    # v3 / ADR-028: emit the wave-sizing tripwire warning (never silent). The
    # orchestrator pipes this through to the operator verbatim; the manifest is
    # still written (advisory, not blocking).
    warning = wave_sizing_warning(manifest)
    if warning:
        print(f"wave-manifest: {warning}", file=sys.stderr)
    return 0


def _cmd_update_ticket_status(args):
    extra = {}
    for kv in args.field or []:
        if "=" not in kv:
            print(f"wave-manifest: --field expects key=value; got {kv!r}", file=sys.stderr)
            return 2
        k, v = kv.split("=", 1)
        # Try JSON-decode the value (so "null", "true", "[]" work); fall back to literal string.
        try:
            extra[k] = json.loads(v)
        except json.JSONDecodeError:
            extra[k] = v
    try:
        update_ticket_status(args.manifest_path, args.ticket_key, args.status, **extra)
    except ValueError as e:
        print(f"wave-manifest: update error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_update_wave_field(args):
    try:
        value = json.loads(args.value)
    except json.JSONDecodeError:
        value = args.value
    try:
        update_wave_field(args.manifest_path, args.field, value)
    except (ValueError, KeyError) as e:
        print(f"wave-manifest: update error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_next_ready_ticket(args):
    # SA-002: wrap read_manifest the same way the other subcommands do; on
    # missing/unreadable/malformed input, surface a clean error and exit 2
    # rather than spilling a Python traceback (which leaks the absolute path).
    # UnicodeDecodeError (subclass of ValueError) covers binary-file inputs
    # that json.JSONDecodeError doesn't catch — added in iter-2 SA-002 residual.
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    nxt = find_next_ready_ticket(manifest)
    if nxt is not None:
        print(nxt)
    return 0


def _cmd_find_stuck_tickets(args):
    # A3: defensive read pattern same as the other subcommands. Output one
    # tab-separated line per stuck ticket: <key>\t<reason>\t<ticket_run_dir>.
    # Empty stdout = no stuck tickets (caller should check exit 0 + empty).
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    stuck = find_stuck_tickets(manifest)
    for record in stuck:
        print(f"{record['key']}\t{record['reason']}\t{record['ticket_run_dir']}")
    return 0


def _cmd_find_tickets_for_file(args):
    # V2-W4-T01: same defensive read pattern as _cmd_next_ready_ticket — clean
    # error + exit 2 on missing/unreadable/malformed input rather than spilling
    # a Python traceback (which leaks the absolute path).
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    keys = find_tickets_for_file(manifest, args.file_path)
    for k in keys:
        print(k)
    return 0


def _cmd_detect_amendment(args):
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    try:
        descriptor = detect_amendment(manifest, args.ticket_key, args.actual_file or [])
    except ValueError as e:
        print(f"wave-manifest: detect error: {e}", file=sys.stderr)
        return 2
    if descriptor is not None:
        json.dump(descriptor, sys.stdout, indent=2, sort_keys=False)
        sys.stdout.write("\n")
    return 0


def _cmd_amend_planned_files(args):
    try:
        added = amend_planned_files(args.manifest_path, args.ticket_key, args.file or [])
    except (ValueError, OSError, json.JSONDecodeError) as e:
        print(f"wave-manifest: amend error: {e}", file=sys.stderr)
        return 2
    for f in added:
        print(f)
    return 0


def _cmd_amend_new_files(args):
    try:
        added = amend_new_files(args.manifest_path, args.ticket_key, args.file or [])
    except (ValueError, OSError, json.JSONDecodeError) as e:
        print(f"wave-manifest: amend error: {e}", file=sys.stderr)
        return 2
    for f in added:
        print(f)
    return 0


def _cmd_deletive_files(args):
    try:
        result = deletive_files(args.file or [], args.base_ref, args.head_ref)
    except subprocess.CalledProcessError as e:
        msg = e.stderr.strip() if e.stderr else str(e)
        print(f"wave-manifest: git error: {msg}", file=sys.stderr)
        return 2
    for p in result:
        print(p)
    return 0


def _cmd_partition_files(args):
    """F-005a / A2: print the chosen + cascade partition of files_modified.

    Output: two TSV-shaped sections separated by `--`:

        <chosen-1>
        <chosen-2>
        ...
        --
        <cascade-1>
        <cascade-2>
        ...

    The orchestrator at t-implement.md Step 6 Check A counts only the
    chosen section against the scope cap; the cascade section is
    informational.
    """
    try:
        manifest = read_manifest(args.manifest_path) if args.manifest_path else None
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2

    # Resolve planned_files. If --ticket-key + --manifest are provided, look
    # them up. Otherwise use --planned (free-form list).
    if manifest is not None and args.ticket_key:
        ticket = next(
            (t for t in manifest.get("tickets", []) if t.get("key") == args.ticket_key),
            None,
        )
        if ticket is None:
            print(f"wave-manifest: ticket '{args.ticket_key}' not found in manifest", file=sys.stderr)
            return 2
        planned = ticket.get("planned_files", [])
    else:
        planned = args.planned or []

    # Optional pre-computed deletive set (from a separate `deletive-files` run).
    deletive = args.deletive_path or []

    chosen, cascade = partition_files(args.file or [], planned, deletive=deletive)
    for p in chosen:
        print(p)
    print("--")
    for p in cascade:
        print(p)
    return 0


def _cmd_scan_downstream_impact(args):
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    try:
        keys = scan_downstream_impact(manifest, args.amended_ticket_key)
    except ValueError as e:
        print(f"wave-manifest: scan error: {e}", file=sys.stderr)
        return 2
    for k in keys:
        print(k)
    return 0


def _cmd_apply_amendment_source(args):
    try:
        apply_amendment_source(
            args.manifest_path,
            args.source_key,
            args.actual_file or [],
            args.delta_summary,
        )
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: apply-amendment-source error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_apply_amendment_downstream(args):
    # Read amendment text from file (avoids shell quoting issues with multi-line markdown).
    try:
        with open(args.amendment_text_file, "r") as f:
            amendment_text = f.read()
    except OSError as e:
        print(f"wave-manifest: cannot read amendment text file: {e}", file=sys.stderr)
        return 2
    try:
        apply_amendment_downstream(
            args.manifest_path,
            args.downstream_key,
            args.source_key,
            amendment_text,
        )
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: apply-amendment-downstream error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_set_amendment_proposal(args):
    try:
        with open(args.proposal_json_file, "r") as f:
            proposal = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"wave-manifest: cannot read proposal JSON: {e}", file=sys.stderr)
        return 2
    try:
        set_amendment_proposal(args.manifest_path, args.source_key, proposal)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: set-amendment-proposal error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_clear_amendment_proposal(args):
    try:
        clear_amendment_proposal(args.manifest_path, args.source_key)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: clear-amendment-proposal error: {e}", file=sys.stderr)
        return 2
    return 0


# ADR-024 / INFRA-026 — precedent cache CLI handlers

def _cmd_update_precedent(args):
    try:
        update_precedent(
            args.manifest_path,
            args.halt_class_key,
            args.disposition,
            args.criterion,
            args.ticket,
        )
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: update-precedent error: {e}", file=sys.stderr)
        return 2
    return 0


def _cmd_read_precedent(args):
    try:
        entry = read_precedent(args.manifest_path, args.halt_class_key)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: read-precedent error: {e}", file=sys.stderr)
        return 2
    print(json.dumps(entry, indent=2))
    return 0


def _cmd_list_precedents(args):
    try:
        entries = list_precedents(args.manifest_path, ticket_filter=args.ticket)
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print(f"wave-manifest: list-precedents error: {e}", file=sys.stderr)
        return 2
    print(json.dumps(entries, indent=2))
    return 0


def _cmd_validate(args):
    # SA-002 iter-2 residual: UnicodeDecodeError (ValueError subclass) covers
    # binary-file inputs that json.JSONDecodeError doesn't catch.
    try:
        manifest = read_manifest(args.manifest_path)
    except (OSError, json.JSONDecodeError, ValueError, UnicodeDecodeError) as e:
        print(f"wave-manifest: read error: {e}", file=sys.stderr)
        return 2
    errors = validate(manifest)
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 2
    return 0


def main():
    parser = argparse.ArgumentParser(description="Wave manifest helpers")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("write-from-plan", help="Parse a wave plan into a manifest and write it")
    p1.add_argument("plan_path")
    p1.add_argument("manifest_path")
    p1.set_defaults(func=_cmd_write_from_plan)

    p2 = sub.add_parser("update-ticket-status", help="Update a ticket's status atomically")
    p2.add_argument("manifest_path")
    p2.add_argument("ticket_key")
    p2.add_argument("status")
    p2.add_argument("--field", action="append", help="Extra key=value pairs to set on the ticket")
    p2.set_defaults(func=_cmd_update_ticket_status)

    p3 = sub.add_parser("update-wave-field", help="Update a top-level wave field atomically")
    p3.add_argument("manifest_path")
    p3.add_argument("field")
    p3.add_argument("value")
    p3.set_defaults(func=_cmd_update_wave_field)

    p4 = sub.add_parser("next-ready-ticket", help="Print the key of the next ready ticket")
    p4.add_argument("manifest_path")
    p4.set_defaults(func=_cmd_next_ready_ticket)

    # A3: detect tickets stuck in 'in-progress' status with no work artifacts.
    # Used by /orchestrated <slug> resume entry to surface stuck tickets at
    # session start. One line per stuck ticket: <key>\t<reason>\t<ticket_run_dir>.
    p4c = sub.add_parser("find-stuck-tickets",
                         help="Print stuck tickets (in-progress with no work product)")
    p4c.add_argument("manifest_path")
    p4c.set_defaults(func=_cmd_find_stuck_tickets)

    # V2-W4-T01: end-of-wave-gates Step 5.1 maps a finding's File: field to the
    # owning ticket(s). One key per line on stdout; empty output if the file is
    # not in any ticket's planned_files (caller falls back to git log --follow).
    p4b = sub.add_parser("find-tickets-for-file",
                         help="Print ticket keys whose planned_files contains the given file path")
    p4b.add_argument("manifest_path")
    p4b.add_argument("file_path")
    p4b.set_defaults(func=_cmd_find_tickets_for_file)

    p5 = sub.add_parser("validate", help="Validate a manifest; print errors to stderr")
    p5.add_argument("manifest_path")
    p5.set_defaults(func=_cmd_validate)

    # Amendment subcommands (V2-W2-T01).
    p6 = sub.add_parser("detect-amendment",
                        help="Print amendment descriptor JSON if scope shifted; empty otherwise")
    p6.add_argument("manifest_path")
    p6.add_argument("ticket_key")
    p6.add_argument("--actual-file", action="append",
                    help="Path of a file actually modified by the implementer "
                         "(repeat for multiple files)")
    p6.set_defaults(func=_cmd_detect_amendment)

    p7 = sub.add_parser("scan-downstream-impact",
                        help="Print one ticket key per line for tickets impacted by an amendment")
    p7.add_argument("manifest_path")
    p7.add_argument("amended_ticket_key")
    p7.set_defaults(func=_cmd_scan_downstream_impact)

    p8 = sub.add_parser("apply-amendment-source",
                        help="Apply source-side amendment: union planned_files, append history, status -> amending")
    p8.add_argument("manifest_path")
    p8.add_argument("source_key")
    p8.add_argument("delta_summary")
    p8.add_argument("--actual-file", action="append",
                    help="Path of a file actually modified (repeat for multiple)")
    p8.set_defaults(func=_cmd_apply_amendment_source)

    p9 = sub.add_parser("apply-amendment-downstream",
                        help="Apply downstream-side amendment: append to prompt.md, status -> pending-amendment-applied")
    p9.add_argument("manifest_path")
    p9.add_argument("downstream_key")
    p9.add_argument("source_key")
    p9.add_argument("amendment_text_file",
                    help="Path to a file containing the amendment text body (markdown)")
    p9.set_defaults(func=_cmd_apply_amendment_downstream)

    p10 = sub.add_parser("set-amendment-proposal",
                         help="Persist an in-flight amendment proposal on the source ticket")
    p10.add_argument("manifest_path")
    p10.add_argument("source_key")
    p10.add_argument("proposal_json_file",
                     help="Path to a JSON file containing the proposal dict")
    p10.set_defaults(func=_cmd_set_amendment_proposal)

    p11 = sub.add_parser("clear-amendment-proposal",
                         help="Clear the in-flight amendment proposal on the source ticket")
    p11.add_argument("manifest_path")
    p11.add_argument("source_key")
    p11.set_defaults(func=_cmd_clear_amendment_proposal)

    # A4 / pm-spec → manifest amendment: planning event (not amendment) when
    # pm-spec at t-spec authorizes files not in tickets[i].planned_files. The
    # helper appends with set semantics so the post-implement detect-amendment
    # path doesn't surface legitimate spec-time scope refinement as drift.
    p_apf = sub.add_parser("amend-planned-files",
                           help="Append files to a ticket's planned_files (planning, not amendment)")
    p_apf.add_argument("manifest_path")
    p_apf.add_argument("ticket_key")
    p_apf.add_argument("--file", action="append",
                       help="File path to append (repeat for multiple). "
                            "Empty input is a no-op.")
    p_apf.set_defaults(func=_cmd_amend_planned_files)

    # ADR-017: mirror of amend-planned-files for the NEW-vs-MODIFY discriminator.
    # Called from w-pm-spec.md Step 8 after disk-stat classification. The caller
    # is responsible for ensuring the file is also in planned_files (validate()
    # rejects non-subset entries).
    p_anf = sub.add_parser("amend-new-files",
                           help="Append files to a ticket's new_files (planning; ADR-017)")
    p_anf.add_argument("manifest_path")
    p_anf.add_argument("ticket_key")
    p_anf.add_argument("--file", action="append",
                       help="File path to append (repeat for multiple). "
                            "Must already be in planned_files. Empty input is a no-op.")
    p_anf.set_defaults(func=_cmd_amend_new_files)

    # 10-file cap deletion-cascade carve-out (rules-orchestrated-mode.md):
    # mechanically classify which of the listed files are purely deletive in
    # the diff. Conditions 2/3 of the carve-out (direct consequence + AC
    # requirement) remain orchestrator-judgment.
    p12 = sub.add_parser("deletive-files",
                         help="Print files (one per line) whose diff is purely deletive")
    p12.add_argument("--base-ref", default="HEAD~1",
                     help="git ref for the diff base (default: HEAD~1)")
    p12.add_argument("--head-ref", default="HEAD",
                     help="git ref for the diff head (default: HEAD)")
    p12.add_argument("--file", action="append", required=True,
                     help="File path to classify (repeat for multiple)")
    p12.set_defaults(func=_cmd_deletive_files)

    # F-005a / A2 — partition files_modified into (chosen, cascade) so the
    # scope cap counts only chosen files. Cascade-class files (lockfiles
    # with corresponding manifest changes; deletion-cascade artifacts) are
    # mechanical consequences of authorized changes.
    p13 = sub.add_parser("partition-files",
                         help="Partition files_modified into chosen + cascade per F-005a")
    p13.add_argument("--manifest-path",
                     help="Wave manifest path (used with --ticket-key to look up planned_files)")
    p13.add_argument("--ticket-key",
                     help="Ticket key whose planned_files governs the partition")
    p13.add_argument("--planned", action="append",
                     help="Planned file path (repeat for multiple; alternative to --manifest-path/--ticket-key)")
    p13.add_argument("--deletive-path", action="append",
                     help="Pre-computed deletive file path (repeat; from `deletive-files` subcommand)")
    p13.add_argument("--file", action="append", required=True,
                     help="File-modified path to partition (repeat for multiple)")
    p13.set_defaults(func=_cmd_partition_files)

    # ADR-024 / INFRA-026 — disposition-precedent memory subcommands
    p_up = sub.add_parser(
        "update-precedent",
        help="Upsert a precedent cache entry on the wave manifest (ADR-024).",
    )
    p_up.add_argument("manifest_path")
    p_up.add_argument("--halt-class-key", dest="halt_class_key", required=True,
                      help="Deterministic key per halt-templates.md derivation rule.")
    p_up.add_argument("--disposition", required=True,
                      help="Verbatim operator reply text (becomes the soft prior).")
    p_up.add_argument("--criterion", required=True,
                      choices=["none", "crit-1", "crit-2", "crit-3", "crit-4", "crit-5"],
                      help="Criterion-match value from the halt's CRITERION_MATCHED line.")
    p_up.add_argument("--ticket", required=True,
                      help="Current ticket key (for last_seen_ticket).")
    p_up.set_defaults(func=_cmd_update_precedent)

    p_rp = sub.add_parser(
        "read-precedent",
        help="Return precedent cache entry for halt_class_key as JSON; empty dict if absent.",
    )
    p_rp.add_argument("manifest_path")
    p_rp.add_argument("halt_class_key")
    p_rp.set_defaults(func=_cmd_read_precedent)

    p_lp = sub.add_parser(
        "list-precedents",
        help="List all precedent cache entries as JSON array; optionally filter by --ticket.",
    )
    p_lp.add_argument("manifest_path")
    p_lp.add_argument("--ticket", default=None,
                      help="Filter to entries whose last_seen_ticket matches.")
    p_lp.set_defaults(func=_cmd_list_precedents)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
