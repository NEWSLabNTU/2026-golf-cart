# Phase 3A — Camera Calibration

Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 A](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#a--camera-calibration-contract-for-d)

**Status: Intrinsics partly done, and in a more dangerous state than not done.
Extrinsics not started. Still blocks sub-phases C and D.**

Last updated: 2026-08-20

---

## Why this is a hard blocker

AR-tag pose error scales directly with intrinsic and extrinsic error. With the
current values, tag-derived poses are not degraded — they are meaningless.

### Current state, corrected 2026-08-20

The intrinsics are **no longer placeholders**. `camera_left_calibration.yaml`
now carries a real calibration: `fx 986.06, fy 1007.40, cx 712.07, cy 632.61`,
a `rational_polynomial` model with 12 coefficients, and a projection matrix.
Somebody calibrated a camera since this document was written.

**But it is one calibration used for all three cameras.** Verified by diff:
`camera_left_calibration.yaml`, `camera_right_calibration.yaml` and
`camera_rear_calibration.yaml` are byte-identical apart from the `camera_name`
field. Three physically different lenses share one intrinsic set.

That is worse than the placeholder state it replaced, not better. Placeholders
announce themselves — a focal length of 1 pixel cannot be mistaken for
calibration. A plausible, real-looking matrix on the wrong camera produces
plausible, real-looking poses that are wrong by an amount nobody will think to
question.

One number to check while redoing this: **`cx` is 712 on a 1920-wide image**,
about 248 px left of centre. That is a large principal-point offset. It is
possible on a real lens, and it is also what you would see if the calibration
was run at a different capture size than the one declared. Worth confirming
rather than inheriting.

The previous text of this section, retained because it describes what the files
held before:

```yaml
camera_matrix:
  data: [1, 0, 960, 0, 1, 640, 0, 0, 1]   # focal length = 1 pixel
distortion_coefficients:
  data: [0, 0, 0, 0, 0]                    # no distortion model
```

`autoware_individual_params/.../golfcart_sensor_kit/sensor_kit_calibration.yaml`
camera extrinsics are round-number guesses that document themselves as such:

```yaml
camera_left:
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

Note the contrast within the same file: `vlp32c` and `falcon` now carry real
calibrated values (`yaw: -0.05`, `pitch: -1.7707963`). The camera entries do not.

### Cameras in scope

Three: `camera_left`, `camera_right`, `camera_rear`. All 1920×1280 @ 30 Hz via
gscam. These are TIER IV GMSL cameras, not USB — the gscam pipeline reads
`tegra-capture-vi` and encodes with `nvjpegenc`:

```yaml
# camera_left.yaml:15
gscam_config: "v4l2src device=/dev/v4l/by-path/platform-tegra-capture-vi-video-index0 io-mode=4 ! ..."
```

`sensor_kit_calibration.yaml` also lists a `usb_camera_front` entry with no
corresponding launch node — leftover from the USB camera era, resolve during
this sub-phase.

---

## Tasks

### Not done

- [ ] **Intrinsic calibration, per camera, three times.** One calibration exists
      and is currently installed as all three. Redo it per lens, and confirm the
      `cx` offset noted above rather than copying it forward. The declared model
      is `rational_polynomial` with 12 coefficients, which the detector now
      supports end to end (phase 3D-5), so there is no reason to drop back to
      `plumb_bob`.
- [ ] **Make the three files impossible to confuse again.** Byte-identical
      calibrations that differ only in `camera_name` are what got us here. A
      check that fails when two cameras share intrinsics costs a few lines and
      would have caught this.
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
calibration via LCTK, targeting TIER IV cameras. The three cameras in scope here
**are** those TIER IV GMSL units, so this is the same calibration work — do it
once, in Track A, and this sub-phase consumes the result. What this doc adds on
top is the AR-tag-specific requirements: the numeric acceptance criteria below,
the optical-frame convention, and the fixed-exposure profiles.
