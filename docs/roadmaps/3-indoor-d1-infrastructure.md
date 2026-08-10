# Phase 3D-1 — Infrastructure

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §3, §4.1, §4.2

**Depends on**: nothing.
**Blocks**: D2, D3, D4, D5.

**Status: COMPLETE — 2026-08-10.** 31 tests green. See "Outcome" at the bottom
for what shipped and the two things it changed in the spec.

---

## Goal

Packages, message definitions, and the tag map loader. No algorithm, no launch
wiring. When this lands, everything downstream has something to compile against.

The tag map loader is the one piece here with real substance and it is fully
unit-testable, so it should carry most of the effort.

---

## Tasks

### `aruco_detection_msgs` — new package

Deliberately **not** named `golfcart_*`: LCTK depends on it too, and LCTK should
not depend on a vehicle repo.

- [x] `ArucoDetection.msg`
      ```
      uint32   id
      float64[8] corners_rectified      # TL,TR,BR,BL as u,v — rectified pixels
      geometry_msgs/Pose pose_1         # camera-optical frame, IPPE solution 1
      geometry_msgs/Pose pose_2         # solution 2
      float64  reprojection_error_1
      float64  reprojection_error_2
      ```
- [x] `ArucoDetectionArray.msg`
      ```
      std_msgs/Header header            # stamp = capture; frame_id = camera OPTICAL frame
      float64[9] k                      # the K used for rectification
      ArucoDetection[] detections
      ```
- [x] `ArucoLocalizerStatus.msg` — state enum, per-camera detection counts,
      markers used, normal spread, condition number, flagged IDs.
- [x] `ament_cmake` + `rosidl_default_generators`, builds standalone.

**Why `k` travels in the message.** It makes a recorded detection stream
replayable with no camera and no calibration file. Detections are small enough
that a bag of them is a practical tuning artifact where a bag of three
1920×1280 streams is not.

**Why corners get a real field.** LCTK shipped the alternative twice: `C-01`
smuggled corners through a bounding box and every consumer reconstructed them
as `centre ± size/2`, wrong by up to 20 px for any non-fronto-parallel view;
then `H-10` re-created the same bug through a dump/load path that forgot to
serialize the smuggled field.

### `golfcart_aruco_localizer` — package skeleton

- [x] `package.xml`, `CMakeLists.txt` (`ament_cmake_auto`), `resource/`
- [x] Node that starts, declares and validates all parameters, logs its config,
      and shuts down cleanly. No subscriptions, no solve.
- [x] `config/aruco_localizer.param.yaml` with the full parameter set and
      documented defaults from the spec.
- [x] License header convention settled — `golfcart_launch` currently declares
      `TODO: License declaration` in `package.xml`; do not copy that.

### Tag map loader

The substantive piece. Lives in the localizer package, unit-tested standalone.

- [x] Parse the YAML of spec §3: `frame_id`, `survey` block, `defaults`, `tags`.
- [x] Accept **both** tag forms — `position` + `orientation`, and `corners`
      (four points, counter-clockwise). The corners form is preferred for a hand
      survey and is what the survey team will actually produce.
- [x] Convert `corners` → centre, orientation and size. Reject non-planar sets
      beyond a tolerance, and report *which* tag and by how much.
- [x] Validation, all with messages that name the offending tag:
      - duplicate ID → **hard error** (uniqueness is load-bearing for association)
      - malformed or non-unit quaternion → hard error
      - missing `marker_size` with no default → hard error
      - two boards closer together than a threshold → warning (safe, but usually a typo)
      - ~~board far outside the field bounds → warning~~ **not implemented**:
        there is no field-bounds concept yet, and inventing one to warn about
        would be guessing at the site. Revisit once the coverage walk defines it.
- [x] Per-tag `position_stddev`, falling back to `survey.stated_accuracy`.
- [x] Publish the loaded map as a `MarkerArray` for RViz (latched).

### Corner-order constant

- [x] Define the tag-local corner array **once**, in one header:
      ```
      p_TL = (−s/2, +s/2, 0)   p_TR = (+s/2, +s/2, 0)
      p_BR = (+s/2, −s/2, 0)   p_BL = (−s/2, −s/2, 0)
      ```
- [x] Unit test asserting it matches OpenCV's ordering for
      `estimatePoseSingleMarkers` / `solvePnP` object points.

LCTK's `M-14`: corner order was defined twice, in two languages, with nothing
checking they agreed. A corner permutation is a silent 90° or 180° pose error
that still "succeeds" — it will not show up as a crash or a failed solve.

