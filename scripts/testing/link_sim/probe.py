#!/usr/bin/env python3
"""The master's consumer of the orin's IMU, instrumented.

Subscribes to /sensing/camera/zed/imu/data the way gyro_odometer does
(SensorDataQoS), and to /diagnostics and /tf_static, and reports at exit:

    rate      messages per second actually received, over the run
    latency   header.stamp -> arrival, mean and p99, in milliseconds

Both machines are one machine in the simulation, so the stamp and the arrival
clock are the same clock and the latency is real. On the vehicle they are two
chrony-disciplined clocks tens of microseconds apart, which is still fine at
the millisecond scale this reports.

This is the "does the data still arrive" half of the measurement: the split
is only a result if the IMU rate stays at 100 Hz and the latency stays under
what gyro_odometer tolerates.

    probe.py SECONDS OUTFILE
"""

import statistics
import sys
import time

import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy

from diagnostic_msgs.msg import DiagnosticArray
from sensor_msgs.msg import Imu
from tf2_msgs.msg import TFMessage


class Probe(Node):
    def __init__(self):
        super().__init__("link_probe")
        sensor = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=10,
                            reliability=ReliabilityPolicy.BEST_EFFORT)
        reliable = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=100,
                              reliability=ReliabilityPolicy.RELIABLE)
        latched = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=100,
                             reliability=ReliabilityPolicy.RELIABLE,
                             durability=DurabilityPolicy.TRANSIENT_LOCAL)
        self.imu_lat = []
        self.imu_n = 0
        self.diag_n = 0
        self.tf_frames = set()
        self.create_subscription(Imu, "/sensing/camera/zed/imu/data", self.imu, sensor)
        self.create_subscription(DiagnosticArray, "/diagnostics", self.diag, reliable)
        self.create_subscription(TFMessage, "/tf_static", self.tf, latched)
        self.t0 = None

    def imu(self, m):
        now = self.get_clock().now().nanoseconds
        stamp = m.header.stamp.sec * 1_000_000_000 + m.header.stamp.nanosec
        if self.t0 is None:
            self.t0 = time.monotonic()
        self.imu_n += 1
        self.imu_lat.append((now - stamp) / 1e6)

    def diag(self, m):
        # Only the orin's rows: the master's own monitors publish here too.
        if any(s.hardware_id == "orin" for s in m.status):
            self.diag_n += 1

    def tf(self, m):
        for t in m.transforms:
            self.tf_frames.add(t.child_frame_id)


def main():
    seconds = float(sys.argv[1])
    out = sys.argv[2]
    rclpy.init()
    node = Probe()
    end = time.monotonic() + seconds
    try:
        while rclpy.ok() and time.monotonic() < end:
            rclpy.spin_once(node, timeout_sec=0.1)
    except KeyboardInterrupt:
        pass
    span = (time.monotonic() - node.t0) if node.t0 else seconds
    lat = node.imu_lat
    with open(out, "w") as f:
        f.write(f"imu_msgs {node.imu_n}\n")
        f.write(f"imu_rate_hz {node.imu_n / span if span > 0 else 0:.1f}\n")
        if lat:
            lat_sorted = sorted(lat)
            f.write(f"imu_latency_mean_ms {statistics.fmean(lat):.3f}\n")
            f.write(f"imu_latency_p99_ms {lat_sorted[int(0.99 * (len(lat) - 1))]:.3f}\n")
            f.write(f"imu_latency_max_ms {lat_sorted[-1]:.3f}\n")
        else:
            f.write("imu_latency_mean_ms nan\nimu_latency_p99_ms nan\nimu_latency_max_ms nan\n")
        f.write(f"orin_diagnostics_msgs {node.diag_n}\n")
        f.write(f"tf_static_frames {len(node.tf_frames)}\n")
    node.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


if __name__ == "__main__":
    main()
