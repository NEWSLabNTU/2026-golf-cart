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

Last updated: 2026-08-28. **All four sub-phases are done**, plus a round of
hardening that a real dataset forced and a first pass at the cost of running
this on an Orin. **It has still never met this vehicle**, which is what remains
and what should shape everything after it. Candidates are at the end.

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

- [x] Camera list as display properties. Each camera is a `CameraLayer`, a
      child `BoolProperty` carrying its own image topic, `camera_info` topic and
      alpha. The three GMSL cameras are defaults, not hardcoding: every topic is
      editable and layers can be added or removed at runtime, so the same
      display serves the ZED on the orin or a bag with other names.
- [x] Per-camera decode worker, one thread each, waiting on a condition
      variable. Newest frame wins and the rest are dropped — this is a monitor,
      so a growing queue would be the wrong answer.
- [x] Sphere radius as a live property.
- [x] Per-camera alpha, and enable/disable per layer.
- [x] Rebuild patch geometry when `CameraInfo` or TF changes, and only then. A
      layer whose `CameraInfo` arrives late marks itself dirty and is picked up
      without rebuilding the layers that are already correct.

**Acceptance: met.** Three cameras render at once at 31 fps against the 30 fps
cap, each visibly its own patch, with the seams between them where the geometry
says they should be.

Radius was exercised by comparing 10 m against 3 m: at 10 m the three patches
nearly meet, at 3 m they separate into three islands with gaps between. That is
the parallax the design warns about, made visible — each camera sits about a
metre off the sphere centre, so the solid angle it covers shrinks as the sphere
closes in. The property is wired through the same dirty-flag path as everything
else; it was verified by relaunching rather than by dragging the slider, because
this workstation has no GUI automation and RViz properties are not reachable
from outside the process.

Per-camera status is reported in the Displays panel, one line per layer:
triangle count when it is drawing, the missing transform when it is not, and a
count of undecodable frames if any arrived.

What S2 settled beyond the checklist:

- **Decoding moved off the executor thread as well.** S1 decoded in the
  subscription callback, which was fine for one camera. Three would have
  serialised behind each other on the executor, so each layer now owns a thread
  and the callback does nothing but hand over bytes.
- **Format conversion happens on the worker**, not in the upload. The render
  thread's share of a frame is now the blit alone.
- **Layers are Qt properties, so deleting one takes its Ogre objects with it**
  through the destructor. No separate teardown path to get wrong.

---

## S3 — the LiDARs, and the actual check

- [x] Cloud layers, one `CloudLayer` per sensor, each with its own topic and
      style, transformed into the centre frame.
- [x] `Angular` placement: returns snapped to the sphere radius. Removes
      parallax, leaving the direction, which is the only thing a camera can be
      compared against. This is the default.
- [x] `Metric` placement: true range kept, so a translation error shows as depth
      disagreement rather than being projected away.
- [x] Colour by intensity, by range, and flat per sensor. Flat is what makes
      VLP-32C against Falcon legible in an overlap.
- [x] Point size, alpha and decimation, so a 32-plane cloud does not bury the
      image it is meant to be checked against.

**Acceptance: partly met, and honestly so.** Both modes render correctly against
a synthetic wall with a doorway cut out of it, at 31 fps against the 30 fps cap,
with 33.7k returns at 10 Hz alongside three cameras.

In `Angular`, the returns form a band on the sphere and the doorway is legible
as an intensity change -- the opening dark, its retroreflective frame bright,
which is what a VLP-32C reports above 100. In `Metric` with colour by range, the
wall stands at its true distance and the returns that went through the doorway
sit visibly behind it. That is the distinction the two modes exist for, shown
rather than asserted.

**What is not met** is the acceptance as written: it asks for the cloud's depth
discontinuity to sit on a *camera's* visual edge, and a synthetic wall and a
synthetic camera agree with each other by construction. Nothing here proves the
tool detects a real miscalibration, because nothing here is miscalibrated. That
needs the vehicle, and it is the first thing to do with it.

---

## S4 — make it usable by someone else

