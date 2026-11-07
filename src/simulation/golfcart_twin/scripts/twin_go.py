#!/usr/bin/env python3
"""Drive one of the demo's routes: wait until the cart is localized, set the route's goal,
engage, and report until it arrives (Phase 10).

    twin_go.py ROUTES_YAML ROUTE [--no-engage] [--timeout 300]

The same as a person does in RViz: 2D Goal Pose on the route's goal, then the Autoware
state panel's engage button. Use it to rehearse, or when no one is at the RViz window.
Run it on the stack's ROS domain and DDS profile (`just twin go`).
"""
import argparse
import math
import sys
import time

import yaml


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("routes")
    ap.add_argument("route")
    ap.add_argument("--no-engage", action="store_true", help="set the goal only")
    ap.add_argument("--timeout", type=float, default=300.0, help="wall seconds to arrive")
    a = ap.parse_args()
    routes = yaml.safe_load(open(a.routes))["routes"]
    if a.route not in routes:
        sys.exit(f"no route {a.route!r}; the routes are {', '.join(routes)}")
    r = routes[a.route]
    g = r["goal"]

    import rclpy
    from autoware_adapi_v1_msgs.msg import (LocalizationInitializationState, OperationModeState,
                                            RouteState)
    from autoware_adapi_v1_msgs.srv import ChangeOperationMode, ClearRoute, SetRoutePoints
    from geometry_msgs.msg import Pose
    from nav_msgs.msg import Odometry
    from rclpy.qos import DurabilityPolicy, QoSProfile

    rclpy.init()
    node = rclpy.create_node("twin_go")
    latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
    seen = {}
    node.create_subscription(LocalizationInitializationState,
                             "/api/localization/initialization_state",
                             lambda m: seen.__setitem__("loc", m.state), latched)
    node.create_subscription(OperationModeState, "/api/operation_mode/state",
                             lambda m: seen.__setitem__("op", m), latched)
    node.create_subscription(RouteState, "/api/routing/state",
                             lambda m: seen.__setitem__("route", m.state), latched)
    node.create_subscription(Odometry, "/localization/kinematic_state",
                             lambda m: seen.__setitem__("odom", m), 1)

    def wait(cond, what, limit):
        t0 = time.monotonic()
        while not cond():
            rclpy.spin_once(node, timeout_sec=0.2)
            if time.monotonic() - t0 > limit:
                sys.exit(f"twin_go: no {what} after {limit:.0f} s")

    def call(srv_type, name, req):
        cli = node.create_client(srv_type, name)
        if not cli.wait_for_service(timeout_sec=30.0):
            sys.exit(f"twin_go: {name} is not offered")
        fut = cli.call_async(req)
        rclpy.spin_until_future_complete(node, fut, timeout_sec=30.0)
        res = fut.result()
        if res is None or not res.status.success:
            sys.exit(f"twin_go: {name} failed: {res.status.message if res else 'no answer'}")

    print(f"route {a.route}: {r['title']}", flush=True)
    wait(lambda: seen.get("loc") == LocalizationInitializationState.INITIALIZED,
         "localization", 300)
    print("localized", flush=True)
    call(ClearRoute, "/api/routing/clear_route", ClearRoute.Request())
    # The planner takes the clear on its own time (sim time, which runs slow on a loaded
    # host): setting a route before it reads UNSET is refused, "The route is already set".
    wait(lambda: seen.get("route") == RouteState.UNSET, "cleared route", 60)
    req = SetRoutePoints.Request()
    req.header.frame_id = "map"
    req.option.allow_goal_modification = False
    p = Pose()
    p.position.x, p.position.y, p.position.z = float(g["x"]), float(g["y"]), float(g["z"])
    p.orientation.z, p.orientation.w = math.sin(g["yaw"] / 2), math.cos(g["yaw"] / 2)
    req.goal = p
    call(SetRoutePoints, "/api/routing/set_route_points", req)
    print(f"goal set: ({g['x']}, {g['y']}), yaw {g['yaw']}", flush=True)
    if a.no_engage:
        return
    wait(lambda: seen.get("op") is not None and seen["op"].is_autonomous_mode_available,
         "autonomous mode available", 120)
    call(ChangeOperationMode, "/api/operation_mode/change_to_autonomous",
         ChangeOperationMode.Request())
    print("engaged", flush=True)
    t0, last = time.monotonic(), 0.0
    while seen.get("route") != RouteState.ARRIVED:
        rclpy.spin_once(node, timeout_sec=0.2)
        now = time.monotonic()
        if now - t0 > a.timeout:
            sys.exit(f"twin_go: not arrived after {a.timeout:.0f} s")
        if now - last > 5.0 and "odom" in seen:
            o = seen["odom"]
            q = o.pose.pose.position
            print(f"  {now - t0:5.1f} s  x {q.x:.2f} y {q.y:.2f}  "
                  f"v {o.twist.twist.linear.x:.2f} m/s", flush=True)
            last = now
    q = seen["odom"].pose.pose.position
    print(f"arrived in {time.monotonic() - t0:.1f} s, "
          f"{math.hypot(q.x - g['x'], q.y - g['y']):.2f} m from the goal", flush=True)


if __name__ == "__main__":
    main()
