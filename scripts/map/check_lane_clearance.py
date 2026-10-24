#!/usr/bin/env python3
"""Check built lanelets against an obstacle grid: what is inside, what is nearest.

    python3 scripts/map/check_lane_clearance.py obstacles.npz \\
        data/mingda-basement/lanelet2_map_loop.osm \\
        --route data/mingda-basement/route_loop_cw.yaml

Phase 8, M7. Reads the lanelet polygons out of the OSM the builder wrote (the
Local frame's local_x / local_y tags) and reports, against obstacle_grid.py's
grid:

- obstacle cells whose centre is inside a lanelet, and where;
- the nearest cell outside, measured from the lane edge to the cell's square
  (its nearest face or corner, not its centre), and where it is;
- with --route, what the route file holds: the stretch narrower than
  --narrow, the narrowest width, where the speed limit changes, and the
  tightest radius by the builder's own check (1 m resampling) against the
  minimum the vehicle description's wheel base and max steer allow.

Exit status 1 if any cell is inside or touches the lane, or the nearest is
closer than --min-clearance; 0 otherwise. A tight radius is reported, not
failed: the builder already warns, and the controller is the judge.

What it does NOT check is the cart: the lane is not the footprint, and a cart
cutting a corner leaves the lane. The planning simulator is that check.
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import centerline_to_lanelet as c2l  # noqa: E402
from obstacle_grid import load_grid, occupied_centres  # noqa: E402


def lanelet_polygons(osm_text: str) -> list[np.ndarray]:
    """One closed-ring polygon (left bound, then right bound backwards) per lanelet."""
    root = ET.fromstring(osm_text)
    nodes = {}
    for n in root.iter('node'):
        tags = {t.get('k'): t.get('v') for t in n.findall('tag')}
        if 'local_x' in tags:
            nodes[n.get('id')] = (float(tags['local_x']), float(tags['local_y']))
    ways = {w.get('id'): [nodes[nd.get('ref')] for nd in w.findall('nd')] for w in root.iter('way')}
    polys = []
    for rel in root.iter('relation'):
        if {t.get('k'): t.get('v') for t in rel.findall('tag')}.get('type') != 'lanelet':
            continue
        m = {mm.get('role'): np.array(ways[mm.get('ref')]) for mm in rel.findall('member')}
        # Both bounds run the same way (the builder stores both reversed), so
        # one forwards and the other backwards is a ring.
        polys.append(np.vstack([m['left'], m['right'][::-1]]))
    return polys


def inside(poly: np.ndarray, pts: np.ndarray) -> np.ndarray:
    """Even-odd point-in-polygon, vectorised over the points."""
    x, y = pts[:, 0], pts[:, 1]
    hit = np.zeros(len(pts), bool)
    for (x1, y1), (x2, y2) in zip(poly, np.roll(poly, -1, 0)):
        crosses = (y1 > y) != (y2 > y)
        with np.errstate(divide='ignore', invalid='ignore'):
            xc = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
        hit ^= crosses & (x < xc)
    return hit


def _point_segment(px, py, ax, ay, bx, by):
    """Distance from points (M, 1) to segments (1, K), broadcast."""
    dx, dy = bx - ax, by - ay
    ll = dx * dx + dy * dy
    with np.errstate(divide='ignore', invalid='ignore'):
        t = np.clip(np.where(ll > 0, ((px - ax) * dx + (py - ay) * dy) / ll, 0.0), 0.0, 1.0)
    return np.hypot(px - (ax + t * dx), py - (ay + t * dy))


def square_segment_distance(centres: np.ndarray, h: float, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Exact distance from each axis-aligned square (centre, half side h) to the
    nearest of the segments a[k] -> b[k]; 0 where one crosses it.

    Two disjoint convex shapes are nearest at a vertex of one, so it is the
    least of the segment ends to the square and the square's corners to the
    segment, unless the segment crosses the square."""
    cx, cy = centres[:, :1], centres[:, 1:]
    ax, ay, bx, by = a[None, :, 0], a[None, :, 1], b[None, :, 0], b[None, :, 1]

    def to_square(px, py):
        return np.hypot(np.maximum(np.abs(px - cx) - h, 0), np.maximum(np.abs(py - cy) - h, 0))

    d = np.minimum(to_square(ax, ay), to_square(bx, by))
    side = []
    for sx, sy in ((-h, -h), (-h, h), (h, -h), (h, h)):
        d = np.minimum(d, _point_segment(cx + sx, cy + sy, ax, ay, bx, by))
        side.append((bx - ax) * (cy + sy - ay) - (by - ay) * (cx + sx - ax))
    side = np.stack(side)
    straddles = (side.min(axis=0) <= 0) & (side.max(axis=0) >= 0)
    overlaps = ((np.minimum(ax, bx) <= cx + h) & (np.maximum(ax, bx) >= cx - h)
                & (np.minimum(ay, by) <= cy + h) & (np.maximum(ay, by) >= cy - h))
    d[straddles & overlaps] = 0.0
    return d.min(axis=1)