- [x] `just tool sphere` recipe, plus `just tool sphere-demo` which brings up
      the synthetic sensors and the display together and cleans them up on exit.
- [x] Saved RViz config at `config/sphere_view.rviz`, wired to this vehicle's
      three cameras and both LiDARs, with the Falcon off by default so the first
      view is not two clouds at once.
- [x] [Guide](../guides/sphere_sensor_view.md): what each mode shows, how to
      read a seam, what sweeping the radius proves, what the tool cannot tell
      you, and a symptom table for when nothing appears.
- [x] Note in [3A](3-indoor-a-camera-calibration.md) pointing its
      projection-overlay criterion at this tool — and qualifying that criterion,
      since judging a seam by eye is worth about a degree and 3A asks for 0.5°.

The guide went to `docs/guides/` rather than the book. `CLAUDE.md` describes a
`book/` directory with mkdocs; there is no such directory in this repository, so
this follows the guides that actually exist.

**Acceptance: not yet met, and it cannot be met here.** It asks that somebody
who did not write the tool can bring up the vehicle and say whether the
extrinsics look right. Everything above has been exercised against synthetic
sensors, which agree with each other by construction. The first person to run
`just tool sphere` on the cart is the test.

---

## Post-S4 hardening, done

Everything in S1 to S4 was verified against sensors this display also generated.
Autoware's Leo Drive bags were the first data it had not written itself, and
they cost five fixes in two sittings. Listed because the failures are more
instructive than the features:

- [x] **Raw `sensor_msgs/Image` alongside `CompressedImage`.** Public datasets
      frequently publish raw, and standing up a republisher per camera to look
      at one is a poor trade for twenty lines. `rawImageToQImage` is its own
      unit with five tests, because `bgr8` read as `rgb8` gives plausible wrong
      colours that a visual check cannot catch.
- [x] **An optical frame override, and the discipline not to need it.** These
      bags publish `camera_link` and `camera_optical_link`, and it is the first
      that satisfies the optical convention. Believing the *name* rolled every
      image ninety degrees. The override stays for publishers that genuinely
      name the wrong frame; the property description now says to check the axes
      first.
- [x] **A bound on the distortion model.** Radial polynomials turn over outside
      their fitted range and start mapping ever-wider rays back into the image.
      On these cameras a ray at 65 degrees landed at pixel 536 of 720. The
      display now stops at each model's own turnover, so patches end at the
      lens's real edge and bare sphere shows between them — a gap being an
      honest answer where smeared texture was a lie that looked like data.
- [x] **Layers created from the config, and empty topics tolerated.** RViz
      assigns saved entries to properties by name and drops the rest silently,
      and an empty topic threw out of rclcpp and took the whole config load with
      it. Both were invisible until a config written for a different vehicle
      met them.
- [x] **The sphere follows its centre frame every frame.** It was placed once
      and left behind by anything that moved it — a fixed frame of `odom` or
      `map`, or the user switching frames in Global Options.

## Performance, first pass

