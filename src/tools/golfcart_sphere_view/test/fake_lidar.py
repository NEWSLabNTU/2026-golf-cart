"""Publish a synthetic LiDAR whose returns lie on a known wall.

The wall is a vertical plane at a fixed distance with a doorway cut out of it,
so there is a depth discontinuity to line up against whatever the cameras paint.
Returns carry intensity, and the doorway edge is marked retroreflective, which
is what the VLP-32C reports above 100.
"""
import math
import struct

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import PointCloud2, PointField
from tf2_ros import StaticTransformBroadcaster
from geometry_msgs.msg import TransformStamped

WALL_DISTANCE = 8.0
DOOR_HALF_WIDTH = 1.0
DOOR_HEIGHT = 2.0


def wall_points():
    """Returns on a wall in the sensor frame, x forward, y left, z up."""
    points = []
    for azimuth_step in range(-600, 601, 3):
        azimuth = math.radians(azimuth_step / 10.0)
        for elevation_step in range(-100, 151, 3):
            elevation = math.radians(elevation_step / 10.0)
            if abs(math.cos(azimuth)) < 1e-3:
                continue
            # Range to a plane at x = WALL_DISTANCE along this bearing.
            distance = WALL_DISTANCE / (math.cos(azimuth) * math.cos(elevation))
            if distance <= 0.0 or distance > 40.0:
                continue
            x = distance * math.cos(elevation) * math.cos(azimuth)
            y = distance * math.cos(elevation) * math.sin(azimuth)
            z = distance * math.sin(elevation)

            # The doorway: no return from the plane, so the beam passes through
            # and lands on something further back.
            in_doorway = abs(y) < DOOR_HALF_WIDTH and -0.5 < z < DOOR_HEIGHT
            if in_doorway:
                distance *= 2.0
                x, y, z = x * 2.0, y * 2.0, z * 2.0
                intensity = 20.0
            elif abs(abs(y) - DOOR_HALF_WIDTH) < 0.05 and z < DOOR_HEIGHT:
                # Retroreflective tape down the door frame.
                intensity = 200.0
            else:
                intensity = 60.0
            points.append((x, y, z, intensity))
    return points


class FakeLidar(Node):
    def __init__(self):
        super().__init__("fake_lidar")
        self.publisher = self.create_publisher(
            PointCloud2, "/sensing/lidar/vlp32/velodyne_points", qos_profile_sensor_data)
        self.broadcaster = StaticTransformBroadcaster(self)
        self.publish_static_transform()
        points = wall_points()
        # The wall does not move, so pack once. Re-packing the returns every
        # tick would make this publisher, not the display, the thing being
        # measured.
        self.point_count = len(points)
        self.payload = b"".join(struct.pack("<ffff", *point) for point in points)
        self.get_logger().info("wall has %d returns" % self.point_count)
        self.create_timer(0.1, self.publish)

    def publish_static_transform(self):
        t = TransformStamped()
        t.header.stamp = self.get_clock().now().to_msg()
        t.header.frame_id = "base_link"
        t.child_frame_id = "velodyne"
        t.transform.translation.x = 0.0
        t.transform.translation.y = 0.0
        t.transform.translation.z = 1.6
        t.transform.rotation.w = 1.0
        self.broadcaster.sendTransform(t)

    def publish(self):
        msg = PointCloud2()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = "velodyne"
        msg.height = 1
        msg.width = self.point_count
        msg.fields = [
            PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
            PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
            PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
            PointField(name="intensity", offset=12, datatype=PointField.FLOAT32, count=1),
        ]
        msg.is_bigendian = False
        msg.point_step = 16
        msg.row_step = msg.point_step * msg.width
        msg.is_dense = True
        msg.data = self.payload
        self.publisher.publish(msg)


def main():
    rclpy.init()
    rclpy.spin(FakeLidar())


if __name__ == "__main__":
    main()
