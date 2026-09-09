# Phase 3E — Reflective Board Pose Initializer

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Design: [board_pose_initializer.md](../design/board_pose_initializer.md)
Map contract: [indoor_pcd_mapping_reflector_anchor.md](../design/indoor_pcd_mapping_reflector_anchor.md)

> **RETIRED 2026-08-17. The package is deleted; this doc is history.**
>
> Built to replace GNSS for **NDT cold start** indoors. The ArUco localizer
> ([spec](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md)) made
> ArUco boards the sole indoor pose source and removed NDT, so nothing was left
> to seed — initialization is a mode inside that localizer, publishing to
> `/initialpose3d` once ≥2 markers and 5 agreeing solves pass its gates.
>
> `src/localization/reflective_pose_detector/` is gone as of the commit after
> `486bf5b`, which is where to look for the detector, the VLP-32C simulator, the
> map anchoring tool and the intensity-preserving PLY/PCD conversion. Nothing was
> broken; the job went away. The option of repurposing it as an out-of-channel
> integrity check is written up below, and remains available from that commit if
> the coverage argument ever turns.

**Status: Implemented and passing in simulation. Not scheduled — its caller was
removed with NDT; see the banner above and *Where this leaves the work* below.**

Last updated: 2026-08-17 (premise superseded)

---

## Goal

Detect the single retroreflective board from a stationary LiDAR scan, compute the
vehicle pose in the map frame, and hand it to `autoware_pose_initializer` as an
initial guess. This *was* the GNSS replacement for cold start indoors, when NDT
was the indoor pose source.

---

## What is and is not blocked

Most of this sub-phase is testable with synthetic point clouds and needs no
vehicle, no bag, and no map. That is the reason to start here while the Orin work
proceeds in parallel.

| Work | Blocked by |
|------|------------|
| Simulator, detector, unit tests | Nothing |
| Node wiring, service call, diagnostics | Nothing |
| End-to-end replay validation | ~~Indoor map from sub-phase B~~ — that sub-phase is deleted, so this is not blocked, it is moot |
| On-vehicle validation | Same. There is no NDT to initialize |

---

## Work items

### 1. Package scaffolding

- [x] Create `src/localization/reflective_pose_detector/` with the layout in
      design §3 — `detector.py`, `geometry.py`, `node.py`, `test/`, `config/`, `launch/`.
- [x] `detector.py` must not import `rclpy`. It is shared with the offline
      map-anchoring step, and it is what makes the tests runnable without ROS.
- [x] Add `config/board_initializer.param.yaml` with the parameter set in design §6.

### 2. Simulator

- [x] Load the 32 lasers' `vert_correction` and `rot_correction` from
      `/opt/ros/humble/share/nebula_decoders/calibration/velodyne/VLP32.yaml`
      rather than assuming uniform elevation spacing.
- [x] Ray–plane scene renderer: room (six planes) + board + distractors, nearest
      hit per ray.
- [x] Calibrated-reflectivity intensity model — diffuse clipped to 0–100, retro
      clipped to 101–255 (design §7).
- [x] Range noise σ = 0.02 m and 2% dropout.
- [x] Optional blooming: halo points around the panel with range inflated 3–5 cm.
- [x] Distractor set: exit sign, floor tape, safety vest, second board.
- [x] Emit `sensor_msgs/PointCloud2` with `x, y, z, intensity, ring`, and support
      writing a rosbag2 for repeatable regression runs.

### 3. Detector

- [x] Stage 1 gates: intensity ≥ 110, range **3–18 m**, height 0.4–1.8 m in
      `base_link`. The 3 m floor was measured, not chosen — see the results below.
- [x] Stage 2 clustering: voxel-grid connected components, tolerance **0.30 m**,
      minimum 20 points.
- [x] Stage 3 geometric scoring: planarity, verticality, extent, height, density.
- [x] Ambiguity abort when two or more clusters survive.
- [x] Stage 4 pose extraction: normal sign from the sensor direction, up axis from
      gravity, bounding-rectangle **centre** rather than centroid.
- [x] Observed-edge tracking, with rejection or covariance inflation when a centre
      axis is unconstrained.
- [x] Fit the Stage 3 density model from simulator output rather than deriving it
      analytically (design §10).

### 4. Node

- [x] Scan accumulation (10 scans), with restart when the vehicle is moving.
- [x] Static TF lookup `base_link ← velodyne`, with the state machine waiting for it.
- [x] Pose composition and the covariance model of design §5 stage 5.
- [x] Service call to `/localization/initialize`,
      `tier4_localization_msgs/srv/InitializeLocalization`, **`method=AUTO`**.
      `DIRECT` converts every detection error into a localization error.