### Build wiring

- [x] Both packages build under `just build`.
- [x] `aruco_detection_msgs` kept **in this repo** for now (see Outcome). It has
      no golfcart dependencies, so extracting it for LCTK is a `git mv` when D5
      needs it. Not worth splitting before there is a second consumer.

---

## Acceptance

- `colcon build --base-paths src` clean from scratch.
- Localizer node launches, prints its resolved config, exits on SIGINT.
- Tag map loader tests pass, including:
  - a map given in `corners` form and the same map in `position`/`orientation`
    form produce **identical** in-memory tags (this is the test that catches a
    convention error before it reaches the solve)
  - duplicate ID is rejected, naming the ID
  - non-planar corner set is rejected, naming the tag and the deviation
  - corner-order constant matches OpenCV

---

## Open decisions to close here

1. **Where `aruco_detection_msgs` lives** — this repo, LCTK, or standalone. It
   is the coupling point between the two repos and everything in D5 depends on
   the answer.
2. **Whether LCTK's existing `vision_msgs/Detection2DArray` output is retained**
   alongside the new message or replaced. Replacing is cleaner and `C-01`/`H-10`
   are the argument, but it breaks LCTK's calibration pipeline — coordinate,
   do not decide unilaterally.

---

## Outcome — 2026-08-10

Both packages build clean and **31 tests pass** (20 gtest, plus copyright and
xmllint linters across both packages).

```
src/localization/aruco_detection_msgs/          ArucoDetection, ArucoDetectionArray,
                                                ArucoLocalizerStatus
src/localization/golfcart_aruco_localizer/
  include/.../tag_frame.hpp                     the convention, defined once
  include/.../tag_map.hpp,  src/tag_map.cpp     loader + validation
  src/aruco_localizer_node.cpp                  params, map load, RViz publish
  config/aruco_localizer.param.yaml             full parameter set
  config/example_tag_map.yaml                   schema reference, both forms
  test/test_tag_frame.cpp                       5 tests, incl. the OpenCV pin
  test/test_tag_map.cpp                        15 tests
```

### The corner-order test was verified to fail

A test that pins a convention is worthless if it passes for the wrong reason, so
the corner order was deliberately rotated by one and the suite re-run. **Five
tests failed**, across both files — including both load-bearing ones:
`TagFrame.IsInterchangeableWithOpenCvObjectPoints` and
`TagMap.CornerFormAndPoseFormAgree`.

The OpenCV pin reported:

```
OpenCV recovered a pose rotated by 89.999997 deg about (0, 0, 1)
  -- the tag frame convention disagrees with OpenCV's
```

That is the failure mode the test exists for: a permutation still converges and
still reports a small residual, so without this it would reach the vehicle
looking plausible.

### Two corrections to the spec

**1. The ambiguity ratio was written inverted.** The spec said reject when
`err₂/err₁ > 0.2`, but IPPE returns solutions sorted by error, so `err₂ ≥ err₁`
and that ratio is always ≥ 1 — the gate could never fire. The correct metric is
`err₁/err₂ ∈ (0, 1]`, near 1 meaning ambiguous. Fixed in the spec, D3, D4, D5
and the message definition, and the node now range-checks the parameter at
startup so an out-of-range value fails loudly rather than silently never gating.

**2. `tier4_map_launch` cannot be told to skip the point cloud map**, confirmed
while checking D2's assumptions — `map.launch.xml` composes
`PointCloudMapLoaderNode` unconditionally. Already recorded in D2.

### Decisions taken

- **`aruco_detection_msgs` lives in this repo** for now, at
  `src/localization/`. It has no golfcart dependencies, so moving it to a
  standalone repo for LCTK to consume is a `git mv` whenever D5 needs it. Not
  worth splitting before there is a second consumer.
- **The four-corner form is accepted alongside the pose form**, and
  `TagMap.CornerFormAndPoseFormAgree` holds them to the same meaning.
- **Missing position uncertainty is a hard error**, not a default. It is the
  board's weight in the solve; assuming one would quietly invent confidence.
- **Malformed quaternions are rejected rather than normalized.** A norm
  meaningfully off 1 is usually transcription error, and normalizing bakes the
  mistake in as a plausible rotation.

### Still open, carried to D5

The dictionary and physical board geometry actually used are still unconfirmed,
so `defaults.marker_size: 0.384` in the example map is LCTK's shipped default,
not a measurement. Same for `corner_sigma_px: 0.3`, which the node now logs as
`(INFERRED, not measured)` every startup so it cannot quietly become folklore.
