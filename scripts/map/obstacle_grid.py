#!/usr/bin/env python3
"""Obstacle grid of a point-cloud map, with hand edits, for fitting a lane.

    python3 scripts/map/obstacle_grid.py data/basement-indoor/pointcloud_map.pcd \\
        data/mingda-basement/obstacle_edits.yaml -o obstacles.npz \\
        --from-anchor data/basement-indoor/board_anchor.yaml \\
        --to-anchor data/mingda-basement/board_anchor.yaml

Phase 8, M7. A cell is an obstacle when at least `min_points` points lie in it
between the band's two heights above the floor. The cloud is not the aisle: it
holds things that were there only on the survey day and misses things the
cart must avoid. Those corrections are data, in an edits YAML beside the map,
so that a refit starts from the same obstacles and a reviewer can read what
was changed and why. Every edit carries a `why`.

    cell: 0.1                  # m
    min_points: 3              # per cell, counted in the band
    band: [0.25, 2.13]         # m above `floor`; points outside never count
    floor: 0.0                 # map z of the floor
    origin: [-6.0, -12.0]      # map x, y of cell [0, 0]'s corner
    size: [34.0, 40.0]         # m along x, y
    remove:                    # band points inside any box are dropped
      - {why: ..., x: [3.5, 4.45], y: [1.7, 2.3]}
      - {why: ..., x: [10.5, 16.2], y: [23.5, 25.2], z: [null, 1.7]}
    add:
      - {why: ..., cloud: {x: [12.3, 12.65], y: [23.5, 24.75], z: [2.0, 2.4]}}
      - {why: ..., line: [[7.5, -3.2], [16.0, -3.2]]}

A box bound is open where it is null or absent, and strict (a point exactly on
it is outside). `remove` applies to band points only. `add` comes after it:

- `cloud` puts the cloud's points in a box back, at any height, on top of the
  band. Points the band already holds are counted twice; for the Ming-Da board
  (z 2.0-2.4 against a band top of 2.13) that is how the lane was fitted.
- `line` marks every cell it crosses, for an obstacle the cloud cannot resolve
  (a curb a few centimetres high). Sampled at half a cell from the first end,
  the second end excluded.

The output .npz holds `occ` (bool, indexed [ix, iy], x first), `x0`, `y0`,
`cell`, `band` and `min_points`; fit_lane_corridor.py and
check_lane_clearance.py read it.

The density matters: `min_points` assumes the full SLAM cloud. A cloud
voxel-downsampled to 0.30 m has at most a point or two per 0.1 m cell, and the
grid comes out nearly empty; the tool warns when that looks like the case.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from downsample_pcd import read_pcd  # noqa: E402


def anchor_transform(from_anchor: Path, to_anchor: Path) -> np.ndarray:
    """4x4 taking one anchored frame of a cloud into another: T_to * inv(T_from).

    Both board_anchor.yaml files must anchor the same SLAM cloud."""
    import yaml

    def t(p):
        return np.array(yaml.safe_load(Path(p).read_text())['transform_map_cloud'], float)
    return t(to_anchor) @ np.linalg.inv(t(from_anchor))


def in_box(xyz: np.ndarray, box: dict) -> np.ndarray:
    """Points strictly inside a {x, y, z: [lo, hi]} box; null or absent is open."""
    keep = np.ones(len(xyz), bool)
    for k, axis in (('x', 0), ('y', 1), ('z', 2)):
        lo, hi = (box.get(k) or [None, None])
        if lo is not None:
            keep &= xyz[:, axis] > lo
        if hi is not None:
            keep &= xyz[:, axis] < hi
    return keep


def line_points(a, b, spacing: float) -> np.ndarray:
    """Points from a toward b every `spacing`, b excluded, z 0."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    length = float(np.linalg.norm(b - a))
    t = np.arange(0.0, length, spacing)
    xy = a + (t / length)[:, None] * (b - a)
    return np.c_[xy, np.zeros(len(t))]


