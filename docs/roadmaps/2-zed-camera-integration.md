# Phase 2 — ZED X Camera Integration

Moves the ZED X camera from a standalone launch file in `golfcart_launch` into
the sensor kit, behind the standard `camera.launch.xml` entry point, and makes
its built-in IMU selectable as an alternative to the Xsens.

Design spec: [../design/zed_camera_integration.md](../design/zed_camera_integration.md)

**Status: Code complete, verified against a live ZED X. Remaining work is the
physical measurement listed under "Deferred to field work".**

Last updated: 2026-08-12

---

## Why

The ZED X currently lives in `src/launcher/golfcart_launch/launch/zed.launch.xml`,
outside the sensor kit and outside the `camera_model` convention every other
sensor follows. Three consequences:

1. **No single camera entry point.** The three GMSL cameras go through
   `camera.launch.xml`; the ZED does not. Two conventions for one sensor class.
2. **Parameters are inline in the launch file.** Every ZED tuning decision is an
   XML `<param>` element rather than a YAML file, so it cannot be layered,
   diffed, or overridden per deployment.
3. **All transforms are disabled.** The existing file turns off every ZED
   transform, including the harmless ones, because the harmful ones were not
   separated from them. Nothing can be placed relative to `base_link`, so the
   camera is unusable for anything that needs geometry — tag localisation,
   projection overlay, sensor fusion.

The camera also has a built-in IMU that the system currently ignores, while the
Xsens is the only IMU option. Making the source selectable gives a fallback and
a cross-check.

---

## Scope

In scope:

- ZED launch moved into `golfcart_sensor_kit_launch`, reached via `camera.launch.xml`
- ZED parameters extracted to a YAML file
- Rectified RGB output and the IMU stream published
- Transform ownership split correctly between the ZED driver and Autoware
- `imu_source` argument selecting Xsens or ZED

Out of scope:

- Stereo left/right output — the parameter exists and is off; turn it on when
  visual SLAM is actually added
- Depth and point cloud — disabled, nothing consumes them
- ZED object detection
- ZED extrinsic *measurement* — see task 6 below, which is a physical
  measurement task, not a code task

---

## Work items

### 1. ZED parameter file

- [x] Create `golfcart_sensor_kit_launch/config/zed.param.yaml` holding every
      ZED override: video publish flags, sensor flags, positional tracking
      flags, depth mode.
- [x] No ZED tuning parameter remains inline in any launch file, except
      `general.camera_name` and `general.camera_model`, which are also
      substituted into namespaces and the URDF command.

### 2. ZED launch file

- [x] Create `golfcart_sensor_kit_launch/launch/zed.launch.xml`:
      `component_container_isolated`, `stereolabs::ZedCamera` composable node,
      and a `robot_state_publisher` fed the vendor `zed_descr.urdf.xacro`.
- [x] Layer the three parameter files in order: vendor common, vendor per-model,
      project override.
- [x] Keep absolute namespaces and no `push-ros-namespace`, preserving the
      workaround documented in the design spec.

### 3. Camera dispatch

- [x] Add a `camera_model` argument to `camera.launch.xml`: `gscam`, `zedx`, or
      `none`.
- [x] Move the three existing `gscam` nodes under the `gscam` branch unchanged.
- [x] Route the `zedx` branch to `zed.launch.xml`.

### 4. Retire the standalone launch file

- [x] Delete `src/launcher/golfcart_launch/launch/zed.launch.xml`.
- [x] Repoint the `is_orin` group in `golfcart.launch.yaml` at
      `camera.launch.xml` with `camera_model:=zedx`.
- [x] Do the same in `sensor_only.launch.yaml`.
- [x] Confirm no other file references the deleted launch file.

### 5. IMU source selection

- [x] Add `imu_source` argument to `imu.launch.xml`: `xsens` or `zed`.
- [x] Gate the Xsens driver node on `imu_source == xsens`.
- [x] Switch the `imu_corrector` and `gyro_bias_estimator` input topic between
      `xsens/imu_raw` and `/sensing/camera/zed/imu/data`.
- [x] Split `imu_corrector.param.yaml` into `imu_corrector_xsens.param.yaml` and
      `imu_corrector_zed.param.yaml`, selected by source.
- [x] Keep `imu_corrector` and `gyro_bias_estimator` unconditional — they are
      Autoware-side processing and run for either source.

### 6. Transform anchoring

- [x] Add a `zed_camera_link` joint to `sensor_kit.xacro`, parented to
      `sensor_kit_base_link`, reading `sensor_kit_calibration.yaml`.
- [x] Add a `zed_camera_link` entry to `sensor_kit_calibration.yaml`.
- [ ] **Measure the real mounting position** — to the threaded screw hole in the
      camera's bottom face, relative to `sensor_kit_base_link`. Until this is
      done the entry holds a placeholder and every ZED-derived pose is wrong by
      the mounting error. Requires physical access to the cart.

