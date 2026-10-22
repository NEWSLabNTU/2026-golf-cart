#!/usr/bin/env python3
"""Watch the reflective board detector for a while, and judge what it saw.

    python3 scripts/testing/board_check.py --duration 30
    just tool board-check                   # the usual way in; see just/tool.just

Read-only. It subscribes to what board_detector already publishes and nothing
else: /diagnostics for the detector's own counters and verdict, and
/board_detector/board_pose for every pose it chose to publish. It calls no
service and initializes nothing.

The run ends after --duration seconds, or on SIGINT/SIGTERM (Ctrl-C, or the
replay script when the bag is done), and prints one report.

PASS needs all of:
  - the detector got its TF (it left wait_tf). Without base_link <- velodyne it
    never looks at a cloud, and every other number would be zero for that
    reason alone;
  - at least --min-detections published poses;
  - detections / attempts at or above --min-rate, from the detector's own
    cumulative counters, so a batch this script happened not to sample still
    counts;
  - every published pose within --max-xy-m and --max-yaw-deg of the median
    pose. The cart is meant to be parked: a board that is found but jumps is
    as useless to localization as one that is not found.

The outcome breakdown (detected / low confidence / ambiguous / no candidate)
is SAMPLED: the detector reports only its last batch, once a second, so at
10 scans per batch and 10 Hz it is close to one sample per batch but not
exactly. It explains a FAIL; it does not decide one.

Exit 0 on PASS, 1 on FAIL, with the reason on the last line.
"""

from __future__ import annotations

import argparse
import collections
import math
import signal
import statistics
import sys
import time

DIAGNOSTIC_NAME = 'localization: board_detector'

# Message prefixes from reflective_pose_ros/decision.py, in the order a report
# lists them. Anything else (wait_tf, accumulate) is a state, not an outcome.
OUTCOMES = (
    ('detected', 'board detected'),
    ('low confidence', 'low confidence'),
    ('ambiguous', 'ambiguous'),
    ('no candidate', 'no candidate'),
)


def classify(message: str) -> str:
    for name, prefix in OUTCOMES:
        if message.startswith(prefix):
            return name
    return 'other'


def yaw_of(q) -> float:
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def wrap(angle: float) -> float:
    return math.atan2(math.sin(angle), math.cos(angle))


