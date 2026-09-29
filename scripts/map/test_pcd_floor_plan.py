"""Tests for pcd_floor_plan.py (Phase 8, M1).

    python3 -m pytest scripts/map/test_pcd_floor_plan.py
"""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

_SCRIPT = Path(__file__).resolve().with_name('pcd_floor_plan.py')
_spec = importlib.util.spec_from_file_location('pcd_floor_plan', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
fp = importlib.util.module_from_spec(_spec)
sys.modules['pcd_floor_plan'] = fp  # dataclasses look their module up here
_spec.loader.exec_module(fp)


def _write_pcd(path, xyzi):
    header = (
        '# .PCD v0.7\nVERSION 0.7\nFIELDS x y z intensity\nSIZE 4 4 4 4\n'
        'TYPE F F F F\nCOUNT 1 1 1 1\n'
        f'WIDTH {len(xyzi)}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\n'
        f'POINTS {len(xyzi)}\nDATA binary\n')
    path.write_bytes(header.encode() + xyzi.astype('<f4').tobytes())


def _scene():
    """A 20 x 10 m floor with a ramp rising 0.3 m, and one wall at x = 15."""
    rng = np.random.default_rng(0)
    x = rng.uniform(0, 20, 40000)
    y = rng.uniform(-5, 5, 40000)
    floor_z = np.clip((x - 10) * 0.03, 0, 0.3)          # ramp, like the basement
    floor = np.c_[x, y, floor_z, np.zeros_like(x)]
    wy = rng.uniform(-5, 5, 4000)
    wz = rng.uniform(0.0, 2.5, 4000) + 0.15
    wall = np.c_[np.full_like(wy, 15.0), wy, wz, np.zeros_like(wy)]
    return np.vstack([floor, wall])


def test_reads_binary_pcd(tmp_path):
    pts = _scene()
    pcd = tmp_path / 'm.pcd'
    _write_pcd(pcd, pts)
    xyz = fp.read_pcd_xyz(pcd)
    assert xyz.shape == (len(pts), 3)
    assert np.allclose(xyz[:3], pts[:3, :3], atol=1e-5)


def test_rejects_ascii_pcd(tmp_path):
    pcd = tmp_path / 'a.pcd'
    pcd.write_text('VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\n'
                   'COUNT 1 1 1\nWIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0 0 0\n')
    with pytest.raises(ValueError):
        fp.read_pcd_xyz(pcd)


def test_wall_is_an_obstacle_and_the_ramp_is_not():
    xyz = _scene()[:, :3]
    grid = fp.obstacle_grid(xyz, resolution=0.2)
    col_wall = int((15.0 - grid.x0) / grid.resolution)
    col_ramp = int((13.0 - grid.x0) / grid.resolution)
    row_mid = int((0.0 - grid.y0) / grid.resolution)
    assert grid.obstacle[row_mid, col_wall], 'the wall was not marked'
    assert not grid.obstacle[row_mid, col_ramp], 'the ramp floor was marked as an obstacle'
    assert grid.floor[row_mid, col_ramp], 'the ramp floor was not seen as floor'
