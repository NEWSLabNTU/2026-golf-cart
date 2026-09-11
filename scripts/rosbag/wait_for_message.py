#!/usr/bin/env python3
"""Wait for one message on a topic. Exit 0 if it arrives, 1 if it does not.

    wait_for_message.py /sensing/lidar/vlp32/velodyne_points --timeout 30

Written because `ros2 topic echo --once` is not a reliable answer to "is data
flowing". It resolves the message type through the graph before it subscribes,
and while 83 nodes are starting that lookup can outlast any timeout worth
waiting: a replay with scans visibly arriving reported "no scans arriving" for
60 s, twice, on two different machines. This subscribes directly, takes the
type from the graph itself with a retry, and reports what it saw.

Sensor topics are published BEST_EFFORT, and a RELIABLE subscriber does not
match a BEST_EFFORT publisher at all, so that is the default here. The
mismatch is silent in ROS 2: no error, no data, forever.
"""
from __future__ import annotations

import argparse
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSHistoryPolicy, QoSProfile, QoSReliabilityPolicy
from rosidl_runtime_py.utilities import get_message


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("topic")
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--reliable", action="store_true",
                    help="subscribe RELIABLE instead of BEST_EFFORT")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    rclpy.init()
    node = Node("wait_for_message")
    deadline = time.time() + args.timeout

    # The type comes from the graph, which needs a moment to populate; a topic
    # that is about to exist is the normal case for a caller that is waiting.
    type_name = None
    while time.time() < deadline and type_name is None:
        for name, types in node.get_topic_names_and_types():
            if name == args.topic and types:
                type_name = types[0]
                break
        if type_name is None:
            rclpy.spin_once(node, timeout_sec=0.2)
    if type_name is None:
        if not args.quiet:
            print(f"{args.topic}: not advertised within {args.timeout:.0f}s",
                  file=sys.stderr)
        rclpy.shutdown()
        return 1

    qos = QoSProfile(
        depth=1,
        history=QoSHistoryPolicy.KEEP_LAST,
        reliability=(QoSReliabilityPolicy.RELIABLE if args.reliable
                     else QoSReliabilityPolicy.BEST_EFFORT),
    )
    seen: list[object] = []
    node.create_subscription(get_message(type_name), args.topic,
                             lambda msg: seen.append(msg), qos)

    while time.time() < deadline and not seen:
        rclpy.spin_once(node, timeout_sec=0.1)

    rclpy.shutdown()
    if seen:
        if not args.quiet:
            print(f"{args.topic}: {type_name}")
        return 0
    if not args.quiet:
        print(f"{args.topic}: advertised as {type_name}, but no message in "
              f"{args.timeout:.0f}s", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
