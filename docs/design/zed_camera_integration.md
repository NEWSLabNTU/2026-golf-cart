# ZED X Camera Integration

How the ZED X stereo camera is launched, what it publishes, and how its
transforms are divided between the camera driver and Autoware.

Last updated: 2026-08-12

Related: [multi_machine_deployment.md](multi_machine_deployment.md),
[../roadmaps/2-zed-camera-integration.md](../roadmaps/2-zed-camera-integration.md)

---

## Scope

The golf cart carries two independent camera sets on two different machines:

| Machine | Cameras | Driver |
|---------|---------|--------|
| Advantech (`is_master`) | three GMSL cameras — left, right, rear | `gmslcam` |
| Orin (`is_orin`) | one ZED X stereo camera with built-in IMU | `zed_components::ZedCamera` |

Both are reached through the same entry point,
`golfcart_sensor_kit_launch/launch/camera.launch.xml`, selected by the
`camera_model` argument. Only one branch is ever active in a given process,
because the two machines run different parts of the launch tree.

The ZED contributes three things: a rectified RGB image, an IMU stream that can
substitute for the Xsens, and the camera-local transforms that let both be
placed relative to `base_link`.

---

## Launch structure

```
golfcart_sensor_kit_launch/
  launch/camera.launch.xml     dispatch on camera_model: gmslcam | zedx | none
  launch/zed.launch.xml        component container + ZedCamera + robot_state_publisher
  config/zed.param.yaml        all ZED parameters
  launch/imu.launch.xml        dispatch on imu_source: xsens | zed
```

### Invocation paths

```
Advantech (is_master)
  golfcart.launch.yaml -> golfcart_autoware.launch.xml -> tier4_sensing_component
    -> golfcart_sensor_kit_launch/launch/sensing.launch.xml
         -> camera.launch.xml  camera_model:=gmslcam -> 3x gmslcam
         -> imu.launch.xml     imu_source:=xsens|zed -> imu_corrector + gyro_bias_estimator
         -> lidar.launch.xml, gnss.launch.xml

Orin (is_orin)
  golfcart.launch.yaml -> camera.launch.xml  camera_model:=zedx
                            -> zed.launch.xml
                                 -> component_container_isolated + stereolabs::ZedCamera
                                 -> robot_state_publisher (zed_descr.urdf.xacro)
```

`golfcart_autoware.launch.xml` is gated on `is_master`, so the sensing subtree
never runs on the Orin. The Orin therefore includes `camera.launch.xml`
directly.

### Why the ZED branch uses absolute namespaces

The ZED branch deliberately does **not** use `push-ros-namespace`.
`load_composable_node` resolves its target container name as an absolute string
before any namespace push is applied, while the `node_container` action itself
*is* pushed. The two then disagree and the component silently never loads. For
the same reason, when this file is included from a conditional group, the
`LoadComposableNodes` action sits in a nested scope and its wait on the
container's `load_node` service never completes.

Both the container and the component therefore carry absolute namespaces
(`/sensing/camera/...`), and the group has no push. The `gmslcam` branch keeps its
`push-ros-namespace` because plain nodes are unaffected.

### Parameter layering

`zed.launch.xml` composes three parameter files, last one winning:

1. `zed_wrapper/config/common_stereo.yaml` — vendor defaults
2. `zed_wrapper/config/<camera_model>.yaml` — vendor per-model defaults
3. `golfcart_sensor_kit_launch/config/zed.param.yaml` — this project's overrides

Only `general.camera_name` and `general.camera_model` are set inline in the
launch file. They must be, because they are also substituted into namespaces and
the URDF command, so they cannot live only in a shared YAML.

---

## Published topics

```
/sensing/camera/zed/rgb/color/rect/image          30 Hz, 960x600, bgr8
/sensing/camera/zed/rgb/color/rect/camera_info    30 Hz
/sensing/camera/zed/imu/data                      ~98 Hz
```

Plus the `image_transport` variants of the image topic (`compressed`,
`compressedDepth`, `theora`) and a second `camera_info` under
`rgb/color/rect/image/camera_info`. Those are created by `image_transport` and
are not separately configurable; the transport plugins publish only when
subscribed.

The ZED wrapper builds image topic names as
`<sensor>/<color model>/<rectification>/image`. This project publishes the
rectified colour RGB channel only. Left, right, stereo, greyscale, and
unrectified variants are all disabled to save GPU time on the Orin and bandwidth
on the inter-machine link.

**The RGB channel is the left camera.** In
`zed_camera_component_video_depth.cpp`, `mPubRgb` publishes `mMatLeft` with
`mLeftCamInfoMsg`. There is no separate RGB sensor on a stereo ZED. The image
and its `camera_info` are stamped with the frame
`zed_left_camera_frame_optical`.

