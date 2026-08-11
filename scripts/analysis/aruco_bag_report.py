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

"""Phase 3D-7: turn a recorded bag into the numbers the design is waiting on.

    python3 scripts/analysis/aruco_bag_report.py rosbags/aruco_bench_static_1board_3m_...

Three measurements, each answering a question the design currently guesses at:

**corner sigma** — the standard deviation of corner pixel positions with the
camera and board both stationary. `corner_sigma_px` is currently 0.3, inferred
from other people's data, and the entire covariance model scales on it. This is
the single most valuable number on the list and it needs nothing but a tripod.

**detection rate against geometry** — how often a board is detected, bucketed by
range and by incidence angle. The design takes its 25-75 degree usable window
from the literature; this says whether that window is right on these optics.

**coverage census** — how many boards, and with how much normal spread, were
visible at each point of a route. This is what decides whether a board layout
delivers the two-well-spread-boards the localizer needs, and doing it from a bag
means it can be re-run when detection parameters change instead of re-walked.

Reads `aruco_detection_msgs/ArucoDetectionArray`, so it works on a bag recorded
with the detector running, or on one replayed through the detector afterwards.
"""

from __future__ import annotations

import argparse
import math
import os
import statistics
import sys
from collections import defaultdict
from dataclasses import dataclass, field


# ── bag reading ─────────────────────────────────────────────────────────────


def read_messages(bag_path: str, type_filter: str | None = None):
    """Yield (topic, message, timestamp_ns) for every message in the bag."""
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    reader = rosbag2_py.SequentialReader()
    storage_id = "mcap" if _looks_like_mcap(bag_path) else "sqlite3"
    reader.open(
        rosbag2_py.StorageOptions(uri=bag_path, storage_id=storage_id),
        rosbag2_py.ConverterOptions("", ""),
    )

    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    while reader.has_next():
        topic, data, stamp = reader.read_next()
        type_name = types.get(topic)
        if type_name is None:
            continue
        if type_filter is not None and type_name != type_filter:
            continue
        yield topic, deserialize_message(data, get_message(type_name)), stamp


def _looks_like_mcap(bag_path: str) -> bool:
    if os.path.isdir(bag_path):
        return any(name.endswith(".mcap") for name in os.listdir(bag_path))
    return bag_path.endswith(".mcap")


# ── geometry ────────────────────────────────────────────────────────────────


def pose_range(pose) -> float:
    p = pose.position
    return math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)


def incidence_deg(pose) -> float:
    """Angle between the line of sight and the board normal, in degrees.

    0 is fronto-parallel, which is the WORST case for orientation rather than
    the best — the two planar solutions merge there. Same convention as the
    localizer's `BoardObservation::viewAngleDeg`, deliberately, so numbers from
    this report can be compared against the gates directly.
    """
    q = pose.orientation
    # Third column of the rotation matrix: the board normal in camera frame.
    nx = 2.0 * (q.x * q.z + q.w * q.y)
    ny = 2.0 * (q.y * q.z - q.w * q.x)
    nz = 1.0 - 2.0 * (q.x * q.x + q.y * q.y)

    p = pose.position
    norm = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
    if norm < 1e-9:
        return float("nan")
    cos_phi = -(nx * p.x + ny * p.y + nz * p.z) / norm
    if cos_phi <= 0.0:
        return 180.0
    return math.degrees(math.acos(min(1.0, cos_phi)))


def ambiguity_ratio(detection) -> float:
    if detection.reprojection_error_2 > 0.0 and math.isfinite(
        detection.reprojection_error_2
    ):
        return detection.reprojection_error_1 / detection.reprojection_error_2
    return 0.0


# ── corner sigma ────────────────────────────────────────────────────────────


@dataclass
class CornerSeries:
    """Corner pixel positions for one board id, over time."""

    xs: list[list[float]] = field(default_factory=lambda: [[] for _ in range(4)])
    ys: list[list[float]] = field(default_factory=lambda: [[] for _ in range(4)])
    ranges: list[float] = field(default_factory=list)
    incidences: list[float] = field(default_factory=list)


