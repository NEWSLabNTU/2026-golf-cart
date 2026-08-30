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

"""Find where a Nebula azimuth crop lands relative to the vehicle's heading.

    python3 scripts/localization/fov_azimuth_probe.py <run_dir> [<run_dir> ...]

`cloud_min_angle` / `cloud_max_angle` are degrees in the **sensor's** azimuth
frame. Nothing states how that frame relates to `base_link`: the mounting yaw is
in the calibration, but the rotation sense of the raw azimuth counter and the
sensor's own zero reference are Nebula and vendor conventions, and `scan_phase`
sits in between. Guessing produces a study that measures a wedge pointing
somewhere other than where it claims. So: crop to a known window, replay, and
read back which direction actually survived.

This histograms the bearing of the points NDT was fed, in `base_link`, where 0
is straight ahead and positive is to the left.

Points closer than `--min-range` are dropped. The rig's two VLP16s publish a full
360 degrees regardless of what the top sensor is cropped to, and they are capped
at 5 m, so a near-field filter is what separates the sensor under test from them.
"""

from __future__ import annotations

import argparse
import math
import sys
from collections import Counter
from pathlib import Path

TOPIC = "/localization/util/downsample/pointcloud"


def find_bag(run_dir: Path) -> Path:
    candidates = [d for d in run_dir.iterdir()
                  if d.is_dir() and list(d.glob("*.db3")) + list(d.glob("*.mcap"))]
    if not candidates:
        raise FileNotFoundError(f"no recorded bag under {run_dir}")
    return sorted(candidates)[-1]


def bearings(run_dir: Path, min_range: float, max_clouds: int):
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message
    from sensor_msgs_py import point_cloud2

    reader = rosbag2_py.SequentialReader()
    reader.open(
        rosbag2_py.StorageOptions(uri=str(find_bag(run_dir)), storage_id=""),
        rosbag2_py.ConverterOptions("", ""),
    )
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    if TOPIC not in types:
        raise KeyError(f"{run_dir} has no {TOPIC}")

    out, seen = [], 0
    while reader.has_next() and seen < max_clouds:
        topic, data, _ = reader.read_next()
        if topic != TOPIC:
            continue
        seen += 1
        msg = deserialize_message(data, get_message(types[topic]))
        for x, y in point_cloud2.read_points(
                msg, field_names=["x", "y"], skip_nans=True):
            if math.hypot(x, y) < min_range:
                continue
            out.append(math.degrees(math.atan2(y, x)))
    return out, seen


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", type=Path, nargs="+")
    ap.add_argument("--min-range", type=float, default=6.0,
                    help="drop points nearer than this, to exclude the 5 m VLP16s")
    ap.add_argument("--clouds", type=int, default=20,
                    help="how many clouds to read from each run")
    ap.add_argument("--bins", type=int, default=24)
    args = ap.parse_args()

    for run_dir in args.runs:
        try:
            angles, n_clouds = bearings(run_dir, args.min_range, args.clouds)
        except (FileNotFoundError, KeyError) as exc:
            print(f"{run_dir.name}: {exc}", file=sys.stderr)
            continue
        if not angles:
            print(f"{run_dir.name}: no points beyond {args.min_range} m")
            continue

        width = 360.0 / args.bins
        hist = Counter(int((a + 180.0) // width) for a in angles)
        peak = max(hist.values())
        print(f"\n{run_dir.name}: {len(angles)} points beyond {args.min_range} m "
              f"over {n_clouds} clouds")
        print("  bearing in base_link (0 = ahead, + = left)")
        for b in range(args.bins):
            lo = -180.0 + b * width
            count = hist.get(b, 0)
            bar = "#" * int(40 * count / peak)
            marker = "  <- ahead" if lo <= 0.0 < lo + width else ""
            print(f"  {lo:>7.0f}..{lo + width:>6.0f} {count:>8} |{bar}{marker}")

        # Report the occupied arc as a circular span. Taking min..max of the bin
        # indices instead is wrong for exactly the case this study produces most:
        # a wedge straddling +/-180 occupies the first and last bins and reads as
        # "-180..180", i.e. the whole circle, which is the opposite of the truth.
        occupied = [b for b in range(args.bins) if hist.get(b, 0) > peak * 0.05]
        if occupied:
            occ = set(occupied)
            starts = [b for b in occupied if (b - 1) % args.bins not in occ]
            start = starts[0] if len(starts) == 1 else (starts[0] if starts else occupied[0])
            lo = -180.0 + start * width
            hi = lo + len(occupied) * width
            centre = lo + len(occupied) * width / 2.0
            centre = (centre + 180.0) % 360.0 - 180.0
            print(f"  occupied arc: {lo:.0f}..{hi:.0f} deg "
                  f"(width {len(occupied) * width:.0f}, centre {centre:.0f}), "
                  f"{len(occupied)} of {args.bins} bins above 5% of peak")
    return 0


if __name__ == "__main__":
    sys.exit(main())
