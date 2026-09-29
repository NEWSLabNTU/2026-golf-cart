#!/usr/bin/env python3
"""Turn a driven centreline into a drivable lanelet2 map in a Local frame.

    python3 scripts/map/centerline_to_lanelet.py route.yaml \\
        --map-dir data/basement-indoor --width 2.4 --write

Phase 8, M1. The basement map's lanelet2_map.osm held the reflective board and
nothing else, so no route could exist. This builds road lanelets along a
centreline given as map-frame points and writes them beside the board polygon.

The route file is YAML: a list of [x, y] or [x, y, z] in the map frame, in the
direction of travel. Repeat the first point last for a closed loop.

    - [2.0, 0.0]
    - [14.0, 0.0]
    - [20.0, 6.0]

What it guarantees, and the tests check:

- **Local frame.** Every node carries local_x, local_y and ele, and no lat/lon.
  The basement projector is `Local`; Autoware's map loader overwrites each
  point's x and y from those tags, so a georeferenced node would land somewhere
  else with no warning.
- **The board survives.** The base is `board_polygon.osm`; new element ids start
  well above its own.
- **One connected route.** Consecutive lanelets share their boundary nodes, and
  a closed loop's last lanelet ends on the first one's start.
- **The right direction after Autoware loads it.** Bounds are written against the
  direction of travel; see the comment in build_osm for why that is correct.
- **format_version.** The loader warned about its absence on the polygon-only map.

What it does NOT know is where the cart can drive. The centreline is a human
choice, made against `pcd_floor_plan.py`'s top-down image or a driven path.
"""

from __future__ import annotations

import argparse
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

Point = tuple[float, float]

NODE_ID0, WAY_ID0, REL_ID0 = 100000, 200000, 300000
WHEEL_BASE_M = 2.061        # golfcart_vehicle_description vehicle_info.param.yaml
MAX_STEER_RAD = 0.349       # same file; inherited from the PWM cart (Phase 8, V3)


def min_turning_radius(wheel_base: float = WHEEL_BASE_M,
                       max_steer: float = MAX_STEER_RAD) -> float:
    """Bicycle-model minimum radius at the rear axle."""
    return wheel_base / math.tan(max_steer)


def smooth(points: list[Point], iterations: int, closed: bool) -> list[Point]:
    """Chaikin corner cutting. Keeps the endpoints of an open polyline."""
    pts = list(points)
    for _ in range(iterations):
        if closed:
            ring = pts[:-1] if pts[0] == pts[-1] else pts
            out = []
            for a, b in zip(ring, ring[1:] + ring[:1]):
                out += [(0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]),
                        (0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1])]
            pts = out + [out[0]]
        else:
            out = [pts[0]]
            for a, b in zip(pts, pts[1:]):
                out += [(0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]),
                        (0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1])]
            pts = out[:1] + out[2:-1] + [pts[-1]] if len(out) > 3 else out + [pts[-1]]
    return pts


def resample(points: list[Point], step: float) -> list[Point]:
    """Points along the polyline no more than `step` apart, endpoints kept."""
    pts = [(float(p[0]), float(p[1])) for p in points]
    if len(pts) < 2 or all(math.dist(pts[0], p) < 1e-9 for p in pts):
        raise ValueError('a centreline needs at least two distinct points')
    out = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        seg = math.dist(a, b)
        if seg < 1e-9:
            continue
        n = max(1, math.ceil(seg / step - 1e-9))
        for i in range(1, n + 1):
            t = i / n
            out.append((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])))
    return out


def _tangents(pts: list[Point], closed: bool) -> list[Point]:
    tans = []
    for i in range(len(pts)):
        if closed and i in (0, len(pts) - 1):
            a, b = pts[-2], pts[1]
        else:
            a = pts[max(i - 1, 0)]
            b = pts[min(i + 1, len(pts) - 1)]
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy)
        tans.append((dx / n, dy / n))
    return tans


