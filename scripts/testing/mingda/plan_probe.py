#!/usr/bin/env python3
"""Find where the planning chain stops, with the stack up and nothing engaged.

    python3 scripts/testing/mingda/plan_probe.py                 # route to the Ming-Da goal
    python3 scripts/testing/mingda/plan_probe.py --no-route      # observe only
    just tool plan-probe                                         # the same, environment sourced

Run on the MASTER, in a terminal (never on the driver's display), while
`just launch-drive-mingda` is up. It never initializes localization and never
changes the operation mode. Unless --no-route, it clears any route and sets
one to --goal with allow_goal_modification false, as the handover asks.

Then, for --window seconds, it counts messages on:
  - the planning inputs (localization, occupancy grid, obstacle cloud, objects, route);
  - the lane-driving chain, stage by stage, down to the control command;
  - every other /planning and /control topic the graph advertises, so a stage
    named differently from the list below still shows up.

and prints the chain with the FIRST silent stage marked, the AD API's
is_autonomous_mode_available and route state, and the most recent distinct
"waiting for" lines from the node logs.

Paste the whole output back. Exit 0 if the control command is published, 1 if
the chain stops somewhere, 2 if the route could not be set.
"""

from __future__ import annotations

import argparse
import glob
import math
import os
import re
import sys
import time

INPUTS = [
    ('kinematic state', '/localization/kinematic_state'),
    ('acceleration', '/localization/acceleration'),
    ('occupancy grid', '/perception/occupancy_grid_map/map'),
    ('obstacle cloud', '/perception/obstacle_segmentation/pointcloud'),
    ('objects', '/perception/object_recognition/objects'),
    ('route', '/planning/mission_planning/route'),
]

CHAIN = [
    ('path_with_lane_id', '/planning/scenario_planning/lane_driving/behavior_planning/path_with_lane_id'),
    ('behavior path', '/planning/scenario_planning/lane_driving/behavior_planning/path'),
    ('path_optimizer', '/planning/scenario_planning/lane_driving/motion_planning/path_optimizer/trajectory'),
    ('lane_driving', '/planning/scenario_planning/lane_driving/trajectory'),
    ('scenario_selector', '/planning/scenario_planning/scenario_selector/trajectory'),
    ('velocity_smoother', '/planning/scenario_planning/velocity_smoother/trajectory'),
    ('planning_validator', '/planning/trajectory'),
    ('trajectory_follower', '/control/trajectory_follower/control_cmd'),
    ('control_cmd', '/control/command/control_cmd'),
]

EXTRA_PREFIXES = ('/planning/', '/control/')
# Silent topics matching this are debug or on-demand outputs, silent by design.
QUIET = re.compile(r'debug|marker|virtual_wall|processing_time|component_events|'
                   r'planning_factors|objects_of_interest|cooperate_status|'
                   r'auto_mode_status|parking/|checkpoint|/goal$|external_request|'
                   r'clear_velocity_limit|max_velocity|modified_goal|mrm/route|'
                   r'lateral_offset|actuation_cmd|latency|gate_mode_cmd')


