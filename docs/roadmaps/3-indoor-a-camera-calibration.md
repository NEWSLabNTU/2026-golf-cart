# Phase 3A — Camera Calibration

Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 A](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#a--camera-calibration-contract-for-d)

**Status: Not started — blocks sub-phases C and D**

Last updated: 2026-07-27

---

## Why this is a hard blocker

AR-tag pose error scales directly with intrinsic and extrinsic error. With the
current values, tag-derived poses are not degraded — they are meaningless.

### Current state

`golfcart_sensor_kit_launch/config/usb_camera_left_calibration.yaml` (and the
`_right`, `_rear` siblings) contain placeholders, not calibration:

```yaml
camera_matrix:
  data: [1, 0, 960, 0, 1, 640, 0, 0, 1]   # focal length = 1 pixel
distortion_coefficients:
  data: [0, 0, 0, 0, 0]                    # no distortion model
```

`autoware_individual_params/.../golfcart_sensor_kit/sensor_kit_calibration.yaml`
camera extrinsics are round-number guesses that document themselves as such:

```yaml
usb_camera_left:
  x: 0.0      # centered front-back
  y: 0.4      # 40cm to the left
  z: 0.3      # 30cm up
  roll: 0.0
  pitch: 0.0
  yaw: 1.5708 # facing left (90 degrees)
```

Roll and pitch are hard-zeroed. The orientation looks like a body-frame yaw
rather than a ROS camera optical frame (z forward, x right, y down) — the
body→optical rotation appears to be missing entirely, not just uncalibrated.

### Cameras in scope

Three, from `camera.launch.xml`: `usb_camera_left`, `usb_camera_right`,
`usb_camera_rear`. No front camera node exists. All 1920×1280 @ 30 Hz via gscam.

`sensor_kit_calibration.yaml` also lists a `usb_camera_front` entry with no
corresponding launch node — dead config, resolve during this sub-phase.

---

## Tasks

### Not done

- [ ] **Confirm which physical cameras the indoor work runs on** — current
      USB/GMSL units, or the TIER IV cameras from ROADMAP Phase 2 Track A.
      Calibration is per-unit and does not transfer.
- [ ] **Intrinsic calibration, per camera** — checkerboard, `plumb_bob` model.
      Write real values into `usb_camera_{left,right,rear}_calibration.yaml`.
- [ ] **Extrinsic calibration, camera→base_link, per camera** — including the
      body→optical frame convention, stated explicitly rather than folded into
      a yaw value.
- [ ] **Resolve the `usb_camera_front` phantom entry** in `sensor_kit_calibration.yaml`.
- [ ] **Fixed-exposure camera profiles** — current config has
      `auto_exposure: true` and `auto_white_balance: true`, which cause
      intermittent ArUco detection through exposure hunting and motion blur.
      Needs tuning under the actual indoor lighting, trading shutter speed
      against gain noise.
- [ ] **Verify with projection overlay** — project the VLP-32C point cloud onto
      each camera image in RViz and confirm alignment.

### Can do before the indoor site is chosen

- [ ] Intrinsic calibration — needs only a checkerboard, done anywhere.
- [ ] Extrinsic measurement and frame-convention cleanup.
- [ ] Build LCTK ([NEWSLabNTU/LCTK](https://github.com/NEWSLabNTU/LCTK)) and
      prepare calibration targets.

Fixed-exposure tuning must wait for the actual site lighting.

---

## Acceptance criteria

These are the numbers sub-phase D depends on:

- Intrinsics: reprojection RMS ≤ 0.5 px per camera.
- Extrinsics: ≤ 2 cm position, ≤ 0.5° orientation, camera→base_link.
- Optical frame convention correct and explicit.
- Point cloud projection overlay visually aligned in RViz for all three cameras.

Extrinsic error propagates directly into every tag observation, and its runtime
signature is a **range-correlated offset** between tag-derived and NDT poses —
easy to misdiagnose downstream as a tuning problem. Getting the numbers right
here saves debugging in D.

---

## Overlap with existing roadmap

[ROADMAP.md](../../ROADMAP.md) Phase 3 Track A already covers LiDAR-camera
calibration via LCTK, targeting TIER IV cameras. Reuse that work rather than
duplicating it. If the indoor work runs on the current USB cameras instead,
calibration must be repeated for those specific units.