Measured, and the measurement corrected two guesses. Details and the trap in
[the design](../design/sphere_sensor_view.md#performance-on-the-agx-orin).

- [x] **Per-stage timing**, as a property row and on stderr under
      `GOLFCART_SPHERE_VIEW_TIMING`, which is how the numbers will be taken on
      the vehicle over ssh. Reads `geometry 0.00 / textures 0.48 / clouds
      0.47 ms` against the Leo bags: the whole update path is under a
      millisecond and geometry is zero, which is the architecture's central
      invariant holding under real data.
- [x] **`Max Update Rate`, 10 Hz by default**, applied in the subscription
      callback so a dropped frame costs nothing rather than costing a decode.
      Three cameras at 30 Hz would spend two to three Orin cores decoding
      1920x1280 JPEG faster than anyone can read it.
- [x] **Decode smaller, and straight to the target format.** `Decode Width
      Limit`, 960 by default, through libjpeg's `scale_num`/`scale_denom`. A
      photograph-like 1920x1280 frame goes from 3.72 ms on the old Qt path to
      0.91 ms. Most of that is decoding directly to RGB888 rather than letting
      Qt choose a format and converting; scaling halves what remains. The
      four-times-fewer-pixels intuition does not hold, because Huffman decoding
      is proportional to compressed size and happens either way — on a noisy
      frame the same scaling saved 14%. Qt's `setScaledSize` is not a substitute:
      it decodes full size and resamples.
- [ ] **Take the numbers on the Orin.** Everything above was measured on a
      workstation whose RViz runs on llvmpipe, so its CPU totals are software
      rasterisation and say nothing about the vehicle. The instrumentation
      exists precisely so this is a five-minute job once there is an Orin to run
      it on.
- [ ] **Decide the deployment.** Running RViz off-vehicle over the network, or
      subscribing to a downscaled preview branch from the capture pipeline,
      would each make the whole question disappear without code in this display.
      Cheaper than any optimisation here, and worth settling before item 3 above
      is started.

## Beyond S4 — candidates, none started

S1 to S4 are done and the tool is usable. What follows is optional, ordered by
value per unit of effort, and argued in
[the design](../design/sphere_sensor_view.md#where-this-can-go-next).

Nothing here should start before the tool has been run on the cart. Four
assumptions died on contact with the first real dataset, and the cart is a
different rig again — its own surprises should shape this list rather than
being planned around.

### S5 — colour the cloud from the cameras

- [ ] Project each return into whichever cameras contain it; colour it with that
      pixel. `Colour By: Camera`, alongside intensity, range and flat.
- [ ] Decide the rule when several cameras contain a return: nearest optical
      axis is the obvious one, and blending is not, since a seam that blends is
      a seam you cannot see.
- [ ] Mark returns no camera sees, rather than leaving them black and
      indistinguishable from a dark surface.

**Why first.** Every return carries its true range, so there is no bowl and no
parallax: this answers the alignment question exactly where the sphere can only
approximate it. A wrong extrinsic shows as colour bleeding across depth
discontinuities. It reuses `projectToPixel` and `CloudLayer` nearly unchanged,
and the pipeline it needs — a shared snapshot of what each camera currently is —
is designed in
[the design doc](../design/sphere_sensor_view.md#the-data-pipeline-the-next-phases-need).

**Not a performance concern.** Colouring 33 000 returns against three cameras is
about 100 000 polynomial evaluations once per cloud, which is milliseconds. Any
proposal to put this on the GPU is optimising the cheap half.

**Acceptance:** on a bag with a depth discontinuity, the colour boundary sits on
the geometric one; introducing a deliberate one-degree error in a camera
extrinsic visibly bleeds colour across it.

### S6 — a coverage map

- [ ] Colour the sphere by how many cameras see each direction.
- [ ] Report solid angle covered by none, one, and two or more.

**Why.** Not a calibration check, but the same patch geometry answers the
question phase 3 asks about ArUco boards — whether two are visible everywhere —
and the same numbers size camera placement.

**Acceptance:** the reported fractions match a hand calculation for a synthetic
rig of known field of view and spacing.

### S7 — disagreement as a number

- [ ] For directions two cameras both cover, report the mean colour difference.
- [ ] Sweep the radius and plot it: the minimum estimates scene depth, the
      residual at the minimum bounds extrinsic error.
- [ ] Normalise for exposure and vignetting first, or the number measures the
      cameras' auto-exposure rather than their alignment.

**Why.** Turns the tool from a picture into a measurement, which is what allows
a regression test over a recorded bag.

**Acceptance:** on the Leo bags the swept minimum lands near the true depth of
the structure in the overlap, and a deliberately corrupted extrinsic raises the
residual.

### S8 — an adaptive shell, only if the seams obstruct real use

- [ ] Replace the constant radius with measured range per direction.

**Why it is last, and may never happen.** It removes the seams properly. It also
couples the two sensor families the tool exists to compare independently: once a
LiDAR extrinsic error deforms the surface the images are painted on, the two
failure modes mix and the picture stops being diagnostic. It needs geometry
rebuilt at scan rate, which the current architecture deliberately avoids.

On this vehicle the case is weak anyway — the cart's cameras are centimetres
apart, not the 2.08 m of the Leo bus, so its seams should be small at any
sensible radius.

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
