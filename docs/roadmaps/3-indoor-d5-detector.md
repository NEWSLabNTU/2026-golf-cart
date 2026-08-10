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

- [ ] **`rational_polynomial` support.** `DistortionModel` is a one-variant enum
      (`PlumbBob`) and the MRPT loader hard-errors on non-zero coefficients past
      index 5. The detector core already passes `camera_info.d` through in full,
      so this is a loader and validation fix, not a maths fix. These cameras
      publish 12 coefficients.
      Also **validate `distortion_model`** rather than assuming — nothing in
      LCTK currently reads that field at all.
      Related: `L-03`, the bug of truncating `D` to five and silently dropping
      rational-polynomial `k4`–`k6`.
- [ ] **Switch the wired entry point.** `detect_markers()` gates all-or-nothing
      on the detected ID set exactly equalling the configured set — correct when
      calibrating against one known board, wrong for a localizer that must accept
      whatever is in view. `detect_single_aruco()` already has the right
      semantics and is currently unused by the node.
- [ ] **Per-marker pose with an ambiguity metric.** Replace the dead
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

- [ ] **Take candidates from both `SOLVEPNP_ITERATIVE` and `SOLVEPNP_IPPE_SQUARE`,
      polish every one with `solvePnPRefineLM`, and score them with a
      reprojection error computed in our own code** rather than the one OpenCV
      returns. After refinement every geometry tested recovers the true pose to
      about 1e-5 px, and the ambiguity ratio becomes meaningful — 0.9998 where
      the view is genuinely two-valued, near zero where it is not.
- [ ] **Deduplicate before reporting the alternate.** Refining several seeds
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

- [ ] Keep construction in **exactly one validated function**. `L-11`: a
      copy-pasted five-line block set `adaptive_thresh_win_size_step` twice and
      tuned a refiner that was never enabled.
- [ ] Defaults from LCTK's measured sweep: `SUBPIX`, `win_size 5`,
      `max_iterations 30`, `min_accuracy 0.01`; adaptive threshold `13/33/10`.
      SUBPIX beat NONE by 25–60% at every apparent marker size from 54 px to 302 px;
      CONTOUR was equal or worse.
- [ ] Expose the parameters LCTK leaves at OpenCV defaults — marker perimeter
      rate, error correction rate, `min_marker_distance_rate`. An indoor scene
      has small distant markers and these matter there.

---

## Tests

- [ ] Port `rust/aruco-detector/tests/rectify_contract.rs`, including the two
      tests that were verified to fail when their bugs were reintroduced:
      one fails with *"SUBPIX and NONE produced the same corners, so corner
      refinement is not running at all"*, the other catches a `P`-less
      `undistortPoints` returning normalized coordinates.
- [ ] Round-trip test: distort → detect → undistort, built by inverting
      `undistortPoints` into a `remap` table.
- [ ] 12-coefficient `rational_polynomial` handling, end to end.
- [ ] IPPE returns two distinct solutions on a near-fronto-parallel view, and
      `err₁/err₂` approaches 1 there.

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
