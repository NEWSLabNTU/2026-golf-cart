"""Tests for fit_lane_corridor.py (Phase 8, M7).

    python3 -m pytest scripts/map/test_fit_lane_corridor.py

The scene is a ring aisle: a round block of radius 5 inside a round wall of
radius 10, cells 0.1 m. The lane goes counter-clockwise round it.

refine needs scipy's lsq_linear. On the workstation a user-site numpy 2
shadows apt's and scipy then fails to import (pcd_floor_plan.py notes the same
for matplotlib), so those tests run the tool in a child under python3 -s when
the import fails here; they skip only when neither works.
"""

import importlib.util
import math
import os
import subprocess
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest

_HERE = Path(__file__).resolve().parent
_SCRIPT = _HERE / 'fit_lane_corridor.py'
_spec = importlib.util.spec_from_file_location('fit_lane_corridor', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
flc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(flc)
c2l, og = flc.c2l, sys.modules['obstacle_grid']

_CHECK = importlib.util.spec_from_file_location('check_lane_clearance', _HERE / 'check_lane_clearance.py')
clc = importlib.util.module_from_spec(_CHECK)
_CHECK.loader.exec_module(clc)

BODY = (0.821, 2.467, 0.6075)


def ring_grid(r_in=5.0, r_out=10.0, extra=None):
    """The ring aisle; `extra(x, y)` marks more cells."""
    c = 0.1
    x0 = y0 = -12.0
    n = int(24 / c)
    cx = x0 + (np.arange(n) + 0.5) * c
    X, Y = np.meshgrid(cx, cx, indexing='ij')
    r = np.hypot(X, Y)
    occ = (r < r_in) | ((r > r_out) & (r < r_out + 0.5))
    if extra is not None:
        occ |= extra(X, Y)
    return dict(occ=occ, x0=x0, y0=y0, cell=c)


def circle(radius, step=0.5):
    k = int(round(2 * math.pi * radius / step))
    a = np.linspace(0, 2 * math.pi, k + 1)
    xy = np.c_[radius * np.cos(a), radius * np.sin(a)]
    xy[-1] = xy[0]
    return xy


def lane_polys(xy, w):
    osm = c2l.build_osm([tuple(p) for p in xy], width=list(w), ele=0.0, segment_length=5.0,
                        speed_limit_kmh=4.0, base_osm=None)
    return clc.lanelet_polygons(osm)


def _quiet(_):
    pass


# ---------------------------------------------------------------- centre


def test_centre_moves_an_offset_line_to_the_middle():
    xy, w = flc.fit_centre(ring_grid(), circle(6.0), log=_quiet)
    r = np.hypot(xy[:, 0], xy[:, 1])
    assert np.abs(r - 7.5).max() < 0.15, 'the line was not centred in the aisle'
    assert np.all(w == 2.5)
    assert np.linalg.norm(xy[0] - xy[-1]) < 1e-9, 'the output is not closed'


def test_centre_narrows_at_a_pinch_and_keeps_both_edges_off():
    # Something in the aisle from the outer wall to r 7.5, on the +y side.
    def pinch(X, Y):
        return (np.hypot(X, Y) > 7.5) & (np.abs(X) < 1.0) & (Y > 0)
    grid = ring_grid(extra=pinch)
    xy, w = flc.fit_centre(grid, circle(6.0), log=_quiet)
    at = np.argmax(xy[:, 1])
    assert w[at] < 2.5 and w.min() >= 1.5
    res = clc.clearance(grid, lane_polys(xy, w))
    assert res['inside'].sum() == 0
    # centre measures margins along its rays only; refine is what holds them.
    assert res['dist'].min() > 0.0


# ---------------------------------------------------------------- refine


def _python_with_scipy():
    try:
        with warnings.catch_warnings():   # scipy warns about the numpy it then fails on
            warnings.simplefilter('ignore')
            from scipy.optimize import lsq_linear  # noqa: F401
        return [sys.executable] + (['-s'] if sys.flags.no_user_site else []), dict(os.environ)
    except ImportError:
        pass
    env = dict(os.environ, PYTHONNOUSERSITE='1')
    ok = subprocess.run([sys.executable, '-s', '-c', 'from scipy.optimize import lsq_linear'],
                        env=env, capture_output=True).returncode == 0
    if not ok:
        pytest.skip('scipy.optimize does not import')
    return [sys.executable, '-s'], env


def _refine(tmp_path, grid, xy, w, cfg, *extra):
    """Run `refine` as a command and read its route back."""
    import yaml
    g, route, fit, out = (tmp_path / n for n in ('g.npz', 'in.yaml', 'fit.yaml', 'out.yaml'))
    np.savez(g, **grid)
    route.write_text(flc.route_text(xy, w))
    fit.write_text(yaml.safe_dump(cfg))
    python, env = _python_with_scipy()
    run = subprocess.run(python + [str(_SCRIPT), 'refine', str(g), str(route), str(fit), str(out),
                                   *extra], capture_output=True, text=True, env=env)
    assert run.returncode == 0, run.stderr
    xy2, w2 = flc.read_route(out)
    return xy2, w2, run.stderr, out.read_text()


def _wall_bump(X, Y):
    # The outer wall bulges in to r 8.4 over the top of the ring.
    return (np.hypot(X, Y) > 8.4) & (np.abs(X) < 1.7) & (Y > 0)


CFG = {'width': 2.5, 'min_width': 1.5, 'min_radius': 3.8, 'reach': 3.5, 'strip': 0.25,
       'pull': 0.02, 'pin': 3,
       'stretches': [{'name': 'top', 'where': [{'y': [3, None]}], 'margin': 0.25, 'passes': 2}]}


def test_refine_moves_the_lane_off_an_obstacle_and_only_on_its_stretch(tmp_path):
    grid = ring_grid(extra=_wall_bump)
    xy, w = flc._quantise(circle(7.5), np.full(len(circle(7.5)), 2.5))
    before = clc.clearance(grid, lane_polys(xy, w))
    assert before['inside'].sum() > 0, 'the scene does not test anything'

    xy2, w2, log, _ = _refine(tmp_path, grid, xy, w, CFG)
    after = clc.clearance(grid, lane_polys(xy2, w2))
    assert after['inside'].sum() == 0
    assert after['dist'].min() > 0.1
    stretch = xy[:, 1] > 3
    assert np.array_equal(xy2[~stretch], xy[~stretch]), 'points off the stretch moved'
    assert np.abs(xy2[stretch] - xy[stretch]).max() > 0.3
    r = flc.ring_radii(xy2[:-1])
    assert r.min() >= 3.8 - 1e-3


def test_refine_pinch_holds_the_body_between_two_faces(tmp_path):
    # A short obstacle hanging into the top of the aisle down to y 8.0, at
    # x -0.2 .. 0.2, where the lane's outer edge is 8.75: the lane narrows to
    # 1.5 beside it, and wherever the cart is level with it the centre keeps
    # the cart's half width and the margin inside the faces (y 5.6 and 8.0),
    # so it must come down by 0.26 m at least. The lane runs -x up there.
    def board(X, Y):
        return (np.abs(X) < 0.2) & (Y > 8.0)
    grid = ring_grid(extra=board)
    xy, w = flc._quantise(circle(7.5), np.full(len(circle(7.5)), 2.5))
    cfg = dict(CFG, pinch={'aisle': {'y': [6.5, None]}, 'x': [-0.2, 0.2], 'pad': 0.3,
                           'width': 1.5, 'ease': 3.0, 'edge_margin': 0.15,
                           'body': {'y': [5.6, 8.0], 'margin': 0.15}})
    xy2, w2, log, _ = _refine(tmp_path, grid, xy, w, cfg)
    n = flc.ring_normals(xy2[:-1])
    # Unpadded: the solve's level set was taken on its own input, a hair away.
    lvl = flc.level_with(xy2[:-1], n, dict(cfg['pinch'], pad=0.0), BODY)
    assert lvl.any() and np.all(n[lvl, 1] < 0), 'expected travel along -x at the top'
    half = BODY[2]
    assert xy2[:-1][lvl, 1].max() <= 8.0 - half - 0.15 + 1e-3
    assert xy2[:-1][lvl, 1].min() >= 5.6 + half + 0.15 - 1e-3
    assert w2[:-1][lvl].max() == pytest.approx(1.5)
    assert 'body band' in log


def test_refine_tags_the_slow_stretch(tmp_path):
    grid = ring_grid(extra=lambda X, Y: (np.abs(X) < 0.2) & (Y > 8.6))
    xy, w = flc._quantise(circle(7.5), np.full(len(circle(7.5)), 2.5))
    cfg = dict(CFG, pinch={'aisle': {'y': [6.5, None]}, 'x': [-0.2, 0.2], 'pad': 0.3,
                           'width': 1.5, 'ease': 3.0})
    _, w2, _, text = _refine(tmp_path, grid, xy, w, cfg, '--slow-below', '2.0')
    assert text.count('speed_limit: 2') == 1 and text.count('speed_limit: 4') == 1
    _, widths, speeds = c2l.parse_route(__import__('yaml').safe_load(text), 2.5)
    assert all(s == 2 for s, ww in zip(speeds, widths) if ww < 2.0), \
        'a point narrower than 2 m is not in the slow stretch'


# ---------------------------------------------------------------- pieces


def test_level_with_reads_the_direction_of_travel():
    pinch = {'aisle': {'y': [21, None]}, 'x': [10.0, 10.5], 'pad': 0.0}
    xs = np.arange(5.0, 15.0, 0.25)
    xy = np.c_[xs, np.full_like(xs, 22.0)]
    east = flc.level_with(xy, np.tile([0.0, 1.0], (len(xs), 1)), pinch, (1.0, 2.0, 0.6))
    west = flc.level_with(xy, np.tile([0.0, -1.0], (len(xs), 1)), pinch, (1.0, 2.0, 0.6))
    # Eastbound the body spans x - 1 .. x + 2; westbound x - 2 .. x + 1.
    assert xs[east].min() > 8.0 - 1e-9 and xs[east].max() < 11.5
    assert xs[west].min() > 9.0 - 1e-9 and xs[west].max() < 12.5
    assert not flc.level_with(xy - [0, 2], np.tile([0.0, 1.0], (len(xs), 1)),
                              pinch, (1.0, 2.0, 0.6)).any(), 'outside the aisle box'


def test_slow_zone_pads_the_narrow_stretch():
    xy = np.c_[np.arange(0, 20.5, 0.5), np.zeros(41)]
    w = np.full(41, 2.5)
    w[16:21] = 1.6   # x 8 .. 10
    a, b = flc.slow_zone(xy, w, 2.0, 2.0)
    assert xy[a, 0] == pytest.approx(6.0) and xy[b, 0] == pytest.approx(12.5)


def test_free_space_strip_sees_a_cell_a_ray_misses():
    occ = np.zeros((100, 100), bool)
    occ[60, 52] = True          # one cell at x 6.0-6.1, y 5.2-5.3
    grid = dict(occ=occ, x0=0.0, y0=0.0, cell=0.1)
    p, n = np.array([[5.0, 5.0]]), np.array([[1.0, 0.0]])
    assert flc.free_space(grid, p, n, 3.5, 0.025)[0] == 3.5
    assert flc.free_space(grid, p, n, 3.5, 0.025, strip=0.25)[0] == pytest.approx(1.0)


def test_quantise_matches_the_file_precision(tmp_path):
    xy = np.array([[1.23456, -2.34567], [3.0, 4.0], [1.23456, -2.34567]])
    w = np.array([2.5 - 1e-10, 2.4999, 2.5 - 1e-10])
    q, qw = flc._quantise(xy, w)
    p = tmp_path / 'r.yaml'
    p.write_text(flc.route_text(q, qw))
    assert q.tolist() == [[1.235, -2.346], [3.0, 4.0], [1.235, -2.346]]
    assert qw.tolist() == [2.5, 2.49, 2.5], 'float error under 2.50 floors to 2.50; a real 2.4999 to 2.49'


def test_vehicle_body_comes_from_the_vehicle_description():
    import yaml
    p = yaml.safe_load(c2l.VEHICLE_INFO.read_text())['/**']['ros__parameters']
    rear, front, half = c2l.vehicle_body()
    assert rear == p['rear_overhang']
    assert front == pytest.approx(p['wheel_base'] + p['front_overhang'])
    assert 2 * half == pytest.approx(p['wheel_tread'] + p['left_overhang'] + p['right_overhang'])


def test_the_ming_da_fit_file_names_its_stretches():
    import yaml
    p = _HERE.parents[1] / 'data/mingda-basement/loop_fit.yaml'
    cfg = yaml.safe_load(p.read_text())
    assert [s['name'] for s in cfg['stretches']] == ['top', 'bottom']
    for k in ('width', 'min_width', 'min_radius'):
        assert k in cfg


if __name__ == '__main__':
    sys.exit(pytest.main([__file__]))
