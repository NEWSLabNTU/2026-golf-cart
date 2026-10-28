"""Unit tests for scripts/perception_stubs.py.

The node is two timers publishing constants; what can be wrong without a ROS
graph is the grid arithmetic and that the stand-in covers the maps we drive.
"""

import importlib.util
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'perception_stubs.py'
_spec = importlib.util.spec_from_file_location('perception_stubs', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)


def test_grid_is_all_free_and_sized():
    f = ps.grid_fields(0.5, 240, 200, -70.0, -45.0)
    assert len(f['data']) == 240 * 200
    assert set(f['data']) == {0}


def test_default_grid_covers_the_mingda_map():
    # Ming-Da cloud: x -62.4..42.2, y -37.7..47.5 (data/mingda-basement).
    f = ps.grid_fields(0.5, 240, 200, -70.0, -45.0)
    x1 = f['origin_x'] + f['width'] * f['resolution']
    y1 = f['origin_y'] + f['height'] * f['resolution']
    assert f['origin_x'] <= -62.4 and x1 >= 42.2
    assert f['origin_y'] <= -37.7 and y1 >= 47.5


@pytest.mark.parametrize('bad', [(0.0, 10, 10), (0.5, 0, 10), (0.5, 10, -1)])
def test_rejects_a_degenerate_grid(bad):
    with pytest.raises(ValueError):
        ps.grid_fields(bad[0], bad[1], bad[2], 0.0, 0.0)
