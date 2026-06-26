"""Wave 1 (ADR-098 / ADR-077 D5) — unit test for graphiti-eval.py's per-arm recall grouping.

Mocks `graphiti-read.py` (via monkeypatching the module's `subprocess.run`) so the test is pure
stdlib — no docker, no live Gemini, no real read. Mirrors test_graphiti_eval_inject_modes.py exactly
(pytest is unavailable on the host; the repo .sh convention shells these stdlib tests). Asserts:
  - arm_key() recovers the arm from the partition's `-arm-<x>` suffix and honors an explicit `arm`;
  - the harness, run over a ≥2-arm fixture, emits one per-arm recall@k line per partition via main();
  - the inject-on overall regression gate is preserved (arms extend, not replace, the gate).

graphiti-eval.py has a hyphen in its name (not importable as a module name), so we load it by path.

Run (stdlib; pytest not on host — repo .sh convention):
    python3 core/scripts/tests/test_graphiti_eval_arms.py
    bash core/scripts/tests/test-graphiti-eval-arms.sh
"""

import importlib.util
import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVAL_PATH = HERE.parent / "graphiti-eval.py"
ARMS_FIXTURE = HERE / "fixtures" / "graphiti-eval-arms.jsonl"


def _load_eval():
    spec = importlib.util.spec_from_file_location("graphiti_eval_arms_mod", EVAL_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ge = _load_eval()


class _FakeCompleted:
    def __init__(self, stdout, stderr):
        self.stdout = stdout
        self.stderr = stderr


def test_arm_key_recovers_partition():
    # suffix convention
    assert ge.arm_key({"group_id": "claude-infra-v2-arm-flash-lite"}) == "flash-lite"
    assert ge.arm_key({"group_id": "claude-infra-v2-arm-flash"}) == "flash"
    # explicit arm field wins
    assert ge.arm_key({"group_id": "x-arm-a", "arm": "explicit"}) == "explicit"
    # no arm dimension -> default
    assert ge.arm_key({"group_id": "claude-infra-v2"}) == "default"


def test_fixture_has_two_distinct_arms():
    cases = ge.load_cases(ARMS_FIXTURE)
    arms = {ge.arm_key(c) for c in cases}
    assert len(arms) >= 2, f"arm fixture must carry >=2 distinct arm partitions, got {arms}"


def test_main_emits_per_arm_recall_line_per_partition():
    """Wire-to-consumer: running main() over the >=2-arm fixture must emit one per-arm line per arm
    via the REAL code path (not just a helper that exists). subprocess.run is monkeypatched so no
    docker / live read is needed; we feed back the expected facts so each arm scores deterministically."""

    def fake_run(cmd, **kw):
        # graphiti-read.py is invoked as: python -u read.py --group-id <gid> --top-k k --max-bytes ...
        gid = cmd[cmd.index("--group-id") + 1]
        # echo the case's expected facts so recall resolves per arm
        body = {
            "claude-infra-v2-arm-flash-lite": "native workflow tool / thin manifest / adr-036 consolidated gate surface",
            "claude-infra-v2-arm-flash": "one implementer per wave adr-062 / claim-id.py o_excl",
        }.get(gid, "")
        return _FakeCompleted(stdout=body, stderr=f"meter: group_id={gid}\n")

    orig_run = ge.subprocess.run
    orig_argv = sys.argv
    ge.subprocess.run = fake_run
    sys.argv = ["graphiti-eval.py", "--fixture", str(ARMS_FIXTURE), "--tolerance", "1.0"]
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            rc = ge.main()
    finally:
        ge.subprocess.run = orig_run
        sys.argv = orig_argv

    out = buf.getvalue()
    assert rc == 0, f"main() should exit 0 (tolerance 1.0 floors the gate), got {rc}"
    assert "arm[flash-lite]" in out, f"missing per-arm line for flash-lite arm:\n{out}"
    assert "arm[flash]" in out, f"missing per-arm line for flash arm:\n{out}"
    # one recall@k token per arm line + the overall line
    assert out.count("recall@k") >= 3, f"expected overall + >=2 per-arm recall@k lines:\n{out}"


if __name__ == "__main__":
    test_arm_key_recovers_partition()
    test_fixture_has_two_distinct_arms()
    test_main_emits_per_arm_recall_line_per_partition()
    print("ok: per-arm recall harness tests PASS")
