#!/usr/bin/env python3
"""Shrink a point cloud map by voxel-centroid downsampling, for NDT.

    python3 scripts/map/downsample_pcd.py IN.pcd OUT.pcd --leaf 0.3

Every occupied LEAF-sized cube becomes one point, the mean of its points in
every field (intensity included). Binary PCDs with 4-byte float fields only,
which is what the map tools here write; anything else is refused rather than
misread.

Why 0.3 m for the basement (2026-10-22). cuda_ndt grids the map in 2.0 m
voxels and keeps those with >= 6 points; the 4.0 M-point basement cloud has a
median of 1787 per voxel, so nearly all of it is redundant. Replaying both
2026-09-24 drives (clockwise loop, and counter-clockwise with reversing) from
a board start, against the full map and against 0.30 m (63 k points, 1.0 MB,
64x smaller): never lost, 6.3-6.6 cm p95 and 9.1 cm max from the full-map
poses, 0.13 deg yaw p95, at most 3 iterations per scan where the full map hit
the 30 cap, and NVTL >= 2.55 against the 1.3 gate. 0.50 m tracked too, at
10.2 cm p95 and 13.5 cm max. Those runs held the bag still while localization
initialized, as the cart is parked at the board then; with the bag rolling
through a 10 s align, coarser maps did not recover from the stale start.

NVTL rises as the map thins (p5 2.34 full, 2.63 at 0.30), so a gate derived
on one map does not transfer to another: re-check it against the new map.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np


def read_pcd(path) -> tuple[np.ndarray, list[str]]:
    """Points (N x fields, float32) and field names of a binary float PCD."""
    with open(path, 'rb') as f:
        header = {}
        while True:
            line = f.readline()
            if not line:
                raise ValueError(f'{path}: no DATA line')
            text = line.decode('ascii', 'replace').strip()
            if not text or text.startswith('#'):
                continue
            key, _, value = text.partition(' ')
            header[key] = value.split()
            if key == 'DATA':
                break
        fields = header['FIELDS']
        if header['DATA'] != ['binary']:
            raise ValueError(f'{path}: DATA {header["DATA"][0]}, only binary is supported')
        if set(header['TYPE']) != {'F'} or set(header['SIZE']) != {'4'} \
                or set(header.get('COUNT', ['1'])) != {'1'}:
            raise ValueError(f'{path}: only single 4-byte float fields are supported')
        n = int(header['POINTS'][0])
        data = np.frombuffer(f.read(n * 4 * len(fields)), dtype='<f4')
    if data.size != n * len(fields):
        raise ValueError(f'{path}: truncated, {data.size} of {n * len(fields)} values')
    return data.reshape(n, len(fields)).copy(), fields


def write_pcd(path, pts: np.ndarray, fields: list[str]) -> None:
    pts = np.ascontiguousarray(pts, dtype='<f4')
    k, n = len(fields), len(pts)
    head = ('# .PCD v0.7 - Point Cloud Data file format\nVERSION 0.7\n'
            f'FIELDS {" ".join(fields)}\nSIZE {" ".join(["4"] * k)}\n'
            f'TYPE {" ".join(["F"] * k)}\nCOUNT {" ".join(["1"] * k)}\n'
            f'WIDTH {n}\nHEIGHT 1\nVIEWPOINT 0 0 0 1 0 0 0\nPOINTS {n}\nDATA binary\n')
    with open(path, 'wb') as f:
        f.write(head.encode('ascii'))
        f.write(pts.tobytes())


def voxel_downsample(pts: np.ndarray, leaf: float) -> np.ndarray:
    """One point per occupied leaf cube: the mean of every field. x y z first."""
    keys = np.floor(pts[:, :3].astype(np.float64) / leaf).astype(np.int64)
    _, inv, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    inv = inv.ravel()
    out = np.empty((len(counts), pts.shape[1]), dtype=np.float64)
    for c in range(pts.shape[1]):
        out[:, c] = np.bincount(inv, weights=pts[:, c].astype(np.float64), minlength=len(counts)) / counts
    return out.astype(np.float32)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('input', type=Path)
    ap.add_argument('output', type=Path)
    ap.add_argument('--leaf', type=float, default=0.3, help='voxel edge, m (default 0.3)')
    args = ap.parse_args(argv)
    if args.output.resolve() == args.input.resolve():
        ap.error('output must not be the input; keep the full map')
    pts, fields = read_pcd(args.input)
    if fields[:3] != ['x', 'y', 'z']:
        ap.error(f'expected x y z first, got {fields}')
    out = voxel_downsample(pts, args.leaf)
    write_pcd(args.output, out, fields)
    print(f'{args.input}: {len(pts)} points -> {args.output}: {len(out)} points '
          f'at {args.leaf} m ({args.output.stat().st_size / 1e6:.1f} MB)', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