def offset_bounds(center: list[Point], width: float,
                  closed: bool = False) -> tuple[list[Point], list[Point]]:
    """Left and right boundaries, `width / 2` either side, left being left of travel."""
    if not width > 0:
        raise ValueError(f'width must be positive, got {width}')
    h = width / 2.0
    left, right = [], []
    for (x, y), (tx, ty) in zip(center, _tangents(center, closed)):
        nx, ny = -ty, tx
        left.append((x + h * nx, y + h * ny))
        right.append((x - h * nx, y - h * ny))
    return left, right


def split_segments(n_points: int, points_per_segment: float) -> list[tuple[int, int]]:
    """Index ranges [start, end] covering 0..n-1, consecutive ranges sharing an end."""
    k = max(1, round(points_per_segment))
    bounds = list(range(0, n_points - 1, k)) + [n_points - 1]
    if len(bounds) > 2 and bounds[-1] - bounds[-2] < k / 2:
        bounds.pop(-2)  # fold a stub tail into the previous lanelet
    return list(zip(bounds, bounds[1:]))


def min_radius(pts: list[Point]) -> float:
    """Smallest circumradius over consecutive point triples."""
    best = math.inf
    for a, b, c in zip(pts, pts[1:], pts[2:]):
        ab, bc, ca = math.dist(a, b), math.dist(b, c), math.dist(c, a)
        cross = abs((b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]))
        if cross > 1e-12:
            best = min(best, ab * bc * ca / (2.0 * cross))
    return best


def _node(parent, nid, x, y, z):
    el = ET.SubElement(parent, 'node', id=str(nid), visible='true')
    for k, v in (('local_x', x), ('local_y', y), ('ele', z)):
        ET.SubElement(el, 'tag', k=k, v=f'{v:.4f}')


def build_osm(centerline, *, width: float, ele: float, segment_length: float,
              speed_limit_kmh: float, base_osm: str | None, step: float = 1.0,
              smoothing: int = 0) -> str:
    """The full lanelet2 OSM document, base elements first."""
    pts2 = [(float(p[0]), float(p[1])) for p in centerline]
    closed = len(pts2) > 2 and math.dist(pts2[0], pts2[-1]) < 1e-6
    if smoothing:
        pts2 = smooth(pts2, smoothing, closed)
    center = resample(pts2, step)
    if closed:
        center[-1] = center[0]
    left, right = offset_bounds(center, width, closed)

    if base_osm:
        root = ET.fromstring(base_osm)
    else:
        root = ET.Element('osm', version='0.6')
    root.set('generator', 'golfcart centerline_to_lanelet')
    if root.find('MetaInfo') is None:
        root.insert(0, ET.Element('MetaInfo', format_version='1', map_version='1'))

    existing = [int(i) for e in root if (i := e.get('id'))]
    offset = 0
    while any(i >= NODE_ID0 + offset for i in existing):
        offset += 1000000
    nid, wid, rid = NODE_ID0 + offset, WAY_ID0 + offset, REL_ID0 + offset

    n = len(center)
    left_ids, right_ids = [], []
    for i in range(n):
        if closed and i == n - 1:
            left_ids.append(left_ids[0])
            right_ids.append(right_ids[0])
            continue
        _node(root, nid, *left[i], ele)
        left_ids.append(nid)
        nid += 1
        _node(root, nid, *right[i], ele)
        right_ids.append(nid)
        nid += 1

    for s0, s1 in split_segments(n, segment_length / step):
        way_ids = []
        for ids in (left_ids, right_ids):
            way = ET.SubElement(root, 'way', id=str(wid), visible='true')
            # Both bounds are stored AGAINST the direction of travel, on purpose.
            # lanelet2's loader orients a lanelet's bounds with geometry::align(),
            # which inverts a bound unless the other one lies strictly on the
            # correct side of it. Autoware's LocalProjector puts every point at
            # (0, 0) during the load and only restores local_x / local_y
            # afterwards (lanelet2_map_loader_node.cpp), so every signed distance
            # is 0 and align() inverts BOTH bounds, always. Stored in travel order,
            # every lanelet would load backwards with its bounds on the wrong
            # sides. Stored reversed, the degenerate load inverts them into place,
            # and a loader that does see real geometry reaches the same result,
            # because align() corrects reversed bounds.
            for ref in reversed(ids[s0:s1 + 1]):
                ET.SubElement(way, 'nd', ref=str(ref))
            ET.SubElement(way, 'tag', k='type', v='line_thin')
            ET.SubElement(way, 'tag', k='subtype', v='solid')
            way_ids.append(wid)
            wid += 1
        rel = ET.SubElement(root, 'relation', id=str(rid), visible='true')
        ET.SubElement(rel, 'member', type='way', ref=str(way_ids[0]), role='left')
        ET.SubElement(rel, 'member', type='way', ref=str(way_ids[1]), role='right')
        for k, v in (('type', 'lanelet'), ('subtype', 'road'), ('location', 'urban'),
                     ('one_way', 'yes'), ('participant:vehicle', 'yes'),
                     ('speed_limit', f'{speed_limit_kmh:g}')):
            ET.SubElement(rel, 'tag', k=k, v=v)
        rid += 1

    ET.indent(root, space='  ')
    return "<?xml version='1.0' encoding='UTF-8'?>\n" + ET.tostring(root, encoding='unicode') + '\n'