- [x] State machine with `max_attempts`, then `ERROR` and idle.
- [x] Fallback to `user_defined_initial_pose` implemented but **default off**.
- [x] Debug topics: `~/debug/board_points`, `~/debug/board_pose`, and
      `~/debug/rejected` carrying a rejection reason per cluster.
- [x] Clear every debug topic at the start of each attempt. They are latched, so
      a stale detection otherwise keeps drawing after a failed attempt.
- [x] Publish both candidates, labelled, when the result is ambiguous.
- [x] Diagnostics distinguishing "no detection", "ambiguous", and "service failed".
- [x] `rviz/board_initializer.rviz` layout, verified on a display.

### 5. Tests

- [x] Range sweep: 3, 5, 10, 15 m, plus 2 m asserting **no** detection.
- [x] Yaw sweep: 0°, ±30°, ±60°.
- [x] Occlusion: 0%, 30% left, 50% bottom.
- [x] Distractors only — asserts **no detection**.
- [x] Two boards — asserts **ambiguity abort**.
- [x] Dirty board, intensity capped at 130 — asserts detection.
- [x] Board tilted 10° — asserts the verticality gate does not reject it.
- [x] Blooming enabled — asserts bias stays within tolerance.
- [x] Metrics reported per run: position error, yaw error, detection rate,
      false-positive rate.

### 6. Integration

- [x] Launch file, wired behind an argument so it is off by default outdoors.
- [ ] Confirm stage 0 (`user_defined_initial_pose`) still works independently —
      it is the fallback path and the thing to test first on any new map.
- [ ] `automatic_pose_initializer` is launched only when GNSS is enabled
      (`cuda_localization.launch.xml:28,86`). Decide whether this node replaces
      that trigger indoors or runs alongside it.
- [ ] End-to-end: `logging_simulation` replay of an indoor bag, no GNSS, no manual
      RViz input.

---

## Acceptance criteria

- [x] Detector recovers the board pose within **0.20 m and 5°** across the nominal
      test matrix rows in simulation. Measured 1–8 cm across range and yaw sweeps.
- [x] **Zero false positives** on the distractor-only scene.
- [x] Ambiguity abort fires on the two-board scene.
- [x] Diagnostics distinguish "no detection", "ambiguous", and "service failed".
- [x] `detector.py` runs, and its tests pass, with no ROS installed. 30 tests,
      about one second.
- [ ] ~~Node initializes localization end to end in replay~~ — moot. There is no
      NDT indoors to initialize, and the sub-phase B map it needed is deleted.

---

## Results

Simulation, `python3 -m pytest test` in the package — 30 tests, no ROS.

| Case | Outcome |
|------|---------|
| Range 3, 5, 10, 15 m | Detect; vehicle-pose error 1–8 cm |
| Range 2 m | No detection, as designed |
| Yaw 0°, ±30°, ±60° | Detect; error under 4 cm |
| Blooming | Detect; error 5 cm |
| Tilt 10°, dirty board | Detect |
| 30% horizontal occlusion | Detect, centre flagged unconstrained, covariance inflated, error 22 cm |
| 50% vertical occlusion | Clean reject on the extent gate |
| Distractors only | No detection |
| Two boards | Ambiguity abort |

Live ROS graph, `simulated_scene.launch.xml` with `dry_run:=true` — all three node
paths exercised: detection at 6.0 m with a published pose, ambiguity abort with
both candidates reported, and no-candidate with the rejection reason logged.

Topic values checked against ground truth on the running graph:

| Topic | Value | Against |
|-------|-------|---------|
| `debug/board_points` | 6436 points | matches the count the detection logged |
| `debug/board_pose` (`velodyne`) | x 6.0001, y 0.0010, z −0.489, yaw 180° | board at 6.0 m; yaw 180° is the normal facing the sensor |
| `debug/initial_pose` (`map`) | x 6.0018, y 0.0092, z −0.0267 | vehicle 6 m along map +x, facing the board |
| covariance σ²ₓ | 0.4365 | (2 × (0.15 + 0.03 × 6.02))² — the range model with its safety factor |

The pose z reads 3.6 cm high because the board's lower rows fall below the beam
fan at 6 m — the observed height is 0.91 m against a nominal 1.0 m. Bounded, and
inside tolerance, but note the edge test still calls the vertical centre
constrained there: the margin at 6 m is 0.20 m, so roughly 9 cm of missing height
passes unflagged.

