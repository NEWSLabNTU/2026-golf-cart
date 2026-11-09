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

"""Set the route to a saved goal pose, instead of a "2D Goal Pose" click.

    python3 scripts/localization/set_goal_pose.py --map ntu-r01 gate

Reads `goal_pose:` from config/initial_poses/<map>/<spot>.yaml (written by
`just pose listen`) and calls /api/routing/set_route_points, clearing any
previous route first. Localization must already be initialized. Does not engage.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import yaml

import pose_maps

sys.path.insert(0, os.path.join(pose_maps.REPO, "scripts", "testing"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("spot")
    parser.add_argument("--map", required=True, help="map name under config/initial_poses/")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--allow-goal-modification", action="store_true")
    args = parser.parse_args()

    if args.map not in pose_maps.known_maps():
        print(f"unknown map {args.map!r}; known: {', '.join(pose_maps.known_maps())}",
              file=sys.stderr)
        return 1
    path = os.path.join(pose_maps.map_dir(args.map), f"{args.spot}.yaml")
    goal = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            goal = (yaml.safe_load(f) or {}).get("goal_pose")
    if goal is None:
        print(f"no goal_pose in {path}", file=sys.stderr)
        print(f"  Click one in RViz with: just pose listen {args.map} {args.spot}",
              file=sys.stderr)
        return 1
    problem = pose_maps.check_extent(args.map, float(goal["x"]), float(goal["y"]))
    if problem:
        print(problem, file=sys.stderr)
        return 1

    import rclpy
    from rclpy.node import Node
    from geometry_msgs.msg import Pose
    from autoware_adapi_v1_msgs.srv import ClearRoute, SetRoutePoints
    from route_subscriber import wait_for_route_subscriber

    rclpy.init()
    node = Node("set_goal_pose")

    def call(srv_type, name, request):
        client = node.create_client(srv_type, name)
        if not client.wait_for_service(timeout_sec=args.timeout):
            return f"{name} never appeared; is the stack up?"
        future = client.call_async(request)
        rclpy.spin_until_future_complete(node, future, timeout_sec=args.timeout)
        res = future.result()
        if res is None:
            return f"{name}: no response"
        return "" if res.status.success else f"{name}: {res.status.message}"

    def done(code, msg):
        print(msg, file=sys.stderr if code else sys.stdout)
        node.destroy_node()
        rclpy.try_shutdown()
        return code

    # Avoids a route the lane departure checker never hears (route_subscriber.py).
    err = wait_for_route_subscriber(node, args.timeout, say=print)
    if err:
        return done(1, err)

    call(ClearRoute, "/api/routing/clear_route", ClearRoute.Request())  # none set is fine

    req = SetRoutePoints.Request()
    req.header.frame_id = "map"
    req.header.stamp = node.get_clock().now().to_msg()
    p = Pose()
    p.position.x, p.position.y, p.position.z = (float(goal[k]) for k in ("x", "y", "z"))
    o = p.orientation
    o.x, o.y, o.z, o.w = (float(goal[k]) for k in ("qx", "qy", "qz", "qw"))
    req.goal = p
    req.option.allow_goal_modification = args.allow_goal_modification

    # The planner may not have the pose yet straight after `init`; retry briefly.
    deadline = time.time() + args.timeout
    while True:
        err = call(SetRoutePoints, "/api/routing/set_route_points", req)
        if not err or time.time() > deadline:
            break
        time.sleep(2.0)
    if err:
        return done(1, f"route refused: {err}")
    return done(0, f"route set to {args.spot}: x={goal['x']:.2f} y={goal['y']:.2f}")


if __name__ == "__main__":
    sys.exit(main())
