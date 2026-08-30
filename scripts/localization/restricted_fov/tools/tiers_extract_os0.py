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

"""Pull the Ouster OS0-128 out of a TIERS ROS 1 bag into a ROS 2 bag.

    python3 scripts/localization/tiers_extract_os0.py \\
        data/tiers/road01.bag data/tiers/road01_os0

Why the OS0 specifically: it is 360 degrees by 90 degrees, which is wider than a
Seyond Robin-W in *both* axes, so a crop of it can emulate that sensor's field of
view including the vertical extent. The Autoware sample bag's VLS128 spans only
40 degrees vertically and cannot. See
docs/research/localization/restricted-fov-ndt.md.

Extracting rather than converting the whole bag: the source is 48 GB of six
sensors, and everything except this one LiDAR and its IMU is dead weight for this
question.

**Both Ouster sensors stamp `os_sensor`.** The OS0-128 and the OS1-64 in this rig
publish the same `frame_id`, so a TF tree containing both would be ambiguous and
whichever transform was published last would win. The frames are rewritten on the
way out, which is also why this cannot be done with `rosbags-convert`.

**The Ouster clouds are stamped in sensor time, not ROS time.** Their headers
carry time since the sensor booted -- 2468 seconds into this recording -- while
the bag's own message timestamps are the 2022 wall clock everything else uses.
Replayed as-is, `ros2 bag play --clock` publishes a clock from the bag time and
every consumer that pairs a cloud with a pose fails: NDT reports "Pose
interpolation failed (validation error or timestamp mismatch)" on every frame and
never publishes, which reads as a localization failure rather than a clock one.
Headers are therefore restamped from the bag timestamp. Pass --keep-stamps to
preserve the originals.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

# The OS0-128 and its IMU, renamed to something unambiguous. Values are the
# output topic and the frame_id to stamp.
WANTED = {
    "/os_cloud_node/points": ("/sensing/lidar/os0/pointcloud_raw", "os0_sensor"),
    "/os_cloud_node/imu": ("/sensing/imu/os0/imu_raw", "os0_imu"),
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path, help="TIERS ROS 1 .bag")
    ap.add_argument("dest", type=Path, help="output rosbag2 directory (must not exist)")
    ap.add_argument("--keep-original-topics", action="store_true",
                    help="write under the source topic names instead of Autoware-style ones")
    ap.add_argument("--keep-stamps", action="store_true",
                    help="do NOT restamp headers from the bag timestamp; see the note above")
    args = ap.parse_args()

    from rosbags.highlevel import AnyReader
    from rosbags.rosbag2 import Writer
    from rosbags.typesys import Stores, get_typestore

    if args.dest.exists():
        print(f"{args.dest} exists; refusing to overwrite", file=sys.stderr)
        return 1

    typestore = get_typestore(Stores.ROS2_HUMBLE)
    written = {}

    with AnyReader([args.source]) as reader:
        conns = [c for c in reader.connections if c.topic in WANTED]
        if not conns:
            print(f"none of {list(WANTED)} in {args.source}", file=sys.stderr)
            return 1

        with Writer(args.dest) as writer:
            out_conns = {}
            for c in conns:
                topic = c.topic if args.keep_original_topics else WANTED[c.topic][0]
                if topic not in out_conns:
                    out_conns[topic] = writer.add_connection(
                        topic, c.msgtype, typestore=typestore)
                    written[topic] = 0

            for conn, timestamp, raw in reader.messages(connections=conns):
                msg = reader.deserialize(raw, conn.msgtype)
                # Restamp the frame. Doing it here rather than downstream keeps
                # the ambiguity from ever entering a TF tree.
                msg.header.frame_id = WANTED[conn.topic][1]
                if not args.keep_stamps:
                    msg.header.stamp.sec = timestamp // 1_000_000_000
                    msg.header.stamp.nanosec = timestamp % 1_000_000_000
                topic = conn.topic if args.keep_original_topics \
                    else WANTED[conn.topic][0]
                writer.write(out_conns[topic], timestamp,
                             typestore.serialize_cdr(msg, conn.msgtype))
                written[topic] += 1
                total = sum(written.values())
                if total % 2000 == 0:
                    print(f"  {total} messages", flush=True)

    for topic, count in written.items():
        print(f"{count:7d}  {topic}")
    print(f"wrote {args.dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