Enabling `video.publish_left_right` would add the stereo pair, needed if visual
SLAM is added later. It also changes nothing about transforms, since
`pos_tracking` stays disabled either way.

---

## Transforms

### Division of ownership

| Edge | Publisher | Machine |
|------|-----------|---------|
| `map -> odom`, `odom -> base_link` | Autoware NDT + EKF | Advantech |
| `base_link -> sensor_kit_base_link -> zed_camera_link` | vehicle `robot_state_publisher`, from `sensor_kit_calibration.yaml` | Advantech |
| `zed_camera_link -> zed_camera_center -> zed_left/right_camera_frame -> *_optical` | ZED `robot_state_publisher`, from `zed_descr.urdf.xacro` | Orin |
| `zed_left_camera_frame -> zed_imu_link` | ZED driver | Orin |

No edge has two publishers.

### Why positional tracking is disabled

The ZED driver can publish `odom -> zed_camera_link` (`pos_tracking.publish_tf`)
and `map -> odom` (`pos_tracking.publish_map_tf`). Both collide head-on with
Autoware, which owns those edges through NDT and the EKF. Both are therefore
off, and `pos_tracking.pos_tracking_enabled` is off as well, which saves the GPU
cost of visual odometry the system does not use.

Disabling positional tracking has a second, less obvious consequence.
`publishTFs()` returns early when positional tracking is not ready, and
`publishCameraTFs()` — the function that would broadcast
`zed_camera_center -> zed_left_camera_frame` and the matching right edge — is
reached only through it. So with tracking off, the driver publishes no camera
geometry at all.

That is the desired outcome, because those same two edges are also defined in
`zed_macro.urdf.xacro`. Enabling positional tracking would produce two
publishers for both of them.

### Why a second robot_state_publisher

`robot_state_publisher` is a stock ROS 2 node: give it a URDF in the
`robot_description` parameter and it broadcasts every fixed joint once on
`/tf_static`. The ZED URDF is entirely fixed joints, so it acts as a latched
publisher of the camera's rigid internal geometry.

The driver never publishes `zed_camera_link -> zed_camera_center` nor either
`*_optical` edge, under any configuration. It also *consumes*
`zed_camera_center -> zed_camera_link` through `getCamera2BaseTransform()`, so
that edge has to exist regardless. Something outside the driver must supply
them.

The choice is between instantiating `zed_macro.urdf.xacro` inside
`sensor_kit.xacro`, or running a dedicated `robot_state_publisher` on the
vendor's `zed_descr.urdf.xacro` next to the driver. This project does the
latter, for two reasons: the transforms then start and stop with the driver on
the same machine, and the numbers come from the vendor's own file rather than
being transcribed into this repository.

`sensor_kit.xacro` therefore declares only the bare `zed_camera_link` and its
joint to `sensor_kit_base_link`. It does not instantiate the ZED macro, which
would duplicate the whole subtree.

### The one number that must be measured

`zed_camera_link` is the camera's mounting point — described in
`zed_macro.urdf.xacro` as "the threaded screw hole in the bottom". It is a bare
link with no geometry, and it is the only ZED frame whose placement this project
is responsible for. Everything below it is fixed by the camera's construction.

For a ZED X, the vendor geometry below `zed_camera_link` is:

```
zed_camera_link
  -> zed_camera_center             xyz  0     0     0.016    rpy 0 0 0
    -> zed_left_camera_frame       xyz -0.01  0.06  0        rpy 0 0 0
      -> zed_left_camera_frame_optical         rpy -pi/2 0 -pi/2
    -> zed_right_camera_frame      xyz -0.01 -0.06  0        rpy 0 0 0
      -> zed_right_camera_frame_optical
```

The left lens sits 6 cm to the left of the body centre, 1.6 cm above the screw
hole, and 1 cm behind centre. Do not fold any of that into
`sensor_kit_calibration.yaml` — the URDF already applies it. Measure to the
screw hole.

### Consequence for tag and object detection

A pose computed from the RGB channel — an ArUco or AprilTag detection, for
instance — is expressed in `zed_left_camera_frame_optical`, not in
`zed_camera_center`. `solvePnP` returns poses in the frame the intrinsics
describe, and those intrinsics arrive on `rgb/color/rect/camera_info`, which
carries the left rectified projection and that frame id.

That frame uses the ROS optical convention: **Z forward, X right, Y down** —
not the body convention. Transform detections into `base_link` with `tf2`,
never by composing offsets by hand.

---

## IMU

### Which topic

The ZED publishes two IMU topics and this project uses `imu/data`.

| Topic | Contents |
|-------|----------|
| `imu/data` | orientation, angular velocity, linear acceleration, all covariances — factory-calibrated |
| `imu/data_raw` | angular velocity and linear acceleration only, from the SDK's `*_uncalibrated` fields, no orientation |

