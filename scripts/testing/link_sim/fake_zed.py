#!/usr/bin/env python3
"""Stand-in for the orin's payload in the link simulation.

Publishes what the ZED X wrapper and the orin's system monitor publish, at the
rates and sizes the real ones do, under the real topic names, so that
config/link/topics.yaml is exercised unchanged:

  /sensing/camera/zed/imu/data                        Imu              100 Hz
  /sensing/camera/zed/rgb/color/rect/camera_info      CameraInfo        15 Hz
  /sensing/camera/zed/rgb/color/rect/image/compressed CompressedImage   15 Hz, ~330 kB
  /diagnostics                                        DiagnosticArray    1 Hz
  /tf_static                                          TFMessage      latched

The image is the ~5 MB/s stream that must NOT cross the link. It is here so
the simulation can show what an accidental subscription on the master costs
before the split and after it.

Header stamps are wall time, so a subscriber on the same machine can measure
end-to-end latency (probe.py). No sim time anywhere.
"""

import os
import sys

import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy

from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus, KeyValue
from geometry_msgs.msg import TransformStamped
from sensor_msgs.msg import CameraInfo, CompressedImage, Imu
from tf2_msgs.msg import TFMessage


IMAGE_BYTES = int(os.environ.get("LINK_SIM_IMAGE_BYTES", 330_000))


class FakeZed(Node):
    def __init__(self):
        super().__init__("fake_zed")
        sensor = QoSProfile(
            history=HistoryPolicy.KEEP_LAST, depth=10,
            reliability=ReliabilityPolicy.BEST_EFFORT)
        reliable = QoSProfile(
            history=HistoryPolicy.KEEP_LAST, depth=10,
            reliability=ReliabilityPolicy.RELIABLE)
        latched = QoSProfile(
            history=HistoryPolicy.KEEP_LAST, depth=1,
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.TRANSIENT_LOCAL)

        self.imu_pub = self.create_publisher(Imu, "/sensing/camera/zed/imu/data", sensor)
        self.info_pub = self.create_publisher(
            CameraInfo, "/sensing/camera/zed/rgb/color/rect/camera_info", reliable)
        self.img_pub = self.create_publisher(
            CompressedImage, "/sensing/camera/zed/rgb/color/rect/image/compressed", sensor)
        self.diag_pub = self.create_publisher(DiagnosticArray, "/diagnostics", reliable)
        self.tf_pub = self.create_publisher(TFMessage, "/tf_static", latched)

        self.image_payload = bytes(os.urandom(IMAGE_BYTES))  # incompressible, like a JPEG
        self.seq = 0

        self.create_timer(1.0 / 100.0, self.tick_imu)
        self.create_timer(1.0 / 15.0, self.tick_camera)
        self.create_timer(1.0, self.tick_diag)
        self.publish_tf_static()
        self.get_logger().info(
            f"imu 100 Hz, camera_info 15 Hz, image 15 Hz x {IMAGE_BYTES} B, diagnostics 1 Hz, tf_static latched")

    def stamp(self):
        return self.get_clock().now().to_msg()

    def tick_imu(self):
        m = Imu()
        m.header.stamp = self.stamp()
        m.header.frame_id = "zed_imu_link"
        m.orientation.w = 1.0
        m.angular_velocity.z = 0.01
        m.linear_acceleration.z = 9.81
        self.imu_pub.publish(m)

    def tick_camera(self):
        info = CameraInfo()
        info.header.stamp = self.stamp()
        info.header.frame_id = "zed_left_camera_frame_optical"
        info.width, info.height = 1920, 1200
        info.distortion_model = "plumb_bob"
        info.d = [0.0] * 5
        info.k = [1000.0, 0.0, 960.0, 0.0, 1000.0, 600.0, 0.0, 0.0, 1.0]
        info.p = [1000.0, 0.0, 960.0, 0.0, 0.0, 1000.0, 600.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        self.info_pub.publish(info)

        img = CompressedImage()
        img.header = info.header
        img.format = "jpeg"
        img.data = self.image_payload
        self.img_pub.publish(img)

    def tick_diag(self):
        arr = DiagnosticArray()
        arr.header.stamp = self.stamp()
        for name in ("cpu_usage", "cpu_temperature", "memory_usage", "net_usage",
                     "ntp_offset", "process_high_load", "process_high_mem", "gpu_usage"):
            st = DiagnosticStatus()
            st.level = DiagnosticStatus.OK
            st.name = f"orin_{name}: {name}"
            st.message = "OK"
            st.hardware_id = "orin"
            st.values = [KeyValue(key=f"k{i}", value=f"v{i}") for i in range(6)]
            arr.status.append(st)
        self.diag_pub.publish(arr)

    def publish_tf_static(self):
        msg = TFMessage()
        for child in ("zed_camera_center", "zed_left_camera_frame",
                      "zed_left_camera_frame_optical", "zed_imu_link"):
            t = TransformStamped()
            t.header.stamp = self.stamp()
            t.header.frame_id = "zed_camera_link"
            t.child_frame_id = child
            t.transform.rotation.w = 1.0
            msg.transforms.append(t)
        self.tf_pub.publish(msg)


def main():
    rclpy.init(args=sys.argv)
    node = FakeZed()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
