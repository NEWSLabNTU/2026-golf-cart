# Phase 5 — Spherical sensor view

An Autoware-side package that subscribes to the live camera and LiDAR topics,
projects all of them onto one sphere centred on `base_link`, and renders it in
RViz2. Its purpose is to make a wrong sensor transform visible.

Design: [sphere_sensor_view.md](../design/sphere_sensor_view.md).

**Scope: rendering only.** [LCTK](https://github.com/NEWSLabNTU/LCTK) computes
the extrinsics; this package reads what `/tf_static` already carries and draws
it. No optimiser, no target detection, no parameter file written. A viewer that
also adjusts parameters is a different program, and the value of this one comes
from being downstream — it shows the calibration the system is *running*, not
the file that is supposed to describe it.

Last updated: 2026-08-25. **S1 is done**, verified against a synthetic camera on a
workstation. S2 is next.

---

## Why now

Three cameras and two LiDARs are mounted, and nothing on the vehicle answers
"are these transforms right?" other than reading numbers out of
`sensor_kit_calibration.yaml` and believing them. Phase 3A has already shown how
badly that goes: one intrinsic calibration was cloned across three cameras and
nobody noticed, because nothing displayed the consequence.

The check this package performs needs no target, no ground truth and no
measurement — only the observation that two sensors looking at the same feature
should report the same direction from `base_link`.

---

## Prerequisites, and one that is not

**Required before the output means anything:**

- Phase 3A's per-camera intrinsics. A cloned calibration produces a systematic
  bearing error that would dominate everything on screen.
- `*_optical_link` frames in the URDF. Camera projection happens in the optical
  frame; without those frames the chain is off by the body-to-optical rotation,
  and the tool would show a real ~90° error that lives in the URDF rather than
  in the calibration.

**Not required:** working DBW, a map, localisation, or a moving vehicle. This is
a stationary check. It runs against a parked vehicle or a rosbag.

Both prerequisites are 3A's, and both are listed there. Building S1 before they
land is fine — it proves the rendering path, and the geometry is wrong in a way
that does not depend on the sensors being right. Reading anything into the
picture is not.

---

## S1 — the rendering path

The risk phase. If dynamic textures on `ManualObject` geometry misbehave inside
RViz2's render loop, that is worth finding in a day rather than after the
projection maths is written.

- [x] Package `golfcart_sphere_view` at `src/tools/`, `rviz_common::Display`
      subclass, `plugin_description.xml`, loads in RViz2 and shows in the
      Displays panel.
- [x] Vendor `tile_object.{hpp,cpp}` from `nobleo/rviz_satellite` as
      `textured_patch`, Apache-2.0 header and attribution intact.
- [x] Replace its quad builder with a sphere-patch builder.
- [x] Replace per-update texture reallocation with `createManual` plus a blit
      into the `HardwarePixelBuffer`. The original suits map tiles that change
      when the vehicle drives a block; three cameras at 30 Hz would be ninety
      allocations a second.
- [x] One camera, live radius, texture updating live.
- [x] Nine unit tests over the projection and the patch builder, which need no
      GPU and no ROS graph.

**Acceptance: met.** A curved patch of a 30 Hz JPEG camera renders in RViz2 at
31 fps against the 30 fps cap, image features visibly bending with the sphere,
and a frame-to-frame diff confined to the part of the test pattern that moves —
so the texture is live rather than one frozen upload.

Verified on a workstation against a synthetic camera rather than the vehicle,
since the point of S1 is the rendering path. The publisher is
`test/fake_camera.py`: a grid, a circle, a moving dot and a corner marker, with
a static `base_link -> camera_left_optical` transform in the REP-103 optical
convention.

What S1 settled beyond the checklist:

- **Geometry and texture are already decoupled.** `setGeometry` runs when the
  `CameraInfo` or the transform changes; `update()` does nothing per frame but
  upload. The structure S2 and S3 need is in place rather than promised.
- **`K`, not `P`.** The topic this display draws is the distorted image straight
  off the camera, so the projection pairs the distortion model with the
  unrectified intrinsics. Using `P` would silently undistort twice.
- **Sensor QoS on both subscriptions.** A reliable subscription matches nothing
  against a best-effort sensor stream, and does so silently.
- **Transforms are looked up at time zero**, not at the image stamp. These are
  static mounts, and asking at the stamp fails during the window before
  `tf_static` arrives.
- One test asserts that `k4` in slot 5 pulls a point *inward* while `k1` pushes
  it out. That is the coefficient ordering the vehicle's camera files disagree
  with, per [3A](3-indoor-a-camera-calibration.md), so the check is worth
  keeping even though nothing here reads those files yet.

---

## S2 — many cameras

- [ ] Camera list as a display property, each entry an image topic plus its
      `camera_info` topic. Nothing hardcoded; the same display serves the three
      GMSL cameras on the Advantech and the ZED on the orin.
- [ ] Per-camera decode worker. The cameras publish `image_raw/compressed`
      only, so every frame needs a JPEG decode, and doing it on the render
      thread stalls RViz. Newest frame wins, older frames drop — this is a
      monitor, dropping is correct.
- [ ] Sphere radius as a live property, adjustable while watching.
- [ ] Per-camera alpha, and enable/disable per layer.
- [ ] Rebuild patch geometry when `CameraInfo` or TF changes, and only then.

**Acceptance:** all three GMSL cameras on the sphere at once, seams visible
between them, radius adjustable without a restart, RViz frame rate unchanged.

---

## S3 — the LiDARs, and the actual check

- [ ] Cloud layers, configurable topic list, transformed into `base_link`.
- [ ] `angular` mode: points snapped to the sphere radius. Removes parallax, so
      what remains is a pure rotation comparison. This is the default.
- [ ] `metric` mode: true range kept. Exposes translation error, at the cost of
      the sphere no longer being a sphere.
- [ ] Colour by intensity, by range, and by source sensor. Source colouring is
      what makes VLP-32C against Falcon legible.
- [ ] Point size and decimation properties, so a 32-plane cloud at 10 Hz does
      not bury the image underneath it.

**Acceptance:** with the vehicle parked facing structure that has both depth
discontinuities and visual texture — a doorway, a building edge, parked cars —
the cloud's depth discontinuity sits on the image's visual edge for each camera
in turn.

---

## S4 — make it usable by someone else

- [ ] `just tool sphere` recipe.
- [ ] Saved RViz config with the display configured for this vehicle's topics.
- [ ] A page in the book: what each mode shows, how to read a seam, and what
      the radius property does and does not prove.
- [ ] Note in [3A](3-indoor-a-camera-calibration.md) pointing at this as the
      verification step for its projection-overlay acceptance criterion.

**Acceptance:** somebody who did not write it can bring up the vehicle, run one
command, and say whether the extrinsics look right.

---

## What this does not do

Stated so it is not re-litigated:

- **No parameter estimation.** LCTK's job.
- **No writing to `sensor_kit_calibration.yaml`.** Rendering only.
- **No target detection.** Checkerboards and ArUco boards belong to LCTK and to
  phase 3D respectively.
- **No adaptive depth shell** in this phase. Using LiDAR range per direction
  instead of a constant radius would remove the parallax entirely, but it
  couples the two sensor families that the tool exists to compare
  independently. Revisit after S3 if the constant radius proves too blunt.
- **No recording or export.** RViz screenshots are enough for a check.

---

## Honest caveats

**The radius is a real limitation, not a rough edge.** One sphere has one
radius; the world does not. A camera ray is painted at the sphere's radius,
which is correct only for features actually at that distance. Rotation errors
are visible at any radius; translation errors masquerade as radius errors. The
LiDAR's true range is what separates the two, which is why S3 rather than S2 is
where the tool starts answering the question.

**It cannot distinguish a bad extrinsic from a bad intrinsic.** Both bend the
projection. If the cloud does not sit on the image, this tool says so without
saying which parameter is wrong. That is still a large improvement on nothing,
and 3A's projection-overlay criterion has the same property.

**Stock RViz2 already does the single-camera version.** The `Camera` display
composites the 3D scene onto a camera image using `camera_info`, with an alpha
slider. Anyone should try that first, and S1 is only worth starting once it is
clear that the one-camera check is not enough. What it cannot do is put several
cameras and several LiDARs in one angular frame, which is where inter-sensor
disagreement lives.
