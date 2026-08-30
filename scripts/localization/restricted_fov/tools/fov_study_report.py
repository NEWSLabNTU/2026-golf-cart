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

"""Score restricted-field-of-view NDT replays against a full-FOV baseline.

    python3 scripts/localization/fov_study_report.py \\
        --baseline .../logs/fov_study/baseline_360 \\
        .../logs/fov_study/fwd_120 .../logs/fov_study/fwd_090

Reads the bags `scripts/fov_study.sh` recorded, so it works after the fact and
does not need a stack running. Companion to ndt_quality_report.py, which does the
same job live and against `/localization/kinematic_state`.

Two differences from that script, both deliberate:

**It reads `/localization/pose_estimator/pose`, not the kinematic state.** The
question here is what the scan matcher does with less input, and the kinematic
state is the EKF's fusion of that with IMU and wheel odometry. On a restricted
FOV the EKF is exactly the thing that would hide the degradation being measured.

**It reports deviation from a baseline run.** Scatter and yaw step catch an
estimator that is visibly unstable, but a narrowed FOV can also fail by sliding
smoothly along a wall -- low scatter, low yaw step, steadily wrong. The full-FOV
run over the same bag is the reference, and lateral drift away from it is the
metric that sees that failure. It is not ground truth; it is "what this same
matcher concluded when it could see everything".
"""

from __future__ import annotations

import argparse
import bisect
import math
import statistics
import sys
from pathlib import Path


def percentile(values, q):
    if not values:
        return float("nan")
    s = sorted(values)
    k = min(int(q * (len(s) - 1) + 0.5), len(s) - 1)
    return s[k]


def yaw_of(q) -> float:
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y),
                      1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def find_bag(run_dir: Path) -> Path:
    """A run directory holds one recorded bag under a timestamped name."""
    candidates = [d for d in run_dir.iterdir()
                  if d.is_dir() and list(d.glob("*.db3")) + list(d.glob("*.mcap"))]
    if not candidates:
        raise FileNotFoundError(f"no recorded bag under {run_dir}")
    return sorted(candidates)[-1]


def read_run(run_dir: Path):
    """Return (poses, scalars) for one run directory.

    poses is a list of (t, x, y, yaw); scalars maps topic basename to values.
    """
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    bag = find_bag(run_dir)
    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=str(bag), storage_id=""),
        rosbag2_py.ConverterOptions("", ""),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}

    poses = []
    scalars: dict[str, list[float]] = {}
    wanted_scalars = {
        "/localization/pose_estimator/exe_time_ms": "exe_time_ms",
        "/localization/pose_estimator/iteration_num": "iteration_num",
        "/localization/pose_estimator/initial_to_result_distance": "init_to_result",
        "/localization/pose_estimator/nearest_voxel_transformation_likelihood": "nvtl",
        "/localization/pose_estimator/transform_probability": "tp",
    }

    while reader.has_next():
        topic, data, _ = reader.read_next()
        if topic == "/localization/pose_estimator/pose":
            msg = deserialize_message(data, get_message(types[topic]))
            t = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
            p = msg.pose
            poses.append((t, p.position.x, p.position.y, yaw_of(p.orientation)))
        elif topic in wanted_scalars:
            msg = deserialize_message(data, get_message(types[topic]))
            scalars.setdefault(wanted_scalars[topic], []).append(float(msg.data))

    poses.sort(key=lambda r: r[0])
    return poses, scalars


def self_metrics(poses):
    """Scatter and yaw step, defined exactly as in ndt_quality_report.py."""
    window = 5
    scatter, yaw_steps = [], []
    for i in range(window, len(poses) - window):
        xs = [p[1] for p in poses[i - window:i + window + 1]]
        ys = [p[2] for p in poses[i - window:i + window + 1]]
        scatter.append(math.hypot(poses[i][1] - statistics.fmean(xs),
                                  poses[i][2] - statistics.fmean(ys)))
    for a, b in zip(poses, poses[1:]):
        d = b[3] - a[3]
        yaw_steps.append(abs(math.degrees(math.atan2(math.sin(d), math.cos(d)))))
    path = sum(math.dist(a[1:3], b[1:3]) for a, b in zip(poses, poses[1:]))
    return scatter, yaw_steps, path


def deviation_from(baseline, poses, tol=0.05):
    """Position and heading deviation at matched timestamps.

    Both runs replay the same bag with `use_sim_time`, so stamps are directly
    comparable. Poses with no baseline sample within `tol` are skipped rather
    than interpolated across a gap -- a run that lost frames must not have its
    error smoothed over the hole where it was failing.
    """
    times = [p[0] for p in baseline]
    dpos, dyaw = [], []
    for t, x, y, yaw in poses:
        i = bisect.bisect_left(times, t)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(times) and abs(times[j] - t) <= tol:
                if best is None or abs(times[j] - t) < abs(times[best] - t):
                    best = j
        if best is None:
            continue
        _, bx, by, byaw = baseline[best]
        dpos.append(math.hypot(x - bx, y - by))
        d = yaw - byaw
        dyaw.append(abs(math.degrees(math.atan2(math.sin(d), math.cos(d)))))
    return dpos, dyaw


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--baseline", type=Path, required=True,
                    help="run directory of the full-FOV reference")
    ap.add_argument("runs", type=Path, nargs="+", help="restricted run directories")
    args = ap.parse_args()

    base_poses, _ = read_run(args.baseline)
    if len(base_poses) < 20:
        print(f"baseline has only {len(base_poses)} poses; it did not localize.",
              file=sys.stderr)
        return 1

    header = (f"{'run':<16}{'poses':>7}{'path m':>9}{'scatter95':>11}"
              f"{'yaw95':>8}{'dev50':>8}{'dev95':>8}{'dyaw95':>8}"
              f"{'nvtl50':>8}{'iter50':>8}{'exe50':>8}")
    print(f"\nNDT under restricted FOV — baseline {args.baseline.name}")
    print(header)
    print("-" * len(header))

    for run_dir in [args.baseline] + list(args.runs):
        poses, scalars = read_run(run_dir)
        if len(poses) < 20:
            print(f"{run_dir.name:<16}{len(poses):>7}   did not localize")
            continue
        scatter, yaw_steps, path = self_metrics(poses)
        if run_dir == args.baseline:
            dpos, dyaw = [0.0], [0.0]
        else:
            dpos, dyaw = deviation_from(base_poses, poses)
            if not dpos:
                dpos, dyaw = [float("nan")], [float("nan")]
        print(f"{run_dir.name:<16}{len(poses):>7}{path:>9.1f}"
              f"{percentile(scatter, .95):>11.3f}{percentile(yaw_steps, .95):>8.3f}"
              f"{percentile(dpos, .5):>8.3f}{percentile(dpos, .95):>8.3f}"
              f"{percentile(dyaw, .95):>8.3f}"
              f"{percentile(scalars.get('nvtl', []), .5):>8.2f}"
              f"{percentile(scalars.get('iteration_num', []), .5):>8.1f}"
              f"{percentile(scalars.get('exe_time_ms', []), .5):>8.1f}")

    print("\n  dev = distance from the baseline run's pose at the same stamp. It is"
          "\n  not ground truth, and it is the column that catches a run drifting"
          "\n  smoothly in the wrong place, which scatter and yaw step do not."
          "\n  NVTL is reported and NOT ranked on: it rises when far returns are"
          "\n  cropped away, which is precisely what every run here does.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
