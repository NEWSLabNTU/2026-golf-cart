"""Tests for downsample_pcd.py.

    python3 -m pytest scripts/map/test_downsample_pcd.py
"""

import importlib.util
from pathlib import Path

import numpy as np
import pytest

_SCRIPT = Path(__file__).resolve().with_name('downsample_pcd.py')
_spec = importlib.util.spec_from_file_location('downsample_pcd', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
ds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ds)


def _cloud():
    """Two 0.1 m-spaced patches, one per 0.3 m voxel, intensity 10 and 50."""
    a = np.array([[x, y, 0.05, 10.0] for x in (0.05, 0.15, 0.25) for y in (0.05, 0.15, 0.25)])
    b = a + [0.9, 0.0, 0.0, 40.0]   # x 0.95-1.15, inside the 0.9-1.2 voxel
    return np.vstack([a, b]).astype(np.float32)


def test_round_trip_keeps_fields_and_values(tmp_path):
    pts = _cloud()
    path = tmp_path / 'in.pcd'
    ds.write_pcd(path, pts, ['x', 'y', 'z', 'intensity'])
    back, fields = ds.read_pcd(path)
    assert fields == ['x', 'y', 'z', 'intensity']
    assert np.array_equal(back, pts)


def test_one_centroid_per_voxel_with_mean_intensity():
    out = ds.voxel_downsample(_cloud(), 0.3)
    assert len(out) == 2
    out = out[np.argsort(out[:, 0])]
    assert out[0] == pytest.approx([0.15, 0.15, 0.05, 10.0], abs=1e-5)
    assert out[1] == pytest.approx([1.05, 0.15, 0.05, 50.0], abs=1e-5)


def test_cli_writes_a_loadable_smaller_cloud(tmp_path):
    src, dst = tmp_path / 'in.pcd', tmp_path / 'out.pcd'
    ds.write_pcd(src, _cloud(), ['x', 'y', 'z', 'intensity'])
    assert ds.main([str(src), str(dst), '--leaf', '0.3']) == 0
    pts, fields = ds.read_pcd(dst)
    assert len(pts) == 2 and fields == ['x', 'y', 'z', 'intensity']
    head = dst.read_bytes().split(b'DATA')[0].decode()
    assert 'POINTS 2' in head and 'WIDTH 2' in head


def test_refuses_to_overwrite_its_input(tmp_path):
    src = tmp_path / 'in.pcd'
    ds.write_pcd(src, _cloud(), ['x', 'y', 'z', 'intensity'])
    with pytest.raises(SystemExit):
        ds.main([str(src), str(src), '--leaf', '0.3'])


def test_rejects_ascii_and_non_float_clouds(tmp_path):
    path = tmp_path / 'ascii.pcd'
    path.write_text('VERSION 0.7\nFIELDS x y z\nSIZE 4 4 4\nTYPE F F F\nCOUNT 1 1 1\n'
                    'WIDTH 1\nHEIGHT 1\nPOINTS 1\nDATA ascii\n0 0 0\n')
    with pytest.raises(ValueError):
        ds.read_pcd(path)
