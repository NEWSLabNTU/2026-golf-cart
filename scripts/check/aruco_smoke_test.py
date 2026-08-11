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

"""Phase 3D-6 stage 1: run the ArUco stack against synthetic detections and
grade it.

Launches ``sim_smoke.launch.xml`` per scenario, records the fused pose against
ground truth, and asserts the outcome each scenario is meant to produce. Exits
non-zero if any scenario fails, so it can gate a merge.

    ros2 run --prefix 'python3' ...            # not installed as a ros2 exec
    python3 scripts/check/aruco_smoke_test.py            # every scenario
    python3 scripts/check/aruco_smoke_test.py --list
    python3 scripts/check/aruco_smoke_test.py straight blackout

Error is reported in the VEHICLE frame — lateral and longitudinal separately —
because the two have different causes and different consequences. A longitudinal
error is a board-range error; a lateral one usually means heading. Reporting a
single Euclidean number hides which.
"""

from __future__ import annotations

import argparse
import math
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field

WORKSPACE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@dataclass
class Expect:
    """What a scenario is asserted to produce.

    ``None`` means "not checked" rather than "no limit" — several scenarios
    deliberately assert on state alone, because their whole point is that the
    pose is untrustworthy.
    """

    max_lateral_m: float | None = None
    max_longitudinal_m: float | None = None
    max_heading_deg: float | None = None
    # Median limits, for scenarios where the tail is a known and understood
    # excursion rather than a defect. Stating both is more honest than widening
    # the p95 until it passes and calling the result clean.
    max_lateral_p50_m: float | None = None
    max_longitudinal_p50_m: float | None = None
    min_fixes: int = 1
    # Localization states that must appear at some point, and that must not.
    require_states: tuple[str, ...] = ()
    forbid_states: tuple[str, ...] = ()
    # Board IDs the integrity monitor must exclude, and must not.
    require_flagged: tuple[int, ...] = ()
    forbid_other_flags: bool = False
    require_mrm: bool = False


@dataclass
class Scenario:
    name: str
    args: dict[str, str]
    seconds: float
    expect: Expect
    why: str


# The envelope numbers are deliberately loose. This is a smoke test: it is
# looking for "the stack is coherent", not for accuracy, which needs real
# optics and comes from phase 3D-7. Tightening these without real data would
# only encode the simulator's own assumptions as a requirement.
SCENARIOS: list[Scenario] = [
    Scenario(
        "straight",
        {"pattern": "straight"},
        25.0,
        Expect(
            max_lateral_m=0.20,
            max_longitudinal_m=0.20,
            max_heading_deg=3.0,
            min_fixes=100,
            require_states=("NOMINAL",),
            forbid_states=("FAULT",),
        ),
        "the baseline: boards in view throughout, nothing injected",
    ),
    Scenario(
        "circle",
        # Radius 2, not the 4 m default: the corridor walls are at y = +-3, so
        # a 4 m circle drives the vehicle straight through them and past the
        # boards it is meant to be using.
        {"pattern": "circle", "speed": "1.0", "radius": "2.0"},
        25.0,
        Expect(
            max_lateral_m=0.30,
            max_longitudinal_m=0.40,
            max_heading_deg=5.0,
            min_fixes=100,
            forbid_states=("FAULT",),
        ),
        "continuous yaw rate: exercises the gyro path and boards entering and leaving view",
    ),
    Scenario(
        "corridor",
        {"pattern": "corridor", "speed": "1.0"},
        25.0,
        Expect(
            max_lateral_m=0.30,
            # The tail is wide ON PURPOSE, and the median carries the real
            # assertion. Along-track error reaches about 3 m while turning
            # through the corner and recovers immediately afterwards; see the
            # note in bench_tag_map.yaml. Corner coverage is a board-layout
            # problem, not a localizer defect, and pretending otherwise by
            # tightening this would just hide it. What must NOT happen is
            # divergence or a fault, and those are asserted.
            max_longitudinal_m=4.0,
            max_longitudinal_p50_m=0.10,
            max_lateral_p50_m=0.10,
            max_heading_deg=6.0,
            min_fixes=80,
            forbid_states=("FAULT",),
        ),
        "a 90 degree turn, where the visible board set changes completely",
    ),
    Scenario(
        "blackout",
        {"pattern": "straight", "blackout": "true", "blackout_start": "12.0"},
        30.0,
        Expect(
            min_fixes=0,
            require_states=("NOMINAL", "DEAD_RECKONING", "FAULT"),
            require_mrm=True,
        ),
        "boards lost mid-drive: the budget must count down and expire into FAULT. "
        "Blacking out from t=0 would test nothing -- with no first fix there is "
        "nothing to dead-reckon from, and UNINITIALIZED is the right answer",
    ),
    Scenario(
        "displaced_board",
        # The offset is the point: `displaced_board_id` alone moves the board
        # by the default displacement, which is zero, so the "fault" was a board
        # sitting exactly where the map said it was.
        {"pattern": "straight", "displaced_board_id": "100",
         "displacement": "[0.6, 0.0, 0.0]"},
        30.0,
        Expect(
            min_fixes=50,
            require_flagged=(100,),
            forbid_other_flags=True,
        ),
        "one board moved off its map entry: integrity must flag exactly that ID",
    ),
    Scenario(
        "clock_skew",
        {"pattern": "straight", "stamp_offset_s": "0.5"},
        20.0,
        Expect(
            min_fixes=0,
            require_states=("UNINITIALIZED",),
            forbid_states=("NOMINAL", "DEGRADED"),
        ),
        "stamps pushed into the future: every detection is rejected, so the system "
        "never initializes and must say so. Not DEAD_RECKONING -- that would claim "
        "a fix it never had",
    ),
]


