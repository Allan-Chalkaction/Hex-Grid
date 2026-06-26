"""Wave 4 (ADR-077 D4) — unit test for graphiti-eval.py's --inject-on / --inject-off modes.

Mocks `graphiti-read.py` (via monkeypatching the module's `subprocess.run`) so the test is pure
stdlib — no docker, no live Gemini, no real read. Asserts:
  - inject-on invokes graphiti-read.py exactly once, passes --meter, and CAPTURES its stderr meter line;
  - inject-off does NOT invoke graphiti-read.py at all;
  - turns_to_fact is 1 on a successful inject-on and the rediscovery cap on inject-off.

graphiti-eval.py has a hyphen in its name (not importable as a module name), so we load it by path.

Run (stdlib; pytest not on host — repo .sh convention):
    python3 core/scripts/tests/test_graphiti_eval_inject_modes.py
    bash core/scripts/tests/test-graphiti-eval-inject-modes.sh
"""

import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVAL_PATH = HERE.parent / "graphiti-eval.py"


def _load_eval():
    spec = importlib.util.spec_from_file_location("graphiti_eval_mod", EVAL_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ge = _load_eval()


class _FakeCompleted:
    def __init__(self, stdout, stderr):
        self.stdout = stdout
        self.stderr = stderr


def test_inject_on_invokes_read_and_captures_stderr():
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return _FakeCompleted(
            stdout="embedding dim 1024 everywhere\n",
            stderr="graphiti-read meter: injected=1 facts=3 latency_ms=12 group_id=claude-infra-v2\n",
        )

    orig = ge.subprocess.run
    ge.subprocess.run = fake_run
    try:
        case = {"group_id": "claude-infra-v2", "top_k": 5, "expected_facts": ["embedding dim 1024"]}
        r = ge.score_case(case, inject_on=True)
    finally:
        ge.subprocess.run = orig

    assert len(calls) == 1, "inject-on must invoke graphiti-read.py exactly once"
    assert "--meter" in calls[0], "inject-on must pass --meter to graphiti-read.py"
    assert str(ge.READ_SCRIPT) in calls[0], "inject-on must shell out to READ_SCRIPT"
    assert "meter:" in r["meter"], f"inject-on must CAPTURE the stderr meter line, got {r['meter']!r}"
    assert r["recall"] == 1.0, f"expected fact should surface, got recall {r['recall']}"
    assert r["turns_to_fact"] == 1, f"inject-on turns_to_fact should be 1, got {r['turns_to_fact']}"


def test_inject_off_skips_read():
    calls = []

    def fake_run(cmd, **kw):
        calls.append(cmd)
        return _FakeCompleted(stdout="", stderr="")

    orig = ge.subprocess.run
    ge.subprocess.run = fake_run
    try:
        case = {"group_id": "claude-infra-v2", "top_k": 5, "expected_facts": ["embedding dim 1024"]}
        r = ge.score_case(case, inject_on=False)
    finally:
        ge.subprocess.run = orig

    assert len(calls) == 0, "inject-off must NOT invoke graphiti-read.py"
    assert r["recall"] == 0.0, "inject-off has no injected facts → recall 0"
    assert r["meter"] == "", "inject-off captures no meter line"
    assert r["turns_to_fact"] == ge.REDISCOVERY_CAP, (
        f"inject-off turns_to_fact should be the rediscovery cap {ge.REDISCOVERY_CAP}, "
        f"got {r['turns_to_fact']}"
    )


if __name__ == "__main__":
    test_inject_on_invokes_read_and_captures_stderr()
    test_inject_off_skips_read()
    print("ok: inject-on/inject-off harness tests PASS")