### 7. Documentation

- [x] Write `docs/design/zed_camera_integration.md`.
- [x] This phase document.
- [x] Rewrite the `CLAUDE.md` camera and IMU sections, which described USB
      cameras, a future TIER IV upgrade, and a Tamagawa IMU that was never
      fitted.
- [x] Correct `golfcart_sensor_kit_launch/README.md`, which claimed the cameras
      were ZED X Mini when the GMSL cameras are `gscam`, and listed pre-5.x ZED
      topic names.
- [x] Repoint `docs/design/multi_machine_deployment.md` and the two recording
      script comments at the new file locations.

---

## Acceptance criteria

### Build and launch

- `just build` completes with no new warnings from the touched packages.
- `camera_model:=zedx` loads the composable node. A silent failure here looks
  like a running container with no component inside it, so check for the node,
  not just the container:
  ```
  ros2 node list | grep /sensing/camera/zed
  ```
- `camera_model:=gscam` still starts all three `gscam` nodes, unchanged from
  before this work.
- `camera_model:=none` starts neither.

### Topics

- `/sensing/camera/zed/rgb/color/rect/image` publishes at the configured frame
  rate, verified with `ros2 topic hz`.
- `/sensing/camera/zed/rgb/color/rect/camera_info` carries
  `header.frame_id == zed_left_camera_frame_optical`, non-zero focal lengths in
  `k`, and an all-zero `d` — rectified images carry no distortion.
- `/sensing/camera/zed/imu/data` publishes near `sensors_pub_rate`, with a
  populated `orientation` field.
- No left, right, stereo, greyscale, raw, depth, or point cloud topics are
  advertised.

### Transforms

- Every frame has exactly one parent. Verified by inspection of
  `ros2 run tf2_tools view_frames` output — this is the criterion the whole
  design turns on.
- `ros2 run tf2_ros tf2_echo base_link zed_left_camera_frame_optical` resolves.
- `ros2 run tf2_ros tf2_echo base_link zed_imu_link` resolves.
- The ZED driver publishes no `map` or `odom` transform. Confirm `map -> odom`
  and `odom -> base_link` still have exactly one publisher each with the full
  stack running on both machines.

### IMU

- `imu_source:=xsens` reproduces current behaviour exactly.
- `imu_source:=zed` produces `/sensing/imu/imu_data` at a stable rate, and
  `gyro_odometer` publishes `/localization/twist_estimator/twist_with_covariance`
  without TF lookup errors in the log.
- With the cart stationary, the corrected angular velocity on
  `/sensing/imu/imu_data` sits within `gyro_bias_threshold` (0.009 rad/s) of
  zero on all three axes. Failing this means the ZED corrector parameters have
  not been measured yet, not that the wiring is wrong.

### Deferred to field work

The following need the cart and cannot be closed from a desk:

- `zed_camera_link` measured to ±2 cm and ±1°.
- ZED `imu_corrector` offsets and standard deviations measured at standstill.
- Cross-machine IMU jitter characterised with both machines live.

---

---

## Verification record — 2026-08-12

Run on the development machine. `just build` clean for all four touched
packages.

**Confirmed:**

- `camera_model:=none` starts nothing; `gscam` starts the three camera nodes;
  `zedx` loads the composable node into its container. The `zedx` branch was
  additionally checked with `launch_driver:=false`, which correctly starts
  nothing.
- Parameter layering reaches the node. Its own startup log reports
  `Publish RGB image: TRUE`, `Publish Left/Right images: FALSE`,
  `Publish IMU: TRUE`, `Publish IMU Raw: FALSE`,
  `Broadcast IMU TF: TRUE`, `Depth mode: NONE - DEPTH DISABLED`.
- The vendor URDF loads: the ZED `robot_state_publisher` reports all six
  segments (`zed_camera_link`, `zed_camera_center`, both lens frames, both
  optical frames).
- Full vehicle URDF expands with `zed_camera_link` present exactly once.
- With both `robot_state_publisher` instances running, every ZED frame resolves
  from `base_link`, at the exact vendor geometry:

  | Lookup | Translation |
  |---|---|
  | `base_link -> zed_camera_link` | `[0.000, 0.000, 0.000]` (placeholder calibration) |
  | `base_link -> zed_camera_center` | `[0.000, 0.000, 0.016]` |
  | `base_link -> zed_left_camera_frame` | `[-0.010, 0.060, 0.016]` |
  | `base_link -> zed_left_camera_frame_optical` | same, rotated `[-90°, 0°, -90°]` |
  | `base_link -> zed_right_camera_frame_optical` | `[-0.010, -0.060, 0.016]` |