# ── measurement ─────────────────────────────────────────────────────────────


@dataclass
class Recording:
    lateral: list[float] = field(default_factory=list)
    longitudinal: list[float] = field(default_factory=list)
    heading_deg: list[float] = field(default_factory=list)
    states: set[str] = field(default_factory=set)
    flagged: set[int] = field(default_factory=set)
    mrm: bool = False
    fixes: int = 0
    unexpected_nodes: list[str] = field(default_factory=list)


def yaw_of(q) -> float:
    return math.atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z))


def record(seconds: float) -> Recording:
    """Subscribe for `seconds` and collect everything the assertions need."""
    import rclpy
    from rclpy.node import Node
    from nav_msgs.msg import Odometry
    from diagnostic_msgs.msg import DiagnosticArray
    from aruco_detection_msgs.msg import ArucoLocalizerStatus

    out = Recording()

    class Listener(Node):
        def __init__(self):
            super().__init__("aruco_smoke_listener")
            self.truth: list[tuple[float, float, float, float]] = []
            self.create_subscription(
                Odometry, "/simulation/ground_truth/kinematic_state", self.on_truth, 50
            )
            self.create_subscription(
                Odometry, "/localization/kinematic_state", self.on_fused, 50
            )
            self.create_subscription(
                ArucoLocalizerStatus,
                "/localization/pose_estimator/aruco_localizer/status",
                self.on_status,
                10,
            )
            # RELIABLE (the plain depth-10 default), not sensor-data QoS.
            # diagnostic_updater publishes reliably, and a best-effort
            # subscriber is simply never connected to it -- so every scenario
            # reported "no ERROR on /diagnostics" no matter what the localizer
            # actually said. Same mismatch that silently disconnected the IMU
            # from gyro_odometer.
            self.create_subscription(DiagnosticArray, "/diagnostics", self.on_diag, 10)

        def on_truth(self, msg):
            t = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
            p = msg.pose.pose
            self.truth.append((t, p.position.x, p.position.y, yaw_of(p.orientation)))
            if len(self.truth) > 6000:
                self.truth.pop(0)

        def on_fused(self, msg):
            if not self.truth:
                return
            t = msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9
            ref = min(self.truth, key=lambda r: abs(r[0] - t))
            if abs(ref[0] - t) > 0.15:
                return

            p = msg.pose.pose.position
            dx, dy = p.x - ref[1], p.y - ref[2]
            # Rotate the error into the vehicle frame: along-track and
            # cross-track have different causes and different consequences.
            c, s = math.cos(ref[3]), math.sin(ref[3])
            out.longitudinal.append(abs(dx * c + dy * s))
            out.lateral.append(abs(-dx * s + dy * c))
            d = yaw_of(msg.pose.pose.orientation) - ref[3]
            out.heading_deg.append(abs(math.degrees(math.atan2(math.sin(d), math.cos(d)))))
            out.fixes += 1

        def on_status(self, msg):
            names = {0: "UNINITIALIZED", 1: "NOMINAL", 2: "DEGRADED",
                     3: "DEAD_RECKONING", 4: "FAULT"}
            out.states.add(names.get(msg.state, f"UNKNOWN({msg.state})"))
            out.flagged.update(int(i) for i in msg.markers_flagged)

        def on_diag(self, msg):
            for status in msg.status:
                if "aruco_localization_status" in status.name:
                    # ERROR on this diagnostic is exactly what escalates to an
                    # MRM, so it is the honest thing to assert on rather than a
                    # log line.
                    #
                    # `level` arrives as a one-byte bytes object in rclpy, and
                    # `b"\x02" == 2` is False, so the naive comparison silently
                    # never matched and every scenario reported "no ERROR".
                    level = status.level
                    if isinstance(level, (bytes, bytearray)):
                        level = int.from_bytes(level, "little")
                    if int(level) >= 2:
                        out.mrm = True

    rclpy.init()
    node = Listener()
    deadline = time.time() + seconds
    try:
        while time.time() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
    except BaseException:
        pass
    finally:
        try:
            node.destroy_node()
            rclpy.shutdown()
        except BaseException:
            pass
    return out


