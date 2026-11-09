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

"""Save the initial pose and goal pose you click in RViz, as a spot on a map.

    python3 scripts/localization/listen_pose.py --map ntu-r01 gate

Listens for RViz's "2D Pose Estimate" (/initialpose) and "2D Goal Pose"
(/planning/mission_planning/goal, or the route tool's /rviz/routing/rough_goal)
and writes each click into config/initial_poses/<map>/<spot>.yaml as
`initial_pose:` / `goal_pose:`. Click again to replace one; the other is kept.
Ctrl-C when done.

Replay later with `just pose init|goal|go <map> <spot>`.

Unlike capture_initial_pose.py this stores the click itself, not the pose NDT
converged to. That is what the planning simulator gives anyway, and on the
vehicle `init` uses method AUTO, so NDT refines the seed.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import yaml

import pose_maps

KEYS = ("x", "y", "z", "qx", "qy", "qz", "qw")


def pose_dict(p) -> dict:
    o = p.orientation
    yaw = math.atan2(2.0 * (o.w * o.z + o.x * o.y), 1.0 - 2.0 * (o.y * o.y + o.z * o.z))
    values = (p.position.x, p.position.y, p.position.z, o.x, o.y, o.z, o.w)
    d = {k: round(float(v), 6) for k, v in zip(KEYS, values)}
    d["yaw_deg"] = round(math.degrees(yaw), 2)
    return d


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("spot", help="name for this start/goal pair, e.g. gate")
    parser.add_argument("--map", required=True, help="map name under config/initial_poses/")
    args = parser.parse_args()

    if args.map not in pose_maps.known_maps():
        print(f"unknown map {args.map!r}; known: {', '.join(pose_maps.known_maps())}",
              file=sys.stderr)
        return 1
    path = os.path.join(pose_maps.map_dir(args.map), f"{args.spot}.yaml")

    import rclpy
    from rclpy.executors import ExternalShutdownException
    from rclpy.node import Node
    from geometry_msgs.msg import PoseStamped, PoseWithCovarianceStamped

    data = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}

    def save(key: str, pose) -> None:
        d = pose_dict(pose)
        problem = pose_maps.check_extent(args.map, d["x"], d["y"])
        if problem:
            print(f"ignored {key}: {problem}", file=sys.stderr)
            return
        data[key] = d
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# Spot {args.spot} on map {args.map}, clicked in RViz "
                    f"(just pose listen). Frame: map.\n")
            yaml.safe_dump({k: data[k] for k in ("initial_pose", "goal_pose") if k in data},
                           f, sort_keys=False)
        print(f"saved {key:12s} x={d['x']:.2f} y={d['y']:.2f} yaw={d['yaw_deg']:.1f} deg"
              f"  -> {os.path.relpath(path, pose_maps.REPO)}", flush=True)

    rclpy.init()
    node = Node("listen_pose")
    node.create_subscription(PoseWithCovarianceStamped, "/initialpose",
                             lambda m: save("initial_pose", m.pose.pose), 10)
    for topic in ("/planning/mission_planning/goal", "/rviz/routing/rough_goal"):
        node.create_subscription(PoseStamped, topic, lambda m: save("goal_pose", m.pose), 10)

    print(f"listening on map {args.map}, spot {args.spot}.")
    print("  In RViz: '2D Pose Estimate' for the start, '2D Goal Pose' for the goal.")
    print("  Click again to replace one. Ctrl-C when done.", flush=True)
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass  # Ctrl-C; Humble's rclpy shuts the context down itself
    finally:
        node.destroy_node()
        rclpy.try_shutdown()

    missing = [k for k in ("initial_pose", "goal_pose") if k not in data]
    if missing:
        print(f"not saved yet: {', '.join(missing)}", file=sys.stderr)
        return 1 if len(missing) == 2 else 0
    print(f"replay with: just pose go {args.map} {args.spot}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
