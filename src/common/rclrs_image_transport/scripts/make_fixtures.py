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
"""Produce CompressedImage fixtures with the **C++** compressed_image_transport.

The crate's job is to be byte-compatible with that plugin, and the only way to
know is to make it write the bytes. This publishes a raw Image, lets
`image_transport republish` compress it, and records exactly what came out --
the `format` string and the JPEG payload -- into codec/tests/fixtures/.

Run it when the plugin version changes, not on every build: the fixtures are
committed precisely so the tests do not need a ROS graph.

    ros2 run image_transport republish raw compressed \
        --ros-args -r in:=/fixture/image_raw -r out/compressed:=/fixture/out/compressed &
    python3 scripts/make_fixtures.py
"""

import json
import pathlib
import struct
import subprocess
import sys
import time

import rclpy
from rclpy.node import Node
from sensor_msgs.msg import CompressedImage, Image

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "codec" / "tests" / "fixtures"

WIDTH, HEIGHT = 64, 48


def pattern(channels: int, blue_first: bool) -> bytes:
    """A deterministic image with hard edges, so a channel swap is visible.

    Left half saturated blue, right half saturated red, with a green ramp down
    the rows. If red and blue transpose anywhere in the round trip, the two
    halves exchange and the test says so.
    """
    rows = []
    for y in range(HEIGHT):
        row = bytearray()
        green = (y * 255) // (HEIGHT - 1)
        for x in range(WIDTH):
            red = 255 if x >= WIDTH // 2 else 0
            blue = 255 if x < WIDTH // 2 else 0
            if channels == 1:
                row.append(green)
            elif blue_first:
                row += bytes((blue, green, red))
            else:
                row += bytes((red, green, blue))
        rows.append(bytes(row))
    return b"".join(rows)


class Harness(Node):
    def __init__(self):
        super().__init__("image_transport_fixture_maker")
        self.pub = self.create_publisher(Image, "/fixture/image_raw", 1)
        self.sub = self.create_subscription(
            CompressedImage, "/fixture/out/compressed", self.on_compressed, 1
        )
        self.received = None

    def on_compressed(self, msg):
        self.received = msg

    def run_case(self, name, encoding, channels, blue_first):
        raw = pattern(channels, blue_first)
        msg = Image()
        msg.header.frame_id = "fixture"
        msg.height = HEIGHT
        msg.width = WIDTH
        msg.encoding = encoding
        msg.is_bigendian = 0
        msg.step = WIDTH * channels
        msg.data = list(raw)

        self.received = None
        deadline = time.time() + 15.0
        while self.received is None and time.time() < deadline:
            self.pub.publish(msg)
            rclpy.spin_once(self, timeout_sec=0.2)
        if self.received is None:
            raise SystemExit(
                f"{name}: no CompressedImage came back. Is `image_transport "
                f"republish raw compressed` running with the remaps in the docstring?"
            )

        payload = bytes(self.received.data)
        (OUT / f"{name}.jpg").write_bytes(payload)
        (OUT / f"{name}.raw").write_bytes(raw)
        meta = {
            "name": name,
            "format": self.received.format,
            "source_encoding": encoding,
            "width": WIDTH,
            "height": HEIGHT,
            "channels": channels,
            "payload_bytes": len(payload),
        }
        (OUT / f"{name}.json").write_text(json.dumps(meta, indent=2) + "\n")
        print(f"  {name}: format={self.received.format!r} {len(payload)} bytes")
        return meta


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rclpy.init()
    harness = Harness()
    print("Recording what the C++ plugin writes:")
    cases = [
        harness.run_case("cpp_bgr8", "bgr8", 3, True),
        harness.run_case("cpp_rgb8", "rgb8", 3, False),
        harness.run_case("cpp_mono8", "mono8", 1, False),
    ]
    (OUT / "index.json").write_text(json.dumps(cases, indent=2) + "\n")
    harness.destroy_node()
    rclpy.shutdown()


if __name__ == "__main__":
    main()