### What running RViz exposed

Everything above was verified by echoing topics, and it all passed. Opening RViz
found a defect none of it could: **the debug topics are latched, and a failed
attempt published nothing**, so an ambiguous or no-candidate result left the
previous run's successful detection on screen — a green board and a stale
rejection label, drawn confidently, while the node was refusing to initialize.

Three fixes followed, all of them about the failure cases rather than the success
case:

- Every attempt clears the markers and the point cloud before publishing.
- An ambiguous result publishes **both** candidates, green with red
  `AMBIGUOUS candidate N` labels. Previously the one case where the operator most
  needs to see what the sensor saw drew nothing at all.
- The detection pose also goes out as an arrow marker inside the cleared array,
  because a latched `PoseStamped` cannot be retracted. The separate `Pose`
  display is off by default for that reason.

Worth generalising: a debug topic that is only exercised on the success path is
not a debug topic. All three of these were invisible to topic echoes, unit tests,
and the node's own logs, and visible immediately on a screen.

Two smaller findings from the same session:

- Only one rejection marker appears in the distractor scene, because the floor
  tape and the vest are killed by the height and cluster-size gates before stage
  3 ever sees them. The log line `clusters 1` is their only trace. Not wrong, but
  the markers do not show everything the gates discarded.
- `ros2 launch` under a shell `timeout` can leave the scene publisher alive. A
  stale publisher feeding a second scene into the same topic presents exactly as
  a detector bug — three board candidates in a two-board scene. Check
  `pgrep -f board_scene_publisher` before believing a detector defect.

### What the simulator taught us that the design got wrong

- **Minimum range is 3 m, and the reason is the beam table, not blooming.** The
  VLP-32C's 9.36° gap between the −25.0° and −15.6° beams swallows the bottom of
  the board below 3 m; a board at 2 m measures 0.55 m tall against a nominal 1.0 m.
  Parking closer makes detection worse.
- **The density gate needs the real elevation table.** A mean-elevation-step model
  is wrong by 3× across the working range, in a range-dependent direction. Reading
  the Nebula table brings the prediction within a few percent.
- **Accumulated scan count belongs to the detector, not just the node.** The first
  end-to-end run rejected a perfectly good board as ten times too dense.
- **A one-sided view cannot recover the centre.** The detector flags it and
  inflates the covariance instead of pretending otherwise; the tight 0.20 m bound
  is not claimed for occluded cases.

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


---

## Where this leaves the work

Two honest options, and the choice is not obvious.

### Retire it

The straightforward reading. NDT is gone indoors, the ArUco localizer initializes
itself, and a LiDAR board detector that seeds nothing is a package to maintain
for no current caller. The code stays in git history and `anchor_map_to_board`
remains useful independently (see the [3B note](3-indoor-b-indoor-mapping.md)).

### Repurpose it as the second opinion the new architecture lacks

The ArUco spec is candid that removing NDT removed the fallback, and names the
resulting failure precisely (§0, §6):

> A board that was mistyped or has been knocked askew will place the vehicle
> confidently in the wrong place, with nothing to disagree.

Its defence is redundancy *between markers* — per-marker residuals from the joint
solve, RAIM-style fault exclusion. That catches one bad board among several. It
cannot catch a systematic error, because every check lives inside the same
measurement channel: the same cameras, the same hand-measured map, the same
solver.

A retroreflective board detected by the **LiDAR** is a different channel end to
end — different sensor, different physics, different failure modes, and a pose
derived from geometry rather than from the tag map. It does not need to localize
the vehicle. Publishing "I am 6.0 m from the board, the ArUco solution says
5.4 m" is enough to turn a silent wrong-place failure into a loud disagreement,
which is the whole gap §6 is working around.

What that would take, roughly:

- The detector, already built and tested, running against the live scan.
- One board's pose in the same frame the ArUco map uses — hand-measured like the
  rest, not NDT-derived, so the deleted bootstrap is not resurrected.
- A residual published as a diagnostic, with **no** path into the EKF. It is a
  check, not a pose source; feeding it into the filter would recreate the fusion
  complexity this architecture deliberately dropped.

Cost is small because the detection half exists. The real question is whether the
integrity gap is worth one more mounted object and one more node — a call for
whoever owns the safety case, not one to make by default.

### Not an option

Keeping this doc as-is. It currently reads as scheduled work on the critical
path, and it is neither.
