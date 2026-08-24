"""Publish synthetic cameras so the sphere display can be exercised off-vehicle.

Three cameras arranged like the vehicle's -- left, right and rear -- each with a
grid image, a pinhole CameraInfo and a static transform in the optical
convention. The yaw spacing is deliberately wider than each camera's field of
view, so the seams between them are visible and a wrong transform shows up as a
discontinuity across one.

Pass --cameras left,right to publish a subset.
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


def grid_jpeg(tick, label, colour):
    image = Image.new("RGB", (WIDTH, HEIGHT), (40, 30, 30))
    draw = ImageDraw.Draw(image)
    for x in range(0, WIDTH, 40):
        draw.line([(x, 0), (x, HEIGHT)], fill=colour)
    for y in range(0, HEIGHT, 40):
        draw.line([(0, y), (WIDTH, y)], fill=colour)
    draw.ellipse(
        [WIDTH // 2 - 60, HEIGHT // 2 - 60, WIDTH // 2 + 60, HEIGHT // 2 + 60],
        outline=(255, 0, 0), width=3)
    # Something that moves, so a frozen texture is obvious.
    x = int(WIDTH / 2 + WIDTH / 3 * math.sin(tick / 10.0))
    draw.ellipse([x - 25, HEIGHT // 4 - 25, x + 25, HEIGHT // 4 + 25], fill=(0, 255, 255))
    draw.text((20, HEIGHT - 30), label, fill=(255, 255, 255))
    # Corner markers, so the texture's orientation on the sphere is unambiguous.
    draw.rectangle([0, 0, 30, 30], fill=(255, 0, 255))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=90)
    return buffer.getvalue()


# name, yaw about base_link z, and a colour so each camera is identifiable on
# the sphere without reading the label.
CAMERAS = [
    ("left", math.radians(60.0), (0, 255, 0)),
    ("right", math.radians(-60.0), (255, 128, 0)),
    ("rear", math.radians(180.0), (120, 160, 255)),
]


def optical_from_yaw(yaw):
    """Quaternion taking base_link to a camera optical frame at this yaw.

    base_link is x forward, y left, z up; the optical frame is x right, y down,
    z forward. The fixed part of that is a -90 degree roll followed by a -90
    degree yaw, which is the quaternion (-0.5, 0.5, -0.5, 0.5); the camera's own
    yaw is then applied about base_link z before it.
    """
    base = (-0.5, 0.5, -0.5, 0.5)
    half = yaw / 2.0
    spin = (0.0, 0.0, math.sin(half), math.cos(half))

    x1, y1, z1, w1 = spin
    x2, y2, z2, w2 = base
    return (
        w1 * x2 + x1 * w2 + y1 * z2 - z1 * y2,
        w1 * y2 - x1 * z2 + y1 * w2 + z1 * x2,
        w1 * z2 + x1 * y2 - y1 * x2 + z1 * w2,
        w1 * w2 - x1 * x2 - y1 * y2 - z1 * z2,
    )


class FakeCameras(Node):
    def __init__(self, wanted):
        super().__init__("fake_cameras")
        self.tick = 0
        self.cameras = [c for c in CAMERAS if c[0] in wanted]
        self.publishers_by_name = {}
        for name, _, _ in self.cameras:
            self.publishers_by_name[name] = (
                self.create_publisher(
                    CompressedImage,
                    "/sensing/camera/%s/image_raw/compressed" % name,
                    qos_profile_sensor_data,
                ),
                self.create_publisher(
                    CameraInfo,
                    "/sensing/camera/%s/camera_info" % name,
                    qos_profile_sensor_data,
                ),
            )
        self.broadcaster = StaticTransformBroadcaster(self)
        self.publish_static_transforms()
        self.create_timer(1.0 / 30.0, self.publish)
        self.get_logger().info(
            "publishing %s" % ", ".join(name for name, _, _ in self.cameras))

    def publish_static_transforms(self):
        transforms = []
        for name, yaw, _ in self.cameras:
            t = TransformStamped()
            t.header.stamp = self.get_clock().now().to_msg()
            t.header.frame_id = "base_link"
            t.child_frame_id = "camera_%s_optical" % name
            # Roughly where they sit on the cart: forward of the axle, up at
            # roof height, offset to whichever side they face.
            t.transform.translation.x = 1.0 * math.cos(yaw)
            t.transform.translation.y = 1.0 * math.sin(yaw)
            t.transform.translation.z = 1.2
            x, y, z, w = optical_from_yaw(yaw)
            t.transform.rotation.x = x
            t.transform.rotation.y = y
            t.transform.rotation.z = z
            t.transform.rotation.w = w
            transforms.append(t)
        self.broadcaster.sendTransform(transforms)

    def publish(self):
        self.tick += 1
        stamp = self.get_clock().now().to_msg()
        for name, _, colour in self.cameras:
            image_pub, info_pub = self.publishers_by_name[name]
            frame = "camera_%s_optical" % name

            msg = CompressedImage()
            msg.header.stamp = stamp
            msg.header.frame_id = frame
            msg.format = "jpeg"
            msg.data = grid_jpeg(self.tick, name.upper(), colour)
            image_pub.publish(msg)

            info = CameraInfo()
            info.header.stamp = stamp
            info.header.frame_id = frame
            info.width = WIDTH
            info.height = HEIGHT
            fx = fy = 320.0
            info.k = [fx, 0.0, WIDTH / 2.0, 0.0, fy, HEIGHT / 2.0, 0.0, 0.0, 1.0]
            info.d = [0.0, 0.0, 0.0, 0.0, 0.0]
            info.distortion_model = "plumb_bob"
            info.p = [fx, 0.0, WIDTH / 2.0, 0.0, 0.0, fy, HEIGHT / 2.0, 0.0, 0.0, 0.0, 1.0, 0.0]
            info_pub.publish(info)


def main():
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--cameras", default="left,right,rear")
    arguments, ros_arguments = parser.parse_known_args()

    rclpy.init(args=ros_arguments)
    rclpy.spin(FakeCameras(set(arguments.cameras.split(","))))


if __name__ == "__main__":
    main()
