#!/usr/bin/env python3
"""Top-down floor plan of a point-cloud map, for choosing a drivable route.

    PYTHONNOUSERSITE=1 python3 scripts/map/pcd_floor_plan.py \\
        data/basement-indoor/pointcloud_map.pcd -o basement_floor_plan.png

Phase 8, M1. Draws what a cart would hit (points 0.3 to 2.0 m above the local
floor) over where the floor was seen, with a metre grid in the map frame and the
map origin marked. For the basement that origin is the reflective board, the
cart's cold-start spot. Read route coordinates off it for
centerline_to_lanelet.py.

The floor is estimated per coarse cell rather than as z = 0, because the
basement has a ramp: base_link sits 0.30 m higher at the 12 m spot, so a fixed
height band would call the far end of the ramp an obstacle.

matplotlib needs PYTHONNOUSERSITE=1 on this machine: a user-site install
shadows the system one and fails to import.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np

CLEARANCE_LOW_M = 0.3    # below this above the floor: floor, curb, noise
CLEARANCE_HIGH_M = 2.0   # above this: ceiling, pipes, nothing a cart hits
FLOOR_CELL_M = 2.0       # coarse cells for the local floor estimate
MIN_HITS = 4             # points per pixel before it counts as an obstacle
EXTENT_PERCENTILE = 0.2  # crop stray points this far into each tail of x and y


def read_pcd_xyz(path: Path) -> np.ndarray:
    """x, y, z of a binary PCD whose first three fields are float32 x y z."""
    raw = Path(path).read_bytes()
    end = raw.index(b'DATA ')
    header = raw[:end].decode(errors='replace').splitlines()
    fields = dict((ln.split()[0], ln.split()[1:]) for ln in header if ln and ln[0] != '#')
    data_line_end = raw.index(b'\n', end)
    kind = raw[end + 5:data_line_end].decode().strip()
    if kind != 'binary':
        raise ValueError(f'only binary PCD is supported, this one is {kind!r}')
    if fields['FIELDS'][:3] != ['x', 'y', 'z'] or set(fields['TYPE'][:3]) != {'F'} \
            or set(fields['SIZE'][:3]) != {'4'}:
        raise ValueError('expected float32 x y z as the first three fields')
    stride = sum(int(s) * int(c) for s, c in zip(fields['SIZE'], fields['COUNT']))
    n = int(fields['POINTS'][0])
    buf = np.frombuffer(raw, dtype=np.uint8, count=n * stride, offset=data_line_end + 1)
    return buf.reshape(n, stride)[:, :12].copy().view('<f4').reshape(n, 3).astype(np.float64)


@dataclass
class Grid:
    x0: float
    y0: float
    resolution: float
    obstacle: np.ndarray   # [row = y, col = x]
    floor: np.ndarray


def obstacle_grid(xyz: np.ndarray, resolution: float = 0.1,
                  min_hits: int = MIN_HITS) -> Grid:
    """Rasterise obstacles and seen floor, relative to a per-cell floor height.

    A pixel is an obstacle only with `min_hits` points in the clearance band:
    one stray return, a GLIM ghost or a person walking past, should not close
    an aisle. Stray points far outside the building are cropped.
    """
    lo = np.percentile(xyz[:, :2], EXTENT_PERCENTILE, axis=0) - 2.0
    hi = np.percentile(xyz[:, :2], 100 - EXTENT_PERCENTILE, axis=0) + 2.0
    keep = np.all((xyz[:, :2] >= lo) & (xyz[:, :2] <= hi), axis=1)
    xyz = xyz[keep]
    x, y, z = xyz[:, 0], xyz[:, 1], xyz[:, 2]
    x0, y0 = np.floor(x.min()), np.floor(y.min())

    # Local floor: a low percentile of z per coarse cell, so ramps and a biased
    # z origin both come out as floor.
    cx = ((x - x0) // FLOOR_CELL_M).astype(int)
    cy = ((y - y0) // FLOOR_CELL_M).astype(int)
    floor_h = np.full((cy.max() + 1, cx.max() + 1), np.nan)
    order = np.lexsort((z, cx, cy))
    keys = cy[order] * (cx.max() + 1) + cx[order]
    starts = np.r_[0, np.flatnonzero(np.diff(keys)) + 1]
    counts = np.diff(np.r_[starts, len(keys)])
    pick = starts + (counts * 0.05).astype(int)
    floor_h.flat[keys[pick]] = z[order][pick]
    above = z - floor_h[cy, cx]

    gx = ((x - x0) / resolution).astype(int)
    gy = ((y - y0) / resolution).astype(int)
    shape = (gy.max() + 1, gx.max() + 1)
    hits = np.zeros(shape, np.int32)
    floor = np.zeros(shape, bool)
    hit = (above > CLEARANCE_LOW_M) & (above < CLEARANCE_HIGH_M)
    np.add.at(hits, (gy[hit], gx[hit]), 1)
    obstacle = hits >= min_hits
    floor[gy[above <= CLEARANCE_LOW_M], gx[above <= CLEARANCE_LOW_M]] = True
    return Grid(x0, y0, resolution, obstacle, floor)


def render(grid: Grid, out: Path, title: str) -> None:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    h, w = grid.obstacle.shape
    img = np.ones((h, w, 3))
    img[grid.floor] = (0.86, 0.90, 0.95)
    img[grid.obstacle] = (0.15, 0.15, 0.18)
    extent = (grid.x0, grid.x0 + w * grid.resolution, grid.y0, grid.y0 + h * grid.resolution)
    fig, ax = plt.subplots(figsize=(max(8, w * grid.resolution / 4), max(6, h * grid.resolution / 4)))
    ax.imshow(img, origin='lower', extent=extent, interpolation='nearest')
    ax.set_xticks(np.arange(np.ceil(extent[0] / 5) * 5, extent[1], 5))
    ax.set_yticks(np.arange(np.ceil(extent[2] / 5) * 5, extent[3], 5))
    ax.grid(color=(0.35, 0.55, 0.85), linewidth=0.4, alpha=0.6)
    ax.plot(0, 0, marker='o', color=(0.8, 0.2, 0.1))
    ax.annotate('map origin (board)', (0, 0), textcoords='offset points', xytext=(6, 6),
                color=(0.8, 0.2, 0.1), fontsize=9)
    ax.arrow(0, 0, 3, 0, width=0.08, color=(0.8, 0.2, 0.1), length_includes_head=True)
    ax.set_xlabel('map x (m)')
    ax.set_ylabel('map y (m)')
    ax.set_title(title)
    ax.set_aspect('equal')
    fig.tight_layout()
    fig.savefig(out, dpi=150)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('pcd', type=Path)
    ap.add_argument('-o', '--output', type=Path, default=Path('floor_plan.png'))
    ap.add_argument('--resolution', type=float, default=0.1, help='m per pixel')
    args = ap.parse_args(argv)
    grid = obstacle_grid(read_pcd_xyz(args.pcd), args.resolution)
    render(grid, args.output,
           f'{args.pcd.parent.name}: dark = 0.3 to 2.0 m above the local floor')
    print(f'wrote {args.output}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