# Nodes that must never appear on the ArUco path. Their presence means the
# launch switch leaked and something is quietly doing scan matching or loading a
# point cloud map.
FORBIDDEN_NODES = (
    "ndt_scan_matcher",
    "cuda_ndt_matcher",
    "pointcloud_map_loader",
    "ar_tag_based_localizer",
    "lidar_marker_localizer",
)


def check_nodes() -> list[str]:
    try:
        listed = subprocess.run(
            ["ros2", "node", "list"], capture_output=True, text=True, timeout=20
        ).stdout
    except Exception:
        return []
    return [n for n in FORBIDDEN_NODES if n in listed]


# ── running ─────────────────────────────────────────────────────────────────


# Nodes this harness launches itself. One left over from an earlier run
# publishes on the same topics as the new one, and the results are then a blend
# of two simulations with different phases -- which reads as a localizer that is
# metres out rather than as a dirty machine.
OWNED_NODES = (
    "sim_trajectory_publisher",
    "aruco_sim_detector",
    "aruco_localizer",
    "ekf_localizer",
    "gyro_odometer",
    "pose_initializer",
)


def preflight() -> list[str]:
    """Refuse to measure into a graph that already has our nodes in it."""
    try:
        listed = subprocess.run(
            ["ros2", "node", "list"], capture_output=True, text=True, timeout=20
        ).stdout.splitlines()
    except Exception:
        return []
    return [n for n in listed if any(owned in n for owned in OWNED_NODES)]