class Watch:
    """Everything one run collected, and the verdict on it."""

    def __init__(self):
        self.attempts = 0
        self.detections = 0
        self.states = set()
        self.outcomes = collections.Counter()
        self.last_message = {}
        self.poses = []  # (x, y, yaw)
        self._last_attempts = -1

    def on_status(self, status) -> str | None:
        values = {kv.key: kv.value for kv in status.values}
        self.states.add(values.get('state', ''))
        attempts = int(values.get('attempts', '0'))
        self.attempts = attempts
        self.detections = int(values.get('detections', '0'))
        if attempts == self._last_attempts or attempts == 0:
            return None
        self._last_attempts = attempts
        outcome = classify(status.message)
        self.outcomes[outcome] += 1
        self.last_message[outcome] = status.message
        return outcome

    def on_pose(self, msg):
        p = msg.pose.pose
        self.poses.append((p.position.x, p.position.y, yaw_of(p.orientation)))

    def spread(self):
        """Worst distance and yaw of any published pose from the median one."""
        if not self.poses:
            return None
        mx = statistics.median(p[0] for p in self.poses)
        my = statistics.median(p[1] for p in self.poses)
        # Median yaw around the first pose, so a board near +-180 deg does not
        # split into two clusters.
        ref = self.poses[0][2]
        myaw = wrap(ref + statistics.median(wrap(p[2] - ref) for p in self.poses))
        xy = max(math.hypot(p[0] - mx, p[1] - my) for p in self.poses)
        yaw = max(abs(wrap(p[2] - myaw)) for p in self.poses)
        return (mx, my, myaw), xy, yaw

    def verdict(self, args) -> tuple[bool, str]:
        if not self.states:
            return False, 'no diagnostics from board_detector: is it running?'
        if self.states <= {'wait_tf'}:
            return False, 'detector never got base_link <- velodyne TF (stuck in wait_tf)'
        if self.detections < args.min_detections:
            return False, (f'{self.detections} detections, need {args.min_detections} '
                           f'({self.attempts} attempts)')
        rate = self.detections / self.attempts if self.attempts else 0.0
        if rate < args.min_rate:
            return False, f'detection rate {rate:.0%} < {args.min_rate:.0%}'
        spread = self.spread()
        if spread is None:
            return False, 'detector counted detections but no board_pose arrived'
        _, xy, yaw = spread
        if xy > args.max_xy_m:
            return False, f'pose spread {xy:.3f} m > {args.max_xy_m:.3f} m'
        if math.degrees(yaw) > args.max_yaw_deg:
            return False, f'yaw spread {math.degrees(yaw):.2f} deg > {args.max_yaw_deg:.2f} deg'
        return True, (f'{self.detections}/{self.attempts} detected, spread '
                      f'{xy:.3f} m / {math.degrees(yaw):.2f} deg')

    def report(self, args, elapsed: float) -> int:
        print()
        print(f'board check: {elapsed:.0f} s')
        rate = self.detections / self.attempts if self.attempts else 0.0
        print(f'  attempts {self.attempts}, detections {self.detections} ({rate:.0%}), '
              f'poses received {len(self.poses)}')
        sampled = sum(self.outcomes.values())
        if sampled:
            print(f'  outcomes (sampled, {sampled} batches):')
            for name, _ in OUTCOMES + (('other', ''),):
                if self.outcomes[name]:
                    print(f'    {name:15s} {self.outcomes[name]:4d}  '
                          f'last: {self.last_message[name]}')
        spread = self.spread()
        if spread is not None:
            (mx, my, myaw), xy, yaw = spread
            print(f'  median pose in map: x {mx:.3f}  y {my:.3f}  yaw {math.degrees(myaw):.2f} deg')
            print(f'  worst deviation:    {xy:.3f} m, {math.degrees(yaw):.2f} deg')
        ok, reason = self.verdict(args)
        print(f"{'PASS' if ok else 'FAIL'}: {reason}")
        return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--duration', type=float, default=0.0,
                    help='seconds to watch; 0 watches until SIGINT/SIGTERM')
    ap.add_argument('--pose-topic', default='/board_detector/board_pose')
    ap.add_argument('--min-detections', type=int, default=3)
    ap.add_argument('--min-rate', type=float, default=0.5,
                    help='detections / attempts, 0..1')
    ap.add_argument('--max-xy-m', type=float, default=0.10)
    ap.add_argument('--max-yaw-deg', type=float, default=1.0)
    ap.add_argument('--quiet', action='store_true', help='no per-batch lines')
    args = ap.parse_args(argv)

    import rclpy
    from diagnostic_msgs.msg import DiagnosticArray
    from geometry_msgs.msg import PoseWithCovarianceStamped
    from rclpy.qos import QoSDurabilityPolicy, QoSProfile

    rclpy.init()
    node = rclpy.create_node('board_check')
    watch = Watch()

    def on_diagnostics(msg):
        for status in msg.status:
            if status.name != DIAGNOSTIC_NAME:
                continue
            outcome = watch.on_status(status)
            if outcome is not None and not args.quiet:
                print(f'[{watch.attempts:4d}] {status.message}', flush=True)

    node.create_subscription(DiagnosticArray, '/diagnostics', on_diagnostics, 50)
    # The detector latches its pose. Matching that here means a pose published
    # before this script subscribed is still seen; it is one pose, not a replay.
    latched = QoSProfile(depth=1, durability=QoSDurabilityPolicy.TRANSIENT_LOCAL)
    node.create_subscription(PoseWithCovarianceStamped, args.pose_topic, watch.on_pose, latched)

    stop = False

    def on_signal(*_):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    start = time.monotonic()
    print(f"watching board_detector{f' for {args.duration:.0f} s' if args.duration else ''}; "
          'Ctrl-C ends the run and prints the report', flush=True)
    while not stop and rclpy.ok():
        rclpy.spin_once(node, timeout_sec=0.2)
        if args.duration and time.monotonic() - start >= args.duration:
            break
    code = watch.report(args, time.monotonic() - start)
    node.destroy_node()
    rclpy.try_shutdown()
    return code


if __name__ == '__main__':
    sys.exit(main())
