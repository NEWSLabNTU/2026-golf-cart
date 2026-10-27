#!/usr/bin/env python3
"""Inject a fault while the planning simulator drives, and follow the MRM down to CAN.

    just sim-drive-basement ./data/mingda-basement      # one terminal
    python3 scripts/testing/sim_mrm_check.py \\
        --start 17.6 -2.8 180 --goal 6.5 -2.8 180      # another

Phase 8, S5 (exit criterion 4, desk half). Starts the real vehicle interface on
vcan0 with mock_vcu reporting AUTO, so the interface is in the loop exactly as
on the cart except that its reports stay private: the simulator owns
/vehicle/status/*. Then initializes, routes and engages as sim_route_check.py
does, and once the cart is moving forces one diagnostic leaf to ERROR through
the planning simulator's dummy_diag_publisher.

PASS needs every link of the chain, each timed from the injection:
  - /system/fail_safe/mrm_state reaches MRM_OPERATING with EMERGENCY_STOP. A
    COMFORTABLE_STOP here would mean the leaf did not take the comfortable stop
    down with it, and vehicle_cmd_gate then never raises emergency_cmd;
  - /control/command/emergency_cmd says emergency;
  - /control/command/control_cmd asks for at most --min-decel;
  - the interface's brake frame (0x68) carries the 3.0 m/s2 safety-brake
    deceleration and its vehicle frame (0x43F) the Veh_Estop bit;
  - the simulated cart stops, and the MRM reports MRM_SUCCEEDED;
  - after the leaf is set back to OK, emergency_cmd and Veh_Estop clear. A
    latch that outlived its cause would hold the cart braked for good.

Exit 0 on PASS, 1 on FAIL, with the reason on the last line. --no-can checks
the ROS half only, for a machine without vcan0 or the vendor DBC.
"""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
CRATE = REPO / 'src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface'
DBC = Path(os.environ.get('CAX_ADS_DBC', CRATE / 'CAX_ADS_CAN.dbc'))
BRAKE_ID, VEHICLE_ID = 0x68, 0x43F
SAFETY_BRAKE_DECEL = 3.0  # SAFETY_BRAKE_DECEL_MPS2 in can_io.rs

# The interface's command inputs, wired as vehicle_interface.launch.xml wires
# them. Its outputs are left private: remapped onto /vehicle/status/* they would
# race the simulator's own reports.
INPUTS = {
    'control_cmd': '/control/command/control_cmd',
    'gear_cmd': '/control/command/gear_cmd',
    'turn_indicators_cmd': '/control/command/turn_indicators_cmd',
    'hazard_lights_cmd': '/control/command/hazard_lights_cmd',
    'emergency_stop': '/vehicle/emergency_stop',
    'emergency_cmd': '/control/command/emergency_cmd',
}


def yaw_to_quat(yaw: float) -> tuple[float, float, float, float]:
    return 0.0, 0.0, math.sin(yaw / 2.0), math.cos(yaw / 2.0)


class CanWatch:
    """Receive-only reader of the interface's brake and vehicle frames."""

    def __init__(self, iface: str):
        import can
        import cantools

        self.db = cantools.database.load_file(str(DBC))
        self.bus = can.interface.Bus(channel=iface, interface='socketcan',
                                     can_filters=[{'can_id': i, 'can_mask': 0x7FF}
                                                  for i in (BRAKE_ID, VEHICLE_ID)])
        self.decel = None
        self.estop = None
        self.frames = 0
        self._stop = False
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while not self._stop:
            msg = self.bus.recv(timeout=0.2)
            if msg is None:
                continue
            fields = self.db.decode_message(msg.arbitration_id, msg.data,
                                            decode_choices=False)
            self.frames += 1
            if msg.arbitration_id == BRAKE_ID:
                self.decel = float(fields['Ads_Vcu_Target_Deceleration'])
            else:
                self.estop = int(fields['Ads_Vcu_Veh_Estop'])

    def close(self):
        self._stop = True
        self._thread.join(timeout=1.0)
        self.bus.shutdown()