The name `imu_raw` in Autoware's launch files means "not yet corrected by
Autoware", not "uncalibrated by the vendor". The Xsens path in this same
repository already demonstrates the distinction: the driver's own filtered
`imu/data` output is remapped to `imu_raw`.

`gyro_bias_estimator` estimates a constant three-axis bias and nothing else — it
cannot reconstruct scale, axis misalignment, or temperature compensation.
Autoware's scale estimator exists but ships disabled
(`scale_imu_injection.modify_imu_scale: false`). Feeding it `imu/data_raw` would
discard vendor corrections that nothing downstream can rebuild.

### Processing chain

```
/sensing/camera/zed/imu/data  ->  imu_corrector       ->  /sensing/imu/imu_data  ->  gyro_odometer
                              ->  gyro_bias_estimator ->  gyro_bias              ->  imu_corrector
```

Identical in shape to the Xsens path. `imu.launch.xml` selects between them with
`imu_source`, switching the input topic and the driver node, but never the
processing chain — `imu_corrector` and `gyro_bias_estimator` run on the
Advantech in both cases. No ZED node is added to `imu.launch.xml`; the ZED is
launched by `camera.launch.xml` on the Orin, and `imu.launch.xml` only subscribes
to what it already publishes.

Each source needs its own `imu_corrector` parameters. The existing offsets and
standard deviations were measured on the Xsens and are meaningless for the ZED,
so the file is split into `imu_corrector_xsens.param.yaml` and
`imu_corrector_zed.param.yaml`.

### Frame resolution

`autoware_gyro_odometer` rotates the IMU's angular velocity into `base_link` by
TF lookup. With `imu_source:=zed` that lookup traverses:

```
base_link -> sensor_kit_base_link -> zed_camera_link -> zed_camera_center
          -> zed_left_camera_frame -> zed_imu_link
```

The last edge comes from the driver, which publishes it independently of
positional tracking — `publishImuFrameAndTopic()` is gated only on
`sensors.publish_imu_tf`. The rest come from the two `robot_state_publisher`
instances.

### Cross-machine caveat

With `imu_source:=zed`, the IMU stream crosses the DDS link at
`sensors_pub_rate: 100.0`. The data volume is negligible, but `gyro_odometer`
time-synchronises the IMU against vehicle twist, so link jitter appears as twist
noise. A wired link is strongly preferred; otherwise lower the publish rate.

---

## Configuration

`golfcart_sensor_kit_launch/config/zed.param.yaml`:

```yaml
video:
  publish_rgb: true
  publish_left_right: false
  publish_raw: false
  publish_gray: false
  publish_stereo: false
  enable_24bit_output: true
sensors:
  publish_imu: true
  publish_imu_raw: false
  publish_imu_tf: true
  sensors_pub_rate: 100.0
pos_tracking:
  pos_tracking_enabled: false
  publish_tf: false
  publish_map_tf: false
depth:
  depth_mode: 'NONE'
  publish_depth_map: false
  publish_point_cloud: false
```

Depth is disabled because nothing consumes it, and it is the most expensive
thing the ZED can be asked to compute.

Two of these are not obvious:

- **`enable_24bit_output: true`** gives `bgr8` images instead of the default
  `bgra8`. The alpha channel is always opaque and no consumer reads it, so the
  default wastes a quarter of the image bandwidth on the inter-machine link.
  Needs SDK 5.1 or newer; the vehicle runs 5.2.3.
- **`publish_depth_map` and `publish_point_cloud` are not implied by
  `depth_mode: NONE`.** The `camera_info` publishers are guarded on
  `mPublishDepthMap`, not on the depth mode, so with only the mode set the
  driver still advertises and ticks `depth/camera_info` and
  `depth/depth_registered/camera_info` at the full frame rate — measured at
  30 Hz each — carrying the left camera's info for a depth map that does not
  exist.

### Publishing resolution

The vendor default is `general.pub_resolution: 'CUSTOM'` with
`pub_downscale_factor: 2.0`, which halves the ZED X's native `HD1200`
(1920×1200) down to **960×600** before publishing. The `camera_info` is scaled
to match (`fx = fy ≈ 364`), so the stream is self-consistent — just half
resolution.

That default is deliberately left in place, but it is a real trade-off rather
than a neutral choice: detection range for anything measured out of the image,
AR tags in particular, scales with pixel resolution. Raise
`pub_downscale_factor` to `1.0` if tag range matters more than the bandwidth,
and re-measure the link.

---

## Operational notes

Carried over from the previous standalone ZED launch file:

- The ZED node needs OpenGL hardware acceleration. Plain VNC breaks it.
- If the GMSL link wedges (`ZEDX#0#0#FROZEN`), recover with
  `sudo service zed_x_daemon restart; sleep 25`. Restarting `nvargus-daemon`
  alone is not sufficient.
