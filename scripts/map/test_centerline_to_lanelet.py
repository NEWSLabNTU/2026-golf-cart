"""Tests for centerline_to_lanelet.py (Phase 8, M1).

    python3 -m pytest scripts/map/test_centerline_to_lanelet.py

The last two tests load the output the way Autoware's map loader does (any
projector, then local_x/local_y overwrite the coordinates) and build a lanelet2
routing graph; they skip when the lanelet2 Python bindings are not sourced.
"""

import importlib.util
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().with_name('centerline_to_lanelet.py')
_spec = importlib.util.spec_from_file_location('centerline_to_lanelet', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
c2l = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(c2l)

BOARD_OSM = """<?xml version='1.0' encoding='UTF-8'?>
<osm version='0.6' generator='golfcart_board_initializer'>
  <node id='1001' visible='true'><tag k='local_x' v='0.0'/><tag k='local_y' v='0.3'/><tag k='ele' v='1.0'/></node>
  <node id='1002' visible='true'><tag k='local_x' v='0.0'/><tag k='local_y' v='-0.3'/><tag k='ele' v='1.0'/></node>
  <way id='2001' visible='true'><nd ref='1001'/><nd ref='1002'/>
    <tag k='type' v='pose_marker'/><tag k='subtype' v='reflector'/></way>
</osm>
"""

STRAIGHT = [(0.0, 0.0), (30.0, 0.0)]
L_TURN = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0)]


def test_resample_spacing_and_endpoints():
    pts = c2l.resample(STRAIGHT, 1.0)
    assert pts[0] == pytest.approx((0.0, 0.0))
    assert pts[-1] == pytest.approx((30.0, 0.0))
    gaps = [math.dist(a, b) for a, b in zip(pts, pts[1:])]
    assert max(gaps) <= 1.0 + 1e-9


def test_bounds_are_half_width_either_side_and_left_is_left():
    left, right = c2l.offset_bounds(c2l.resample(STRAIGHT, 1.0), 2.4)
    # Driving along +x, left is +y.
    assert all(p[1] == pytest.approx(1.2) for p in left)
    assert all(p[1] == pytest.approx(-1.2) for p in right)


def test_rejects_degenerate_input():
    with pytest.raises(ValueError):
        c2l.resample([(1.0, 1.0)], 1.0)
    with pytest.raises(ValueError):
        c2l.offset_bounds(c2l.resample(STRAIGHT, 1.0), 0.0)


def test_segments_share_endpoints():
    segs = c2l.split_segments(len(c2l.resample(STRAIGHT, 1.0)), 10.0 / 1.0)
    assert len(segs) == 3
    for (a0, a1), (b0, b1) in zip(segs, segs[1:]):
        assert a1 == b0


def test_osm_keeps_board_and_adds_connected_local_lanelets():
    osm = c2l.build_osm(L_TURN, width=2.4, ele=0.0, segment_length=10.0,
                        speed_limit_kmh=4.0, base_osm=BOARD_OSM)
    root = ET.fromstring(osm)
    meta = root.find('MetaInfo')
    assert meta is not None and meta.get('format_version') == '1'
    ids = [e.get('id') for e in root if e.get('id')]
    assert len(ids) == len(set(ids)), 'element ids collide'
    assert root.find("way[@id='2001']") is not None, 'board polygon dropped'

    lanelets = [r for r in root.findall('relation')
                if {'type': 'lanelet'}.items() <= {t.get('k'): t.get('v')
                                                   for t in r.findall('tag')}.items()]
    assert len(lanelets) >= 4
    for rel in lanelets:
        tags = {t.get('k'): t.get('v') for t in rel.findall('tag')}
        assert tags['subtype'] == 'road'
        assert tags['speed_limit'] == '4'
    for node in root.findall('node'):
        tag_keys = {t.get('k') for t in node.findall('tag')}
        assert {'local_x', 'local_y', 'ele'} <= tag_keys


def _load_like_autoware(path):
    lanelet2 = pytest.importorskip('lanelet2')
    from lanelet2.io import Origin
    from lanelet2.projection import UtmProjector
    lmap, errors = lanelet2.io.loadRobust(str(path), UtmProjector(Origin(0.0, 0.0)))
    for p in lmap.pointLayer:
        if 'local_x' in p.attributes:
            p.x = float(p.attributes['local_x'])
            p.y = float(p.attributes['local_y'])
    return lanelet2, lmap, errors


def test_lanelet2_loads_it_and_coordinates_come_from_local_tags(tmp_path):
    out = tmp_path / 'lanelet2_map.osm'
    out.write_text(c2l.build_osm(STRAIGHT, width=2.4, ele=0.0, segment_length=10.0,
                                 speed_limit_kmh=4.0, base_osm=BOARD_OSM))
    _, lmap, errors = _load_like_autoware(out)
    assert not errors, errors
    xs = sorted(p.x for p in lmap.pointLayer)
    assert xs[0] == pytest.approx(0.0, abs=1e-6) and xs[-1] == pytest.approx(30.0, abs=1e-6)


def test_route_exists_from_first_to_last_lanelet(tmp_path):
    out = tmp_path / 'lanelet2_map.osm'
    out.write_text(c2l.build_osm(L_TURN, width=2.4, ele=0.0, segment_length=10.0,
                                 speed_limit_kmh=4.0, base_osm=BOARD_OSM))
    lanelet2, lmap, _ = _load_like_autoware(out)
    graph = _graph(lanelet2, lmap)
    lls = sorted(lmap.laneletLayer, key=lambda ll: ll.id)
    route = graph.getRoute(lls[0], lls[-1])
    assert route is not None, 'lanelets are not connected into one route'
    assert len(route.shortestPath()) == len(lls)


def _graph(lanelet2, lmap):
    rules = lanelet2.traffic_rules.create(lanelet2.traffic_rules.Locations.Germany,
                                          lanelet2.traffic_rules.Participants.Vehicle)
    return lanelet2.routing.RoutingGraph(lmap, rules)


def test_lanelets_point_in_the_direction_of_travel_after_an_autoware_load(tmp_path):
    """The regression this tool exists to avoid: Autoware's Local load inverts
    both bounds of every lanelet, so travel-order bounds load backwards."""
    out = tmp_path / 'lanelet2_map.osm'
    out.write_text(c2l.build_osm(STRAIGHT, width=2.4, ele=0.0, segment_length=10.0,
                                 speed_limit_kmh=4.0, base_osm=None))
    _, lmap, _ = _load_like_autoware(out)
    for ll in lmap.laneletLayer:
        left, right = ll.leftBound, ll.rightBound
        assert left[len(left) - 1].x > left[0].x, f'lanelet {ll.id} runs backwards'
        assert all(p.y > 0 for p in left) and all(p.y < 0 for p in right), \
            f'lanelet {ll.id} has its bounds on the wrong sides'


def test_closed_loop_last_lanelet_leads_into_the_first(tmp_path):
    loop = [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0), (0.0, 0.0)]
    out = tmp_path / 'lanelet2_map.osm'
    out.write_text(c2l.build_osm(loop, width=2.4, ele=0.0, segment_length=10.0,
                                 speed_limit_kmh=4.0, base_osm=None, smoothing=2))
    lanelet2, lmap, _ = _load_like_autoware(out)
    lls = sorted(lmap.laneletLayer, key=lambda ll: ll.id)
    following = [f.id for f in _graph(lanelet2, lmap).following(lls[-1])]
    assert following == [lls[0].id]
