#!/usr/bin/env python3
"""The cart's sensor DRIVERS, replaced by publishers with the real output shape.

    synthetic_sensors.py master     the Advantech's wired sensors
    synthetic_sensors.py orin       the ZED X

Only the drivers. Everything downstream — preprocessing, concatenation, NDT,
EKF, perception, the diagnostic aggregator — is the real stack, launched from
golfcart.launch.yaml with launch_sensing_driver:=false, reading these topics
under their real names. What the stack does with a topic (how many processes
read it, hence whether CycloneDDS multicasts it) is therefore real; only the
bytes inside the messages are synthetic. Bandwidth does not depend on the
bytes.

Every size and rate below is either the device's configured spec in this
repo or a figure measured on the cart and written down in docs/. Nothing is
chosen for effect.

MASTER
  /sensing/lidar/vlp32/velodyne_points        sensor_msgs/PointCloud2, 10 Hz
      VLP-32C, single return: 600 000 pts/s (Velodyne datasheet) -> 60 000
      pts/frame at the 10 Hz configured in VLP32.param.yaml. Nebula publishes
      PointXYZIRCAEDT, 32 B/pt (autoware_point_types) -> 1.92 MB/frame,
      19.2 MB/s. Cart bags measured 48 700 pts, 1.56 MB/scan indoors
      (docs/research/performance/indoor-replay-bottlenecks.md), i.e. this is
      the outdoor upper bound.
  /sensing/lidar/falcon/iv_points              sensor_msgs/PointCloud2, 10 Hz
      Seyond Falcon as configured on the cart: 51 743 pts/frame, point_step
      16 -> 828 kB/frame, 8.3 MB/s. Measured over 3 677 frames of a cart bag
      (docs/research/system/where-the-orin-cpu-goes.md). Field names are the
      Autoware ones (intensity/return_type/channel), which is what the
      driver is meant to emit; the I/R/C mismatch noted in CLAUDE.md changes
      whether the concatenator accepts the cloud, not how many bytes it is.
  /sensing/camera/{left,right,rear}/image_raw/compressed
                                               sensor_msgs/CompressedImage, 30 Hz
      TIER IV GMSL via gscam, 1920x1280 at 30 fps (config/camera_*.yaml),
      JPEG quality 90 4:2:0: 250-400 kB/frame, ~9 MB/s per camera
      (docs/roadmaps/2-camera-image-pipeline.md). 300 kB here.
  /sensing/camera/{left,right,rear}/camera_info CameraInfo, 30 Hz
  /vehicle/status/velocity_status              VelocityReport, 50 Hz
  /vehicle/status/steering_status              SteeringReport, 50 Hz
      From the VCU's MTR frame via golfcart_vehicle_interface. The rate is
      an assumption (the DBC is not on this machine); the messages are
      ~100 B, so it cannot matter to the link. They exist because NDT needs
      velocity through gyro_odometer and the localization chain would
      otherwise sit idle.

ORIN
  /sensing/camera/zed/rgb/color/rect/image/compressed
                                               CompressedImage, 30 Hz
      ZED X, HD1200 (1920x1200) at grab_frame_rate 30, pub_frame_rate 0 =
      grab rate (zed_wrapper zedx.yaml, common_stereo.yaml). JPEG size from
      the cart: a 45 s orin bag was 295 MB (docs/design/
      multi_machine_deployment.md), 6.5 MB/s with IMU and camera_info in it
      -> ~215 kB/frame at 30 Hz. 220 kB here.
  /sensing/camera/zed/rgb/color/rect/camera_info CameraInfo, 30 Hz
  /sensing/camera/zed/imu/data                 Imu, 100 Hz
      sensors_pub_rate: 100 (common_stereo.yaml).
  /tf   zed_left_camera_frame -> zed_imu_link  100 Hz
      publish_imu_tf: true (zed.param.yaml). The wrapper broadcasts the IMU
      frame as a DYNAMIC transform at the sensor rate; a cart bag held 43k
      of them (ntu_logging_sim.launch.xml). gyro_odometer on the master
      cannot use the IMU without it.
  /tf_static                                   latched, the ZED URDF subtree
  /diagnostics                                 1 Hz, the orin's system monitor
      rows, hardware_id "orin" (orin_system_monitor.launch.xml).

Header stamps are wall time; the stack runs with use_sim_time false.
"""

