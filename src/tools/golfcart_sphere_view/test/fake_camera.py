"""Publish a synthetic camera so the sphere display can be exercised off-vehicle.

Grid image, a plausible pinhole CameraInfo, and a static base_link -> camera
transform in the optical convention.
"""
import math

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CameraInfo, CompressedImage
from tf2_ros import StaticTransformBroadcaster
from geometry_msgs.msg import TransformStamped

# PIL rather than cv2: this host's cv2 is built against numpy 1.x and the
# installed numpy is 2.x, and repairing that is not this script's business.
import io

from PIL import Image, ImageDraw

WIDTH, HEIGHT = 640, 480


def grid_jpeg(tick):
    image = Image.new("RGB", (WIDTH, HEIGHT), (40, 30, 30))
    draw = ImageDraw.Draw(image)
    for x in range(0, WIDTH, 40):
        draw.line([(x, 0), (x, HEIGHT)], fill=(0, 200, 0))
    for y in range(0, HEIGHT, 40):
        draw.line([(0, y), (WIDTH, y)], fill=(0, 200, 0))
    draw.ellipse(
        [WIDTH // 2 - 60, HEIGHT // 2 - 60, WIDTH // 2 + 60, HEIGHT // 2 + 60],
        outline=(255, 0, 0), width=3)
    # Something that moves, so a frozen texture is obvious.
    x = int(WIDTH / 2 + WIDTH / 3 * math.sin(tick / 10.0))
    draw.ellipse([x - 25, HEIGHT // 4 - 25, x + 25, HEIGHT // 4 + 25], fill=(0, 255, 255))
    draw.text((20, HEIGHT - 30), "LEFT", fill=(255, 255, 255))
    # Corner markers, so the texture's orientation on the sphere is unambiguous.
    draw.rectangle([0, 0, 30, 30], fill=(255, 0, 255))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue()


class FakeCamera(Node):
    def __init__(self):
        super().__init__("fake_camera")
        self.image_pub = self.create_publisher(
            CompressedImage, "/sensing/camera/left/image_raw/compressed", qos_profile_sensor_data
        )
        self.info_pub = self.create_publisher(
            CameraInfo, "/sensing/camera/left/camera_info", qos_profile_sensor_data
        )
        self.tick = 0
        self.broadcaster = StaticTransformBroadcaster(self)
        self.publish_static_transform()
        self.create_timer(1.0 / 30.0, self.publish)

    def publish_static_transform(self):
        t = TransformStamped()
        t.header.stamp = self.get_clock().now().to_msg()
        t.header.frame_id = "base_link"
        t.child_frame_id = "camera_left_optical"
        t.transform.translation.x = 1.0
        t.transform.translation.y = 0.4
        t.transform.translation.z = 1.2
        # base_link (x fwd, y left, z up) -> optical (x right, y down, z fwd),
        # the -90 about z then -90 about x that REP-103 implies.
        t.transform.rotation.x = -0.5
        t.transform.rotation.y = 0.5
        t.transform.rotation.z = -0.5
        t.transform.rotation.w = 0.5
        self.broadcaster.sendTransform(t)

    def publish(self):
        self.tick += 1
        stamp = self.get_clock().now().to_msg()

        msg = CompressedImage()
        msg.header.stamp = stamp
        msg.header.frame_id = "camera_left_optical"
        msg.format = "jpeg"
        msg.data = grid_jpeg(self.tick)
        self.image_pub.publish(msg)

        info = CameraInfo()
        info.header.stamp = stamp
        info.header.frame_id = "camera_left_optical"
        info.width = WIDTH
        info.height = HEIGHT
        fx = fy = 320.0
        info.k = [fx, 0.0, WIDTH / 2.0, 0.0, fy, HEIGHT / 2.0, 0.0, 0.0, 1.0]
        info.d = [0.0, 0.0, 0.0, 0.0, 0.0]
        info.distortion_model = "plumb_bob"
        info.p = [fx, 0.0, WIDTH / 2.0, 0.0, 0.0, fy, HEIGHT / 2.0, 0.0, 0.0, 0.0, 1.0, 0.0]
        self.info_pub.publish(info)


def main():
    rclpy.init()
    rclpy.spin(FakeCamera())


if __name__ == "__main__":
    main()
