"""Unit tests for scripts/planning_speed_limit.py (Phase 8, S4).

The node's only logic is deciding what it will publish; the ROS side is one
latched publisher. So the decision is a pure function and is what is tested.
"""

import importlib.util
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'planning_speed_limit.py'
_spec = importlib.util.spec_from_file_location('planning_speed_limit', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
psl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(psl)


def test_accepts_a_crawl_speed():
    assert psl.validate_limit(1.0) == 1.0


@pytest.mark.parametrize('bad', [0.0, -1.0, float('nan'), float('inf')])
def test_rejects_non_positive_or_non_finite(bad):
    with pytest.raises(ValueError):
        psl.validate_limit(bad)


def test_rejects_above_the_vcu_ceiling():
    # ROOTS caps target speed at 25 km/h; a planning default above it is a typo,
    # not a policy, and would silently mean "no cap".
    with pytest.raises(ValueError):
        psl.validate_limit(psl.ROOTS_MAX_SPEED_MPS + 0.1)


def test_message_fields():
    fields = psl.limit_fields(1.0)
    assert fields['max_velocity'] == 1.0
    assert fields['use_constraints'] is False
    assert fields['sender'] == psl.SENDER