import os
import sys

import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy

from autoware_vehicle_msgs.msg import SteeringReport, VelocityReport
from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus, KeyValue
from geometry_msgs.msg import TransformStamped
from sensor_msgs.msg import CameraInfo, CompressedImage, Imu, PointCloud2, PointField
from tf2_msgs.msg import TFMessage


def sensor_qos(depth=5):
    return QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=depth,
                      reliability=ReliabilityPolicy.BEST_EFFORT)


def reliable_qos(depth=10):
    return QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=depth,
                      reliability=ReliabilityPolicy.RELIABLE)


def latched_qos():
    return QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=1,
                      reliability=ReliabilityPolicy.RELIABLE,
                      durability=DurabilityPolicy.TRANSIENT_LOCAL)


# ── point clouds ─────────────────────────────────────────────────────────────

XYZIRCAEDT = np.dtype([
    ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
    ("intensity", "u1"), ("return_type", "u1"), ("channel", "<u2"),
    ("azimuth", "<f4"), ("elevation", "<f4"), ("distance", "<f4"),
    ("time_stamp", "<u4"),
])  # 32 B, Nebula's Velodyne output (autoware_point_types PointXYZIRCAEDT)

XYZIRC = np.dtype([
    ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
    ("intensity", "u1"), ("return_type", "u1"), ("channel", "<u2"),
])  # 16 B, the Seyond driver's output as measured (point_step 16)


def fields_of(dtype):
    kind = {("f", 4): PointField.FLOAT32, ("u", 1): PointField.UINT8,
            ("u", 2): PointField.UINT16, ("u", 4): PointField.UINT32}
    return [PointField(name=n, offset=dtype.fields[n][1],
                       datatype=kind[(dtype.fields[n][0].kind, dtype.fields[n][0].itemsize)],
                       count=1)
            for n in dtype.names]


def make_cloud(frame_id, dtype, n, hfov_deg, vfov_deg, channels, rng):
    """A plausible scan: n points spread over the FOV at 2-80 m, so the crop
    box, ring outlier filter and voxel grid downstream have real work."""
    az = np.deg2rad(rng.uniform(-hfov_deg / 2, hfov_deg / 2, n)).astype("<f4")
    el = np.deg2rad(rng.uniform(-vfov_deg / 2, vfov_deg / 2, n)).astype("<f4")
    d = rng.uniform(2.0, 80.0, n).astype("<f4")
    pts = np.zeros(n, dtype=dtype)
    pts["x"] = d * np.cos(el) * np.cos(az)
    pts["y"] = d * np.cos(el) * np.sin(az)
    pts["z"] = d * np.sin(el)
    pts["intensity"] = rng.integers(0, 255, n, dtype="u1")
    pts["return_type"] = 1
    pts["channel"] = rng.integers(0, channels, n, dtype="<u2")
    if "azimuth" in dtype.names:
        pts["azimuth"] = az
        pts["elevation"] = el
        pts["distance"] = d
        pts["time_stamp"] = np.linspace(0, 100_000_000, n, dtype="<u4")  # ns within the 100 ms scan
    msg = PointCloud2()
    msg.header.frame_id = frame_id
    msg.height = 1
    msg.width = n
    msg.fields = fields_of(dtype)
    msg.is_bigendian = False
    msg.point_step = dtype.itemsize
    msg.row_step = dtype.itemsize * n
    msg.data = pts.tobytes()
    msg.is_dense = True
    return msg


# ── the two hosts ────────────────────────────────────────────────────────────

