#!/usr/bin/env python3
"""Stand-in for the master's LiDAR fan-out in the link simulation.

The planning simulator has no sensing stage, and sensing is where the bytes
are: a VLP-32C frame is ~1-2 MB at 10 Hz, and Autoware's preprocessing chain
reads each intermediate cloud from more than one process (crop box,
distortion corrector, concatenator, the map filters). This script supplies
that shape:

    fake_lidar.py pub          one PointCloud2 of LINK_SIM_CLOUD_BYTES (1.2 MB)
                               at 10 Hz on /sensing/lidar/vlp32/pointcloud
    fake_lidar.py sub          one subscriber process; run three

None of it is meant for the orin. Whether any of it reaches the wire anyway is
one of the questions the simulation answers: with two or more readers in
separate processes, CycloneDDS may choose the multicast locator, and a
multicast datagram leaves the NIC whether or not the far side wants it.
"""

import os
import sys

import rclpy
from rclpy.node import Node
from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy

from sensor_msgs.msg import PointCloud2, PointField


CLOUD_BYTES = int(os.environ.get("LINK_SIM_CLOUD_BYTES", 1_200_000))
TOPIC = "/sensing/lidar/vlp32/pointcloud"
POINT_STEP = 16  # x y z intensity, float32 each


def sensor_qos():
    return QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=5,
                      reliability=ReliabilityPolicy.BEST_EFFORT)


class Pub(Node):
    def __init__(self):
        super().__init__("fake_lidar")
        self.pub = self.create_publisher(PointCloud2, TOPIC, sensor_qos())
        n = CLOUD_BYTES // POINT_STEP
        self.msg = PointCloud2()
        self.msg.header.frame_id = "velodyne"
        self.msg.height = 1
        self.msg.width = n
        self.msg.fields = [
            PointField(name=nm, offset=4 * i, datatype=PointField.FLOAT32, count=1)
            for i, nm in enumerate(("x", "y", "z", "intensity"))]
        self.msg.is_bigendian = False
        self.msg.point_step = POINT_STEP
        self.msg.row_step = POINT_STEP * n
        self.msg.data = bytes(os.urandom(POINT_STEP * n))
        self.msg.is_dense = True
        self.create_timer(0.1, self.tick)
        self.get_logger().info(f"{n} points, {len(self.msg.data)} B at 10 Hz on {TOPIC}")

    def tick(self):
        self.msg.header.stamp = self.get_clock().now().to_msg()
        self.pub.publish(self.msg)


class Sub(Node):
    def __init__(self):
        super().__init__("fake_lidar_reader_" + str(os.getpid()))
        self.n = 0
        self.create_subscription(PointCloud2, TOPIC, self.cb, sensor_qos())

    def cb(self, _msg):
        self.n += 1


def main():
    role = sys.argv[1] if len(sys.argv) > 1 else "pub"
    rclpy.init(args=sys.argv)
    node = Pub() if role == "pub" else Sub()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if role != "pub":
            print(f"fake_lidar sub {os.getpid()}: received {node.n}", flush=True)
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
