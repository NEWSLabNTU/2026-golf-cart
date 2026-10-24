#!/usr/bin/env python3
r"""Board detection rate against range and bearing, from a drive and its NDT track.

    PYTHONNOUSERSITE=1 python3 scripts/localization/board_range_report.py \\
        rosbags/indoor-2026-09-24/clockwise-vlp32 --poses REC_BAG \\
        --csv out.csv [--mode raw|deskew] [--accumulate 10] [--range-max 18]

Phase 8, L10. Runs the board detector exactly as board_detector_node does
(reflective_pose_core.detect_board on N stacked scans, judged by
reflective_pose_ros.decision.judge with the scenario's min_confidence) over
every batch of a bag's VLP-32C scans, and scores each batch against where the
board must have been: the cart pose comes from a replay's NDT track
(--poses, a rosbag2 directory holding
/localization/pose_estimator/pose_with_covariance, or a CSV of
t,x,y,z,qx,qy,qz,qw), the board from the scenario's pose_in_map.

Two ways to stack N scans, because the loop bags were driven:

- ``raw``: the scans as they arrive, in the sensor frame, which is what the
  node does. A moving cart smears the board over N scans, so this measures
  the node on a moving cart, not the board's visibility.
- ``deskew``: each scan moved into the last scan's sensor frame through the
  NDT poses before stacking. The board is then as sharp as from a parked cart,
  so this approximates "would a cart parked here detect it". It is optimistic
  in one way: ten scans from ten slightly different places sample more of the
  board's rows than ten scans from one place.

Each batch is classified against the board's expected centre (within
--match-m): detected, low_conf, ambiguous (board among several survivors),
wrong (a pose published, but not of this board), rej:<gate> (the board's
cluster was rejected by that gate), few_points (fewer retro points near the
board than cluster_min_points), out_of_range (expected centre outside the
range gate) and behind (the sensor is behind the board's plane).

Range is from the sensor to the board centre, 3-D. Bearing is the board's
direction from base_link, 0 dead ahead, positive left. Aspect is the sensor's
direction seen from the board, 0 on its normal.
"""

from __future__ import annotations

import argparse
import csv
import math
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Sequence, Tuple

import numpy as np

REPO = Path(__file__).resolve().parents[2]
SCENARIO = (REPO / 'src/launcher/golfcart_launch/config/localization/reflective_pose'
            / 'scenarios/basement/detector.yaml')
POSE_TOPIC = '/localization/pose_estimator/pose_with_covariance'
CLOUD_TOPIC = '/sensing/lidar/vlp32/velodyne_points'
# base_link <- velodyne, sensors_calibration.yaml (sensor_kit_base_link is at
# the VLP-32C origin). x y z roll pitch yaw.
BASE_FROM_SENSOR = (0.46, 0.0, 1.966, -0.016794, 0.031978, -0.0305)
OUTCOMES = ('detected', 'low_conf', 'ambiguous', 'wrong', 'rej:*', 'few_points',
            'out_of_range', 'behind')


# -- geometry (pure) -------------------------------------------------------------


def rpy_matrix(roll: float, pitch: float, yaw: float) -> np.ndarray:
    """Rz(yaw) Ry(pitch) Rx(roll), tf2's setRPY."""
    cr, sr, cp, sp, cy, sy = (math.cos(roll), math.sin(roll), math.cos(pitch),
                              math.sin(pitch), math.cos(yaw), math.sin(yaw))
    return np.array([[cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr],
                     [sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr],
                     [-sp, cp * sr, cp * cr]])


def transform(xyz: Sequence[float], rotation: np.ndarray) -> np.ndarray:
    out = np.eye(4)
    out[:3, :3] = rotation
    out[:3, 3] = xyz
    return out


def quat_matrix(q: Sequence[float]) -> np.ndarray:
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


