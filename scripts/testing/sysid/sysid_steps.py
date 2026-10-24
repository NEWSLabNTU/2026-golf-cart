#!/usr/bin/env python3
"""Publish open-loop steering, speed and brake steps for system identification.

    python3 scripts/testing/sysid/sysid_steps.py PROFILE --dry-run   # the timeline, no ROS
    python3 scripts/testing/sysid/sysid_steps.py PROFILE             # on the cart, in AUTO

Phase 8, V4. Profiles (positive steer = LEFT, REP-103):

  steer-standstill  speed 0 in DRIVE; for each amplitude: left, centre, right,
                    centre. Right is capped at --right-max (mechanical stop ~22 deg).
  steer-crawl       at --speed: doublets left/centre/right/centre, then a stage-1
                    brake. The yaw-rate channel (steer_yaw) of sysid_fit.py
                    identifies the LEFT steps from these, which the VCU's report
                    cannot (it reads 0 for left).
  speed             speed steps up and down (the down steps without brake), then
                    a stage-1 brake.
  brake             for each level: accelerate to --speed, then speed 0 with
                    acceleration -level, then still. Levels either side of the
                    VCU's 1.2 / 1.8 / 2.8 m/s2 stages answer S3.

Publishes /control/command/control_cmd and /control/command/gear_cmd (DRIVE) at
30 Hz, as `just vehicle manual-control` does, so it is the only command source:
it refuses to start if anything else publishes control_cmd (Autoware's
vehicle_cmd_gate, the keyboard), and waits until /vehicle/status/control_mode
reads AUTONOMOUS. The driver enters AUTO on the dashboard as for any drive, and
leaves it, or presses the e-stop, to end the run early; the script stops
commanding as soon as the mode leaves AUTONOMOUS. On Ctrl-C and at the end it
holds speed 0 with a stage-1 brake for 2 s, then stops publishing, and the
interface's 500 ms control watchdog brakes.

The acceleration field is open loop: +--accel for the time a rising speed step
needs at that rate, 0 on falling steps (the VCU's own speed loop slows the
cart, motor on), -level in a brake step.
"""

from __future__ import annotations

import argparse
import dataclasses
import math
import sys
import time

RATE_HZ = 30.0
EXPECTED_STEER_DPS = 7.5     # Phase 9: the right report slews ~7-8 deg/s at the wheels
STOP_BRAKE = 1.5             # m/s2, VCU stage 1


@dataclasses.dataclass
class Segment:
    t: float                 # start [s]
    dur: float               # hold [s]
    steer_deg: float
    speed: float             # m/s
    accel: float             # m/s2 for the first `accel_dur` s of the segment
    accel_dur: float = 0.0
    label: str = ''

    def at(self, t_rel: float) -> tuple[float, float, float]:
        a = self.accel if t_rel < self.accel_dur else 0.0
        return math.radians(self.steer_deg), self.speed, a


class Builder:
    def __init__(self, accel: float):
        self.segs: list[Segment] = []
        self.t = 0.0
        self.speed = 0.0
        self.accel = accel

    def add(self, dur: float, steer_deg: float, speed: float | None = None,
            brake: float | None = None, label: str = '') -> None:
        speed = self.speed if speed is None else speed
        if brake is not None:
            accel, accel_dur = -brake, dur
        elif speed > self.speed + 1e-9:
            accel, accel_dur = self.accel, (speed - self.speed) / self.accel
        else:
            accel, accel_dur = 0.0, 0.0
        self.segs.append(Segment(self.t, dur, steer_deg, speed, accel, accel_dur, label))
        self.t += dur
        self.speed = speed


def steer_hold(amp_deg: float, hold_min: float, settle: float = 3.0) -> float:
    """Long enough for a rate-limited slew plus a few time constants."""
    return max(hold_min, amp_deg / EXPECTED_STEER_DPS + settle)


