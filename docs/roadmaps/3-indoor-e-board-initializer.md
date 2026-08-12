# Phase 3E — Reflective Board Pose Initializer

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Design: [board_pose_initializer.md](../design/board_pose_initializer.md)
Map contract: [indoor_pcd_mapping_reflector_anchor.md](../design/indoor_pcd_mapping_reflector_anchor.md)

**Status: Not started — simulation work is unblocked and can start now**

Last updated: 2026-08-12

---

## Goal

Detect the single retroreflective board from a stationary LiDAR scan, compute the
vehicle pose in the map frame, and hand it to `autoware_pose_initializer` as an
initial guess. This is the GNSS replacement for cold start indoors.

---

## What is and is not blocked

Most of this sub-phase is testable with synthetic point clouds and needs no
vehicle, no bag, and no map. That is the reason to start here while the Orin work
proceeds in parallel.

| Work | Blocked by |
|------|------------|
| Simulator, detector, unit tests | Nothing |
| Node wiring, service call, diagnostics | Nothing |
| End-to-end replay validation | Indoor map from [sub-phase B](3-indoor-b-indoor-mapping.md) |
| On-vehicle validation | Sub-phase B, and the DBW velocity stub (see [3-indoor-localization.md](3-indoor-localization.md)) |

---

## Work items

### 1. Package scaffolding

- [ ] Create `src/localization/golfcart_board_initializer/` with the layout in
      design §3 — `detector.py`, `geometry.py`, `node.py`, `test/`, `config/`, `launch/`.
- [ ] `detector.py` must not import `rclpy`. It is shared with the offline
      map-anchoring step, and it is what makes the tests runnable without ROS.
- [ ] Add `config/board_initializer.param.yaml` with the parameter set in design §6.

### 2. Simulator

- [ ] Load the 32 lasers' `vert_correction` and `rot_correction` from
      `/opt/ros/humble/share/nebula_decoders/calibration/velodyne/VLP32.yaml`
      rather than assuming uniform elevation spacing.
- [ ] Ray–plane scene renderer: room (six planes) + board + distractors, nearest
      hit per ray.
- [ ] Calibrated-reflectivity intensity model — diffuse clipped to 0–100, retro
      clipped to 101–255 (design §7).
- [ ] Range noise σ = 0.02 m and 2% dropout.
- [ ] Optional blooming: halo points around the panel with range inflated 3–5 cm.
- [ ] Distractor set: exit sign, floor tape, safety vest, second board.
- [ ] Emit `sensor_msgs/PointCloud2` with `x, y, z, intensity, ring`, and support
      writing a rosbag2 for repeatable regression runs.

### 3. Detector

- [ ] Stage 1 gates: intensity ≥ 110, range 1.5–15 m, height 0.4–1.8 m in `base_link`.
- [ ] Stage 2 Euclidean clustering, tolerance 0.20 m, minimum 20 points, with a
      range-scaled minimum count.
- [ ] Stage 3 geometric scoring: planarity, verticality, extent, height, density.
- [ ] Ambiguity abort when two or more clusters survive.
- [ ] Stage 4 pose extraction: normal sign from the sensor direction, up axis from
      gravity, bounding-rectangle **centre** rather than centroid.
- [ ] Observed-edge tracking, with rejection or covariance inflation when a centre
      axis is unconstrained.
- [ ] Fit the Stage 3 density model from simulator output rather than deriving it
      analytically (design §10).

### 4. Node

- [ ] Scan accumulation (10 scans), with restart when the vehicle is moving.
- [ ] Static TF lookup `base_link ← velodyne`, with the state machine waiting for it.
- [ ] Pose composition and the covariance model of design §5 stage 5.
- [ ] Service call to `/localization/initialize`,
      `tier4_localization_msgs/srv/InitializeLocalization`, **`method=AUTO`**.
      `DIRECT` converts every detection error into a localization error.
- [ ] State machine with `max_attempts`, then `ERROR` and idle.
- [ ] Fallback to `user_defined_initial_pose` implemented but **default off**.
- [ ] Debug topics: `~/debug/board_points`, `~/debug/board_pose`, and
      `~/debug/rejected` carrying a rejection reason per cluster.
- [ ] Diagnostics distinguishing "no detection", "ambiguous", and "service failed".

### 5. Tests

- [ ] Range sweep: 2, 5, 10, 15 m.
- [ ] Yaw sweep: 0°, ±30°, ±60°.
- [ ] Occlusion: 0%, 30% left, 50% bottom.
- [ ] Distractors only — asserts **no detection**.
- [ ] Two boards — asserts **ambiguity abort**.
- [ ] Dirty board, intensity capped at 130 — asserts detection.
- [ ] Board tilted 10° — asserts the verticality gate does not reject it.
- [ ] Blooming enabled — asserts bias stays within tolerance.
- [ ] Metrics reported per run: position error, yaw error, detection rate,
      false-positive rate.

### 6. Integration

- [ ] Launch file, wired behind an argument so it is off by default outdoors.
- [ ] Confirm stage 0 (`user_defined_initial_pose`) still works independently —
      it is the fallback path and the thing to test first on any new map.
- [ ] `automatic_pose_initializer` is launched only when GNSS is enabled
      (`cuda_localization.launch.xml:28,86`). Decide whether this node replaces
      that trigger indoors or runs alongside it.
- [ ] End-to-end: `logging_simulation` replay of an indoor bag, no GNSS, no manual
      RViz input.

---

## Acceptance criteria

- [ ] Detector recovers the board pose within **0.20 m and 5°** across the nominal
      test matrix rows in simulation.
- [ ] **Zero false positives** on the distractor-only scene.
- [ ] Ambiguity abort fires on the two-board scene.
- [ ] Node initializes localization end to end in replay, with no GNSS and no
      manual RViz input.
- [ ] Diagnostics distinguish "no detection", "ambiguous", and "service failed".
- [ ] `detector.py` runs, and its tests pass, with no ROS installed.

---

## Notes carried from the design

- The VLP-32C reports **calibrated reflectivity**: 0–100 diffuse, 101–255
  retroreflector. The intensity threshold is a sensor contract, not a tuned
  constant — but geometric gating is still required, because exit signs and floor
  tape are also retroreflective.
- `method=AUTO` means the board supplies a guess and NDT align refines it, so the
  detector only has to be approximately right. This is what keeps the accuracy
  requirement loose enough to be achievable.
- `autoware_lidar_marker_localizer` cannot be reused for initialization: it
  associates detections using the EKF pose that cold start does not yet have.
