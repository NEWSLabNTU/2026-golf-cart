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

A point may instead be a mapping that carries its own lane width, for an aisle
that narrows; points without one take --width, and the width varies linearly
along the lane between points. A mapping may also set speed_limit (km/h),
which holds from that point until the next point that sets one; --speed-limit
holds before the first. Lanelets are split where it changes, so a slow zone is
exactly its own lanelets.

    - {x: 14.0, y: 0.0, width: 1.9, speed_limit: 2}

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
from typing import Sequence

Point = tuple[float, float]

NODE_ID0, WAY_ID0, REL_ID0 = 100000, 200000, 300000
VEHICLE_INFO = (Path(__file__).resolve().parents[2] / 'src/vehicle/golfcart_vehicle_launch'
                / 'golfcart_vehicle_description/config/vehicle_info.param.yaml')


def vehicle_geometry() -> tuple[float, float]:
    """(wheel_base, max_steer_angle) from the vehicle description, read each call.

    A copy here went stale once: it kept 0.349 rad after the cart moved to 0.52,
    and warned about a 5.7 m minimum radius that no longer held.
    """
    import yaml
    p = yaml.safe_load(VEHICLE_INFO.read_text())['/**']['ros__parameters']
    return float(p['wheel_base']), float(p['max_steer_angle'])


def vehicle_body() -> tuple[float, float, float]:
    """(rear, front, half_width) of the body about base_link (the rear axle), m.

    rear = rear_overhang, front = wheel_base + front_overhang, half_width =
    (wheel_tread + left_overhang + right_overhang) / 2; from the same file."""
    import yaml
    p = yaml.safe_load(VEHICLE_INFO.read_text())['/**']['ros__parameters']
    width = float(p['wheel_tread']) + float(p['left_overhang']) + float(p['right_overhang'])
    return (float(p['rear_overhang']), float(p['wheel_base']) + float(p['front_overhang']),
            width / 2.0)


def min_turning_radius(wheel_base: float | None = None,
                       max_steer: float | None = None) -> float:
    """Bicycle-model minimum radius at the rear axle."""
    if wheel_base is None or max_steer is None:
        wb, ms = vehicle_geometry()
        wheel_base = wb if wheel_base is None else wheel_base
        max_steer = ms if max_steer is None else max_steer
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


def offset_bounds(center: list[Point], width: float | Sequence[float],
                  closed: bool = False) -> tuple[list[Point], list[Point]]:
    """Left and right boundaries, `width / 2` either side, left being left of travel.

    `width` is one value for the whole lane or one per centre point."""
    widths = [width] * len(center) if isinstance(width, (int, float)) else list(width)
    if len(widths) != len(center):
        raise ValueError(f'{len(widths)} widths for {len(center)} centre points')
    if not all(w > 0 for w in widths):
        raise ValueError(f'width must be positive, got {min(widths)}')
    left, right = [], []
    for (x, y), (tx, ty), w in zip(center, _tangents(center, closed), widths):
        nx, ny = -ty, tx
        h = w / 2.0
        left.append((x + h * nx, y + h * ny))
        right.append((x - h * nx, y - h * ny))
    return left, right


def _arc_fractions(pts: list[Point]) -> list[float]:
    s = [0.0]
    for a, b in zip(pts, pts[1:]):
        s.append(s[-1] + math.dist(a, b))
    return [v / s[-1] for v in s]


def widths_along(route: list[Point], widths: Sequence[float], samples: list[Point]) -> list[float]:
    """Per-route-point widths carried onto `samples`, linear in arc-length fraction.

    Exact for a resampled route, whose samples keep the route's vertices; after
    smoothing it is the same fraction of the way round, which is close."""
    f, g = _arc_fractions(route), _arc_fractions(samples)
    out, i = [], 0
    for t in g:
        while i < len(f) - 2 and f[i + 1] < t:
            i += 1
        span = f[i + 1] - f[i]
        u = 0.0 if span <= 0 else min(max((t - f[i]) / span, 0.0), 1.0)
        out.append(widths[i] + u * (widths[i + 1] - widths[i]))
    return out


