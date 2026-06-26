#!/usr/bin/env python3
"""graphiti-wave2-ab — the typed-vs-freeform A/B episode generator (graphiti-cost-efficiency Wave 2).

Fans the 12 hand-judged eval cases (core/scripts/tests/fixtures/graphiti-eval-set.jsonl, Wave 1's
immutable fixture) into 24 graph writes: each case's synthesized body is written TWICE through the
sanctioned `graphiti_write.write_fact()` path —
  * once to group_id ``ab-wave2-typed-<topic>``    (typed bundle: entity_types=ENTITY_TYPES)
  * once to group_id ``ab-wave2-freeform-<topic>``  (freeform: entity_types=None)
Writing through write_fact() means the scrubber single-source invariant (Wave 1) and the per-call
telemetry JSONL sink (ADR-074) both engage automatically; T5 joins that telemetry on group_id.

DELIMITER: the A/B namespace uses ``-`` not ``:`` — graphiti-core 0.28.1 rejects colons in group_id
(charset = ASCII alnum + dash + underscore). The ADR-073 R5 / architect-D5 colon form is infeasible
at the engine layer; the dash form is semantically identical (W2TE-T3 finding).

BODY SYNTHESIS: the eval set is a RETRIEVAL fixture — each case carries a `context` question +
`expected_facts`, but no standalone source-body field. The harness synthesizes the episode body from
`context` + `expected_facts` so the facts are present for extraction. Both arms receive the
byte-identical synthesized body, so the A/B isolates the ONE variable under test: the ontology.
(Limitation, documented in T5 findings: with facts stated verbatim in the body and a recency-ranked,
query-blind read path, the typed-vs-freeform delta may be within case-level noise → INDETERMINATE is
a legitimate disposition. The harness does not game the body to manufacture a delta.)

  python3 graphiti-wave2-ab.py --dry-run   # guards + construct all 24 payloads; NO docker exec
  python3 graphiti-wave2-ab.py             # guards + 24 live writes (each triggers LLM extraction)

Determinism: <topic> is a stable kebab slug of `context` (first ~24 chars), so re-runs are
content-hash no-ops via write_fact()'s idempotency rather than fanning out duplicates.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from graphiti_write import write_fact  # noqa: E402  (sanctioned single write path)

FIXTURE = HERE / "tests" / "fixtures" / "graphiti-eval-set.jsonl"

# Pre-A/B guard sequence (architect D7 / AC-021) — run BEFORE any payload is constructed.
GUARDS = [
    ["bash", str(HERE / "test-graphiti-embedding-dim.sh"), "ab-wave2-typed"],
    ["bash", str(HERE / "test-graphiti-embedding-dim.sh"), "ab-wave2-freeform"],
    ["bash", str(HERE / "test-graphiti-scrubber-coverage.sh")],
]


def run_guards() -> bool:
    """Run the three pre-A/B guards in order; return False (and surface which) on any failure."""
    for cmd in GUARDS:
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"PRE-A/B GUARD FAILED: {' '.join(cmd)}", file=sys.stderr)
            print((r.stdout + r.stderr).strip()[-500:], file=sys.stderr)
            return False
    return True


def topic_slug(context: str) -> str:
    """Stable kebab slug of the case context (first ~24 chars). Deterministic — identical input
    yields an identical slug so re-runs are content-hash no-ops."""
    s = context.lower()[:24]
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    s = re.sub(r"-+", "-", s)
    return s or "case"


def synth_body(case: dict) -> str:
    """Synthesize the episode body (the source content the LLM extracts FROM) from the eval case.

    The eval set has no source-body field; the expected_facts ARE the durable facts the source
    would state. Both A/B arms get this identical body.
    """
    facts = ". ".join(f.strip().rstrip(".") for f in case.get("expected_facts", []) if f.strip())
    context = case["context"].strip()
    return f"{context}\n\n{facts}." if facts else context


def load_cases() -> list[dict]:
    cases = []
    for line in FIXTURE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "_comment" in obj:  # skip any header/comment line
            continue
        cases.append(obj)
    return cases


def main() -> int:
    ap = argparse.ArgumentParser(description="Typed-vs-freeform A/B episode generator (Wave 2).")
    ap.add_argument("--dry-run", action="store_true",
                    help="run guards + construct all payloads, but do NOT write (no docker exec)")
    args = ap.parse_args()

    if not run_guards():
        print("Refusing to start: a pre-A/B guard failed (see above).", file=sys.stderr)
        return 1

    cases = load_cases()
    if not cases:
        print(f"no eval cases found in {FIXTURE}", file=sys.stderr)
        return 1

    written = 0
    for case in cases:
        topic = topic_slug(case["context"])
        body = synth_body(case)
        for arm in ("typed", "freeform"):
            gid = f"ab-wave2-{arm}-{topic}"
            # Load-bearing isolation guard: a write must NEVER target the live capture group.
            if not gid.startswith("ab-wave2-"):
                print(f"FAIL: refusing to write to non-A/B group_id {gid!r}", file=sys.stderr)
                return 1
            r = write_fact(body, group_id=gid, source_description=f"W2TE-T4 A/B {arm}",
                           dry_run=args.dry_run)
            # Catch a silent quarantine (validator miss) — resolved gid MUST equal the intended one.
            if r["group_id"] != gid:
                print(f"FAIL: {arm} '{topic}' resolved to {r['group_id']!r} "
                      f"(expected {gid!r} — quarantined? namespace unregistered?)", file=sys.stderr)
                return 1
            expected = ("dry-run",) if args.dry_run else ("written", "duplicate")
            if r["status"] not in expected:
                print(f"FAIL: {arm} '{topic}' status={r['status']} {r.get('error', '')}", file=sys.stderr)
                return 1
            written += 1

    verb = "constructed" if args.dry_run else "written"
    prefix = "[dry-run] " if args.dry_run else ""
    print(f"{prefix}A/B complete: {len(cases)} cases x 2 arms = {written} payloads {verb} "
          f"(typed: ab-wave2-typed-*, freeform: ab-wave2-freeform-*)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