class PoseTrack:
    """map <- base_link at any time inside the track: linear in position,
    normalised-linear in quaternion between the two neighbours."""

    def __init__(self, t: np.ndarray, xyz: np.ndarray, quat: np.ndarray, max_gap: float = 0.5):
        order = np.argsort(t)
        self.t, self.xyz, self.quat = t[order], xyz[order], quat[order]
        self.max_gap = max_gap

    def at(self, t: float) -> Optional[np.ndarray]:
        i = int(np.searchsorted(self.t, t))
        if i == 0 or i >= len(self.t):
            return None
        t0, t1 = self.t[i - 1], self.t[i]
        if t1 - t0 > self.max_gap:
            return None
        a = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
        q0, q1 = self.quat[i - 1], self.quat[i]
        if float(np.dot(q0, q1)) < 0:
            q1 = -q1
        q = (1 - a) * q0 + a * q1
        return transform((1 - a) * self.xyz[i - 1] + a * self.xyz[i], quat_matrix(q))


def board_geometry(map_from_base: np.ndarray, base_from_sensor: np.ndarray,
                   board_xyz: Sequence[float], board_yaw: float = 0.0) -> Dict[str, float]:
    """Range (sensor to board centre, 3-D), bearing (from base_link, deg, +left)
    and aspect (sensor seen from the board's normal, deg) of the board."""
    board = np.asarray(board_xyz, dtype=float)
    map_from_sensor = map_from_base @ base_from_sensor
    sensor = map_from_sensor[:3, 3]
    in_base = np.linalg.inv(map_from_base) @ np.append(board, 1.0)
    rel = sensor[:2] - board[:2]
    aspect = math.degrees(math.atan2(rel[1], rel[0]) - board_yaw)
    aspect = (aspect + 180.0) % 360.0 - 180.0
    return {
        'range': float(np.linalg.norm(sensor - board)),
        'bearing': math.degrees(math.atan2(in_base[1], in_base[0])),
        'aspect': aspect,
        'sensor_x': float(sensor[0]), 'sensor_y': float(sensor[1]),
    }


def classify(result, expected_in_sensor: np.ndarray, min_confidence: float,
             retro_near: int, cluster_min_points: int, in_range: bool, behind: bool,
             match_m: float = 1.0) -> str:
    """One batch's outcome for THE board (see the module docstring)."""
    def near(c) -> bool:
        return float(np.linalg.norm(np.asarray(c)[:3] - expected_in_sensor)) <= match_m
    status = getattr(result.status, 'value', str(result.status))
    if status == 'ok':
        d = result.detection
        if near(d.centre):
            return 'detected' if d.confidence >= min_confidence else 'low_conf'
        return 'wrong'
    if status == 'ambiguous':
        if any(near(c.centre) for c in result.candidates):
            return 'ambiguous'
    for rej in result.rejections:
        if near(rej.centroid):
            return f'rej:{rej.reason}'
    if behind:
        return 'behind'
    if not in_range:
        return 'out_of_range'
    if retro_near < cluster_min_points:
        return 'few_points'
    return 'rej:unclustered'


def table(rows: List[dict], key: str, edges: Sequence[float], label: str) -> str:
    """Detection rate per bin of rows[key], with the outcome mix."""
    bins: Dict[int, Counter] = defaultdict(Counter)
    pts: Dict[int, List[int]] = defaultdict(list)
    for r in rows:
        v = r[key]
        for i in range(len(edges) - 1):
            if edges[i] <= v < edges[i + 1]:
                bins[i][r['outcome']] += 1
                pts[i].append(r['retro_near'])
                break
    lines = [f'| {label} | batches | detected | rate | retro pts near board (median) | other outcomes |',
             '|---|---|---|---|---|---|']
    for i in range(len(edges) - 1):
        c = bins.get(i)
        if not c:
            continue
        n = sum(c.values())
        det = c.get('detected', 0)
        rest = ', '.join(f'{k} {v}' for k, v in c.most_common() if k != 'detected')
        lines.append(f'| {edges[i]:g}-{edges[i + 1]:g} | {n} | {det} | {100.0 * det / n:.0f} % | '
                     f'{int(np.median(pts[i]))} | {rest or "-"} |')
    return '\n'.join(lines)


# -- bags -------------------------------------------------------------------------


def _reader(path: str, topics: Sequence[str]):
    import rosbag2_py
    storage = 'sqlite3'
    meta = os.path.join(path, 'metadata.yaml')
    if os.path.isfile(meta):
        for line in open(meta):
            if 'storage_identifier' in line:
                storage = line.split(':', 1)[1].strip()
    reader = rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=path, storage_id=storage),
                rosbag2_py.ConverterOptions('', ''))
    reader.set_filter(rosbag2_py.StorageFilter(topics=list(topics)))
    return reader