def main(argv=None) -> int:
    import yaml

    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('route', type=Path, help='YAML list of [x, y] map-frame points')
    ap.add_argument('--map-dir', type=Path, default=Path('data/basement-indoor'))
    ap.add_argument('--base', default='board_polygon.osm',
                    help='file in --map-dir to build on (default: board_polygon.osm)')
    ap.add_argument('--width', type=float, default=2.4, help='lane width, m')
    ap.add_argument('--ele', type=float, default=0.0,
                    help='elevation of every node, m. The basement z origin may be off by ~0.2 m')
    ap.add_argument('--segment-length', type=float, default=10.0)
    ap.add_argument('--speed-limit', type=float, default=4.0, help='km/h, per lanelet')
    ap.add_argument('--smoothing', type=int, default=2,
                    help='Chaikin iterations to round corners (0 keeps them sharp)')
    ap.add_argument('--write', action='store_true',
                    help='write --map-dir/lanelet2_map.osm; otherwise print to stdout')
    args = ap.parse_args(argv)

    points = yaml.safe_load(args.route.read_text())
    base = args.map_dir / args.base
    osm = build_osm(points, width=args.width, ele=args.ele,
                    segment_length=args.segment_length, speed_limit_kmh=args.speed_limit,
                    base_osm=base.read_text() if base.exists() else None,
                    smoothing=args.smoothing)

    pts2 = [(float(p[0]), float(p[1])) for p in points]
    closed = len(pts2) > 2 and math.dist(pts2[0], pts2[-1]) < 1e-6
    shaped = resample(smooth(pts2, args.smoothing, closed) if args.smoothing else pts2, 1.0)
    r, r_min = min_radius(shaped), min_turning_radius()
    if r < r_min:
        print(f'WARNING: tightest corner radius {r:.1f} m is below the cart\'s '
              f'{r_min:.1f} m minimum (wheel base {WHEEL_BASE_M} m, max steer '
              f'{MAX_STEER_RAD} rad). The controller cannot follow it; widen the '
              f'corner or raise --smoothing.', file=sys.stderr)

    if args.write:
        out = args.map_dir / 'lanelet2_map.osm'
        out.write_text(osm)
        print(f'wrote {out}', file=sys.stderr)
    else:
        sys.stdout.write(osm)
    return 0


if __name__ == '__main__':
    sys.exit(main())
