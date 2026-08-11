# Phase 3D-5 — Detector

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §4.1

**Depends on**: D1 (messages).
**Blocks**: D6 (real-image path only — D6's simulated path does not need it).
**Repo**: LCTK, `ros/aruco_locator_node`. Independent of D2–D4.

---

## Goal

Corners out of images. No map, no TF, no map-frame pose.

LCTK's `aruco_locator_node` already does most of this correctly — it subscribes
image and `CameraInfo`, rebuilds its detector when calibration arrives, runs the
detect → refine → undistort sequence properly, and publishes per-marker corners.
Three gaps separate it from what this system needs, and all three are
improvements LCTK wants on its own terms.

---

## The four-step sequence — do not rearrange it

```
1. detect on the RAW, distorted frame        cv::aruco::detectMarkers
2. sub-pixel refine on the RAW frame         CORNER_REFINE_SUBPIX
3. map corners to the rectified frame        cv::undistortPoints(R = I, P = K,
                                               TermCriteria(COUNT|EPS, 20, 1e-8))
4. PnP with ZERO distortion                  corners are already rectified
```

Three separate LCTK bugs collapse into this. Steps 1–2 run raw because
undistorting the image resamples bilinearly and blunts exactly the gradients
refinement needs (`H-08`). Step 3 needs `P = K` explicitly or it silently
returns *normalized* coordinates instead of pixels, and needs the iterative
variant because OpenCV's default five iterations leave real residual error under
strong distortion. Step 4 must pass zero distortion — passing `D` again
double-corrects, which LCTK measured at **40 px** of displacement on a ~900 px
image (`C-03`), radius-dependent, which poisons precisely the wide-field-of-view
observations this design depends on.

This code already exists and works. The main risk in this phase is someone
"tidying" it.

---

## Tasks

### The three gaps

- [x] **`rational_polynomial` support.** `DistortionModel` is a one-variant enum
      (`PlumbBob`) and the MRPT loader hard-errors on non-zero coefficients past
      index 5. The detector core already passes `camera_info.d` through in full,
      so this is a loader and validation fix, not a maths fix. These cameras
      publish 12 coefficients.
      Also **validate `distortion_model`** rather than assuming — nothing in
      LCTK currently reads that field at all.
      Related: `L-03`, the bug of truncating `D` to five and silently dropping
      rational-polynomial `k4`–`k6`.
- [x] **Switch the wired entry point.** `detect_markers()` gates all-or-nothing
      on the detected ID set exactly equalling the configured set — correct when
      calibrating against one known board, wrong for a localizer that must accept
      whatever is in view. `detect_single_aruco()` already has the right
      semantics and is currently unused by the node.
- [x] **Per-marker pose with an ambiguity metric.** Replace the dead
      `estimate_pose()` — which calls `estimatePoseSingleMarkers` (discarding
      IPPE's second solution) and passes non-zero `D` against already-rectified
      corners — with `cv::solvePnPGeneric(SOLVEPNP_IPPE_SQUARE)`, keeping both
      solutions and both reprojection errors.
      `err₁/err₂` is the confidence metric LCTK currently lacks entirely
      (`score: 1.0` is hardcoded), and D4 gates on it.
      Related: `L-12`, which records this path as deliberately-kept dead code.

### IPPE alone is wrong on this OpenCV — measured, not suspected

`solvePnPGeneric(..., SOLVEPNP_IPPE_SQUARE)` on OpenCV 4.5.4 returns poses that
do not reproject. Measured on noiseless synthetic corners, where the correct
answer reprojects to zero by construction, the *better* of its two solutions was
off by:

| geometry | best-solution reprojection error |
|---|---|
| fronto-parallel, centred | **115 px** |
| 0.2 rad tilt, off-centre | 0.016 px |
| 0.5 rad tilt, off-centre | **2.84 px** |
| 0.9 rad tilt, off-centre | 0.008 px |

`estimatePoseSingleMarkers` looks correct only because on 4.5.4 it quietly calls
`solvePnP` with the default `SOLVEPNP_ITERATIVE` — it does *not* use IPPE. (The
spec previously said otherwise; that claim was wrong and has been corrected.)
IPPE_SQUARE became the default in the 4.7 `ArucoDetector` API, not here.

- [x] **Take candidates from both `SOLVEPNP_ITERATIVE` and `SOLVEPNP_IPPE_SQUARE`,
      polish every one with `solvePnPRefineLM`, and score them with a
      reprojection error computed in our own code** rather than the one OpenCV
      returns. After refinement every geometry tested recovers the true pose to
      about 1e-5 px.
      (An earlier revision of this line claimed the ratio then "becomes
      meaningful — 0.9998 where the view is genuinely two-valued". It was
      measured on one hand-picked geometry and does not generalise; see the
      status section below for the swept measurement, which shows the ratio
      staying between 0.00 and 0.05 across the whole view window.)
- [x] **Deduplicate before reporting the alternate.** Refining several seeds
      often lands them on the same pose; reporting a duplicate as the second
      solution makes every marker look unambiguous, which is the opposite of the
      truth. Where only one distinct pose survives, the second error is
      infinite, not equal.

The reference implementation is `aruco_sim_detector/marker_pnp.hpp`
(`solveMarkerPose`), written for phase 3D-3 and carrying the same reasoning in
comments. The Rust detector must reproduce the behaviour, not just the call.

Skipping this yields a detector that looks like it works, reports small
residuals, and is quietly wrong — the exact failure mode this project keeps
running into.

### Message output

- [ ] Publish `ArucoDetectionArray` from D1, carrying `k` so the stream is
      replayable without the camera.
- [ ] Resolve the coordination question from D1: retain LCTK's existing
      `vision_msgs/Detection2DArray` output alongside, or replace it. Replacing
      is cleaner and `C-01`/`H-10` are the argument, but it breaks LCTK's
      calibration pipeline.

### Input transport

- [ ] Subscribe via `image_transport` with `transport:=compressed`. The gscam
      pipeline is jpeg-only — no raw `sensor_msgs/Image` exists on these topics.
      This avoids both a separate decompressor node and a topic round-trip.

### Detector parameters

- [x] Keep construction in **exactly one validated function**. `L-11`: a
      copy-pasted five-line block set `adaptive_thresh_win_size_step` twice and
      tuned a refiner that was never enabled.
- [x] Defaults from LCTK's measured sweep: `SUBPIX`, `win_size 5`,
      `max_iterations 30`, `min_accuracy 0.01`; adaptive threshold `13/33/10`.
      SUBPIX beat NONE by 25–60% at every apparent marker size from 54 px to 302 px;
      CONTOUR was equal or worse.
- [x] Expose the parameters LCTK leaves at OpenCV defaults — marker perimeter
      rate, error correction rate, `min_marker_distance_rate`. An indoor scene
      has small distant markers and these matter there.

---

## Tests

- [x] Port `rust/aruco-detector/tests/rectify_contract.rs`, including the two
      tests that were verified to fail when their bugs were reintroduced:
      one fails with *"SUBPIX and NONE produced the same corners, so corner
      refinement is not running at all"*, the other catches a `P`-less
      `undistortPoints` returning normalized coordinates.
- [x] Round-trip test: distort → detect → undistort, built by inverting
      `undistortPoints` into a `remap` table.
- [x] 12-coefficient `rational_polynomial` handling, end to end.
- [x] IPPE returns two distinct solutions on a near-fronto-parallel view, and
      `err₁/err₂` approaches 1 there.
      **This turned out to be false, and the test now pins the opposite.** Near
      fronto-parallel the twin solution is not distinct enough to survive
      deduplication, so the ratio reports 0 — maximum confidence — exactly where
      orientation is least reliable. See the status section.

---

## Measure `corner_sigma_px`

Needs only a camera and a board — no vehicle, no map, no calibration.

- [ ] Park stationary in front of a board. Record ~1000 frames. Take the standard
      deviation of the corner positions.
- [ ] Repeat at two ranges, and once while moving.

`corner_sigma_px` is currently **0.3 px, inferred from other people's data** —
back-solved from FMAC's synthetic depth errors and cross-checked against STag's
centre-jitter figures. **No paper publishes a measured corner σ for ArUco with
sub-pixel refinement**; the circulating "0.05–0.5 px" is not traceable to a
primary measurement.

The entire covariance model in D4 scales on this number. An hour of work
converts it from a literature-anchored guess into a measurement, and it can be
done today.

## Status — implemented in LCTK, commit `729e556`

Done, in `rust/aruco-detector`, `rust/aruco-locator` and `ros/aruco_locator_node`:

- **`marker_pnp`** — `solve_marker_pose` returns both candidate poses with the
  reprojection error of each, computed here rather than taken from OpenCV. Seeds
  from both `SOLVEPNP_ITERATIVE` and `SOLVEPNP_IPPE_SQUARE`, refines every
  candidate with `solvePnPRefineLM`, deduplicates, and reports an infinite
  second error when only one distinct pose survives. 7 contract tests, including
  one that fails if the implementation is simplified back to the bare IPPE call.
- **`rational_polynomial`** — the loader carries all coefficients instead of
  truncating to five, `DistortionModel` gained the variant, and the detector now
  validates the declared model against the coefficient count. Measured: dropping
  k4–k6 moves corners by more than 5 px. 3 tests, end to end through a
  synthesized 12-coefficient lens.
- **Detection mode** — `detection_mode: board | any` selects between the
  all-or-nothing board semantic and reporting whatever is in view. Added rather
  than swapped, because calibration genuinely needs the former; default
  unchanged.
- **Ambiguity in the message** — `score` was a hardcoded `1.0`; it now carries
  the ratio. An unscored marker falls back to `1.0`, i.e. maximally ambiguous,
  so a consumer gating on it rejects rather than waves through.
- **Candidate filters** — `min`/`max_marker_perimeter_rate`,
  `error_correction_rate`, `min_marker_distance_rate` exposed.
  `error_correction_rate` deliberately stays at OpenCV's 0.6: a false ID
  associates to a real surveyed pose and yields a confident wrong answer, so it
  is worse than a missed marker.

### The ambiguity ratio does not do what the design assumed

Measured with 0.3 px corner noise on a 0.384 m marker at 3 m through f = 900,
300 trials per tilt:

| tilt | 0° | 5° | 10° | 15° | 25° | 45° | 75° |
|---|---|---|---|---|---|---|---|
| median ratio | 0.000 | 0.000 | 0.000 | 0.046 | 0.029 | 0.016 | 0.013 |
| median rotation error | 1.45° | 1.01° | 0.65° | 0.44° | 0.28° | 0.19° | 0.14° |

Rotation error is worst looking straight at a marker and improves as it tilts —
the design had that right. But the ratio does not track it. Below about 10° of
tilt the ratio reports 0, maximum confidence, precisely where the orientation is
least reliable: the twin solution is not yet distinct enough to survive as a
rival, so there is nothing to compare against.

Taken with the range measurement from D4 — the gate rejects 85–95 % of
detections at 11–13 m — the honest description is that `ambiguity_ratio_max` is
a **resolution** gate, not a **geometry** gate. It catches markers too small or
noisy to solve; `min_view_angle_deg` is the only thing excluding
near-fronto-parallel views. Both config files now say so.

Also worth noting against the design's headline figure: the measured
single-marker rotation error here peaks at 1.45°, not the 11.7° the spec cites.
That figure describes an ungated, poorly-resolved regime this system does not
operate in. This is the second measurement pointing the same way — D4 found
p99 board-to-board disagreement of 2.8°.

## Vendored into this repo, and the message question resolved

The detector now lives here as `src/localization/golfcart_aruco_detector`,
copied from LCTK's four ArUco packages and merged into one. LCTK keeps its own
copy for calibration; the two are expected to diverge, because they want
different things.

That resolves the message question by removing it. `ArucoDetectionArray` is
published directly, and the `Detection2DArray` corner-smuggling hack is gone —
it existed because `bbox` is axis-aligned and cannot carry four real corners.

**Dropped in the merge**, all of it calibration-only or dead:

| dropped | why it has no caller here |
|---|---|
| ICP board fit (`fit_icp`, `IcpRegression`, `PoseEstimation`) | fits a known multi-marker board; this system uses single-ID boards |
| all-or-nothing board mode | returns nothing unless every configured ID is visible; a vehicle sees whatever the room presents |
| `estimate_pose()` | the path `marker_pnp` replaced |
| `MrptCalibration` loader | intrinsics come from `CameraInfo`, by design |
| `MultiArucoPattern` grid | one marker per board, so there is no grid to describe |
| highgui windows | the node publishes a ROS overlay instead |

`marker_size` is now stated directly rather than derived from board size, border
and a square ratio: one number checkable against a tape measure instead of three
that have to agree. `cv-convert` was dropped too — its feature flags pin an exact
OpenCV minor version and had none for the one this repo builds against, so the
fifteen-line conversion is written out.

28 tests: 10 unit, 11 detection contract, 7 pose contract.

### Compressed transport, which turned out to be load-bearing

The gscam config sets `enable_pub_plugins: ["image_transport/compressed"]`, so
**no raw `sensor_msgs/Image` is published on these topics at all**. A detector
subscribed to the raw topic waits forever and presents as a camera that sees
nothing. The node therefore defaults to `use_compressed: true` and decodes
straight to grayscale with `imdecode`.

`rclrs` has no `image_transport` binding, so this is a direct
`CompressedImage` subscription rather than a transport plugin. That is a
simplification, not a workaround: it also avoids a decompressor node and a topic
round trip.

### Wired into the launch

`aruco_localization.launch.xml` claimed in its own header to bring up "the three
per-camera detectors" and brought up none — the localizer's remaps pointed at
topics nothing published. It now launches one detector per camera, guarded by
`use_sim_detector` (an argument phase 3D-2 declared and never used).

## Still open

- [x] **`ArucoDetectionArray` output.** Resolved by vendoring; see above.
      The original note read: blocked on a decision, not on work:
      the message is defined in the golf-cart repo (`aruco_detection_msgs`, phase
      3D-1) and LCTK cannot depend on it without a cross-repo dependency. The
      options are to move the package somewhere both can consume, vendor it into
      `lctk_interfaces`, or have the golf-cart side adapt LCTK's
      `Detection2DArray`. Note that `Detection2DArray` genuinely cannot express
      what is needed — its `bbox` is axis-aligned, so LCTK already smuggles the
      four corners through `results` as one `ObjectHypothesisWithPose` per corner
      (`C-01`). Carrying two poses, two errors and `K` as well would overload
      that field past the point of being defensible.
- [x] **`image_transport` with `transport:=compressed`.** Done as a direct
      `CompressedImage` subscription; see above.
- [ ] **Measure `corner_sigma_px`.** Still 0.3, still inferred from other
      people's data. Needs only a camera and a board.
