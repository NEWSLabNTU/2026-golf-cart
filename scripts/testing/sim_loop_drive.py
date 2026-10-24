#!/usr/bin/env python3
"""Drive N laps of a closed loop as chained routes through the AD API, and judge each leg.

    python3 scripts/testing/sim_loop_drive.py --laps 2
    python3 scripts/testing/sim_loop_drive.py --goals data/mingda-basement/loop_goals_cw.yaml \\
        --laps 2 --csv /tmp/loop.csv

Phase 8, M6. One route round a loop fails (the goal sits just behind the start
and behavior_path_planner's drivable area collapses), so a lap is a chain of
routes: initialize at the goal file's `start`, then for each goal clear the
route, set a route to it, engage, and wait for ARRIVED before the next. Every
leg engages again: Autoware drops to STOP by itself on ARRIVED. The goal
file lives beside the map (data/mingda-basement/loop_goals_cw.yaml) and says why
its poses are where they are.

Before anything is sent, every goal is checked against the map files, offline:
on the lane's centreline and along its heading, base_link clear of lanelet
boundaries, the whole cart where the lane is wide. Autoware refuses goals that
break these ("Goal's footprint exceeds lane!"), and a refusal mid-lap is a worse
place to find out. --check-only stops there, without ROS.

Per leg it reports the arrival error, time, maximum speed, minimum cruising
speed (the slowest the cart went more than --cruise-margin from both ends of
the leg) and peak steering. With --truth-topic the arrival error is also
measured on that odometry, which is how a run with injected localization error
tells the pose Autoware believed from the pose the cart had.

PASS needs every leg to:
  - have its route accepted;
  - reach ARRIVED within --timeout;
  - stop within --tolerance of the goal (on the truth pose when given);
  - never exceed --max-speed;
  - not stop (under 0.05 m/s for 1 s) away from both ends of the leg.

Exit 0 on PASS, 1 on FAIL, with the reason on the last line.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass, field
import math
from pathlib import Path
import sys
import time
import xml.etree.ElementTree as ET

import yaml

REPO = Path(__file__).resolve().parents[2]
DEFAULT_GOALS = REPO / 'data/mingda-basement/loop_goals_cw.yaml'
VEHICLE_INFO = (REPO / 'src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description'
                / 'config/vehicle_info.param.yaml')

STOP_SPEED = 0.05      # m/s, below this the cart is stopped
STOP_HOLD = 1.0        # s a mid-leg stop must last to count


# ---------------------------------------------------------------------------
# Goal file
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Goal:
    name: str
    x: float
    y: float
    yaw_deg: float

    @property
    def yaw(self) -> float:
        return math.radians(self.yaw_deg)


@dataclass(frozen=True)
class LoopPlan:
    start: Goal
    goals: tuple[Goal, ...]
    allow_goal_modification: bool = False
    lanelet2_map_file: str | None = None
    centreline: Path | None = None
    frame_id: str = 'map'


def _goal(entry, where: str) -> Goal:
    if not isinstance(entry, dict):
        raise ValueError(f'{where}: expected a mapping with x, y, yaw_deg')
    missing = [k for k in ('x', 'y', 'yaw_deg') if k not in entry]
    if missing:
        raise ValueError(f'{where}: missing {", ".join(missing)}')
    try:
        x, y, yaw = float(entry['x']), float(entry['y']), float(entry['yaw_deg'])
    except (TypeError, ValueError) as e:
        raise ValueError(f'{where}: x, y, yaw_deg must be numbers ({e})') from None
    if not all(math.isfinite(v) for v in (x, y, yaw)):
        raise ValueError(f'{where}: x, y, yaw_deg must be finite')
    if not -360.0 <= yaw <= 360.0:
        raise ValueError(f'{where}: yaw_deg {yaw} is degrees, not radians or junk')
    return Goal(str(entry.get('name', where)), x, y, yaw)


def load_goals(path: Path | str) -> LoopPlan:
    """Read a loop goal file. Raises ValueError naming the first problem."""
    path = Path(path)
    data = yaml.safe_load(path.read_text())
    if not isinstance(data, dict):
        raise ValueError(f'{path}: expected a mapping at the top level')
    if data.get('frame_id', 'map') != 'map':
        raise ValueError(f'{path}: frame_id must be map, not {data["frame_id"]}')
    if 'start' not in data:
        raise ValueError(f'{path}: no start pose')
    goals = data.get('goals')
    if not isinstance(goals, list) or not goals:
        raise ValueError(f'{path}: goals must be a non-empty list')
    start = _goal(data['start'], 'start')
    parsed = tuple(_goal(g, f'goals[{i}]') for i, g in enumerate(goals))
    centreline = data.get('centreline')
    return LoopPlan(
        start=start,
        goals=parsed,
        allow_goal_modification=bool(data.get('allow_goal_modification', False)),
        lanelet2_map_file=data.get('lanelet2_map_file'),
        centreline=(path.parent / centreline) if centreline else None,
    )


@dataclass(frozen=True)
class Leg:
    index: int     # 0-based over the whole run
    lap: int       # 1-based
    goal_index: int
    goal: Goal
    origin: Goal   # the pose the leg starts from, nominally


def leg_sequence(plan: LoopPlan, laps: int) -> list[Leg]:
    """Every leg of `laps` laps, in order. Each leg starts where the previous ended."""
    if laps < 1:
        raise ValueError('laps must be at least 1')
    legs = []
    origin = plan.start
    for lap in range(1, laps + 1):
        for gi, goal in enumerate(plan.goals):
            legs.append(Leg(len(legs), lap, gi, goal, origin))
            origin = goal
    return legs


# ---------------------------------------------------------------------------
# Offline goal placement check against the map files
# ---------------------------------------------------------------------------

def load_centreline(path: Path) -> list[tuple[float, float, float]]:
    """(x, y, width) points of a centerline_to_lanelet.py route YAML."""
    pts = yaml.safe_load(Path(path).read_text())
    return [(float(p['x']), float(p['y']), float(p.get('width', 0.0))) for p in pts]


def arc_lengths(pts) -> list[float]:
    s = [0.0]
    for a, b in zip(pts, pts[1:]):
        s.append(s[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    return s


def project(pts, s, x, y):
    """Nearest point on the polyline: (distance, arc length, segment index, segment heading)."""
    best = None
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        dx, dy = b[0] - a[0], b[1] - a[1]
        ll = dx * dx + dy * dy
        if ll == 0.0:
            continue
        t = max(0.0, min(1.0, ((x - a[0]) * dx + (y - a[1]) * dy) / ll))
        qx, qy = a[0] + t * dx, a[1] + t * dy
        d = math.hypot(x - qx, y - qy)
        if best is None or d < best[0]:
            best = (d, s[i] + t * math.sqrt(ll), i, math.atan2(dy, dx))
    return best


def lanelet_boundaries(osm: Path) -> list[tuple[float, float]]:
    """Midpoints of each lanelet's two ends: where one lanelet hands over to the next."""
    root = ET.parse(osm).getroot()
    nodes = {}
    for n in root.iter('node'):
        tags = {t.get('k'): t.get('v') for t in n.iter('tag')}
        if 'local_x' in tags and 'local_y' in tags:
            nodes[n.get('id')] = (float(tags['local_x']), float(tags['local_y']))
    ways = {w.get('id'): [nd.get('ref') for nd in w.iter('nd')] for w in root.iter('way')}
    ends = []
    for rel in root.iter('relation'):
        tags = {t.get('k'): t.get('v') for t in rel.iter('tag')}
        if tags.get('type') != 'lanelet':
            continue
        role = {m.get('role'): m.get('ref') for m in rel.iter('member')}
        left, right = ways[role['left']], ways[role['right']]
        for i in (0, -1):
            a, b = nodes[left[i]], nodes[right[i]]
            ends.append(((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0))
    return ends


def vehicle_extent(path: Path = VEHICLE_INFO) -> tuple[float, float]:
    """(rear, front) of the body from base_link along x, from vehicle_info.param.yaml."""
    p = yaml.safe_load(Path(path).read_text())['/**']['ros__parameters']
    return float(p['rear_overhang']), float(p['wheel_base']) + float(p['front_overhang'])


def wrap(a: float) -> float:
    return (a + math.pi) % (2.0 * math.pi) - math.pi


def check_goal_placement(plan: LoopPlan, centreline, boundaries, extent,
                         *, max_offset=0.05, max_heading_deg=3.0,
                         min_boundary=0.5, min_width=2.0) -> list[str]:
    """Problems with where the goals sit, as messages; empty when every goal is placeable.

    centreline: [(x, y, width)] closed loop in travel order; boundaries: lanelet
    hand-over points; extent: (rear, front) of the body from base_link.
    """
    s = arc_lengths(centreline)
    loop = s[-1]
    bs = [project(centreline, s, bx, by)[1] for bx, by in boundaries]
    rear, front = extent
    problems = []
    for g in (plan.start, *plan.goals):
        d, sg, _, heading = project(centreline, s, g.x, g.y)
        tag = f'{g.name} ({g.x:.2f}, {g.y:.2f})'
        if d > max_offset:
            problems.append(f'{tag}: {d:.2f} m off the centreline')
        dh = abs(math.degrees(wrap(g.yaw - heading)))
        if dh > max_heading_deg:
            problems.append(f'{tag}: heading {dh:.1f} deg off the lane')
        if g is plan.start:
            continue
        gap = min(min(abs(sg - b), loop - abs(sg - b)) for b in bs) if bs else math.inf
        if gap < min_boundary:
            problems.append(f'{tag}: {gap:.2f} m from a lanelet boundary (< {min_boundary})')
        for p, sp in zip(centreline, s):
            ahead = (sp - sg) % loop
            behind = (sg - sp) % loop
            if (ahead <= front or behind <= rear) and p[2] < min_width:
                problems.append(f'{tag}: the cart would stand where the lane is '
                                f'{p[2]:.2f} m wide (< {min_width})')
                break
    return problems


# ---------------------------------------------------------------------------
# Per-leg statistics and the verdict
# ---------------------------------------------------------------------------

@dataclass
class LegStats:
    """Samples of one leg, reduced to the numbers the report needs."""
    start_xy: tuple[float, float]
    goal: Goal
    cruise_margin: float = 3.0
    t0: float | None = None
    t_end: float | None = None
    v_max: float = 0.0
    v_min_cruise: float | None = None
    steer_max: float = 0.0
    stops: int = 0
    _stopped_since: float | None = None
    _counted: bool = False
    last_xy: tuple[float, float] | None = None
    truth_xy: tuple[float, float] | None = None

    def add(self, t: float, x: float, y: float, v: float, steer: float = 0.0) -> None:
        if self.t0 is None:
            self.t0 = t
        self.t_end = t
        self.last_xy = (x, y)
        speed = abs(v)
        self.v_max = max(self.v_max, speed)
        self.steer_max = max(self.steer_max, abs(steer))
        mid = (math.hypot(x - self.start_xy[0], y - self.start_xy[1]) > self.cruise_margin
               and math.hypot(x - self.goal.x, y - self.goal.y) > self.cruise_margin)
        if mid:
            prev = self.v_min_cruise
            self.v_min_cruise = speed if prev is None else min(prev, speed)
        if mid and speed < STOP_SPEED:
            if self._stopped_since is None:
                self._stopped_since, self._counted = t, False
            elif not self._counted and t - self._stopped_since >= STOP_HOLD:
                self.stops += 1
                self._counted = True
        else:
            self._stopped_since = None

    def add_truth(self, x: float, y: float) -> None:
        self.truth_xy = (x, y)

    def error(self, truth: bool = False) -> float | None:
        xy = self.truth_xy if truth else self.last_xy
        if xy is None:
            return None
        return math.hypot(xy[0] - self.goal.x, xy[1] - self.goal.y)

    @property
    def duration(self) -> float:
        return 0.0 if self.t0 is None else self.t_end - self.t0


@dataclass
class LegResult:
    leg: Leg
    stats: LegStats
    arrived: bool
    refused: str = ''
    notes: list[str] = field(default_factory=list)


def judge_leg(r: LegResult, tolerance: float, max_speed: float, use_truth: bool) -> list[str]:
    """Why this leg failed; empty when it passed."""
    tag = f'lap {r.leg.lap} leg {r.leg.goal_index + 1} ({r.leg.goal.name})'
    if r.refused:
        return [f'{tag}: {r.refused}']
    why = []
    if not r.arrived:
        why.append(f'{tag}: not ARRIVED')
    err = r.stats.error(truth=use_truth)
    if r.arrived and (err is None or err > tolerance):
        shown = 'no pose' if err is None else f'{err:.2f} m'
        why.append(f'{tag}: stopped {shown} from the goal (> {tolerance} m)')
    if r.stats.v_max > max_speed:
        why.append(f'{tag}: {r.stats.v_max:.2f} m/s over the {max_speed} m/s ceiling')
    if r.stats.stops:
        why.append(f'{tag}: stopped {r.stats.stops}x mid-leg')
    return why


def format_row(r: LegResult, use_truth: bool) -> str:
    s = r.stats
    est = s.error()
    tru = s.error(truth=True) if use_truth else None
    vmin = '-' if s.v_min_cruise is None else f'{s.v_min_cruise:.2f}'
    cols = [f'{r.leg.lap:>3}', f'{r.leg.goal_index + 1:>3}', f'{r.leg.goal.name:<16.16}',
            'ARRIVED' if r.arrived else ('REFUSED' if r.refused else 'TIMEOUT'),
            f'{est:6.3f}' if est is not None else '     -']
    if use_truth:
        cols.append(f'{tru:6.3f}' if tru is not None else '     -')
    cols += [f'{s.duration:5.0f}', f'{s.v_max:5.2f}', f'{vmin:>5}',
             f'{math.degrees(s.steer_max):5.1f}', f'{s.stops:>3}']
    return '  '.join(cols)


def header(use_truth: bool) -> str:
    cols = ['lap', 'leg', f'{"goal":<16}', 'state  ', 'err m ']
    if use_truth:
        cols.append('true m')
    cols += ['    s', 'v max', 'v min', 'steer', 'stp']
    return '  '.join(cols)


# ---------------------------------------------------------------------------
# ROS
# ---------------------------------------------------------------------------

def yaw_to_quat(yaw: float) -> tuple[float, float, float, float]:
    return 0.0, 0.0, math.sin(yaw / 2.0), math.cos(yaw / 2.0)


def quat_yaw(q) -> float:
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def preflight(plan: LoopPlan, goals_path: Path) -> list[str]:
    if plan.centreline is None or plan.lanelet2_map_file is None:
        return []
    osm = goals_path.parent / plan.lanelet2_map_file
    if not plan.centreline.exists() or not osm.exists():
        return [f'cannot check placement: {plan.centreline} or {osm} missing']
    return check_goal_placement(plan, load_centreline(plan.centreline),
                                lanelet_boundaries(osm), vehicle_extent())


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--goals', type=Path, default=DEFAULT_GOALS)
    ap.add_argument('--laps', type=int, default=2)
    ap.add_argument('--timeout', type=float, default=240.0, help='per leg, s')
    ap.add_argument('--tolerance', type=float, default=0.5,
                    help='m from the goal; Phase 9 asks for 0.5')
    ap.add_argument('--max-speed', type=float, default=1.5,
                    help='m/s; the vehicle interface caps commands at 1.5')
    ap.add_argument('--cruise-margin', type=float, default=3.0,
                    help='m from both ends of a leg before speed counts as cruising')
    ap.add_argument('--truth-topic', default='',
                    help='Odometry of the true pose, e.g. /simulation/debug/localization/'
                         'kinematic_state when localization runs on a perturbed pose')
    ap.add_argument('--no-init', action='store_true',
                    help='do not initialize localization: the stack already knows where it is')
    ap.add_argument('--csv', type=Path, help='write every kinematic_state sample here')
    ap.add_argument('--check-only', action='store_true',
                    help='check the goal placement against the map files and exit')
    args = ap.parse_args(argv)

    def say(msg):
        print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)

    try:
        plan = load_goals(args.goals)
        legs = leg_sequence(plan, args.laps)
    except (OSError, ValueError) as e:
        say(f'FAIL: {e}')
        return 1
    problems = preflight(plan, args.goals)
    for p in problems:
        say(f'goal placement: {p}')
    if problems:
        say(f'FAIL: {len(problems)} goal(s) Autoware is likely to refuse; move them first')
        return 1
    say(f'{args.goals.name}: start + {len(plan.goals)} goals, {args.laps} lap(s), '
        f'{len(legs)} legs, placement OK')
    if args.check_only:
        return 0

    import rclpy
    from autoware_adapi_v1_msgs.msg import RouteState
    from autoware_adapi_v1_msgs.srv import (ChangeOperationMode, ClearRoute,
                                            InitializeLocalization, SetRoutePoints)
    from autoware_vehicle_msgs.msg import SteeringReport
    from geometry_msgs.msg import Pose, PoseWithCovarianceStamped
    from nav_msgs.msg import Odometry
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile

    rclpy.init()
    node = Node('sim_loop_drive')
    latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL)
    st = {'odom': None, 'truth': None, 'route': None, 'steer': 0.0,
          'leg': None, 'stats': None}
    out = None
    writer = None
    if args.csv:
        out = open(args.csv, 'w', newline='')
        writer = csv.writer(out)
        writer.writerow(['t', 'lap', 'leg', 'x', 'y', 'yaw', 'v', 'steer', 'tx', 'ty', 'tyaw'])

    def on_odom(m):
        st['odom'] = m
        p = m.pose.pose.position
        v = m.twist.twist.linear.x
        now = time.time()
        if st['stats'] is not None:
            st['stats'].add(now, p.x, p.y, v, st['steer'])
        if writer is not None and st['leg'] is not None:
            tr = st['truth']
            tcols = ['', '', '']
            if tr is not None:
                tp = tr.pose.pose
                tcols = [f'{tp.position.x:.3f}', f'{tp.position.y:.3f}',
                         f'{quat_yaw(tp.orientation):.4f}']
            writer.writerow([f'{now:.3f}', st['leg'].lap, st['leg'].index,
                             f'{p.x:.3f}', f'{p.y:.3f}', f'{quat_yaw(m.pose.pose.orientation):.4f}',
                             f'{v:.3f}', f'{st["steer"]:.4f}', *tcols])

    def on_truth(m):
        st['truth'] = m
        if st['stats'] is not None:
            st['stats'].add_truth(m.pose.pose.position.x, m.pose.pose.position.y)

    node.create_subscription(Odometry, '/localization/kinematic_state', on_odom, 10)
    if args.truth_topic:
        node.create_subscription(Odometry, args.truth_topic, on_truth, 10)
    node.create_subscription(SteeringReport, '/vehicle/status/steering_status',
                             lambda m: st.__setitem__('steer', m.steering_tire_angle), 10)
    node.create_subscription(RouteState, '/api/routing/state',
                             lambda m: st.__setitem__('route', m.state), latched)

    def spin(sec):
        end = time.time() + sec
        while time.time() < end:
            rclpy.spin_once(node, timeout_sec=0.05)

    def call(srv_type, name, request, tries=10, every=2.0):
        client = node.create_client(srv_type, name)
        if not client.wait_for_service(timeout_sec=60.0):
            return f'{name} never appeared'
        last = ''
        for _ in range(tries):
            fut = client.call_async(request)
            rclpy.spin_until_future_complete(node, fut, timeout_sec=10.0)
            res = fut.result()
            if res is not None and res.status.success:
                return ''
            last = res.status.message if res is not None else 'no response'
            spin(every)
        return f'{name}: {last}'

    def finish(code, reason):
        say(('PASS: ' if code == 0 else 'FAIL: ') + reason)
        if out is not None:
            out.close()
        rclpy.try_shutdown()
        return code

    if not args.no_init:
        for srv_type, name in ((ChangeOperationMode, '/api/operation_mode/change_to_stop'),
                               (ClearRoute, '/api/routing/clear_route')):
            call(srv_type, name, srv_type.Request(), tries=1)
        init = InitializeLocalization.Request()
        pose = PoseWithCovarianceStamped()
        pose.header.frame_id = 'map'
        pose.header.stamp = node.get_clock().now().to_msg()
        pose.pose.pose.position.x, pose.pose.pose.position.y = plan.start.x, plan.start.y
        o = pose.pose.pose.orientation
        o.x, o.y, o.z, o.w = yaw_to_quat(plan.start.yaw)
        pose.pose.covariance[0] = pose.pose.covariance[7] = 0.25
        pose.pose.covariance[35] = 0.0685
        init.pose.append(pose)
        err = call(InitializeLocalization, '/api/localization/initialize', init)
        if err:
            return finish(1, f'initialize: {err}')
        say(f'localization initialized at {plan.start.name}')
        spin(2.0)

    use_truth = bool(args.truth_topic)
    results: list[LegResult] = []
    t_run = time.time()
    for leg in legs:
        call(ClearRoute, '/api/routing/clear_route', ClearRoute.Request(), tries=1)
        spin(0.5)
        req = SetRoutePoints.Request()
        req.header.frame_id = 'map'
        req.header.stamp = node.get_clock().now().to_msg()
        g = Pose()
        g.position.x, g.position.y = leg.goal.x, leg.goal.y
        g.orientation.x, g.orientation.y, g.orientation.z, g.orientation.w = \
            yaw_to_quat(leg.goal.yaw)
        req.goal = g
        req.option.allow_goal_modification = plan.allow_goal_modification
        here = st['odom'].pose.pose.position if st['odom'] else None
        stats = LegStats((here.x, here.y) if here else (leg.origin.x, leg.origin.y),
                         leg.goal, cruise_margin=args.cruise_margin)
        err = call(SetRoutePoints, '/api/routing/set_route_points', req)
        if err:
            results.append(LegResult(leg, stats, False, refused=f'route refused: {err}'))
            break
        # The route state is latched: wait to see this route SET before
        # watching for ARRIVED, or the previous leg's ARRIVED ends this one.
        end = time.time() + 10.0
        while time.time() < end and st['route'] != RouteState.SET:
            rclpy.spin_once(node, timeout_sec=0.05)
        err = call(ChangeOperationMode, '/api/operation_mode/change_to_autonomous',
                   ChangeOperationMode.Request())
        if err:
            results.append(LegResult(leg, stats, False, refused=f'engage refused: {err}'))
            break
        say(f'lap {leg.lap} leg {leg.goal_index + 1}: route to {leg.goal.name} '
            f'({leg.goal.x:.2f}, {leg.goal.y:.2f}) engaged')
        st['leg'], st['stats'] = leg, stats
        deadline = time.time() + args.timeout
        while time.time() < deadline and st['route'] != RouteState.ARRIVED:
            rclpy.spin_once(node, timeout_sec=0.05)
        arrived = st['route'] == RouteState.ARRIVED
        spin(0.5)  # settle: the last odometry after the stop
        st['stats'] = None
        r = LegResult(leg, stats, arrived)
        results.append(r)
        say(format_row(r, use_truth))
        if not arrived:
            break

    print(header(use_truth))
    for r in results:
        print(format_row(r, use_truth))
    reasons = [w for r in results for w in judge_leg(r, args.tolerance, args.max_speed, use_truth)]
    if len(results) < len(legs) and not reasons:
        reasons.append(f'only {len(results)} of {len(legs)} legs ran')
    errs = [r.stats.error(truth=use_truth) for r in results if r.arrived]
    errs = [e for e in errs if e is not None]
    summary = (f'{len(results)}/{len(legs)} legs in {time.time() - t_run:.0f} s, '
               f'arrival error max {max(errs):.2f} m' if errs else 'no leg arrived')
    if reasons:
        return finish(1, '; '.join(reasons) + f' ({summary})')
    vmax = max(r.stats.v_max for r in results)
    return finish(0, f'{summary}, max speed {vmax:.2f} m/s')


if __name__ == '__main__':
    sys.exit(main())
