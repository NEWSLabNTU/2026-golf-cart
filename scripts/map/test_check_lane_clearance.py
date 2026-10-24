"""Tests for check_lane_clearance.py (Phase 8, M7).

    python3 -m pytest scripts/map/test_check_lane_clearance.py

Lanes are built with centerline_to_lanelet.build_osm, so the check reads the
builder's real output, reversed bounds included.
"""

import importlib.util
import math
import sys
from pathlib import Path

import numpy as np
import pytest

_SCRIPT = Path(__file__).resolve().with_name('check_lane_clearance.py')
_spec = importlib.util.spec_from_file_location('check_lane_clearance', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
clc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(clc)
c2l = clc.c2l


def straight_osm(width=2.0):
    """A lane along +x from 0 to 10, edges at y +-width/2."""
    return c2l.build_osm([(0.0, 0.0), (10.0, 0.0)], width=width, ele=0.0, segment_length=5.0,
                         speed_limit_kmh=4.0, base_osm=None)


def grid_with(*cells_xy, cell=0.1):
    occ = np.zeros((150, 100), bool)   # x -2.5 .. 12.5, y -5 .. 5
    g = dict(occ=occ, x0=-2.5, y0=-5.0, cell=cell)
    for x, y in cells_xy:
        occ[int(math.floor((x - g['x0']) / cell)), int(math.floor((y - g['y0']) / cell))] = True
    return g


def test_polygons_cover_the_lane():
    polys = clc.lanelet_polygons(straight_osm())
    assert len(polys) == 2
    pts = np.array([[1.0, 0.0], [9.0, 0.9], [5.0, -0.9], [5.0, 1.1], [11.0, 0.0]])
    hit = np.zeros(len(pts), bool)
    for p in polys:
        hit |= clc.inside(p, pts)
    assert hit.tolist() == [True, True, True, False, False]


def test_a_cell_inside_is_found():
    r = clc.clearance(grid_with((5.05, 0.25), (5.05, 3.05)), clc.lanelet_polygons(straight_osm()))
    assert r['inside'].sum() == 1
    assert r['cells'][r['inside']][0] == pytest.approx([5.05, 0.25])


def test_distance_is_to_the_square_not_the_centre():
    # Edge at y 1.0; the cell spans y 1.3 .. 1.4, so its face is 0.30 m off.
    r = clc.clearance(grid_with((5.05, 1.35)), clc.lanelet_polygons(straight_osm()))
    assert r['dist'][0] == pytest.approx(0.30, abs=1e-9)
    assert r['dist_centre'][0] == pytest.approx(0.35, abs=1e-9)
    # Past the lane's end, diagonally: corner to corner.
    r = clc.clearance(grid_with((10.35, 1.35)), clc.lanelet_polygons(straight_osm()))
    assert r['dist'][0] == pytest.approx(math.hypot(0.3, 0.3), abs=1e-9)


def test_a_cell_the_edge_crosses_is_at_zero():
    # Edge at y 1.03; the cell spans y 1.0 .. 1.1, its centre outside the lane.
    r = clc.clearance(grid_with((5.05, 1.05)), clc.lanelet_polygons(straight_osm(2.06)))
    assert r['inside'].sum() == 0
    assert r['dist'][0] == 0.0


def test_square_segment_distance_by_brute_force():
    rng = np.random.default_rng(3)
    cells = rng.uniform(-2, 2, (40, 2))
    a, b = rng.uniform(-2, 2, (5, 2)), rng.uniform(-2, 2, (5, 2))
    got = clc.square_segment_distance(cells, 0.05, a, b)
    # Brute force: dense samples of each square against dense samples of each segment.
    s = np.linspace(-0.05, 0.05, 21)
    sq = np.stack(np.meshgrid(s, s), -1).reshape(-1, 2)
    t = np.linspace(0, 1, 1001)[:, None]
    seg = np.vstack([a[k] + t * (b[k] - a[k]) for k in range(5)])
    for c, g in zip(cells, got):
        d = np.linalg.norm((c + sq)[:, None, :] - seg[None, :, :], axis=2).min()
        assert g <= d + 1e-9 and d - g < 0.01


def _files(tmp_path, grid, osm, route=None):
    g, o = tmp_path / 'g.npz', tmp_path / 'm.osm'
    np.savez(g, **grid)
    o.write_text(osm)
    args = [str(g), str(o)]
    if route:
        r = tmp_path / 'r.yaml'
        r.write_text(route)
        args += ['--route', str(r)]
    return args


def test_exit_status(tmp_path, capsys):
    osm = straight_osm()
    assert clc.main(_files(tmp_path, grid_with((5.05, 1.35)), osm)) == 0
    assert clc.main(_files(tmp_path, grid_with((5.05, 0.05)), osm)) == 1
    assert clc.main(_files(tmp_path, grid_with((5.05, 1.35)), osm) + ['--min-clearance', '0.4']) == 1
    out = capsys.readouterr().out
    assert 'cells inside the lane: 1' in out


def test_route_summary_reports_narrow_stretch_speed_and_radius(tmp_path, capsys):
    route = ''.join(f'- {{x: {x:.1f}, y: 0.0, width: {1.6 if 3 <= x <= 5 else 2.5}'
                    + (', speed_limit: 2' if x == 2 else ', speed_limit: 4' if x == 7 else '')
                    + '}\n' for x in range(11))
    osm = c2l.build_osm([(float(x), 0.0) for x in range(11)],
                        width=[1.6 if 3 <= x <= 5 else 2.5 for x in range(11)], ele=0.0,
                        segment_length=5.0, speed_limit_kmh=4.0, base_osm=None)
    assert clc.main(_files(tmp_path, grid_with(), osm, route)) in (0, 1)
    out = capsys.readouterr().out
    assert 'narrower than 2 m: (3.00, 0.00) to (5.00, 0.00), 2.0 m' in out
    assert 'speed 2 km/h from (2.00, 0.00)' in out
    assert 'speed 4 km/h from (7.00, 0.00)' in out
    wb, ms = c2l.vehicle_geometry()
    assert f'allows {wb / math.tan(ms):.2f} m' in out


if __name__ == '__main__':
    sys.exit(pytest.main([__file__]))