def build_grid(xyz: np.ndarray, edits: dict, log=print) -> dict:
    """The obstacle grid of map-frame points `xyz` under `edits`, as a dict of arrays."""
    cell = float(edits.get('cell', 0.1))
    min_points = int(edits.get('min_points', 3))
    zlo, zhi = (float(v) for v in edits['band'])
    floor = float(edits.get('floor', 0.0))
    x0, y0 = (float(v) for v in edits['origin'])
    nx, ny = (int(round(float(v) / cell)) for v in edits['size'])

    zr = xyz[:, 2] - floor
    band = xyz[(zr > zlo) & (zr < zhi)]
    log(f'{len(band)} points at {zlo}-{zhi} m above the floor')
    for e in edits.get('remove') or []:
        gone = in_box(band, e)
        band = band[~gone]
        log(f'removed {int(gone.sum())} band points: {e.get("why", "(no reason given)")}')

    # Points to count, and how many times each counts.
    pts, weight = [band], [np.ones(len(band), int)]
    for e in edits.get('add') or []:
        if 'cloud' in e:
            got = xyz[in_box(xyz, e['cloud'])]
            pts.append(got)
            weight.append(np.ones(len(got), int))
            log(f'added {len(got)} cloud points: {e.get("why", "(no reason given)")}')
        elif 'line' in e:
            got = line_points(*e['line'], cell / 2)
            pts.append(got)
            weight.append(np.full(len(got), min_points))
            log(f'added a line, {len(got)} samples: {e.get("why", "(no reason given)")}')
        else:
            raise ValueError(f'an add needs cloud or line: {e}')
    pts, weight = np.vstack(pts), np.concatenate(weight)

    ix = np.floor((pts[:, 0] - x0) / cell).astype(int)
    iy = np.floor((pts[:, 1] - y0) / cell).astype(int)
    ok = (ix >= 0) & (ix < nx) & (iy >= 0) & (iy < ny)
    cnt = np.zeros((nx, ny), int)
    np.add.at(cnt, (ix[ok], iy[ok]), weight[ok])
    occ = cnt >= min_points

    # A cloud too thin for min_points: most cells the band reaches stay free.
    seen = int((cnt > 0).sum())
    if seen and occ.sum() < 0.2 * seen:
        log(f'WARNING: only {int(occ.sum())} of the {seen} cells the band reaches hold '
            f'{min_points} points. Is this a downsampled cloud? min_points assumes the full one.')
    return dict(occ=occ, x0=x0, y0=y0, cell=cell, band=np.array([zlo, zhi]),
                min_points=min_points)


def load_grid(path) -> dict:
    g = np.load(path)
    return dict(occ=g['occ'], x0=float(g['x0']), y0=float(g['y0']), cell=float(g['cell']))


def occupied_centres(grid: dict) -> np.ndarray:
    """Map x, y of every obstacle cell's centre."""
    ij = np.argwhere(grid['occ'])
    return np.stack([grid['x0'] + (ij[:, 0] + 0.5) * grid['cell'],
                     grid['y0'] + (ij[:, 1] + 0.5) * grid['cell']], axis=1)


def main(argv=None) -> int:
    import yaml

    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('pcd', type=Path)
    ap.add_argument('edits', type=Path, help='grid parameters and hand edits, YAML')
    ap.add_argument('-o', '--output', type=Path, default=Path('obstacles.npz'))
    ap.add_argument('--from-anchor', type=Path,
                    help="board_anchor.yaml of the PCD's own frame; with --to-anchor, "
                         'moves the cloud into the frame the edits are written in')
    ap.add_argument('--to-anchor', type=Path)
    args = ap.parse_args(argv)
    if (args.from_anchor is None) != (args.to_anchor is None):
        ap.error('--from-anchor and --to-anchor go together')

    pts, fields = read_pcd(args.pcd)
    if fields[:3] != ['x', 'y', 'z']:
        raise ValueError(f'{args.pcd}: expected x y z first, got {fields}')
    xyz = pts[:, :3].astype(np.float64)
    if args.from_anchor:
        d = anchor_transform(args.from_anchor, args.to_anchor)
        xyz = xyz @ d[:3, :3].T + d[:3, 3]
    grid = build_grid(xyz, yaml.safe_load(args.edits.read_text()),
                      log=lambda m: print(m, file=sys.stderr))
    np.savez(args.output, **grid)
    print(f'{int(grid["occ"].sum())} obstacle cells, wrote {args.output}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
