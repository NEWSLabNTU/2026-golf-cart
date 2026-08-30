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

"""Give the TIERS replay the twist input Autoware's localization assumes.

    python3 scripts/localization/tiers_add_odometry.py \\
        data/tiers/road01_os0 data/tiers/road01_os0_odo \\
        --poses data/tiers/road01_reference_poses_kitti.txt \\
        --cloud-topic /sensing/lidar/os0/pointcloud_raw

Autoware estimates twist in `gyro_odometer`, which fuses a **vehicle** velocity
with the IMU's angular rate and hands the result to `ekf_localizer`, which in
turn provides NDT's prior for every frame. Take the vehicle velocity away and
the prior degrades to a constant-position guess.

That is what the TIERS rig is missing. It is a handheld trolley with no wheel
encoder, so nothing publishes
`/sensing/vehicle_velocity_converter/twist_with_covariance`. Measured
consequence: NDT needed a median of 10 iterations against 3 on the Autoware
sample bag, and the same configuration replayed three times gave median errors of
4.4 m, 7.3 m and 0.13 m. Run-to-run variance exceeded the effect the study was
trying to measure, which made the whole arm unusable.

This adds two topics:

- `/sensing/imu/imu_data`, the OS0's own IMU. Real measurement, only renamed to
  the topic the chain reads. There is no `imu_corrector` in this replay, so the
  raw device output is what the chain gets.
- `/sensing/vehicle_velocity_converter/twist_with_covariance`, **synthesised**
  by differentiating the reference trajectory.

**The second one is a stand-in and has to be understood as one.** It is derived
from KISS-ICP, which also produced the map, so it is not independent evidence and
it is better than a real wheel encoder would be -- no slip, no scale error, no
quantisation. It stands in for the odometry a vehicle has and this rig does not.
It does NOT make the replay a fair simulation of a vehicle with poor odometry,
and a field-of-view result obtained with it should be read as "with a good
prior", which is the regime the golf cart is in.

Only linear velocity is synthesised. Angular rate stays with the IMU, which is
where `gyro_odometer` takes it from anyway.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

IMU_IN = "/sensing/imu/os0/imu_raw"
IMU_OUT = "/sensing/imu/imu_data"
TWIST_OUT = "/sensing/vehicle_velocity_converter/twist_with_covariance"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("--poses", type=Path, required=True, help="KITTI-format reference")
    ap.add_argument("--cloud-topic", required=True,
                    help="topic whose timestamps the poses correspond to")
    ap.add_argument("--speed-variance", type=float, default=0.04,
                    help="reported variance on linear x, (m/s)^2")
    args = ap.parse_args()

    from rosbags.highlevel import AnyReader
    from rosbags.rosbag2 import Writer
    from rosbags.typesys import Stores, get_typestore

    if args.dest.exists():
        print(f"{args.dest} exists; refusing to overwrite", file=sys.stderr)
        return 1

    typestore = get_typestore(Stores.ROS2_HUMBLE)
    TwistWithCovarianceStamped = typestore.types[
        "geometry_msgs/msg/TwistWithCovarianceStamped"]
    TwistWithCovariance = typestore.types["geometry_msgs/msg/TwistWithCovariance"]
    Twist = typestore.types["geometry_msgs/msg/Twist"]
    Vector3 = typestore.types["geometry_msgs/msg/Vector3"]
    Header = typestore.types["std_msgs/msg/Header"]
    Time = typestore.types["builtin_interfaces/msg/Time"]

    raw = np.loadtxt(args.poses)
    mats = raw.reshape(-1, 3, 4)
    xyz = mats[:, :, 3]

    # Cloud stamps in nanoseconds, so each pose can be given the time of the
    # scan it was computed from.
    with AnyReader([args.source]) as reader:
        conns = [c for c in reader.connections if c.topic == args.cloud_topic]
        if not conns:
            print(f"{args.cloud_topic} not in {args.source}", file=sys.stderr)
            return 1
        stamps = [t for _c, t, _r in reader.messages(connections=conns)]

    n = min(len(stamps), xyz.shape[0])
    if n < 2:
        print("need at least two poses", file=sys.stderr)
        return 1

    # Central differences, so a sample is not biased half a step early or late.
    # Speed is the magnitude of translation over time and is assigned to linear
    # x: the vehicle frame's forward axis is what a wheel encoder reports, and
    # this trolley does not move sideways in any way the study cares about.
    speeds = np.zeros(n)
    for i in range(n):
        lo, hi = max(0, i - 1), min(n - 1, i + 1)
        dt = (stamps[hi] - stamps[lo]) / 1e9
        speeds[i] = (np.linalg.norm(xyz[hi] - xyz[lo]) / dt) if dt > 0 else 0.0

    cov = [0.0] * 36
    cov[0] = args.speed_variance          # linear x
    cov[7] = cov[14] = 10000.0            # linear y, z: not measured
    cov[21] = cov[28] = cov[35] = 10000.0  # angular: the IMU supplies these

    written = {}
    with AnyReader([args.source]) as reader, Writer(args.dest) as writer:
        out_conns = {}
        for c in reader.connections:
            if c.topic not in out_conns:
                out_conns[c.topic] = writer.add_connection(
                    c.topic, c.msgtype, typestore=typestore)
                written[c.topic] = 0
        imu_conn = reader.connections[0]
        for c in reader.connections:
            if c.topic == IMU_IN:
                imu_conn = c
        out_conns[IMU_OUT] = writer.add_connection(
            IMU_OUT, imu_conn.msgtype, typestore=typestore)
        out_conns[TWIST_OUT] = writer.add_connection(
            TWIST_OUT, TwistWithCovarianceStamped.__msgtype__, typestore=typestore)
        written[IMU_OUT] = written[TWIST_OUT] = 0

        twist_idx = 0
        for conn, stamp, raw_msg in reader.messages():
            writer.write(out_conns[conn.topic], stamp, raw_msg)
            written[conn.topic] += 1

            if conn.topic == IMU_IN:
                writer.write(out_conns[IMU_OUT], stamp, raw_msg)
                written[IMU_OUT] += 1

            if conn.topic == args.cloud_topic and twist_idx < n:
                header = Header(
                    stamp=Time(sec=stamp // 1_000_000_000,
                               nanosec=stamp % 1_000_000_000),
                    frame_id="base_link")
                msg = TwistWithCovarianceStamped(
                    header=header,
                    twist=TwistWithCovariance(
                        twist=Twist(
                            linear=Vector3(x=float(speeds[twist_idx]), y=0.0, z=0.0),
                            angular=Vector3(x=0.0, y=0.0, z=0.0)),
                        covariance=np.array(cov, dtype=np.float64)))
                writer.write(out_conns[TWIST_OUT], stamp,
                             typestore.serialize_cdr(msg, TwistWithCovarianceStamped.__msgtype__))
                written[TWIST_OUT] += 1
                twist_idx += 1

    for topic in (IMU_OUT, TWIST_OUT):
        print(f"{written[topic]:7d}  {topic}")
    print(f"speed: mean {speeds.mean():.2f} m/s, max {speeds.max():.2f} m/s")
    print(f"wrote {args.dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