def speeds_along(route: list[Point], speeds: Sequence[float], samples: list[Point]) -> list[float]:
    """Each sample takes the speed of the last route point at or before it (arc fraction)."""
    f, g = _arc_fractions(route), _arc_fractions(samples)
    out, i = [], 0
    for t in g:
        while i < len(f) - 1 and f[i + 1] <= t + 1e-9:
            i += 1
        out.append(speeds[min(i, len(speeds) - 1)])
    return out


def parse_route(items, default_width: float,
                default_speed: float = 4.0) -> tuple[list[Point], list[float], list[float]]:
    """Route-file items, [x, y], [x, y, z] or {x, y, width, speed_limit}, as points,
    widths and speeds. A speed holds until the next point that sets one."""
    pts, widths, speeds = [], [], []
    speed = default_speed
    for item in items:
        if isinstance(item, dict):
            pts.append((float(item['x']), float(item['y'])))
            widths.append(float(item.get('width', default_width)))
            speed = float(item.get('speed_limit', speed))
        else:
            pts.append((float(item[0]), float(item[1])))
            widths.append(default_width)
        speeds.append(speed)
    return pts, widths, speeds


def split_segments(n_points: int, points_per_segment: float,
                   breaks: Sequence[int] = ()) -> list[tuple[int, int]]:
    """Index ranges [start, end] covering 0..n-1, consecutive ranges sharing an end.

    Every index in `breaks` is also a range boundary."""
    k = max(1, round(points_per_segment))
    bounds = list(range(0, n_points - 1, k)) + [n_points - 1]
    if len(bounds) > 2 and bounds[-1] - bounds[-2] < k / 2:
        bounds.pop(-2)  # fold a stub tail into the previous lanelet
    bounds = sorted(set(bounds) | {b for b in breaks if 0 < b < n_points - 1})
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


def build_osm(centerline, *, width: float | Sequence[float], ele: float, segment_length: float,
              speed_limit_kmh: float | Sequence[float], base_osm: str | None, step: float = 1.0,
              smoothing: int = 0) -> str:
    """The full lanelet2 OSM document, base elements first.

    `width` and `speed_limit_kmh` are one value, or one per centreline point;
    a per-point speed holds from its point to the next."""
    route = [(float(p[0]), float(p[1])) for p in centerline]
    closed = len(route) > 2 and math.dist(route[0], route[-1]) < 1e-6
    pts2 = smooth(route, smoothing, closed) if smoothing else route
    center = resample(pts2, step)
    if closed:
        center[-1] = center[0]
    if not isinstance(width, (int, float)):
        if len(width) != len(route):
            raise ValueError(f'{len(width)} widths for {len(route)} route points')
        width = widths_along(route, width, center)
    if isinstance(speed_limit_kmh, (int, float)):
        speeds = [float(speed_limit_kmh)] * len(center)
    else:
        if len(speed_limit_kmh) != len(route):
            raise ValueError(f'{len(speed_limit_kmh)} speeds for {len(route)} route points')
        speeds = speeds_along(route, speed_limit_kmh, center)
    breaks = [i for i in range(1, len(speeds)) if speeds[i] != speeds[i - 1]]
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

    for s0, s1 in split_segments(n, segment_length / step, breaks):
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
                     ('speed_limit', f'{speeds[s0]:g}')):
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

    points, widths, speeds = parse_route(yaml.safe_load(args.route.read_text()),
                                         args.width, args.speed_limit)
    base = args.map_dir / args.base
    osm = build_osm(points, width=widths if len(set(widths)) > 1 else args.width, ele=args.ele,
                    segment_length=args.segment_length,
                    speed_limit_kmh=speeds if len(set(speeds)) > 1 else args.speed_limit,
                    base_osm=base.read_text() if base.exists() else None,
                    smoothing=args.smoothing)

    pts2 = points
    closed = len(pts2) > 2 and math.dist(pts2[0], pts2[-1]) < 1e-6
    shaped = resample(smooth(pts2, args.smoothing, closed) if args.smoothing else pts2, 1.0)
    wheel_base, max_steer = vehicle_geometry()
    r, r_min = min_radius(shaped), min_turning_radius(wheel_base, max_steer)
    if r < r_min:
        print(f'WARNING: tightest corner radius {r:.1f} m is below the cart\'s '
              f'{r_min:.1f} m minimum (wheel base {wheel_base} m, max steer '
              f'{max_steer} rad). The controller cannot follow it; widen the '
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
