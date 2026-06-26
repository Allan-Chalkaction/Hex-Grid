"""Wave 4 (ADR-077 D1) — unit test for the pure `_pick_lane_and_model` routing helper.

The helper lives in the bind-mounted operator file
`~/graphiti/mcp_server/custom/routing_gemini_client.py`, which top-level-imports
`graphiti_core` (NOT installed on the host py3.9.6 — it lives only in the mcp container, py3.11).
So before importing the module we stub the three `graphiti_core` submodules it touches in
`sys.modules`, providing a fake `ModelSize` enum that mirrors the real one (small / medium / large).
The helper is pure — no Gemini I/O, no docker — so the seven discrimination cases are asserted
directly against the fake `ModelSize`.

Run (stdlib, no pytest — pytest is not on any host python; the repo convention is stdlib .sh
wrappers, mirrored here):
    python3 core/scripts/tests/test_routing_gemini_client_ab.py
or via the canonical wrapper:
    bash core/scripts/tests/test-graphiti-routing-ab.sh
The two `test_*` functions are also auto-collectable by pytest IF it is ever installed — but this
file imports NO pytest, so it runs everywhere.
"""

import enum
import sys
import types


# --- stub graphiti_core (not on host; container-only) before importing the module ---------------
class _FakeModelSize(enum.Enum):
    small = 'small'
    medium = 'medium'
    large = 'large'


def _install_graphiti_core_stub() -> None:
    cfg = types.ModuleType('graphiti_core.llm_client.config')
    cfg.ModelSize = _FakeModelSize

    gem = types.ModuleType('graphiti_core.llm_client.gemini_client')

    class _FakeGeminiClient:  # minimal base — the helper under test never touches it
        def __init__(self, *a, **k):
            pass

    gem.GeminiClient = _FakeGeminiClient

    models = types.ModuleType('graphiti_core.prompts.models')

    class _FakeMessage:
        pass

    models.Message = _FakeMessage

    sys.modules.setdefault('graphiti_core', types.ModuleType('graphiti_core'))
    sys.modules.setdefault('graphiti_core.llm_client', types.ModuleType('graphiti_core.llm_client'))
    sys.modules['graphiti_core.llm_client.config'] = cfg
    sys.modules['graphiti_core.llm_client.gemini_client'] = gem
    sys.modules.setdefault('graphiti_core.prompts', types.ModuleType('graphiti_core.prompts'))
    sys.modules['graphiti_core.prompts.models'] = models


_install_graphiti_core_stub()
sys.path.insert(0, os.path.expanduser('~/graphiti/mcp_server/custom'))

import routing_gemini_client as rgc  # noqa: E402 — must follow the stub install

ModelSize = rgc.ModelSize  # the fake we installed (rgc imported it from the stubbed config module)


# (prompt_name, group_id, expected_lane, expected_model_size) — the seven binding cases.
SEVEN_CASES = [
    # 1. Flash-Lite sub-route: resolve_edge on the flash-lite A/B partition.
    ('dedupe_edges.resolve_edge', 'ab-wave4-flash-lite-topic1', 'resolution', ModelSize.small),
    # 2. Control arm: resolve_edge on the flash partition (also starts with `ab-wave4-flash-`, must NOT mis-route).
    ('dedupe_edges.resolve_edge', 'ab-wave4-flash-topic1', 'resolution', ModelSize.medium),
    # 3. Live rail: resolve_edge on claude-infra-v2 — unchanged routing.
    ('dedupe_edges.resolve_edge', 'claude-infra-v2', 'resolution', ModelSize.medium),
    # 4. Propagation gap: resolve_edge with group_id=None.
    ('dedupe_edges.resolve_edge', None, 'resolution', ModelSize.medium),
    # 5. Empty-string group_id (≠ None) — still control.
    ('dedupe_edges.resolve_edge', '', 'resolution', ModelSize.medium),
    # 6. Sibling resolution prompt on the flash-lite partition — stays Flash (exact-equality guard).
    ('dedupe_nodes.nodes', 'ab-wave4-flash-lite-topic1', 'resolution', ModelSize.medium),
    # 7. Extraction lane (unnamed call).
    ('extract_nodes', None, 'extraction', ModelSize.small),
]


def test_pick_lane_and_model():
    """All seven discrimination cases."""
    for prompt_name, group_id, exp_lane, exp_model in SEVEN_CASES:
        lane, model_size = rgc._pick_lane_and_model(prompt_name, group_id)
        assert lane == exp_lane, f'{prompt_name!r}/{group_id!r}: lane {lane!r} != {exp_lane!r}'
        assert model_size == exp_model, f'{prompt_name!r}/{group_id!r}: model {model_size!r} != {exp_model!r}'


def test_flash_lite_only_for_exact_resolve_edge():
    """The Flash-Lite sub-route requires EXACT prompt_name == 'dedupe_edges.resolve_edge'."""
    assert rgc._pick_lane_and_model('dedupe_edges.resolve_edge', 'ab-wave4-flash-lite-x') == (
        'resolution', ModelSize.small,
    )
    # a near-miss prompt name on the same partition stays on Flash (startswith would have mis-routed)
    assert rgc._pick_lane_and_model('dedupe_edges.resolve_edge_v2', 'ab-wave4-flash-lite-x') == (
        'resolution', ModelSize.medium,
    )


if __name__ == '__main__':
    test_pick_lane_and_model()
    test_flash_lite_only_for_exact_resolve_edge()
    print(f'ok: {len(SEVEN_CASES)} discrimination cases + exact-match guard PASS')
