#!/usr/bin/env python3
"""Record the indoor replay's localization events, with both clocks.

    scripts/rosbag/indoor_sim_record_events.py --out events.jsonl --seconds 400

Every event carries wall time and simulation time. Both are needed and they
answer different questions: sim time says where in the recording something
happened (the cart is near the board at 40 s of bag time regardless of how
slowly the machine replays it), wall time says what it cost to get there.

Topics are subscribed as they appear rather than at startup, because this is
meant to be running before the stack is, and a subscription cannot be created
without knowing the type. The type comes from the graph.
"""
from __future__ import annotations

import argparse
import json
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import (QoSDurabilityPolicy, QoSHistoryPolicy, QoSProfile,
                       QoSReliabilityPolicy)
from rosidl_runtime_py.utilities import get_message

# Topic -> what to pull out of each message. Anything not listed is recorded as
# a bare arrival, which is all a timeline needs for a stream like NDT poses.
TOPICS = {
    "/clock": None,
    "/localization/board_detector/board_pose": "pose",
    "/localization/pose_estimator/pose_with_covariance": "pose",
    "/localization/pose_estimator/exe_time_ms": "data",
    # How hard the matcher worked and how well it fitted. iteration_num
    # pinned at max_iterations means the optimiser ran out of budget rather
    # than converging, and NVTL below its gate means the fit was rejected;
    # either one turns a plausible-looking pose stream into a suspect one.
    "/localization/pose_estimator/iteration_num": "data",
    "/localization/pose_estimator/nearest_voxel_transformation_likelihood": "data",
    "/localization/pose_estimator/transform_probability": "data",
    "/localization/kinematic_state": "pose",
    "/api/localization/initialization_state": "state",
    "/localization/initialization_state": "state",
    "/initialpose3d": "pose",
}


def extract(field, msg):
    if field == "pose":
        p = getattr(msg, "pose", None)
        p = getattr(p, "pose", p)          # PoseWithCovariance nests one deeper
        if p is None or not hasattr(p, "position"):
            return None
        return {"x": round(p.position.x, 3), "y": round(p.position.y, 3),
                "z": round(p.position.z, 3)}
    if field == "data":
        return round(float(msg.data), 3)
    if field == "state":
        return int(getattr(msg, "state", -1))
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=float, default=400.0)
    args = ap.parse_args()

    rclpy.init()
    node = Node("indoor_event_recorder")
    out = open(args.out, "w", buffering=1)
    t0 = time.time()
    sim = {"t": None}
    subscribed: dict[str, bool] = {}
    counts: dict[str, int] = {}

    def write(topic: str, value) -> None:
        counts[topic] = counts.get(topic, 0) + 1
        out.write(json.dumps({
            "topic": topic,
            "wall": round(time.time() - t0, 3),
            "sim": sim["t"],
            "n": counts[topic],
            "value": value,
        }) + "\n")

    def make_cb(topic: str, field):
        def cb(msg) -> None:
            if topic == "/clock":
                sim["t"] = round(msg.clock.sec + msg.clock.nanosec * 1e-9, 3)
                return                      # the clock is context, not an event
            write(topic, extract(field, msg))
        return cb

    def try_subscribe() -> None:
        available = dict(node.get_topic_names_and_types())
        for topic, field in TOPICS.items():
            if topic in subscribed or topic not in available:
                continue
            types = available[topic]
            if not types:
                continue
            # Match the publisher rather than guess. Sensor and debug streams
            # are BEST_EFFORT while the board pose and the initialization
            # state are latched RELIABLE, and an incompatible pair never
            # matches: ROS 2 reports that only as silence, and rosbag2 logs
            # "requesting incompatible QoS. No messages will be sent to it".
            info = node.get_publishers_info_by_topic(topic)
            if not info:
                continue
            offered = info[0].qos_profile
            node.create_subscription(
                get_message(types[0]), topic, make_cb(topic, field),
                QoSProfile(depth=50, history=QoSHistoryPolicy.KEEP_LAST,
                           reliability=offered.reliability,
                           durability=offered.durability))
            subscribed[topic] = True
            print(f"  + {topic}  ({types[0]})", flush=True)

    print(f"recording to {args.out} for {args.seconds:.0f}s", flush=True)
    next_scan = 0.0
    while time.time() - t0 < args.seconds:
        if time.time() - t0 >= next_scan:
            try_subscribe()
            next_scan += 1.0
        rclpy.spin_once(node, timeout_sec=0.1)

    out.close()
    rclpy.shutdown()
    print("\nrecorded:", flush=True)
    for topic, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:6d}  {topic}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