- `imu_source` rewires both nodes. Read off the running processes' command
  lines:

  | Source | `imu_corrector_node` input | Parameter file |
  |---|---|---|
  | `xsens` | `input:=xsens/imu_raw` | `imu_corrector_xsens.param.yaml` |
  | `zed` | `input:=/sensing/camera/zed/imu/data` | `imu_corrector_zed.param.yaml` |

  `gyro_bias_estimator_node` picks up the same parameter file in both cases, and
  both nodes start regardless of source.
- `CAMERA_MODEL` and `IMU_SOURCE` environment overrides reach
  `sensing.launch.xml`: with no override the `gscam` nodes start; with
  `CAMERA_MODEL=zedx` they do not.
- No frame has two parents. The vehicle `robot_state_publisher` publishes ten
  edges, none of them internal to the ZED; the ZED `robot_state_publisher`
  publishes five, all below `zed_camera_link`. The two sets are disjoint, and
  `zed_camera_link` is a child in one and a root in the other — the intended
  junction.

**Cosmetic, do not chase:** the startup log prints `Publish Depth Map: TRUE` and
`Publish Point Cloud: TRUE` in its flag summary. Those lines are printed before
the parameters are applied, and the summary does not reflect the final state.

---

## Verification record — 2026-08-12, live camera

Second pass, ZED X attached (serial 49609767, SDK 5.2.3), on the orin.

**Confirmed against real hardware:**

| Topic | Rate | Payload |
|---|---|---|
| `rgb/color/rect/image` | 30.1 Hz | 960×600, `bgr8`, frame `zed_left_camera_frame_optical` |
| `rgb/color/rect/camera_info` | 30.1 Hz | `d` all zero, `fx = fy = 364.13`, `cx, cy = 478.67, 296.68` |
| `imu/data` | 97.9 Hz | frame `zed_imu_link`, orientation populated, `orientation_covariance[0] = 1.2e-09` |

- No left, right, stereo, greyscale, raw, depth, disparity, or point cloud
  topic is advertised.
- The full ZED frame tree is published and every edge carries the vendor
  geometry:

  | Edge | Value |
  |---|---|
  | `zed_camera_link -> zed_camera_center` | `[0, 0, 0.0160]` |
  | `zed_camera_center -> zed_left_camera_frame` | `[-0.0100, 0.0600, 0]` |
  | `zed_left_camera_frame -> ..._optical` | `q [-0.5, 0.5, -0.5, 0.5]` |
  | `zed_left_camera_frame -> zed_imu_link` | `[0, -0.0356, -0.0001]` |

  The last one is the driver's own, and it matches the Camera-IMU translation
  the SDK reports at startup (`0 -0.035649 -0.000147`) — so `publish_imu_tf`
  works with `pos_tracking_enabled: false`, as the design assumed.
- Six frames, one parent each. No `map` or `odom` transform from the ZED.
  Verified for both a listener that subscribed before the driver started and one
  that joined afterwards.
- `base_link -> zed_*` does not resolve on the orin alone, as expected —
  `sensor_kit_base_link -> zed_camera_link` comes from the master.

**Two defects found and fixed during this pass:**

1. Images published as `bgra8`. The alpha channel is always opaque and no
   consumer reads it, so a quarter of the image bandwidth was wasted on the
   inter-machine link. Fixed with `video.enable_24bit_output: true`; re-measured
   as `bgr8`.
2. `depth/camera_info` and `depth/depth_registered/camera_info` were advertised
   and publishing at 30 Hz each, despite `depth_mode: NONE`. Their publishers
   are guarded on `mPublishDepthMap`, not on the depth mode. Fixed with
   `depth.publish_depth_map: false` and `depth.publish_point_cloud: false`;
   re-measured as gone.

**Open decision, not a defect:** the stream is 960×600, because the vendor
default `pub_downscale_factor: 2.0` halves the native `HD1200`. The
`camera_info` is scaled to match, so the stream is correct — but AR-tag
detection range scales with resolution. Set `pub_downscale_factor: 1.0` if tag
range matters more than link bandwidth.

---

## Known issues filed separately

Both pre-date this work:

- `imu.launch.xml` dereferences an undeclared `vehicle_id` argument. **Fixed
  incidentally** — this work rewrites that exact line to select the
  per-source corrector parameter file, so leaving the substitution broken was
  not an option. `imu.launch.xml` now declares `vehicle_id` (following the
  `lidar.launch.xml` precedent) and `sensing.launch.xml` passes it through.
- The Xsens driver has `pub_transform: true`, broadcasting `world -> imu_link`
  while the URDF publishes `sensor_kit_base_link -> imu_link`. That frame has
  two parents today. This one directly weakens the "every frame has one parent"
  acceptance criterion above — the criterion is judged on ZED frames until it is
  fixed.