def load_poses(path: str, topic: str = POSE_TOPIC) -> PoseTrack:
    if path.endswith('.csv'):
        a = np.loadtxt(path, delimiter=',', skiprows=1)
        return PoseTrack(a[:, 0], a[:, 1:4], a[:, 4:8])
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message
    reader = _reader(path, [topic])
    kinds = {t.name: t.type for t in reader.get_all_topics_and_types()}
    if topic not in kinds:
        raise SystemExit(f'{topic} not in {path}')
    cls = get_message(kinds[topic])
    t, xyz, quat = [], [], []
    while reader.has_next():
        _, data, _ = reader.read_next()
        m = deserialize_message(data, cls)
        p = m.pose.pose if hasattr(m.pose, 'pose') else m.pose
        t.append(m.header.stamp.sec + 1e-9 * m.header.stamp.nanosec)
        xyz.append([p.position.x, p.position.y, p.position.z])
        o = p.orientation
        quat.append([o.x, o.y, o.z, o.w])
    if not t:
        raise SystemExit(f'no poses on {topic} in {path}')
    return PoseTrack(np.array(t), np.array(xyz), np.array(quat))


_NUMPY = {1: np.int8, 2: np.uint8, 3: np.int16, 4: np.uint16, 5: np.int32, 6: np.uint32,
          7: np.float32, 8: np.float64}


def cloud_arrays(msg, min_intensity: float) -> Tuple[np.ndarray, np.ndarray]:
    """(points, intensity) of the points at or above min_intensity. The
    detector gates on intensity first, so dropping the rest here changes
    nothing but the cost."""
    names = {f.name: f for f in msg.fields}
    dtype = np.dtype({'names': ['x', 'y', 'z', 'i'],
                      'formats': [_NUMPY[names[n].datatype] for n in ('x', 'y', 'z', 'intensity')],
                      'offsets': [names[n].offset for n in ('x', 'y', 'z', 'intensity')],
                      'itemsize': msg.point_step})
    a = np.frombuffer(bytes(msg.data), dtype=dtype, count=msg.width * msg.height)
    keep = a['i'].astype(np.float64) >= min_intensity
    a = a[keep]
    pts = np.column_stack([a['x'], a['y'], a['z']]).astype(np.float64)
    finite = np.isfinite(pts).all(axis=1)
    return pts[finite], a['i'].astype(np.float64)[finite]


def iterate_scans(path: str, topic: str, min_intensity: float
                  ) -> Iterator[Tuple[float, np.ndarray, np.ndarray]]:
    from rclpy.serialization import deserialize_message
    from sensor_msgs.msg import PointCloud2
    reader = _reader(path, [topic])
    while reader.has_next():
        _, data, t_ns = reader.read_next()
        msg = deserialize_message(data, PointCloud2)
        t = msg.header.stamp.sec + 1e-9 * msg.header.stamp.nanosec or t_ns * 1e-9
        pts, inten = cloud_arrays(msg, min_intensity)
        yield t, pts, inten


# -- main -------------------------------------------------------------------------


