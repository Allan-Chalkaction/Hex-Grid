#!/usr/bin/env python3
"""graphiti-scrubber — redact secrets/credentials before anything is written to the graph.

MANDATORY on every write path (deliberate `remember` and automated capture). The whole memory
initiative started because API keys hit a transcript — a live auto-writer with no scrubber could
write them into the graph, where they propagate into edges and are a nightmare to purge. So:
scrub FIRST, write second. v1 is regex-based (known secret shapes + obvious PII); an LLM PII pass
is deferred to a post-write audit.

  echo "my key is sk-ant-api03-xxxx" | python3 graphiti-scrubber.py
  -> "my key is [REDACTED:anthropic_key]"   (and a report on stderr)

Importable: `scrub(text) -> (scrubbed_text, [findings])`.
"""
from __future__ import annotations

import re
import sys
from typing import List, Tuple

# (label, compiled pattern). Order matters: more specific shapes first.
_PATTERNS = [
    ("private_key_block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY-----", re.DOTALL)),
    ("anthropic_key", re.compile(r"sk-ant-[A-Za-z0-9_\-]{20,}")),
    ("openai_key", re.compile(r"sk-(?:proj-)?[A-Za-z0-9]{20,}")),
    ("github_token", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("aws_access_key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("slack_token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_\-]{35}\b")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b")),
    ("bearer_token", re.compile(r"\b[Bb]earer\s+[A-Za-z0-9_\-\.=]{20,}")),
    # KEY=secret / "key": "secret" style assignments for secret-named keys
    ("secret_assignment", re.compile(
        r"(?i)\b([A-Z0-9_]*(?:SECRET|PASSWORD|PASSWD|API[_-]?KEY|TOKEN|PRIVATE[_-]?KEY|ACCESS[_-]?KEY)[A-Z0-9_]*)\b\s*[:=]\s*[\"']?([^\s\"',]{6,})[\"']?")),
    ("email", re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")),
]


def scrub(text: str) -> Tuple[str, List[str]]:
    """Return (scrubbed_text, findings). findings is a list of labels redacted."""
    findings: List[str] = []
    out = text or ""
    for label, pat in _PATTERNS:
        if label == "secret_assignment":
            def _repl(m, _l=label):
                findings.append(_l)
                return f"{m.group(1)}=[REDACTED:{_l}]"
            out = pat.sub(_repl, out)
        else:
            def _repl(m, _l=label):
                findings.append(_l)
                return f"[REDACTED:{_l}]"
            out = pat.sub(_repl, out)
    return out, findings


def main() -> int:
    text = sys.stdin.read()
    scrubbed, findings = scrub(text)
    sys.stdout.write(scrubbed)
    if findings:
        from collections import Counter
        summary = ", ".join(f"{k}×{v}" for k, v in Counter(findings).items())
        print(f"graphiti-scrubber: redacted {len(findings)} secret(s): {summary}", file=sys.stderr)
    return 2 if findings else 0  # exit 2 signals "secrets were present" (caller may log/alert)


if __name__ == "__main__":
    sys.exit(main())