def corner_sigma(bag_path: str, min_frames: int) -> int:
    """Standard deviation of corner positions, per board, per corner.

    Only meaningful when the camera and the board are BOTH stationary: any real
    motion shows up here as corner noise and inflates the answer. The report
    prints the drift across the recording so a run that was not actually static
    is visible rather than silently averaged in.
    """
    series: dict[int, CornerSeries] = defaultdict(CornerSeries)

    for _, msg, _s in read_messages(
        bag_path, "aruco_detection_msgs/msg/ArucoDetectionArray"
    ):
        for detection in msg.detections:
            entry = series[detection.id]
            for corner in range(4):
                entry.xs[corner].append(detection.corners_rectified[corner * 2])
                entry.ys[corner].append(detection.corners_rectified[corner * 2 + 1])
            entry.ranges.append(pose_range(detection.pose_1))
            entry.incidences.append(incidence_deg(detection.pose_1))

    if not series:
        print("no ArUco detections in this bag", file=sys.stderr)
        print(
            "  If it holds images but no detections, replay it through the detector "
            "and record the output, or run the detector against the replay.",
            file=sys.stderr,
        )
        return 1

    print("\ncorner sigma — camera and board must both be stationary")
    print(
        f"{'board':>7} {'frames':>7} {'range':>7} {'incid':>7} "
        f"{'sigma_px':>9} {'drift_px':>9}"
    )

    usable = 0
    for board_id in sorted(series):
        entry = series[board_id]
        frames = len(entry.ranges)
        if frames < min_frames:
            print(
                f"{board_id:>7} {frames:>7} "
                f"{'':>7} {'':>7} {'too few frames':>19}"
            )
            continue
        usable += 1

        # Pooled across the eight coordinates: they are the same measurement
        # process, and one corner alone is a small sample.
        sigmas = []
        drifts = []
        for corner in range(4):
            for values in (entry.xs[corner], entry.ys[corner]):
                sigmas.append(statistics.pstdev(values))
                # Start-to-end movement of the mean: if the rig crept, this is
                # where it shows, and the sigma above is then not corner noise.
                half = max(1, len(values) // 2)
                drifts.append(
                    abs(statistics.fmean(values[:half]) - statistics.fmean(values[half:]))
                )

        pooled = math.sqrt(statistics.fmean([s * s for s in sigmas]))
        print(
            f"{board_id:>7} {frames:>7} "
            f"{statistics.fmean(entry.ranges):>7.2f} "
            f"{statistics.fmean(entry.incidences):>7.1f} "
            f"{pooled:>9.3f} {max(drifts):>9.3f}"
        )

    if usable:
        print(
            "\n  sigma_px is the number to put in `corner_sigma_px`. If drift_px is "
            "\n  comparable to it, the rig moved and the sigma is motion, not noise."
        )
    return 0


# ── detection rate against geometry ─────────────────────────────────────────


def detection_rate(bag_path: str) -> int:
    """How detection behaves against range and incidence angle.

    This cannot measure a true detection RATE without knowing what was visible
    and missed, which needs a surveyed map and a pose. What it can measure —
    and what actually decides the gates — is the distribution of the detections
    that did occur, and how their reported quality varies across the geometry.
    """
    by_range: dict[int, list[float]] = defaultdict(list)
    by_incidence: dict[int, list[float]] = defaultdict(list)
    total = 0

    for _, msg, _s in read_messages(
        bag_path, "aruco_detection_msgs/msg/ArucoDetectionArray"
    ):
        for detection in msg.detections:
            total += 1
            r = pose_range(detection.pose_1)
            phi = incidence_deg(detection.pose_1)
            ratio = ambiguity_ratio(detection)
            by_range[int(r)].append(ratio)
            if math.isfinite(phi):
                by_incidence[int(phi // 5) * 5].append(ratio)

    if not total:
        print("no detections in this bag", file=sys.stderr)
        return 1

    print(f"\ndetections by range — {total} total")
    print(f"{'range':>12} {'count':>7} {'share':>7} {'ambiguity p50':>14}")
    for bucket in sorted(by_range):
        ratios = by_range[bucket]
        print(
            f"{f'{bucket}-{bucket + 1} m':>12} {len(ratios):>7} "
            f"{100.0 * len(ratios) / total:>6.1f}% "
            f"{statistics.median(ratios):>14.3f}"
        )

    print("\ndetections by incidence angle (0 = fronto-parallel)")
    print(f"{'angle':>12} {'count':>7} {'share':>7} {'ambiguity p50':>14}")
    for bucket in sorted(by_incidence):
        ratios = by_incidence[bucket]
        print(
            f"{f'{bucket}-{bucket + 5} deg':>12} {len(ratios):>7} "
            f"{100.0 * len(ratios) / total:>6.1f}% "
            f"{statistics.median(ratios):>14.3f}"
        )

    print(
        "\n  The design gates incidence to 25-75 deg. Detections outside that band "
        "\n  here are ones the localizer will discard — if most of the data lives "
        "\n  there, the board layout is wrong, not the gate."
    )
    return 0


# ── coverage census ─────────────────────────────────────────────────────────


def coverage(bag_path: str, min_spread_deg: float, window_ns: int) -> int:
    """Boards visible per instant, and whether their normals were spread enough.

    This is the measurement that decides a board layout. Two boards are not
    enough on their own: they must have different normals, or heading is
    unobservable and the localizer runs DEGRADED with yaw on the gyro.
    """
    # Group ACROSS CAMERAS by time, the way the localizer does.
    #
    # Counting each camera's message separately is the obvious implementation
    # and it is wrong: a vehicle seeing one board in each of three cameras has
    # three well-spread boards, but per-message counting reports "one board"
    # three times and declares the route uncoverable. The first run of this tool
    # produced a suspiciously tidy 33.3/33.3/33.3 split, which is what that bug
    # looks like.
    buckets: dict[int, list[tuple[float, float, float]]] = defaultdict(list)
    for _, msg, stamp in read_messages(
        bag_path, "aruco_detection_msgs/msg/ArucoDetectionArray"
    ):
        # One frame period, matching the localizer's default solve window.
        key = int(stamp // window_ns)
        for detection in msg.detections:
            q = detection.pose_1.orientation
            buckets[key].append(
                (
                    2.0 * (q.x * q.z + q.w * q.y),
                    2.0 * (q.y * q.z - q.w * q.x),
                    1.0 - 2.0 * (q.x * q.x + q.y * q.y),
                )
            )

    per_window: list[tuple[int, float]] = []
    for key in sorted(buckets):
        normals = buckets[key]
        spread = 0.0
        for i in range(len(normals)):
            for j in range(i + 1, len(normals)):
                dot = sum(a * b for a, b in zip(normals[i], normals[j]))
                spread = max(spread, math.degrees(math.acos(max(-1.0, min(1.0, dot)))))
        per_window.append((len(normals), spread))

    if not per_window:
        print("no detection messages in this bag", file=sys.stderr)
        return 1

    total = len(per_window)
    # A window in which NO camera published cannot appear here at all -- the bag
    # has no message to bucket. So "no boards visible" counts windows that were
    # published and empty, and a detector that stopped entirely looks like a
    # shorter recording rather than like zero coverage. Cross-check the window
    # count against the recording length before reading too much into it.
    none_visible = sum(1 for count, _ in per_window if count == 0)
    one_visible = sum(1 for count, _ in per_window if count == 1)
    two_plus = sum(1 for count, _ in per_window if count >= 2)
    well_spread = sum(
        1 for count, spread in per_window if count >= 2 and spread >= min_spread_deg
    )

    print(f"\ncoverage census — {total} detection windows")
    print(f"  no boards visible      {none_visible:>7} {100.0 * none_visible / total:>6.1f}%")
    print(f"  one board              {one_visible:>7} {100.0 * one_visible / total:>6.1f}%")
    print(f"  two or more            {two_plus:>7} {100.0 * two_plus / total:>6.1f}%")
    print(
        f"  two or more, >={min_spread_deg:g} deg apart "
        f"{well_spread:>7} {100.0 * well_spread / total:>6.1f}%"
    )

    print(
        "\n  The last row is the one that matters: it is the fraction of the route "
        "\n  where full 6-DoF localization is possible at all. Everywhere else the "
        "\n  vehicle is on one board or on the gyro."
    )

    # A run of consecutive windows without a usable constellation is a coverage
    # hole, and its LENGTH is what decides whether the dead-reckoning budget
    # covers it. An average hides this entirely.
    longest = current = 0
    for count, spread in per_window:
        if count >= 2 and spread >= min_spread_deg:
            current = 0
        else:
            current += 1
            longest = max(longest, current)
    print(f"\n  longest unbroken stretch without a usable constellation: {longest} windows")
    if longest:
        print(
            "  Compare that against dead_reckoning_budget_s at the detection rate: "
            "\n  a hole longer than the budget is a stop, not a degradation."
        )
    return 0


# ── entry point ─────────────────────────────────────────────────────────────


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("bag", help="path to the bag directory")
    parser.add_argument(
        "--report",
        choices=["all", "corner-sigma", "detection-rate", "coverage"],
        default="all",
    )
    parser.add_argument(
        "--min-frames",
        type=int,
        default=100,
        help="frames a board needs before its corner sigma is reported (default 100)",
    )
    parser.add_argument(
        "--window",
        type=float,
        default=0.033,
        help="seconds of detections fused into one window, matching the localizer "
             "(default 0.033)",
    )
    parser.add_argument(
        "--min-spread-deg",
        type=float,
        default=20.0,
        help="normal spread the localizer requires for 6-DoF (default 20)",
    )
    args = parser.parse_args()

    if not os.path.exists(args.bag):
        print(f"no such bag: {args.bag}", file=sys.stderr)
        return 2

    status = 0
    if args.report in ("all", "corner-sigma"):
        status |= corner_sigma(args.bag, args.min_frames)
    if args.report in ("all", "detection-rate"):
        status |= detection_rate(args.bag)
    if args.report in ("all", "coverage"):
        status |= coverage(args.bag, args.min_spread_deg, int(args.window * 1e9))
    return status


if __name__ == "__main__":
    sys.exit(main())