def build_profile(name: str, amps=None, right_max: float = 20.0, speed: float | None = None,
                  levels=None, hold: float | None = None, accel: float = 0.5) -> list[Segment]:
    b = Builder(accel)
    hold = DEFAULT_HOLD[name] if hold is None else hold
    if name == 'steer-standstill':
        amps = amps or [2.0, 5.0, 10.0, 15.0, 20.0]
        b.add(2.0, 0.0, 0.0, label='settle')
        for a in amps:
            h = steer_hold(a, hold)
            b.add(h, a, label=f'left {a:g}')
            b.add(h, 0.0, label='centre')
            r = min(a, right_max)
            b.add(steer_hold(r, hold), -r, label=f'right {r:g}')
            b.add(steer_hold(r, hold), 0.0, label='centre')
    elif name == 'steer-crawl':
        amps = amps or [3.0, 6.0]
        v = 0.5 if speed is None else speed
        b.add(1.0, 0.0, 0.0, label='settle')
        b.add(v / accel + 2.0, 0.0, v, label=f'to {v:g} m/s')
        for a in amps:
            r = min(a, right_max)
            # Shorter settle than at standstill: the basement lane is 17.8 m.
            b.add(steer_hold(a, hold, 2.0), a, label=f'left {a:g}')
            b.add(steer_hold(a, hold, 2.0), 0.0, label='centre')
            b.add(steer_hold(r, hold, 2.0), -r, label=f'right {r:g}')
            b.add(steer_hold(r, hold, 2.0), 0.0, label='centre')
        b.add(3.0, 0.0, 0.0, brake=STOP_BRAKE, label='stop')
    elif name == 'speed':
        levels = levels or [0.5, 1.0, 0.5, 0.0]
        b.add(2.0, 0.0, 0.0, label='settle')
        for v in levels:
            b.add(hold, 0.0, v, label=f'speed {v:g}')
        b.add(3.0, 0.0, 0.0, brake=STOP_BRAKE, label='stop')
    elif name == 'brake':
        levels = levels or [1.5, 2.0, 3.0]
        v = 1.0 if speed is None else speed
        b.add(2.0, 0.0, 0.0, label='settle')
        for lv in levels:
            b.add(v / accel + 2.0, 0.0, v, label=f'to {v:g} m/s')
            b.add(4.0, 0.0, 0.0, brake=lv, label=f'brake {lv:g}')
            b.add(2.0, 0.0, 0.0, label='still')
    else:
        raise ValueError(f'unknown profile {name}')
    return b.segs


PROFILES = ('steer-standstill', 'steer-crawl', 'speed', 'brake')
DEFAULT_HOLD = {'steer-standstill': 4.0, 'steer-crawl': 2.5, 'speed': 5.0, 'brake': 2.0}


def command_at(segs: list[Segment], t: float) -> tuple[float, float, float] | None:
    for s in segs:
        if s.t <= t < s.t + s.dur:
            return s.at(t - s.t)
    return None


def distance(segs: list[Segment], accel: float, dt: float = 0.01) -> float:
    """Rough travel: speed follows the command at `accel` up and down."""
    v = x = 0.0
    t = 0.0
    end = segs[-1].t + segs[-1].dur
    while t < end:
        _, vc, _ = command_at(segs, t)
        v += max(-accel * 2 * dt, min(accel * dt, vc - v))
        x += v * dt
        t += dt
    return x


def print_timeline(segs: list[Segment], accel: float, out=None) -> None:
    out = out or sys.stdout
    for s in segs:
        a = f'{s.accel:+.1f} for {s.accel_dur:.1f}s' if s.accel_dur else '  0'
        print(f'{s.t:7.1f} s  +{s.dur:4.1f}  steer {s.steer_deg:+6.1f} deg  '
              f'speed {s.speed:4.2f} m/s  accel {a:14s}  {s.label}', file=out)
    end = segs[-1].t + segs[-1].dur
    print(f'total {end:.0f} s, about {distance(segs, accel):.1f} m of travel', file=out)