def yaw_to_quat(yaw: float):
    return 0.0, 0.0, math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def waiting_lines(log_dir: str, since: float, limit: int = 25):
    """Distinct 'waiting for' lines in logs touched since `since`, newest last.

    Each comes with how long ago it was last logged: a node that logged it once
    at startup and then got its input looks the same as one still stuck,
    except for the age.
    """
    last = {}
    pattern = re.compile(r'waiting for', re.IGNORECASE)
    stamp = re.compile(r'\[(\d{9,}\.\d+)\]')
    for path in glob.glob(os.path.join(os.path.expanduser(log_dir), '**', '*'), recursive=True):
        if not os.path.isfile(path) or os.path.getmtime(path) < since:
            continue
        try:
            with open(path, errors='replace') as f:
                for line in f:
                    if not pattern.search(line):
                        continue
                    found = stamp.search(line)
                    when = float(found.group(1)) if found else os.path.getmtime(path)
                    # Drop the timestamp so repeats collapse onto one entry.
                    key = stamp.sub('', line.strip())
                    if key not in last or when > last[key][0]:
                        last[key] = (when, os.path.basename(path))
        except OSError:
            continue
    ordered = sorted(last.items(), key=lambda item: item[1][0])
    return ordered[-limit:]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--goal', nargs=3, type=float, default=[5.95, -4.9, 180.0],
                    metavar=('X', 'Y', 'YAW_DEG'),
                    help='map frame; default is the Ming-Da lane goal from the handover')
    ap.add_argument('--no-route', action='store_true', help='observe only; do not touch the route')
    ap.add_argument('--window', type=float, default=10.0, help='seconds to count messages')
    ap.add_argument('--log-dir', default='~/.ros/log')
    ap.add_argument('--log-since', type=float, default=1800.0,
                    help='scan log files modified in the last this many seconds')
    args = ap.parse_args(argv)

    import rclpy
    from autoware_adapi_v1_msgs.msg import OperationModeState, RouteState
    from autoware_adapi_v1_msgs.srv import ClearRoute, SetRoutePoints
    from geometry_msgs.msg import Pose
    from nav_msgs.msg import Odometry
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from rosidl_runtime_py.utilities import get_message

    rclpy.init()
    node = Node('mingda_plan_probe')
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

    def spin(seconds):
        end = time.time() + seconds
        while time.time() < end:
            rclpy.spin_once(node, timeout_sec=0.1)

    def call(srv_type, name, request):
        client = node.create_client(srv_type, name)
        if not client.wait_for_service(timeout_sec=10.0):
            return False, f'{name} not available'
        fut = client.call_async(request)
        rclpy.spin_until_future_complete(node, fut, timeout_sec=10.0)
        res = fut.result()
        if res is None:
            return False, f'{name}: no response'
        return res.status.success, f'{name}: {res.status.message or "ok"} (code {res.status.code})'

    spin(2.0)
    odom = state['odom']
    if odom is None:
        say('no /localization/kinematic_state yet: localization is not running or not initialized')
    else:
        p, q = odom.pose.pose.position, odom.pose.pose.orientation
        yaw = math.degrees(math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)))
        say(f'cart at ({p.x:.2f}, {p.y:.2f}), yaw {yaw:.1f} deg, '
            f'speed {odom.twist.twist.linear.x:.2f} m/s')

    route_code = 0
    if not args.no_route:
        ok, msg = call(ClearRoute, '/api/routing/clear_route', ClearRoute.Request())
        say(f'clear_route: {msg}')
        gx, gy, gyaw = args.goal[0], args.goal[1], math.radians(args.goal[2])
        req = SetRoutePoints.Request()
        req.header.frame_id = 'map'
        req.header.stamp = node.get_clock().now().to_msg()
        goal = Pose()
        goal.position.x, goal.position.y = gx, gy
        goal.orientation.x, goal.orientation.y, goal.orientation.z, goal.orientation.w = \
            yaw_to_quat(gyaw)
        req.goal = goal
        req.option.allow_goal_modification = False
        ok, msg = call(SetRoutePoints, '/api/routing/set_route_points', req)
        say(f'set_route_points to ({gx:.2f}, {gy:.2f}, {args.goal[2]:.0f} deg): {msg}')
        if not ok:
            route_code = 2
        spin(3.0)  # let the chain react to the new route before counting

    # Every topic to count: the named ones, plus whatever else lives under
    # /planning and /control right now.
    advertised = dict(node.get_topic_names_and_types())
    named = [t for _, t in INPUTS + CHAIN]
    extra = sorted(t for t in advertised
                   if t.startswith(EXTRA_PREFIXES) and t not in named)
    counts = {}

    def qos_for(topic):
        infos = node.get_publishers_info_by_topic(topic)
        reliable = bool(infos) and all(
            i.qos_profile.reliability == ReliabilityPolicy.RELIABLE for i in infos)
        transient = any(
            i.qos_profile.durability == DurabilityPolicy.TRANSIENT_LOCAL for i in infos)
        return QoSProfile(
            depth=10,
            reliability=ReliabilityPolicy.RELIABLE if reliable else ReliabilityPolicy.BEST_EFFORT,
            durability=DurabilityPolicy.TRANSIENT_LOCAL if transient else DurabilityPolicy.VOLATILE,
        ), len(infos)

    publishers = {}
    for topic in named + extra:
        if topic not in advertised:
            continue
        try:
            msg_type = get_message(advertised[topic][0])
        except (AttributeError, ModuleNotFoundError, ValueError):
            continue
        qos, n = qos_for(topic)
        publishers[topic] = n
        counts[topic] = 0
        node.create_subscription(
            msg_type, topic,
            lambda _m, t=topic: counts.__setitem__(t, counts[t] + 1),
            qos, raw=True)

    say(f'counting for {args.window:.0f} s ...')
    spin(args.window)

    def row(label, topic):
        if topic not in advertised:
            return f'  {label:20s} {"not advertised":>16s}  {topic}', False
        if topic not in counts:
            return f'  {label:20s} {"(type unknown)":>16s}  {topic}', False
        n = counts[topic]
        hz = n / args.window
        status = f'{n:4d} msgs {hz:5.1f} Hz' if n else f'SILENT ({publishers[topic]} pub)'
        return f'  {label:20s} {status:>16s}  {topic}', n > 0

    print()
    print('planning inputs:')
    for label, topic in INPUTS:
        print(row(label, topic)[0])

    print('lane-driving chain, in order:')
    first_silent = None
    for label, topic in CHAIN:
        line, alive = row(label, topic)
        if not alive and first_silent is None:
            first_silent = label
            line += '   <-- chain stops here'
        print(line)

    silent_extra = [t for t in extra if counts.get(t, 0) == 0]
    alive_extra = [t for t in extra if counts.get(t, 0) > 0]
    notable = [t for t in silent_extra if publishers.get(t, 0) and not QUIET.search(t)]
    print(f'other /planning and /control topics: {len(alive_extra)} publishing, '
          f'{len(silent_extra)} silent, of which not debug/on-demand: {len(notable)}')
    for topic in notable:
        print(f'  SILENT ({publishers.get(topic, 0)} pub)  {topic}')

    mode = state['mode']
    print()
    if mode is None:
        print('operation mode: no /api/operation_mode/state')
    else:
        print(f'operation mode: mode {mode.mode}, autonomous available '
              f'{mode.is_autonomous_mode_available}, in transition {mode.is_in_transition}')
    route_names = {RouteState.UNKNOWN: 'UNKNOWN', RouteState.UNSET: 'UNSET',
                   RouteState.SET: 'SET', RouteState.ARRIVED: 'ARRIVED',
                   RouteState.CHANGING: 'CHANGING'}
    print(f'route state: {route_names.get(state["route"], state["route"])}')

    lines = waiting_lines(args.log_dir, time.time() - args.log_since)
    print()
    print(f'"waiting for" lines, last {args.log_since / 60:.0f} min of {args.log_dir}: {len(lines)}')
    now = time.time()
    for text, (when, where) in lines:
        print(f'  {now - when:6.0f} s ago  [{where}] {text[:200]}')

    print()
    if route_code:
        print('RESULT: route refused; the chain was observed without a new route')
    elif first_silent is None:
        print('RESULT: control command is published; the chain is complete')
    else:
        print(f'RESULT: chain stops at {first_silent}')
    node.destroy_node()
    rclpy.try_shutdown()
    return route_code or (0 if first_silent is None else 1)


if __name__ == '__main__':
    sys.exit(main())