def run(scenario: Scenario) -> tuple[bool, list[str], Recording]:
    command = [
        "ros2", "launch", "golfcart_launch", "sim_smoke.launch.xml",
    ] + [f"{k}:={v}" for k, v in scenario.args.items()]

    process = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )
    try:
        # Let the graph come up before measuring, or the first seconds of every
        # run are dominated by nodes still starting.
        time.sleep(6.0)
        recording = record(scenario.seconds)
        recording.unexpected_nodes = check_nodes()
    finally:
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGINT)
            process.wait(timeout=15)
        except Exception:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except Exception:
                pass
        time.sleep(2.0)

    return grade(scenario, recording)


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def grade(scenario: Scenario, r: Recording) -> tuple[bool, list[str], Recording]:
    failures: list[str] = []
    e = scenario.expect

    if r.fixes < e.min_fixes:
        failures.append(f"only {r.fixes} fused poses, expected at least {e.min_fixes}")

    def limit(name: str, values: list[float], cap: float | None, unit: str):
        if cap is None or not values:
            return
        p95 = percentile(values, 0.95)
        if p95 > cap:
            failures.append(f"{name} p95 {p95:.3f} {unit} exceeds {cap} {unit}")

    limit("lateral error", r.lateral, e.max_lateral_m, "m")
    limit("longitudinal error", r.longitudinal, e.max_longitudinal_m, "m")
    limit("heading error", r.heading_deg, e.max_heading_deg, "deg")

    def limit_p50(name: str, values: list[float], cap: float | None):
        if cap is None or not values:
            return
        p50 = percentile(values, 0.5)
        if p50 > cap:
            failures.append(f"{name} p50 {p50:.3f} m exceeds {cap} m")

    limit_p50("lateral error", r.lateral, e.max_lateral_p50_m)
    limit_p50("longitudinal error", r.longitudinal, e.max_longitudinal_p50_m)

    for state in e.require_states:
        if state not in r.states:
            failures.append(f"never reached {state} (saw {sorted(r.states) or 'nothing'})")
    for state in e.forbid_states:
        if state in r.states:
            failures.append(f"entered {state}, which this scenario must not")

    for board in e.require_flagged:
        if board not in r.flagged:
            failures.append(f"board {board} was not flagged (flagged: {sorted(r.flagged)})")
    if e.forbid_other_flags:
        extra = r.flagged - set(e.require_flagged)
        if extra:
            failures.append(f"boards {sorted(extra)} flagged but should not have been")

    if e.require_mrm and not r.mrm:
        failures.append("no ERROR on /diagnostics, so no MRM would be requested")

    if r.unexpected_nodes:
        failures.append(f"nodes that must not run on this path: {r.unexpected_nodes}")

    return (not failures), failures, r


def report(scenario: Scenario, ok: bool, failures: list[str], r: Recording) -> None:
    mark = "PASS" if ok else "FAIL"
    print(f"\n── {scenario.name} ── {mark}")
    print(f"   {scenario.why}")
    if r.fixes:
        print(
            f"   {r.fixes} fixes | lateral p50 {percentile(r.lateral, 0.5):.3f} "
            f"p95 {percentile(r.lateral, 0.95):.3f} m"
            f" | longitudinal p50 {percentile(r.longitudinal, 0.5):.3f} "
            f"p95 {percentile(r.longitudinal, 0.95):.3f} m"
            f" | heading p50 {percentile(r.heading_deg, 0.5):.2f} "
            f"p95 {percentile(r.heading_deg, 0.95):.2f} deg"
        )
    else:
        print("   no fused poses recorded")
    print(f"   states: {', '.join(sorted(r.states)) or 'none'}"
          f" | flagged: {sorted(r.flagged) or 'none'}"
          f" | diagnostics ERROR: {r.mrm}")
    for failure in failures:
        print(f"   ✗ {failure}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenarios", nargs="*", help="scenario names; default all")
    parser.add_argument("--list", action="store_true", help="list scenarios and exit")
    args = parser.parse_args()

    if args.list:
        for s in SCENARIOS:
            print(f"{s.name:18s} {s.why}")
        return 0

    selected = SCENARIOS
    if args.scenarios:
        known = {s.name: s for s in SCENARIOS}
        unknown = [n for n in args.scenarios if n not in known]
        if unknown:
            print(f"unknown scenario(s): {unknown}", file=sys.stderr)
            return 2
        selected = [known[n] for n in args.scenarios]

    stale = preflight()
    if stale:
        print(
            "refusing to run: these nodes are already up and would publish onto the "
            "same topics, blending two simulations into one measurement:",
            file=sys.stderr,
        )
        for node in stale:
            print(f"  {node}", file=sys.stderr)
        print("\nkill them first, then re-run.", file=sys.stderr)
        return 2

    print(f"phase 3D-6 stage 1 — {len(selected)} scenario(s)")
    results = []
    for scenario in selected:
        ok, failures, recording = run(scenario)
        report(scenario, ok, failures, recording)
        results.append((scenario.name, ok))

    failed = [name for name, ok in results if not ok]
    print("\n" + "=" * 60)
    print(f"{len(results) - len(failed)}/{len(results)} passed")
    if failed:
        print(f"failed: {', '.join(failed)}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