class Master(Node):
    # LINK_SIM_LOAD picks which end of the sourced range these run at. It exists
    # so the offered load is an explicit, stated choice rather than a number
    # buried in a class body - a simulation can be wrong by inventing too much
    # load as easily as too little, and either way the conclusion is worthless.
    #
    #   spec    the datasheet/config upper bound, the outdoor worst case
    #   cart    what was actually measured in cart bags
    #
    # Use it as a sensitivity check: a conclusion that flips between these two
    # is a conclusion about the guess, not about the configuration under test.
    # The multicast-vs-unicast routing this harness measures does not depend on
    # message size at all; whether the link SATURATES obviously does.
    LOAD = os.environ.get("LINK_SIM_LOAD", "spec")
    # VLP-32C single return: 600 000 pts/s (datasheet) at the 10 Hz in
    # VLP32.param.yaml -> 60 000/frame. Cart bags measured 48 700 indoors
    # (docs/research/performance/indoor-replay-bottlenecks.md).
    VLP32_POINTS = 60_000 if LOAD == "spec" else 48_700
    FALCON_POINTS = 51_743       # measured on the cart, 3 677 frames
    # 250-400 kB measured at q90, 1920x1280
    GMSL_JPEG_BYTES = 300_000 if LOAD == "spec" else 250_000
    CAMERAS = ("left", "right", "rear")

    def __init__(self):
        super().__init__("synthetic_master_sensors")
        rng = np.random.default_rng(1)
        self.vlp32 = make_cloud("velodyne", XYZIRCAEDT, self.VLP32_POINTS, 360, 40, 32, rng)
        self.falcon = make_cloud("falcon", XYZIRC, self.FALCON_POINTS, 120, 25, 1, rng)
        self.vlp32_pub = self.create_publisher(PointCloud2, "/sensing/lidar/vlp32/velodyne_points", sensor_qos())
        self.falcon_pub = self.create_publisher(PointCloud2, "/sensing/lidar/falcon/iv_points", sensor_qos())
        self.jpeg = bytes(os.urandom(self.GMSL_JPEG_BYTES))
        self.cam_pubs = {}
        for cam in self.CAMERAS:
            self.cam_pubs[cam] = (
                self.create_publisher(CompressedImage, f"/sensing/camera/{cam}/image_raw/compressed", sensor_qos()),
                self.create_publisher(CameraInfo, f"/sensing/camera/{cam}/camera_info", sensor_qos()))
        self.vel_pub = self.create_publisher(VelocityReport, "/vehicle/status/velocity_status", reliable_qos())
        self.steer_pub = self.create_publisher(SteeringReport, "/vehicle/status/steering_status", reliable_qos())
        self.create_timer(0.1, self.tick_lidar)
        self.create_timer(1.0 / 30.0, self.tick_cameras)
        self.create_timer(0.02, self.tick_vehicle)
        self.get_logger().info(
            f"vlp32 {len(self.vlp32.data)} B, falcon {len(self.falcon.data)} B at 10 Hz; "
            f"3 cameras x {self.GMSL_JPEG_BYTES} B at 30 Hz; vehicle status 50 Hz")

    def now(self):
        return self.get_clock().now().to_msg()

    def tick_lidar(self):
        t = self.now()
        self.vlp32.header.stamp = t
        self.falcon.header.stamp = t
        self.vlp32_pub.publish(self.vlp32)
        self.falcon_pub.publish(self.falcon)

    def tick_cameras(self):
        t = self.now()
        for cam, (img_pub, info_pub) in self.cam_pubs.items():
            img = CompressedImage()
            img.header.stamp = t
            img.header.frame_id = f"camera_{cam}"
            img.format = "jpeg"
            img.data = self.jpeg
            img_pub.publish(img)
            info = CameraInfo()
            info.header = img.header
            info.width, info.height = 1920, 1280
            info_pub.publish(info)

    def tick_vehicle(self):
        v = VelocityReport()
        v.header.stamp = self.now()
        v.header.frame_id = "base_link"
        v.longitudinal_velocity = 2.0
        self.vel_pub.publish(v)
        s = SteeringReport()
        s.stamp = v.header.stamp
        s.steering_tire_angle = 0.0
        self.steer_pub.publish(s)