def run(segs: list[Segment], args) -> int:
    import rclpy
    from autoware_control_msgs.msg import Control
    from autoware_vehicle_msgs.msg import ControlModeReport, GearCommand, VelocityReport

    rclpy.init()
    node = rclpy.create_node('sysid_steps')
    pub = node.create_publisher(Control, '/control/command/control_cmd', 10)
    gear = node.create_publisher(GearCommand, '/control/command/gear_cmd', 10)
    state = {'mode': None, 'v': float('nan')}
    node.create_subscription(ControlModeReport, '/vehicle/status/control_mode',
                             lambda m: state.__setitem__('mode', m.mode), 10)
    node.create_subscription(VelocityReport, '/vehicle/status/velocity_status',
                             lambda m: state.__setitem__('v', m.longitudinal_velocity), 10)
    log = node.get_logger()

    def spin_for(sec: float) -> None:
        end = time.monotonic() + sec
        while time.monotonic() < end:
            rclpy.spin_once(node, timeout_sec=0.01)

    def send(steer: float, v: float, a: float) -> None:
        now = node.get_clock().now().to_msg()
        c = Control()
        c.stamp = now
        c.lateral.stamp = now
        c.longitudinal.stamp = now
        c.lateral.steering_tire_angle = steer
        c.longitudinal.velocity = v
        c.longitudinal.acceleration = a
        g = GearCommand()
        g.stamp = now
        g.command = GearCommand.DRIVE
        gear.publish(g)
        pub.publish(c)

    spin_for(1.5)  # discovery
    others = node.count_publishers('/control/command/control_cmd') - 1
    if others > 0 and not args.force:
        log.error(f'{others} other publisher(s) on /control/command/control_cmd '
                  '(vehicle_cmd_gate? the keyboard?). Stop them, or --force.')
        return 2
    if not args.no_wait_auto:
        log.info('waiting for /vehicle/status/control_mode AUTONOMOUS (driver: brake + AUTO)')
        while state['mode'] != ControlModeReport.AUTONOMOUS:
            send(0.0, 0.0, 0.0)  # keep the interface's control input fresh, idle
            spin_for(1.0 / RATE_HZ)
    log.info(f'{args.profile}: {len(segs)} segments, {segs[-1].t + segs[-1].dur:.0f} s')
    period = 1.0 / RATE_HZ
    t0 = time.monotonic()
    last_label = None
    steer = 0.0
    try:
        while True:
            t = time.monotonic() - t0
            cmd = command_at(segs, t)
            if cmd is None:
                break
            if not args.no_wait_auto and state['mode'] != ControlModeReport.AUTONOMOUS:
                log.warn('control mode left AUTONOMOUS: stopping')
                return 1
            seg = next(s for s in segs if s.t <= t < s.t + s.dur)
            if seg.label != last_label:
                log.info(f't={t:6.2f}  {seg.label}  (v={state["v"]:.2f} m/s)')
                last_label = seg.label
            steer = cmd[0]
            send(*cmd)
            spin_for(max(0.0, t0 + (math.floor(t / period) + 1) * period - time.monotonic()))
    except KeyboardInterrupt:
        log.warn('interrupted')
    finally:
        log.info(f'holding speed 0, brake {STOP_BRAKE} m/s2 for 2 s, then silent')
        end = time.monotonic() + 2.0
        while time.monotonic() < end:
            send(steer, 0.0, -STOP_BRAKE)
            spin_for(period)
        node.destroy_node()
        rclpy.try_shutdown()
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split('\n\n', 1)[1])
    ap.add_argument('profile', choices=PROFILES)
    ap.add_argument('--amps', help='steer amplitudes, deg, comma separated')
    ap.add_argument('--right-max', type=float, default=20.0,
                    help='cap on right steps, deg (mechanical stop ~22)')
    ap.add_argument('--speed', type=float, help='crawl / pre-brake speed, m/s')
    ap.add_argument('--levels', help='speed profile: speeds, m/s; brake profile: decelerations, m/s2')
    ap.add_argument('--hold', type=float,
                    help='minimum hold per step, s (default: standstill 4, crawl 2.5, speed 5)')
    ap.add_argument('--accel', type=float, default=0.5,
                    help='acceleration sent with rising speed steps, m/s2')
    ap.add_argument('--dry-run', action='store_true', help='print the timeline only')
    ap.add_argument('--no-wait-auto', action='store_true',
                    help='do not wait for or watch AUTONOMOUS (vcan0 with mock_vcu --auto)')
    ap.add_argument('--force', action='store_true', help='start beside another control_cmd publisher')
    args = ap.parse_args(argv)
    fl = (lambda s: [float(x) for x in s.split(',')] if s else None)
    segs = build_profile(args.profile, amps=fl(args.amps), right_max=args.right_max,
                         speed=args.speed, levels=fl(args.levels), hold=args.hold,
                         accel=args.accel)
    print_timeline(segs, args.accel)
    if args.dry_run:
        return 0
    return run(segs, args)


if __name__ == '__main__':
    sys.exit(main())