def start_interface(iface: str, log_dir: Path) -> list[subprocess.Popen]:
    lib = REPO / 'install/golfcart_vehicle_interface/lib/golfcart_vehicle_interface'
    params = [
        REPO / 'install/golfcart_vehicle_description/share/golfcart_vehicle_description'
               '/config/vehicle_info.param.yaml',
        REPO / 'install/golfcart_vehicle_launch/share/golfcart_vehicle_launch'
               '/config/vehicle_interface.param.yaml',
    ]
    ros_args = ['--ros-args', '-r', '__node:=vehicle_interface']
    for p in params:
        ros_args += ['--params-file', str(p)]
    ros_args += ['-p', f'can_interface:={iface}']
    for name, topic in INPUTS.items():
        ros_args += ['-r', f'~/input/{name}:={topic}']
    log_dir.mkdir(parents=True, exist_ok=True)
    procs = []
    for cmd, log in (([str(lib / 'mock_vcu'), '--interface', iface, '--auto'], 'mock_vcu.log'),
                     ([str(lib / 'golfcart_vehicle_interface'), *ros_args],
                      'vehicle_interface.log')):
        procs.append(subprocess.Popen(cmd, stdout=open(log_dir / log, 'w'),
                                      stderr=subprocess.STDOUT, start_new_session=True))
    return procs


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--start', nargs=3, type=float, required=True, metavar=('X', 'Y', 'YAW_DEG'))
    ap.add_argument('--goal', nargs=3, type=float, required=True, metavar=('X', 'Y', 'YAW_DEG'))
    ap.add_argument('--leaf', default='ndt_scan_matcher: scan_matching_status',
                    help="the dummy_diag_publisher diagnostic to fault (default: NDT's, "
                         'a localization leaf, as exit criterion 4 asks)')
    ap.add_argument('--level', default='Error', choices=['Warn', 'Error', 'Stale'])
    ap.add_argument('--inject-speed', type=float, default=0.8,
                    help='m/s the cart must reach before the fault (default 0.8)')
    ap.add_argument('--min-decel', type=float, default=-2.0,
                    help='control_cmd acceleration that counts as an emergency stop '
                         '(default -2.0; the operator targets -2.5)')
    ap.add_argument('--timeout', type=float, default=20.0, help='s for each stage')
    ap.add_argument('--can', default='vcan0', help='interface for the vehicle interface')
    ap.add_argument('--no-can', action='store_true',
                    help='skip the vehicle interface and the CAN checks')
    ap.add_argument('--log-dir', type=Path, default=Path('/tmp/sim_mrm_check'),
                    help='where the interface and mock_vcu logs go')
    ap.add_argument('--route-subscriber-timeout', type=float, default=120.0,
                    help='s to wait for the lane departure checker to subscribe to the '
                         'route before setting one (route_subscriber.py); 0 skips')
    args = ap.parse_args(argv)

    import rclpy
    from autoware_adapi_v1_msgs.msg import MrmState, OperationModeState, RouteState
    from autoware_adapi_v1_msgs.srv import (ChangeOperationMode, ClearRoute,
                                            InitializeLocalization, SetRoutePoints)
    from autoware_control_msgs.msg import Control
    from geometry_msgs.msg import Pose, PoseWithCovarianceStamped
    from nav_msgs.msg import Odometry
    from rcl_interfaces.msg import Parameter, ParameterType, ParameterValue
    from rcl_interfaces.srv import SetParameters
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile
    from tier4_vehicle_msgs.msg import VehicleEmergencyStamped

    procs, watch = [], None
    if not args.no_can:
        procs = start_interface(args.can, args.log_dir)
        watch = CanWatch(args.can)

    rclpy.init()
    node = Node('sim_mrm_check')
    latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
    state = {'odom': None, 'route': None, 'mode': None, 'mrm': None,
             'emergency': None, 'accel': None}
    node.create_subscription(Odometry, '/localization/kinematic_state',
                             lambda m: state.__setitem__('odom', m), 10)
    node.create_subscription(RouteState, '/api/routing/state',
                             lambda m: state.__setitem__('route', m.state), latched)
    node.create_subscription(OperationModeState, '/api/operation_mode/state',
                             lambda m: state.__setitem__('mode', m), latched)
    node.create_subscription(MrmState, '/system/fail_safe/mrm_state',
                             lambda m: state.__setitem__('mrm', m), 10)
    node.create_subscription(VehicleEmergencyStamped, '/control/command/emergency_cmd',
                             lambda m: state.__setitem__('emergency', m.emergency), latched)
    node.create_subscription(Control, '/control/command/control_cmd',
                             lambda m: state.__setitem__('accel', m.longitudinal.acceleration),
                             10)

    def say(msg):
        print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)

    faulted = False

    def finish(code, reason):
        say(f'{"PASS" if code == 0 else "FAIL"}: {reason}')
        if faulted:  # a FAIL must not leave the simulator faulted
            set_leaf('OK')
        if watch:
            watch.close()
        for p in procs:
            os.killpg(p.pid, signal.SIGINT)
        for p in procs:
            try:
                p.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
        rclpy.try_shutdown()
        return code

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

    def set_leaf(status):
        """Set the leaf's status on dummy_diag_publisher, as `ros2 param set` would."""
        client = node.create_client(SetParameters, '/dummy_diag_publisher/set_parameters')
        if not client.wait_for_service(timeout_sec=10.0):
            return '/dummy_diag_publisher is not running: is this the planning simulator?'
        value = ParameterValue(type=ParameterType.PARAMETER_STRING, string_value=status)
        fut = client.call_async(SetParameters.Request(
            parameters=[Parameter(name=f'{args.leaf}.status', value=value)]))
        rclpy.spin_until_future_complete(node, fut, timeout_sec=5.0)
        res = fut.result()
        if res is None or not res.results[0].successful:
            why = res.results[0].reason if res is not None else 'no response'
            return f'dummy_diag_publisher refused {args.leaf!r} = {status}: {why}'
        return ''

    def wait_for(what, done, timeout=args.timeout):
        """Spin until done() holds; return seconds since the injection, or None."""
        end = time.time() + timeout
        while time.time() < end:
            rclpy.spin_once(node, timeout_sec=0.05)
            if done():
                return time.time() - t_inject
        say(f'no {what} within {timeout:.0f} s')
        return None

    def speed():
        return abs(state['odom'].twist.twist.linear.x) if state['odom'] else 0.0

    def clean_slate():
        """Stop, wait for standstill, drop the route.

        The route cannot be cleared while the cart still rolls, and after a
        PASS it does: once the leaf is OK again the MRM ends and the cart
        resumes towards the goal.
        """
        call(ChangeOperationMode, '/api/operation_mode/change_to_stop',
             ChangeOperationMode.Request(), tries=1)
        end = time.time() + 30.0
        while time.time() < end and (state['odom'] is None or speed() > 0.01):
            rclpy.spin_once(node, timeout_sec=0.1)
        call(ClearRoute, '/api/routing/clear_route', ClearRoute.Request(), tries=5)

    clean_slate()
    if (err := set_leaf('OK')):
        return finish(1, err)

    sx, sy, syaw = args.start[0], args.start[1], math.radians(args.start[2])
    gx, gy, gyaw = args.goal[0], args.goal[1], math.radians(args.goal[2])
    init = InitializeLocalization.Request()
    pose = PoseWithCovarianceStamped()
    pose.header.frame_id = 'map'
    pose.header.stamp = node.get_clock().now().to_msg()
    pose.pose.pose.position.x, pose.pose.pose.position.y = sx, sy
    o = pose.pose.pose.orientation
    o.x, o.y, o.z, o.w = yaw_to_quat(syaw)
    pose.pose.covariance[0] = pose.pose.covariance[7] = 0.25
    pose.pose.covariance[35] = 0.0685
    init.pose.append(pose)
    _, err = call(InitializeLocalization, '/api/localization/initialize', init)
    if err:
        return finish(1, f'initialize: {err}')

    from route_subscriber import wait_for_route_subscriber
    err = wait_for_route_subscriber(node, args.route_subscriber_timeout, say=say)
    if err:
        return finish(1, err)

    route = SetRoutePoints.Request()
    route.header.frame_id = 'map'
    route.header.stamp = node.get_clock().now().to_msg()
    goal = Pose()
    goal.position.x, goal.position.y = gx, gy
    q = goal.orientation
    q.x, q.y, q.z, q.w = yaw_to_quat(gyaw)
    route.goal = goal
    _, err = call(SetRoutePoints, '/api/routing/set_route_points', route)
    if err:
        return finish(1, f'route refused: {err}')
    _, err = call(ChangeOperationMode, '/api/operation_mode/change_to_autonomous',
                  ChangeOperationMode.Request())
    if err:
        return finish(1, f'engage refused: {err}')
    say('initialized, routed, engaged')

    t_inject = time.time()
    if wait_for(f'speed of {args.inject_speed} m/s', lambda: speed() >= args.inject_speed,
                timeout=60.0) is None:
        mode = state['mode']
        return finish(1, 'the cart never got going, so there is nothing to stop '
                         f'(route state {state["route"]}, mode {mode.mode if mode else None}'
                         f' in control {mode.is_autoware_control_enabled if mode else None}, '
                         f'control_cmd accel {state["accel"]}, emergency {state["emergency"]}, '
                         f'mrm_state {state["mrm"]})')
    if state['mrm'] is None or state['mrm'].state != MrmState.NORMAL:
        return finish(1, f'MRM not NORMAL before the fault: {state["mrm"]}')
    if watch and (watch.frames == 0 or watch.estop != 0):
        return finish(1, f'the interface is not driving on {args.can} '
                         f'(frames {watch.frames}, Veh_Estop {watch.estop}); '
                         f'see {args.log_dir}/vehicle_interface.log')

    v0 = speed()
    if (err := set_leaf(args.level)):
        return finish(1, err)
    faulted = True
    t_inject = time.time()
    say(f'{args.leaf!r} = {args.level} at {v0:.2f} m/s')

    # Every link is timed on its own, in one loop: waiting for them in turn
    # would date each one no earlier than the link before it.
    def mrm_is(st):
        return lambda: state['mrm'] is not None and state['mrm'].state == st

    events = {
        'MRM_OPERATING': mrm_is(MrmState.MRM_OPERATING),
        'emergency_cmd': lambda: state['emergency'] is True,
        f'control_cmd <= {args.min_decel} m/s2':
            lambda: state['accel'] is not None and state['accel'] <= args.min_decel,
        'stopped': lambda: speed() < 0.01,
        'MRM_SUCCEEDED': mrm_is(MrmState.MRM_SUCCEEDED),
    }
    if watch:
        events['CAN safety brake + Veh_Estop'] = (
            lambda: watch.estop == 1 and watch.decel is not None
            and abs(watch.decel - SAFETY_BRAKE_DECEL) < 0.06)
    timeline, behaviours, min_accel = {}, set(), 0.0
    end = time.time() + args.timeout
    while len(timeline) < len(events) and time.time() < end:
        rclpy.spin_once(node, timeout_sec=0.02)
        if state['mrm'] is not None and state['mrm'].state != MrmState.NORMAL:
            behaviours.add(state['mrm'].behavior)
        if state['accel'] is not None:
            min_accel = min(min_accel, state['accel'])
        for name, done in events.items():
            if name not in timeline and done():
                timeline[name] = time.time() - t_inject
    for name, t in sorted(timeline.items(), key=lambda kv: kv[1]):
        say(f'  +{t:5.2f} s  {name}')
    say(f'  control_cmd down to {min_accel:.2f} m/s2'
        + (f', CAN decel {watch.decel:.2f} m/s2' if watch and watch.decel is not None else ''))
    if behaviours - {MrmState.EMERGENCY_STOP}:
        return finish(1, f'MRM behaviours {sorted(behaviours)}, not only EMERGENCY_STOP: '
                         'vehicle_cmd_gate raises emergency_cmd only for an emergency stop')
    missing = [name for name in events if name not in timeline]
    if missing:
        return finish(1, f'no {", ".join(missing)} within {args.timeout:.0f} s '
                         f'(mrm_state {state["mrm"]})')

    if (err := set_leaf('OK')):
        return finish(1, err)
    faulted = False
    t_inject = time.time()
    released = wait_for('emergency_cmd release', lambda: state['emergency'] is False)
    if watch and released is not None:
        released = wait_for('Veh_Estop release', lambda: watch.estop == 0)
    if released is None:
        return finish(1, 'the emergency outlived the fault')
    say(f'  +{released:5.2f} s  released after the leaf went back to OK '
        f'(mrm_state {state["mrm"].state})')
    clean_slate()
    return finish(0, f'stopped from {v0:.2f} m/s by an injected {args.level} on {args.leaf!r}')


if __name__ == '__main__':
    sys.exit(main())
