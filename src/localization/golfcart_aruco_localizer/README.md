# golfcart_aruco_localizer

Vehicle pose from ArUco boards whose poses are measured by hand and supplied as
data. This is the **sole** pose source for indoor operation — there is no scan
matching, no point cloud map and no GNSS.

Design spec: [`docs/superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md`](../../../docs/superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md)

---

## Status: phase 3D-1 (infrastructure)

What is here:

- `tag_frame.hpp` — the tag frame convention and corner ordering, defined once
- `tag_map.{hpp,cpp}` — tag map loading and validation
- `aruco_localizer_node` — declares and validates the parameter set, loads the
  map, publishes it for RViz, and stops there

What is **not** here yet: detections are not consumed and no pose is produced.
The solve, integrity monitoring and the state machine are phase
[3D-4](../../../docs/roadmaps/3-indoor-d4-localizer.md).

---

## Try it

```bash
colcon build --base-paths src --symlink-install \
  --cmake-args -DCMAKE_BUILD_TYPE=Release \
  --packages-select aruco_detection_msgs golfcart_aruco_localizer
source install/setup.bash

SHARE=$(ros2 pkg prefix golfcart_aruco_localizer)/share/golfcart_aruco_localizer
ros2 run golfcart_aruco_localizer aruco_localizer_node --ros-args \
  --params-file $SHARE/config/aruco_localizer.param.yaml \
  -p tag_map_path:=$SHARE/config/example_tag_map.yaml
```

The loaded map is published latched on `~/debug/mapped_tags`, so RViz shows it
whenever it connects rather than only if it happened to be listening at startup.

---

## The tag frame convention

Origin at the marker centre, **x right, y up, z out of the printed face** toward
a viewer looking at it. Corners are ordered top-left, top-right, bottom-right,
bottom-left, as seen by that viewer.

This is OpenCV's marker frame, and it deliberately violates REP-103's x-forward
preference. Matching OpenCV exactly is worth more here, because these
coordinates go straight into PnP and every other convention in this data path is
already OpenCV's.

There is exactly one definition of it, in `tag_frame.hpp`, and `test_tag_frame`
pins it against OpenCV by projecting our corners through a pinhole camera and
asking `cv::aruco::estimatePoseSingleMarkers` to recover the pose using *its*
object points. If the two disagree, the pose comes back rotated and the test
says by how much and about which axis.

That matters more than it sounds. A corner permutation is a silent multiple-of-90°
pose error that still converges and still reports a small residual, so nothing
downstream can detect it. The pipeline this is adapted from defined corner order
twice, in two languages, with nothing checking the two agreed.

---

## Tag map format

Two forms per board, and they must mean the same thing —
`TagMap.CornerFormAndPoseFormAgree` is the test that holds them together.

```yaml
frame_id: map
survey:
  date: "2026-08-10"
  method: "laser distance meter + plumb line"
  stated_accuracy: 0.02          # [m] 1-sigma — the system's accuracy ceiling
defaults:
  dictionary: DICT_5X5_1000
  marker_size: 0.384             # [m] the black MARKER square, not the board
tags:
  - id: 696                      # pose form
    position:    {x: 12.340, y: -3.210, z: 1.500}
    orientation: {x: 0.0, y: 0.0, z: 0.70711, w: 0.70711}
    position_stddev: 0.02        # optional; overrides survey.stated_accuracy

  - id: 306                      # corner form — PREFERRED for a hand survey
    corners:
      - [3.192, 9.000, 1.692]    # top-left
      - [2.808, 9.000, 1.692]    # top-right
      - [2.808, 9.000, 1.308]    # bottom-right
      - [3.192, 9.000, 1.308]    # bottom-left
```

**Prefer the corner form when measuring by hand.** Four measured points fix
position, orientation and size at once, with no frame convention for a human to
get wrong. Writing a quaternion by hand means deciding what the board's local
axes mean and being right about it.

**`survey.stated_accuracy` is the ceiling on the whole system's accuracy.**
Survey error and vision error add in quadrature, so a 2 cm survey with a 3 cm
vision solution gives about 3.6 cm — while a 10 cm survey makes the vision
accuracy nearly irrelevant. It is worth measuring carefully once.

### What is rejected, and why

| Condition | Reason |
|---|---|
| Duplicate ID | Unique IDs are what make association prior-free, and prior-free association is what makes cold start possible. Not hygiene — load-bearing. |
| Non-planar surveyed corners | A non-planar quad has no well-defined orientation. Accepting one would invent a rotation out of measurement noise. |
| Quaternion whose norm is not 1 | Refused rather than normalized: a norm meaningfully off 1 is usually transcription error, and normalizing bakes the mistake in as a plausible rotation. |
| Both `corners` and `position`/`orientation` | Ambiguous. |
| No `marker_size` anywhere | It scales every range estimate linearly, so it cannot be guessed. |
| No position uncertainty anywhere | It is the board's weight in the solve. Assuming one would quietly invent confidence. |

Warnings — reported, not fatal — cover boards closer together than a threshold
(safe, since association is by ID, but usually a mistyped coordinate) and a
declared `marker_size` that disagrees with the surveyed corners.

Every message names the offending board.

---

## Notes on the parameters

Two defaults are honest placeholders and are marked as such in the log output:

- **`corner_sigma_px: 0.3`** is *inferred*, not measured. No published work gives
  a measured corner sigma for ArUco with sub-pixel refinement. Everything the
  covariance model produces scales on it. Phase 3D-5 replaces it with a
  measurement: park in front of a board, record ~1000 frames, take the standard
  deviation of the corner positions.
- **`dead_reckoning_budget_s`** and **`degraded_budget_s`** must follow from
  measured IMU drift and odometry error against an allowable position error. The
  values shipped here are deliberately short.

One counter-intuitive parameter pair worth reading twice:
`min_view_angle_deg: 25.0` is a *lower* bound. Looking straight down a board's
normal is the **worst** case for orientation, not the best, because that is where
the planar two-solution ambiguity is strongest. The usable window is bounded
below by ambiguity and above by detection failure.
