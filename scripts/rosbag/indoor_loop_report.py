#!/usr/bin/env python3
"""Summarise NDT tracking over a replayed drive, and draw the path on the map.

    PYTHONNOUSERSITE=1 python3 scripts/rosbag/indoor_loop_report.py \\
        log/indoor-test/loop_cw_events.jsonl log/indoor-test/loop_ccw_events.jsonl \\
        --pcd data/basement-indoor/pointcloud_map.pcd --out-dir log/indoor-test

Phase 8, L1. Reads events files written by indoor_sim_record_events.py during
`just indoor-test` replays, and reports per run:

- when localization initialized, in bag time;
- how much of the drive NDT tracked: published poses, rate, and gaps;
- implied speed between consecutive published poses, so a pose that jumps
  shows as an impossible speed rather than hiding in an average;
- the NVTL distribution against the gate the matcher loads (1.3), and how often
  the optimiser hit max_iterations (30) instead of converging.

Writes <name>_path.csv (bag time, x, y, z) per run, which is the driven path in
the map frame and therefore a route centreline candidate, and one PNG with every
run drawn over the floor plan.

What it cannot say: anything about the EKF. The 2026-09-24 loops carry no wheel
speed (the VCU was away), so these replays exercise NDT alone.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

POSE = '/localization/pose_estimator/pose_with_covariance'
NVTL = '/localization/pose_estimator/nearest_voxel_transformation_likelihood'
ITER = '/localization/pose_estimator/iteration_num'
EXE = '/localization/pose_estimator/exe_time_ms'
BOARD = '/localization/board_detector/board_pose'
NVTL_GATE = 1.3     # ndt_scan_matcher.param.yaml, converged_param_nearest_voxel_...
MAX_ITER = 30       # same file, max_iterations
GAP_S = 0.3         # three scans at 10 Hz
JUMP_MPS = 3.0      # faster than the cart is driven by hand indoors


def pct(values, q):
    v = sorted(values)
    if not v:
        return float('nan')
    k = (len(v) - 1) * q / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def load(path: Path) -> dict:
    ev: dict[str, list] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        e = json.loads(line)
        ev.setdefault(e['topic'], []).append(e)
    return ev


def summarise(name: str, ev: dict) -> tuple[dict, list]:
    poses = [(e['sim'], e['value']) for e in ev.get(POSE, [])
             if e.get('sim') is not None and e.get('value')]
    poses.sort(key=lambda p: p[0])
    nvtl = [e['value'] for e in ev.get(NVTL, []) if e.get('value') is not None]
    iters = [e['value'] for e in ev.get(ITER, []) if e.get('value') is not None]
    exe = [e['value'] for e in ev.get(EXE, []) if e.get('value') is not None]
    boards = [e for e in ev.get(BOARD, []) if e.get('value')]

    s = {'run': name, 'poses': len(poses), 'board_detections': len(boards)}
    if boards:
        s['first_board_sim'] = boards[0]['sim']
    if poses:
        t = [p[0] for p in poses]
        s['first_pose_sim'] = t[0]
        s['tracked_span_s'] = round(t[-1] - t[0], 1)
        s['rate_hz'] = round((len(t) - 1) / (t[-1] - t[0]), 2) if t[-1] > t[0] else 0
        gaps = [(b - a) for a, b in zip(t, t[1:]) if b - a > GAP_S]
        s['gaps_over_0.3s'] = len(gaps)
        s['longest_gap_s'] = round(max(gaps), 2) if gaps else 0.0
        jumps, length, speeds = [], 0.0, []
        for (ta, a), (tb, b) in zip(poses, poses[1:]):
            d = math.dist((a['x'], a['y']), (b['x'], b['y']))
            length += d
            dt = tb - ta
            if dt > 0:
                v = d / dt
                speeds.append(v)
                if v > JUMP_MPS:
                    jumps.append((round(tb, 2), round(d, 2), round(v, 1)))
        s['path_length_m'] = round(length, 1)
        s['speed_p50_mps'] = round(pct(speeds, 50), 2)
        s['speed_p99_mps'] = round(pct(speeds, 99), 2)
        s['jumps_over_3mps'] = len(jumps)
        s['worst_jumps'] = sorted(jumps, key=lambda j: -j[2])[:5]
        s['start_xy'] = (poses[0][1]['x'], poses[0][1]['y'])
        s['end_xy'] = (poses[-1][1]['x'], poses[-1][1]['y'])
        s['start_end_gap_m'] = round(math.dist(s['start_xy'], s['end_xy']), 2)
    if nvtl:
        s['nvtl_min'] = round(min(nvtl), 3)
        s['nvtl_p5'] = round(pct(nvtl, 5), 3)
        s['nvtl_p50'] = round(pct(nvtl, 50), 3)
        s['nvtl_below_gate'] = sum(v < NVTL_GATE for v in nvtl)
        s['nvtl_samples'] = len(nvtl)
    if iters:
        s['iter_p50'] = pct(iters, 50)
        s['iter_at_cap'] = sum(i >= MAX_ITER for i in iters)
    if exe:
        s['exe_ms_p50'] = round(pct(exe, 50), 2)
        s['exe_ms_p99'] = round(pct(exe, 99), 2)
    return s, poses


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('events', nargs='+', type=Path)
    ap.add_argument('--pcd', type=Path, default=Path('data/basement-indoor/pointcloud_map.pcd'))
    ap.add_argument('--out-dir', type=Path, default=Path('log/indoor-test'))
    args = ap.parse_args(argv)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    runs = []
    for path in args.events:
        name = path.stem.replace('_events', '')
        s, poses = summarise(name, load(path))
        runs.append((name, s, poses))
        print(json.dumps(s, indent=1))
        with open(args.out_dir / f'{name}_path.csv', 'w') as f:
            f.write('sim_t,x,y,z\n')
            for t, p in poses:
                f.write(f"{t},{p['x']},{p['y']},{p['z']}\n")

    if args.pcd.exists() and any(r[2] for r in runs):
        import importlib.util
        import sys
        here = Path(__file__).resolve().parents[1] / 'map' / 'pcd_floor_plan.py'
        spec = importlib.util.spec_from_file_location('pcd_floor_plan', here)
        fp = importlib.util.module_from_spec(spec)
        sys.modules['pcd_floor_plan'] = fp
        spec.loader.exec_module(fp)
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        import numpy as np

        grid = fp.obstacle_grid(fp.read_pcd_xyz(args.pcd), 0.15)
        h, w = grid.obstacle.shape
        img = np.ones((h, w, 3))
        img[grid.floor] = (0.86, 0.90, 0.95)
        img[grid.obstacle] = (0.35, 0.35, 0.38)
        extent = (grid.x0, grid.x0 + w * grid.resolution, grid.y0, grid.y0 + h * grid.resolution)
        fig, ax = plt.subplots(figsize=(9, 13))
        ax.imshow(img, origin='lower', extent=extent, interpolation='nearest')
        colors = [(0.85, 0.25, 0.1), (0.1, 0.45, 0.85), (0.2, 0.6, 0.2)]
        for (name, s, poses), c in zip(runs, colors):
            if not poses:
                continue
            xs = [p['x'] for _, p in poses]
            ys = [p['y'] for _, p in poses]
            ax.plot(xs, ys, '-', color=c, lw=1.6, label=f"{name} ({s['poses']} poses)")
            ax.plot(xs[0], ys[0], 'o', color=c, ms=7)
            ax.plot(xs[-1], ys[-1], 's', color=c, ms=7)
        ax.plot(0, 0, '*', color='k', ms=12, label='board (map origin)')
        ax.set_xlim(extent[0], extent[1])
        ax.set_ylim(extent[2], extent[3])
        ax.set_aspect('equal')
        ax.grid(alpha=0.3)
        ax.set_xlabel('map x (m)')
        ax.set_ylabel('map y (m)')
        ax.set_title('NDT-tracked path, 2026-09-24 loops (circle = start, square = end)')
        ax.legend(loc='upper left')
        fig.tight_layout()
        out = args.out_dir / 'loop_paths.png'
        fig.savefig(out, dpi=130)
        print(f'wrote {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
