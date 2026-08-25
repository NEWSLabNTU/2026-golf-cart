# Phase 3A — Camera Calibration

Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 A](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#a--camera-calibration-contract-for-d)

**Status: Intrinsics present but unusable — one calibration cloned across three
cameras, at a resolution that does not match the declared one, with a distortion
model that contradicts its own coefficients. Extrinsics not started. Still
blocks sub-phase D.**

Last updated: 2026-08-21

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

### The declared resolution does not match the numbers, 2026-08-21

An earlier revision of this section flagged `cx` as worth confirming. It has now
been checked, and it does not survive the check.

```yaml
image_width: 1920
image_height: 1280
camera_matrix:
  data: [986.059, 0.0, 712.072,  0.0, 1007.400, 632.611,  0.0, 0.0, 1.0]
```

`cy` sits at 632.6, which is 1280/2 within a few pixels — correct. `cx` sits at
712.1, where a 1920-wide image wants roughly 960. That is 248 px, 13% of the
frame width, and a lens decentred that far would look obviously wrong through
the viewfinder.

Scaling the value to the declared width resolves it exactly:

    712.07 × (1920 / 1440) = 949.4 ≈ 960

These intrinsics were computed on **1440-wide** images and written into a file
that declares 1920. The placeholder they replaced had `cx: 960, cy: 640`, so the
real resolution was known before the calibration and lost during it.

For sub-phase D this is the single most damaging number in the file. PnP turns
pixels into bearings through `cx`, so an offset of 248 px at `fx ≈ 986` is a
systematic bearing bias of

    atan(248 / 986) ≈ 14°

applied to every observation, in the same direction every time. Nothing
downstream can detect that: the residuals stay small because every board is
wrong in the same way.

**Do not scale these numbers to 1920 and call it fixed.** The capture size is a
hypothesis that fits the arithmetic; it is not a record of what was done. The
original capture resolution has to be recovered, or the calibration redone.

### The distortion model contradicts its own coefficients, 2026-08-21

```yaml
distortion_model: rational_polynomial
distortion_coefficients:
  cols: 12
  data: [-0.3515, 0.1078, -0.00233, -0.0150,  0.0, 0.0, 0.0, 0.0,
          0.1041, -0.0243, 0.00143, 0.00105]
```

OpenCV's twelve-slot order is `k1 k2 p1 p2 k3 k4 k5 k6 s1 s2 s3 s4`. Read that
way, the file declares every rational coefficient — `k3` through `k6` — to be
zero, while the four thin-prism terms `s1` through `s4` carry real values. A
rational fit whose rational terms all vanish is degenerate; it is not a rational
calibration at all.

The likely explanation is that eight coefficients were padded to twelve with the
zeros inserted in the middle rather than appended, which would mean the trailing
four are `k3`..`k6` and every consumer is currently applying them as thin-prism
terms. That cannot be confirmed from the file alone — it needs the original
calibration output. Either way the label and the data disagree, and one of them
is wrong.

This qualifies the task note below: the detector supporting `rational_polynomial`
end to end (phase 3D-5) says nothing about whether these particular coefficients
are a rational fit.

### Provenance

`ea2e054` "feat: add intrinsic matrices" (Typas Liao, 2026-06-04) wrote the same
calibration into all three files in one commit, replacing the identity
placeholders. So this is one genuine calibration session, propagated — not three
sessions that happened to coincide.

### One thing that hides the resolution mismatch

`camera_left.yaml` and its siblings set `camera_info_rescale: true`. gscam will
silently rescale `camera_info` to the streamed resolution rather than reject a
mismatch, so a wrong `image_width` produces plausible output instead of an
error — and rescales from the wrong starting size. Turning this off during
calibration verification would make the mismatch loud.

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
      and is currently installed as all three. Redo it per lens at the streamed
      1920×1280; do not rescale the existing numbers, for the reason given
      above. The detector supports `rational_polynomial` end to end (phase
      3D-5), so there is no reason to drop back to `plumb_bob` — but write the
      coefficients in OpenCV's documented order and check that the rational
      terms are actually non-zero.
- [ ] **Recover the original capture resolution** of the 2026-06-04 calibration,
      or confirm it is unrecoverable and discard the numbers entirely. Ask
      Typas Liao before assuming.
- [ ] **Confirm the three cameras are the same lens.** The cloned intrinsics are
      wrong for at least two of them regardless, but if the rear unit has a
      different field of view, they are wrong by more than a recalibration of
      the other two would reveal.
- [ ] **Set `camera_info_rescale: false`** while verifying, so a resolution
      mismatch fails loudly instead of being silently absorbed.
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
      each camera image in RViz and confirm alignment. `just tool sphere` does
      this for all three cameras at once; see
      [the guide](../guides/sphere_sensor_view.md). Stock RViz2's `Camera`
      display does one camera at a time and needs no plugin, which is the
      quicker first look.

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
- Point cloud projection overlay visually aligned in RViz for all three cameras,
  and the seams between them continuous in the spherical view. Note the limit of
  that check: judging a seam by eye is worth perhaps a degree, so it catches a
  swapped camera or a missing optical-frame rotation but does not certify the
  0.5° above.

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