def run(args) -> List[dict]:
    from reflective_pose_core.config import load_config
    from reflective_pose_core.detector import detect_board
    from reflective_pose_core.geometry import matrix_from_euler_rpy

    config = load_config(args.config, scan_count=args.accumulate)
    params = config.runtime_detector
    if args.range_max is not None:
        params.range_max = args.range_max
    min_conf = float(params.min_confidence)
    height_offset = float(config.detector.runtime.base_link_height_above_ground)
    bp = list(config.board.pose_in_map)
    board_xyz, board_yaw = bp[:3], bp[5]
    board_map = transform(board_xyz, matrix_from_euler_rpy(bp[3:6]))
    x, y, z, r, p, yw = args.base_from_sensor
    base_from_sensor = transform((x, y, z), rpy_matrix(r, p, yw))
    track = load_poses(args.poses)

    rows: List[dict] = []
    batch: List[Tuple[float, np.ndarray, np.ndarray]] = []
    for t, pts, inten in iterate_scans(args.bag, args.topic, params.intensity_threshold):
        batch.append((t, pts, inten))
        if len(batch) < args.accumulate:
            continue
        stamps = [b[0] for b in batch]
        last = track.at(stamps[-1])
        poses = [track.at(s) for s in stamps]
        if last is None or (args.mode == 'deskew' and any(q is None for q in poses)):
            batch = []
            continue
        sensor_last_inv = np.linalg.inv(last @ base_from_sensor)
        clouds = []
        for (s, pp, ii), pose in zip(batch, poses):
            if args.mode == 'deskew':
                m = sensor_last_inv @ pose @ base_from_sensor
                pp = pp @ m[:3, :3].T + m[:3, 3]
            clouds.append(pp)
        points = np.vstack(clouds) if clouds else np.zeros((0, 3))
        intensity = np.concatenate([b[2] for b in batch]) if batch else np.zeros(0)
        result = detect_board(points, intensity, base_from_sensor, params,
                              height_offset=height_offset)
        expected = (sensor_last_inv @ board_map)[:3, 3]
        geo = board_geometry(last, base_from_sensor, board_xyz, board_yaw)
        retro_near = int((np.linalg.norm(points - expected, axis=1) <= 0.6).sum())
        rng = float(np.linalg.norm(expected))
        in_range = params.range_min <= rng <= params.range_max
        behind = abs(geo['aspect']) >= 90.0
        outcome = classify(result, expected, min_conf, retro_near, params.cluster_min_points,
                           in_range, behind, args.match_m)
        d = result.detection
        if d is not None:
            dm = (last @ base_from_sensor @ np.append(np.asarray(d.centre, dtype=float), 1.0))[:3]
        rows.append({
            't': round(stamps[-1], 3), **{k: round(v, 3) for k, v in geo.items()},
            'outcome': outcome, 'retro_near': retro_near,
            'det_range': round(d.range_m, 3) if d is not None else '',
            'confidence': round(d.confidence, 3) if d is not None else '',
            'det_err_m': (round(float(np.linalg.norm(np.asarray(d.centre) - expected)), 3)
                          if d is not None else ''),
            # Where the published centre is in the map: a 'wrong' row names
            # the reflector that was taken for the board.
            'det_map_x': round(float(dm[0]), 2) if d is not None else '',
            'det_map_y': round(float(dm[1]), 2) if d is not None else '',
            'det_map_z': round(float(dm[2]), 2) if d is not None else '',
        })
        batch = []
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('bag', help='rosbag2 directory with the VLP-32C cloud')
    ap.add_argument('--poses', required=True,
                    help='rosbag2 directory with the NDT pose, or a t,x,y,z,qx,qy,qz,qw CSV')
    ap.add_argument('--topic', default=CLOUD_TOPIC)
    ap.add_argument('--config', default=str(SCENARIO), help='scenario detector.yaml')
    ap.add_argument('--accumulate', type=int, default=10,
                    help='scans per batch [10, board_detector.param.yaml]')
    ap.add_argument('--mode', choices=('raw', 'deskew'), default='deskew')
    ap.add_argument('--range-max', type=float, help="override the scenario's range gate")
    ap.add_argument('--match-m', type=float, default=1.0)
    ap.add_argument('--base-from-sensor', type=float, nargs=6, default=BASE_FROM_SENSOR,
                    metavar=('X', 'Y', 'Z', 'ROLL', 'PITCH', 'YAW'))
    ap.add_argument('--csv', help='write one row per batch')
    args = ap.parse_args(argv)

    rows = run(args)
    if args.csv:
        with open(args.csv, 'w', newline='') as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    print(f'{args.bag}: {len(rows)} batches of {args.accumulate}, mode {args.mode}\n')
    print(table(rows, 'range', list(range(0, 31, 2)), 'range m'))
    print()
    front = [r for r in rows if abs(r['aspect']) < 90]
    print(table(front, 'bearing', list(range(-180, 181, 30)), 'bearing deg (+left)'))
    print()
    print(table(front, 'aspect', list(range(-90, 91, 15)), 'aspect deg'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