def clearance(grid: dict, polys: list[np.ndarray], chunk: int = 2000) -> dict:
    """Cells inside the lanelets, and each outside cell's distance from the lane edge.

    The distance is to the cell's square, exactly. Lanelet ends inside the lane
    are among the edges; they are never nearer than the lane's outline."""
    cells = occupied_centres(grid)
    ins = np.zeros(len(cells), bool)
    for p in polys:
        ins |= inside(p, cells)
    out = cells[~ins]
    a = np.vstack(polys)
    b = np.vstack([np.roll(p, -1, 0) for p in polys])
    h = grid['cell'] / 2
    d = np.concatenate([square_segment_distance(out[i:i + chunk], h, a, b)
                        for i in range(0, len(out), chunk)] or [np.zeros(0)])
    d_c = np.concatenate([_point_segment(out[i:i + chunk, :1], out[i:i + chunk, 1:],
                                         a[None, :, 0], a[None, :, 1],
                                         b[None, :, 0], b[None, :, 1]).min(axis=1)
                          for i in range(0, len(out), chunk)] or [np.zeros(0)])
    return dict(cells=cells, inside=ins, outside=out, dist=d, dist_centre=d_c)


def route_summary(route_file: Path, narrow: float) -> list[str]:
    import yaml
    pts, widths, speeds = c2l.parse_route(yaml.safe_load(route_file.read_text()), 2.5)
    xy, w = np.array(pts), np.array(widths)
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(xy, axis=0), axis=1))])
    lines = [f'route: {len(xy)} points, {s[-1]:.1f} m, width {w.min():.2f} .. {w.max():.2f} m']
    nar = np.where(w < narrow)[0]
    if len(nar):
        a, b = nar.min(), nar.max()
        lines.append(f'narrower than {narrow:g} m: ({xy[a, 0]:.2f}, {xy[a, 1]:.2f}) to '
                     f'({xy[b, 0]:.2f}, {xy[b, 1]:.2f}), {s[b] - s[a]:.1f} m')
    for i in range(1, len(speeds)):
        if speeds[i] != speeds[i - 1]:
            lines.append(f'speed {speeds[i]:g} km/h from ({xy[i, 0]:.2f}, {xy[i, 1]:.2f})')
    r = c2l.min_radius(c2l.resample(pts, 1.0))   # as the builder checks, --smoothing 0
    wb, ms = c2l.vehicle_geometry()
    r_min = c2l.min_turning_radius(wb, ms)
    lines.append(f'tightest radius {r:.2f} m by the builder\'s 1 m check; the vehicle '
                 f'allows {r_min:.2f} m (wheel base {wb} m, max steer {ms} rad)'
                 + ('' if r >= r_min else '  TIGHTER THAN THE VEHICLE ALLOWS'))
    return lines


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('grid', type=Path, help="obstacle_grid.py's .npz")
    ap.add_argument('osm', type=Path, help='lanelet2 map the builder wrote')
    ap.add_argument('--route', type=Path, help='the route file it was built from')
    ap.add_argument('--narrow', type=float, default=2.0, help='m; report the stretch below it')
    ap.add_argument('--near', type=float, default=0.3, help='m; list cells closer than this')
    ap.add_argument('--min-clearance', type=float, default=0.0,
                    help='m; fail if the nearest cell is closer')
    args = ap.parse_args(argv)

    grid = load_grid(args.grid)
    polys = lanelet_polygons(args.osm.read_text())
    if not polys:
        print(f'{args.osm}: no lanelets', file=sys.stderr)
        return 1
    r = clearance(grid, polys)
    n_in, d = int(r['inside'].sum()), r['dist']
    print(f'{args.osm.name}: {len(polys)} lanelets, {len(r["cells"])} obstacle cells')
    print(f'cells inside the lane: {n_in}')
    if n_in:
        print('  at', np.round(r['cells'][r['inside']][:10], 2).tolist())
    if len(d):
        k = int(np.argmin(d))
        print(f'nearest cell outside: {d[k]:.3f} m from the lane edge to its square '
              f'({r["dist_centre"][k]:.3f} m to its centre), '
              f'at ({r["outside"][k, 0]:.2f}, {r["outside"][k, 1]:.2f})')
        near = np.argsort(d)[:int((d < args.near).sum())]
        print(f'cells within {args.near:g} m of an edge: {len(near)}')
        for i in near[:10]:
            print(f'  {d[i]:.3f} m at ({r["outside"][i, 0]:.2f}, {r["outside"][i, 1]:.2f})')
    if args.route:
        for line in route_summary(args.route, args.narrow):
            print(line)
    ok = n_in == 0 and (not len(d) or (d.min() > 0 and d.min() >= args.min_clearance))
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
