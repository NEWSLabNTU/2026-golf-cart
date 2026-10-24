"""Tests for obstacle_grid.py (Phase 8, M7).

    python3 -m pytest scripts/map/test_obstacle_grid.py
"""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

_SCRIPT = Path(__file__).resolve().with_name('obstacle_grid.py')
_spec = importlib.util.spec_from_file_location('obstacle_grid', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
og = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(og)

EDITS = {'cell': 0.1, 'min_points': 3, 'band': [0.25, 2.0], 'floor': 0.0,
         'origin': [0.0, 0.0], 'size': [10.0, 10.0]}


def _column(x, y, z0, z1, n):
    """n points spread over z0..z1 at (x, y)."""
    return np.c_[np.full(n, x), np.full(n, y), np.linspace(z0, z1, n)]


def _cell(grid, x, y):
    return grid['occ'][int((x - grid['x0']) / grid['cell']), int((y - grid['y0']) / grid['cell'])]


def _quiet(_):
    pass


def test_band_and_min_points():
    xyz = np.vstack([
        _column(1.05, 1.05, 0.5, 1.5, 3),     # obstacle
        _column(2.05, 2.05, 0.5, 1.5, 2),     # too few points
        _column(3.05, 3.05, 0.0, 0.2, 10),    # floor, below the band
        _column(4.05, 4.05, 2.2, 3.0, 10),    # ceiling, above it
    ])
    g = og.build_grid(xyz, EDITS, log=_quiet)
    assert _cell(g, 1.05, 1.05)
    assert not _cell(g, 2.05, 2.05)
    assert not _cell(g, 3.05, 3.05)
    assert not _cell(g, 4.05, 4.05)
    assert g['occ'].sum() == 1


def test_remove_box_drops_band_points_and_respects_z():
    xyz = np.vstack([_column(1.05, 1.05, 0.5, 1.5, 5), _column(2.05, 2.05, 1.8, 1.9, 5)])
    edits = dict(EDITS, remove=[{'why': 'a ghost', 'x': [0.5, 3.0], 'y': [0.5, 3.0], 'z': [None, 1.7]}])
    g = og.build_grid(xyz, edits, log=_quiet)
    assert not _cell(g, 1.05, 1.05), 'the box did not remove what was under its z top'
    assert _cell(g, 2.05, 2.05), 'the box removed points above its z top'


def test_add_cloud_and_line():
    hanging = _column(5.05, 5.05, 2.15, 2.3, 4)   # above the band, like the Ming-Da board
    edits = dict(EDITS, add=[
        {'why': 'board', 'cloud': {'x': [5.0, 5.1], 'y': [5.0, 5.1], 'z': [2.1, 2.4]}},
        {'why': 'curb', 'line': [[1.0, 8.0], [3.0, 8.0]]},
    ])
    g = og.build_grid(hanging, EDITS, log=_quiet)
    assert g['occ'].sum() == 0
    g = og.build_grid(hanging, edits, log=_quiet)
    assert _cell(g, 5.05, 5.05)
    row = g['occ'][:, int(8.0 / 0.1)]
    assert row[10:30].all() and not row[:10].any() and not row[30:].any(), \
        'a line marks x 1.0 up to, not including, 3.0'


def test_cells_outside_the_grid_are_dropped_not_wrapped():
    # Truncating toward zero put x in (-0.1, 0) into cell 0; flooring does not.
    xyz = np.vstack([_column(-0.05, 1.05, 0.5, 1.5, 5), _column(10.05, 1.05, 0.5, 1.5, 5)])
    g = og.build_grid(xyz, EDITS, log=_quiet)
    assert g['occ'].sum() == 0


def test_warns_on_a_thin_cloud():
    rng = np.random.default_rng(1)
    xyz = np.c_[rng.uniform(0, 10, 500), rng.uniform(0, 10, 500), rng.uniform(0.3, 1.9, 500)]
    msgs = []
    og.build_grid(xyz, EDITS, log=msgs.append)
    assert any('WARNING' in m for m in msgs)


def test_anchor_transform(tmp_path):
    a, b = tmp_path / 'a.yaml', tmp_path / 'b.yaml'
    a.write_text('transform_map_cloud: [[1,0,0,1],[0,1,0,0],[0,0,1,0],[0,0,0,1]]\n')
    b.write_text('transform_map_cloud: [[0,-1,0,0],[1,0,0,2],[0,0,1,0],[0,0,0,1]]\n')
    d = og.anchor_transform(a, b)
    # A point at (1, 0) in a's map frame is the cloud origin; b puts it at (0, 2).
    assert d @ np.array([1.0, 0.0, 0.0, 1.0]) == pytest.approx([0.0, 2.0, 0.0, 1.0])


def test_main_writes_the_grid(tmp_path):
    import yaml
    pts = np.c_[_column(1.05, 1.05, 0.5, 1.5, 3), np.zeros(3)]
    pcd = tmp_path / 'm.pcd'
    pcd.write_bytes((
        '# .PCD v0.7\nVERSION 0.7\nFIELDS x y z intensity\nSIZE 4 4 4 4\nTYPE F F F F\n'
        'COUNT 1 1 1 1\nWIDTH 3\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS 3\nDATA binary\n'
    ).encode() + pts.astype('<f4').tobytes())
    edits = tmp_path / 'edits.yaml'
    edits.write_text(yaml.safe_dump(EDITS))
    out = tmp_path / 'g.npz'
    assert og.main([str(pcd), str(edits), '-o', str(out)]) == 0
    g = og.load_grid(out)
    assert g['occ'].sum() == 1
    assert og.occupied_centres(g) == pytest.approx(np.array([[1.05, 1.05]]))


def test_the_ming_da_edits_file_parses():
    import yaml
    p = Path(__file__).resolve().parents[2] / 'data/mingda-basement/obstacle_edits.yaml'
    e = yaml.safe_load(p.read_text())
    assert all(item.get('why') for item in e['remove'] + e['add'])
    og.build_grid(np.zeros((0, 3)), e, log=_quiet)


if __name__ == '__main__':
    sys.exit(pytest.main([__file__]))
