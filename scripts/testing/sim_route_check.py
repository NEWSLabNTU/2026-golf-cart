#!/usr/bin/env python3
"""Drive one route in the planning simulator through the AD API, and judge it.

    python3 scripts/testing/sim_route_check.py \\
        --start 7.5 -12 90 --goal 7.5 10 90 --timeout 240

Phase 8, M2. Initializes localization at --start (x y yaw_deg, map frame), sets
a route to --goal, engages autonomous, and watches /localization/kinematic_state.

PASS needs all of:
  - the route is accepted, which means the lanelets connect start to goal;
  - the first metre travelled is FORWARD along the start heading. A lanelet
    loaded backwards either refuses the route or drives the wrong way, and this
    is the check that tells the two apart from a success;
  - /api/routing/state reaches ARRIVED within --timeout, within --tolerance of
    the goal.

Exit 0 on PASS, 1 on FAIL, with the reason on the last line.
"""

from __future__ import annotations

import argparse
import math
import sys
import time


def yaw_to_quat(yaw: float) -> tuple[float, float, float, float]:
    return 0.0, 0.0, math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def forward_progress(start_xy, start_yaw, xy) -> float:
    """Signed distance travelled along the start heading."""
    return (xy[0] - start_xy[0]) * math.cos(start_yaw) + (xy[1] - start_xy[1]) * math.sin(start_yaw)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--start', nargs=3, type=float, required=True, metavar=('X', 'Y', 'YAW_DEG'))
    ap.add_argument('--goal', nargs=3, type=float, required=True, metavar=('X', 'Y', 'YAW_DEG'))
    ap.add_argument('--timeout', type=float, default=240.0)
    ap.add_argument('--tolerance', type=float, default=1.0, help='m from goal')
    ap.add_argument('--allow-goal-modification', action='store_true',
                    help='let the goal planner move the goal. Off by default: with it on, '
                         'the goal planner searches for a pull-over spot, and a lanelet '
                         'with no road shoulder (the basement) leaves it holding a stop '
                         'at distance 0 forever')
    args = ap.parse_args(argv)

    import rclpy
    from autoware_adapi_v1_msgs.msg import OperationModeState, RouteState
    from autoware_adapi_v1_msgs.srv import (ChangeOperationMode, ClearRoute,
                                            InitializeLocalization, SetRoutePoints)
    from geometry_msgs.msg import Pose, PoseWithCovarianceStamped
    from nav_msgs.msg import Odometry
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile

    rclpy.init()
    node = Node('sim_route_check')
    latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
    state = {'odom': None, 'route': None, 'mode': None}
    node.create_subscription(Odometry, '/localization/kinematic_state',
                             lambda m: state.__setitem__('odom', m), 10)
    node.create_subscription(RouteState, '/api/routing/state',
                             lambda m: state.__setitem__('route', m.state), latched)
    node.create_subscription(OperationModeState, '/api/operation_mode/state',
                             lambda m: state.__setitem__('mode', m), latched)

    def say(msg):
        print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)

    def fail(reason):
        say(f'FAIL: {reason}')
        rclpy.try_shutdown()
        return 1

    def call(srv_type, name, request, tries=30, every=2.0):
        client = node.create_client(srv_type, name)
        if not client.wait_for_service(timeout_sec=60.0):
            return None, f'{name} never appeared'
        last = ''
        for _ in range(tries):
            fut = client.call_async(request)
            rclpy.spin_until_future_complete(node, fut, timeout_sec=10.0)
            res = fut.result()
            if res is not None and res.status.success:
                return res, ''
            last = res.status.message if res is not None else 'no response'
            end = time.time() + every
            while time.time() < end:
                rclpy.spin_once(node, timeout_sec=0.1)
        return None, f'{name}: {last}'

    # A clean slate, so a second run against the same simulator is meaningful:
    # stop, then drop any route a previous run left. Failures are fine here.
    for srv_type, name in ((ChangeOperationMode, '/api/operation_mode/change_to_stop'),
                           (ClearRoute, '/api/routing/clear_route')):
        call(srv_type, name, srv_type.Request(), tries=1)

    sx, sy, syaw = args.start[0], args.start[1], math.radians(args.start[2])
    gx, gy, gyaw = args.goal[0], args.goal[1], math.radians(args.goal[2])

    init = InitializeLocalization.Request()
    pose = PoseWithCovarianceStamped()
    pose.header.frame_id = 'map'
    pose.header.stamp = node.get_clock().now().to_msg()
    pose.pose.pose.position.x, pose.pose.pose.position.y = sx, sy
    q = yaw_to_quat(syaw)
    o = pose.pose.pose.orientation
    o.x, o.y, o.z, o.w = q
    pose.pose.covariance[0] = pose.pose.covariance[7] = 0.25
    pose.pose.covariance[35] = 0.0685
    init.pose.append(pose)
    _, err = call(InitializeLocalization, '/api/localization/initialize', init)
    if err:
        return fail(f'initialize: {err}')
    say(f'localization initialized at ({sx:.1f}, {sy:.1f}, {args.start[2]:.0f} deg)')

    route = SetRoutePoints.Request()
    route.header.frame_id = 'map'
    route.header.stamp = node.get_clock().now().to_msg()
    goal = Pose()
    goal.position.x, goal.position.y = gx, gy
    q = yaw_to_quat(gyaw)
    goal.orientation.x, goal.orientation.y, goal.orientation.z, goal.orientation.w = q
    route.goal = goal
    route.option.allow_goal_modification = args.allow_goal_modification
    _, err = call(SetRoutePoints, '/api/routing/set_route_points', route)
    if err:
        return fail(f'route refused, so the lanelets do not connect start to goal '
                    f'in that direction ({err})')
    say(f'route set to ({gx:.1f}, {gy:.1f})')

    _, err = call(ChangeOperationMode, '/api/operation_mode/change_to_autonomous',
                  ChangeOperationMode.Request())
    if err:
        return fail(f'engage refused: {err}')
    say('autonomous engaged')

    deadline = time.time() + args.timeout
    first_metre = None
    max_speed = 0.0
    while time.time() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
        odom = state['odom']
        if odom is None:
            continue
        p = odom.pose.pose.position
        max_speed = max(max_speed, abs(odom.twist.twist.linear.x))
        if first_metre is None and math.hypot(p.x - sx, p.y - sy) >= 1.0:
            first_metre = forward_progress((sx, sy), syaw, (p.x, p.y))
            if first_metre < 0.5:
                return fail(f'moved {first_metre:+.2f} m along the start heading in its '
                            f'first metre: the route runs the wrong way')
            say('first metre was forward along the lane')
        if state['route'] == RouteState.ARRIVED:
            dist = math.hypot(p.x - gx, p.y - gy)
            if dist > args.tolerance:
                return fail(f'ARRIVED {dist:.2f} m from the goal (> {args.tolerance} m)')
            say(f'PASS: arrived {dist:.2f} m from the goal, max speed {max_speed:.2f} m/s')
            rclpy.try_shutdown()
            return 0
    p = state['odom'].pose.pose.position if state['odom'] else None
    where = f' at ({p.x:.1f}, {p.y:.1f})' if p else ''
    return fail(f'not ARRIVED after {args.timeout:.0f} s{where}, max speed {max_speed:.2f} m/s')


if __name__ == '__main__':
    sys.exit(main())