class Orin(Node):
    ZED_JPEG_BYTES = 220_000     # 6.5 MB/s measured bag rate at 30 Hz

    def __init__(self):
        super().__init__("synthetic_orin_sensors")
        # The ZED wrapper publishes everything with rclcpp::QoS(10): reliable.
        self.img_pub = self.create_publisher(
            CompressedImage, "/sensing/camera/zed/rgb/color/rect/image/compressed", reliable_qos())
        self.info_pub = self.create_publisher(
            CameraInfo, "/sensing/camera/zed/rgb/color/rect/camera_info", reliable_qos())
        self.imu_pub = self.create_publisher(Imu, "/sensing/camera/zed/imu/data", reliable_qos())
        self.tf_pub = self.create_publisher(TFMessage, "/tf", reliable_qos(100))
        self.tf_static_pub = self.create_publisher(TFMessage, "/tf_static", latched_qos())
        self.diag_pub = self.create_publisher(DiagnosticArray, "/diagnostics", reliable_qos())
        self.jpeg = bytes(os.urandom(self.ZED_JPEG_BYTES))
        self.create_timer(1.0 / 30.0, self.tick_camera)
        self.create_timer(0.01, self.tick_imu)
        self.create_timer(1.0, self.tick_diag)
        self.publish_tf_static()
        self.get_logger().info(
            f"zed image {self.ZED_JPEG_BYTES} B + camera_info at 30 Hz; imu + imu tf 100 Hz; diagnostics 1 Hz")

    def now(self):
        return self.get_clock().now().to_msg()

    def tick_camera(self):
        t = self.now()
        img = CompressedImage()
        img.header.stamp = t
        img.header.frame_id = "zed_left_camera_frame_optical"
        img.format = "jpeg"
        img.data = self.jpeg
        self.img_pub.publish(img)
        info = CameraInfo()
        info.header = img.header
        info.width, info.height = 1920, 1200
        self.info_pub.publish(info)

    def tick_imu(self):
        t = self.now()
        m = Imu()
        m.header.stamp = t
        m.header.frame_id = "zed_imu_link"
        m.orientation.w = 1.0
        m.angular_velocity.z = 0.001
        m.linear_acceleration.z = 9.81
        self.imu_pub.publish(m)
        tf = TransformStamped()
        tf.header.stamp = t
        tf.header.frame_id = "zed_left_camera_frame"
        tf.child_frame_id = "zed_imu_link"
        tf.transform.translation.y = -0.0356
        tf.transform.translation.z = -0.0001
        tf.transform.rotation.w = 1.0
        self.tf_pub.publish(TFMessage(transforms=[tf]))

    def tick_diag(self):
        arr = DiagnosticArray()
        arr.header.stamp = self.now()
        for name in ("cpu_usage", "cpu_temperature", "memory_usage", "net_usage",
                     "ntp_offset", "process_high_load", "process_high_mem", "gpu_usage"):
            st = DiagnosticStatus(level=DiagnosticStatus.OK, name=f"orin_{name}: {name}",
                                  message="OK", hardware_id="orin")
            st.values = [KeyValue(key=f"k{i}", value=f"v{i}") for i in range(6)]
            arr.status.append(st)
        self.diag_pub.publish(arr)

    def publish_tf_static(self):
        msg = TFMessage()
        for child in ("zed_camera_center", "zed_left_camera_frame", "zed_left_camera_frame_optical"):
            t = TransformStamped()
            t.header.stamp = self.now()
            t.header.frame_id = "zed_camera_link"
            t.child_frame_id = child
            t.transform.rotation.w = 1.0
            msg.transforms.append(t)
        self.tf_static_pub.publish(msg)


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else ""
    if host not in ("master", "orin"):
        sys.exit("usage: synthetic_sensors.py master|orin")
    rclpy.init(args=sys.argv)
    node = Master() if host == "master" else Orin()
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
