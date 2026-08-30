#!/usr/bin/env python3
# Copyright 2026 Golf Cart Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Score NDT replays against an external reference trajectory.

    python3 scripts/localization/compare_to_reference.py \\
        --reference data/tiers/road01_reference_poses_kitti.txt \\
        --reference-bag data/tiers/road01_os0 \\
        --reference-topic /sensing/lidar/os0/pointcloud_raw \\
        <run_dir> [<run_dir> ...]

Companion to fov_study_report.py, which scores each run against a full-FOV run of
the same pipeline. That comparison silently breaks when the reference run is
itself handicapped -- on the TIERS data the full-FOV run passes every point
through a Python filter and drops to 5 Hz, while the restricted runs keep 10 Hz
because they publish less. The "baseline" then has fewer, worse-conditioned poses
than the runs being measured against it, and the deviation column measures the
wrong thing in the wrong direction.

An external reference has neither problem. Here it is the KISS-ICP trajectory the
prior map was built from, so NDT localizing against that map should reproduce it;
divergence from it is real divergence rather than an artifact of the harness.

It is not ground truth either -- it is LiDAR odometry, it drifts, and the map
inherits that drift. What it does give is a fixed yardstick that every run is
measured against identically.

The reference has one pose per cloud in the source bag, so the bag supplies the
timestamps that turn pose indices into times.
"""

from __future__ import annotations

import argparse
import bisect
import math
import sys
from pathlib import Path

import numpy as np


def percentile(values, q):
    if not values:
        return float("nan")
    s = sorted(values)
    return s[min(int(q * (len(s) - 1) + 0.5), len(s) - 1)]


def yaw_of_matrix(R: np.ndarray) -> float:
    return math.atan2(R[1, 0], R[0, 0])


def yaw_of_quat(q) -> float:
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y),
                      1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def find_bag(run_dir: Path) -> Path:
    cands = [d for d in run_dir.iterdir()
             if d.is_dir() and list(d.glob("*.db3")) + list(d.glob("*.mcap"))]
    if not cands:
        raise FileNotFoundError(f"no recorded bag under {run_dir}")
    return sorted(cands)[-1]


def open_reader(uri: Path):
    import rosbag2_py
    reader = rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=str(uri), storage_id=""),
                rosbag2_py.ConverterOptions("", ""))
    return reader


def reference_track(poses_file: Path, bag: Path, topic: str):
    """Pair each reference pose with the timestamp of the cloud it came from."""
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    raw = np.loadtxt(poses_file)
    if raw.ndim == 1:
        raw = raw[None, :]
    mats = raw.reshape(-1, 3, 4)

    reader = open_reader(bag)
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    stamps = []
    while reader.has_next():
        t, data, _ = reader.read_next()
        if t != topic:
            continue
        msg = deserialize_message(data, get_message(types[t]))
        stamps.append(msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9)

    n = min(len(stamps), mats.shape[0])
    if n == 0:
        raise ValueError(f"no {topic} in {bag}")
    return [(stamps[i], mats[i][0, 3], mats[i][1, 3], yaw_of_matrix(mats[i][:, :3]))
            for i in range(n)]


def run_track(run_dir: Path, topic: str = "/localization/pose_estimator/pose"):
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    reader = open_reader(find_bag(run_dir))
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    out = []
    while reader.has_next():
        t, data, _ = reader.read_next()
        if t != topic:
            continue
        msg = deserialize_message(data, get_message(types[t]))
        # PoseStamped carries `pose`; PoseWithCovarianceStamped nests it one
        # level deeper. Accepting both is what lets the same tool score the
        # matcher's own output and the fused estimate the vehicle drives on.
        p = msg.pose.pose if hasattr(msg.pose, "pose") else msg.pose
        out.append((msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9,
                    p.position.x, p.position.y, yaw_of_quat(p.orientation)))
    out.sort(key=lambda r: r[0])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reference", type=Path, required=True)
    ap.add_argument("--reference-bag", type=Path, required=True)
    ap.add_argument("--reference-topic", required=True)
    ap.add_argument("--tolerance", type=float, default=0.06,
                    help="seconds; a pose with no reference sample this close is skipped")
    ap.add_argument("--topic", default="/localization/pose_estimator/pose",
                    help="pose topic to score. The default is the matcher's own "
                         "output; pass the fusion filter's topic to score what "
                         "the vehicle actually drives on.")
    ap.add_argument("runs", type=Path, nargs="+")
    args = ap.parse_args()

    ref = reference_track(args.reference, args.reference_bag, args.reference_topic)
    ref_times = [r[0] for r in ref]
    ref_path = sum(math.dist(a[1:3], b[1:3]) for a, b in zip(ref, ref[1:]))
    print(f"\nreference: {len(ref)} poses, {ref_path:.1f} m "
          f"({args.reference.name})")

    header = (f"{'run':<16}{'poses':>7}{'matched':>9}{'path m':>9}"
              f"{'err50':>9}{'err95':>9}{'errmax':>9}{'yaw95':>9}")
    print(header)
    print("-" * len(header))

    for run_dir in args.runs:
        try:
            track = run_track(run_dir, args.topic)
        except FileNotFoundError as exc:
            print(f"{run_dir.name:<16}  {exc}")
            continue
        if len(track) < 20:
            print(f"{run_dir.name:<16}{len(track):>7}   did not localize")
            continue

        errs, yaw_errs = [], []
        for t, x, y, yaw in track:
            i = bisect.bisect_left(ref_times, t)
            best = None
            for j in (i - 1, i):
                if 0 <= j < len(ref_times) and abs(ref_times[j] - t) <= args.tolerance:
                    if best is None or abs(ref_times[j] - t) < abs(ref_times[best] - t):
                        best = j
            if best is None:
                continue
            errs.append(math.hypot(x - ref[best][1], y - ref[best][2]))
            d = yaw - ref[best][3]
            yaw_errs.append(abs(math.degrees(math.atan2(math.sin(d), math.cos(d)))))

        path = sum(math.dist(a[1:3], b[1:3]) for a, b in zip(track, track[1:]))
        if not errs:
            print(f"{run_dir.name:<16}{len(track):>7}{0:>9}{path:>9.1f}"
                  f"   no timestamp overlap with the reference")
            continue
        print(f"{run_dir.name:<16}{len(track):>7}{len(errs):>9}{path:>9.1f}"
              f"{percentile(errs, .5):>9.3f}{percentile(errs, .95):>9.3f}"
              f"{max(errs):>9.3f}{percentile(yaw_errs, .95):>9.2f}")

    print("\n  err = distance to the reference trajectory at the same stamp."
          "\n  The reference is LiDAR odometry, not ground truth: it drifts, and the"
          "\n  map was built from it, so this measures agreement with the map's own"
          "\n  frame rather than absolute accuracy. Every run is measured the same"
          "\n  way, which is the point."
          "\n  `path` against the reference's own length is the quickest tell: a run"
          "\n  reporting far more path than the reference travelled is wandering.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
