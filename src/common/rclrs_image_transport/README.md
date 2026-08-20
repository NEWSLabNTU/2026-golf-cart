# rclrs_image_transport

The half of `image_transport` that a Rust node cannot reach.

`image_transport` is C++ pluginlib. rclrs cannot load its plugins, and has no
intra-process comms either, so the Rust side has to own both the JPEG codec and
the image/`CameraInfo` pairing. This package is that, and nothing more.

Design and rationale: [`docs/roadmaps/2-camera-image-pipeline.md`](../../../docs/roadmaps/2-camera-image-pipeline.md),
sub-phase C.

## Two crates, and why

| crate | ROS dependencies | holds |
|---|---|---|
| `image_transport_codec` (`codec/`) | none | the `CompressedImage.format` contract, decode, encode |
| `rclrs_image_transport` | rclrs, sensor_msgs, std_msgs | transport hints, image and camera subscriptions, `image_transport_echo` |

The split is not tidiness. `sensor_msgs` and friends do not exist on crates.io --
colcon-cargo-ros2 substitutes generated bindings through `[patch.crates-io]` at
build time -- so any crate naming them cannot resolve a lock file outside an
ament workspace, and cannot be built or tested with plain `cargo`. Keeping the
contract in a crate with no ROS dependency means the part that has to be exactly
right is testable anywhere:

```console
cargo test --manifest-path codec/Cargo.toml
```

## The contract

`CompressedImage.format` is the whole interface between publisher and
subscriber, and the message definition does not specify it. The convention is
whatever `compressed_image_transport` does, so this crate reproduces that
behaviour rather than a tidier one. Verified by running the C++ plugin and
recording what it wrote:

| source `Image.encoding` | `CompressedImage.format` |
|---|---|
| `bgr8` | `bgr8; jpeg compressed bgr8` |
| `rgb8` | `rgb8; jpeg compressed bgr8` |
| `mono8` | `mono8; jpeg compressed mono8` |

Three things follow, and each of them is a way to get this silently wrong:

- **The colour target is the literal `bgr8`.** Not because the bytes are BGR,
  but because that substring is what the C++ subscriber greps for to decide
  whether to swap channels. `CompressedFormat` will not construct anything else.
- **The first field decides the channel order, not the target.** Row two: an
  `rgb8` source yields a BGR payload that a subscriber must hand back as RGB.
  Read the target field and stop, and red and blue transpose on every frame.
- **The bare form is legal.** gscam writes plain `"jpeg"`, and every bag this
  project has recorded carries it. The channel-count fallback is what replays
  them.

## Fixtures

`codec/tests/fixtures/` was produced by the C++ plugin itself, and is committed
so the tests need no ROS graph. Regenerate only when the plugin version changes:

```console
ros2 run image_transport republish raw compressed \
  --ros-args -r in:=/fixture/image_raw -r out/compressed:=/fixture/out/compressed &
python3 scripts/make_fixtures.py
```

## image_transport_echo

What is on a camera topic, whether this crate can decode it, and what that
costs:

```console
ros2 run rclrs_image_transport image_transport_echo --ros-args \
  -p base_topic:=/sensing/camera/left/image_raw \
  -p transport:=compressed -p target:=mono -p with_camera_info:=true
```

```text
#0 format="bgr8; jpeg compressed bgr8" -> codec Jpeg, target Some(Colour);
   decoded 1920x1280x1 mono8 in 4632 us
CameraInfo paired: 1920x1280, 5 distortion coefficients (plumb_bob)
```

## Not implemented, deliberately

- **H.264/H.265 in `CompressedImage`.** The ecosystem answer is
  `ffmpeg_image_transport`, which uses its own message type precisely because
  `CompressedImage` is the wrong container for an inter-frame codec.
- **`compressedDepth`.** A separate transport: a binary header prefixed to a PNG
  payload, not a `format` string variant.
- **PNG and TIFF, 16-bit colour, four-channel colour.** Parsed, named, refused.

## Destination

Its own repository under NEWSLabNTU, added back here as a submodule, the same
shape as `gmslcam`. Nothing in it is golf-cart specific except its current
address.
