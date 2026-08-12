# Reflective Board Pose Initializer — Design

**Status**: Implemented, sub-phase 3E stages 1-5; see the phase doc for what remains
**Date**: 2026-08-12 (updated after implementation)
**Phase doc**: [3-indoor-e-board-initializer.md](../roadmaps/3-indoor-e-board-initializer.md)
**Depends on**: [indoor_pcd_mapping_reflector_anchor.md](indoor_pcd_mapping_reflector_anchor.md)
(map anchored to the board, §4)

---

## 1. Goal

Replace GNSS as the cold-start pose source for indoor operation. A node detects
the single retroreflective board from a stationary LiDAR scan, computes the
vehicle pose in the map frame, and hands it to `autoware_pose_initializer` as an
initial guess.

This is stage 1 of the cold-start staging in
[indoor_pcd_mapping_reflector_anchor.md §7.2](indoor_pcd_mapping_reflector_anchor.md).
Stage 0 — a fixed `user_defined_initial_pose` — needs no code and should be
working first, because it validates the map and the no-GNSS launch path without
also debugging a detector.

### Non-goals

- Continuous localization. This node runs once, at startup, and stops.
- Bounding NDT drift. The board is not visible from most of the route.
- Replacing `autoware_lidar_marker_localizer`. That package solves a different
  problem; see §2.

---

## 2. Two facts that shape the whole design

**The VLP-32C separates retroreflectors in hardware.** Velodyne returns
*calibrated reflectivity*, not raw intensity: 0–100 encodes diffuse surfaces by
reflectivity percentage, and **101–255 is reserved for retroreflectors**. A
threshold at 110 therefore separates the board from every painted wall, floor,
and ceiling in the building by the sensor's own contract, not by a tuned
constant. Geometric gating is still required — exit signage, floor tape, and
safety vests are also retroreflective — but the first filter is exact.

**The board only needs to be approximately right.** `/localization/initialize`
is `tier4_localization_msgs/srv/InitializeLocalization`, whose `method` field
accepts:

```
uint8 AUTO = 0     # input pose used as an initial guess, then localization refines it
uint8 DIRECT = 1   # input pose used directly, no refinement
```

With `AUTO`, NDT align refines whatever the board produces. A guess good to
roughly 0.2 m and 5° is comfortably sufficient. `DIRECT` skips the refinement and
should not be used — it converts every detection error into a localization error.

This also explains why `autoware_lidar_marker_localizer` cannot be reused here:
it subscribes to `/localization/pose_twist_fusion_filter/biased_pose_with_covariance`
and gates detections on `limit_distance_from_self_pose_to_marker` and
`self_pose_timeout_sec`, associating detections using the pose that cold start
does not yet have. It is a tracking corrector, not an initializer.

---

## 3. Package layout

```
src/localization/golfcart_board_initializer/
  golfcart_board_initializer/
    detector.py            # pure numpy — no ROS imports
    geometry.py            # pose composition, covariance model
    vlp32.py               # beam table, Nebula calibration with embedded fallback
    simulation/            # synthetic scan generator, room and distractor scenes
    node.py                # ROS wiring: TF, service call, diagnostics
    scene_publisher.py     # publishes synthetic scans for desk testing
  test/test_detector.py    # pytest, no ROS required
  test/test_geometry.py
  config/board_initializer.param.yaml
  launch/board_initializer.launch.xml
  launch/simulated_scene.launch.xml
```

The simulator ended up inside the package rather than beside the tests, so the
same scene definitions drive both the offline test matrix and the live scene
publisher used for desk testing.

`detector.py` exposes a pure function:

```python
def detect_board(points: np.ndarray,              # (N, 3) in sensor frame
                 intensity: np.ndarray,           # (N,)
                 transform_base_sensor: np.ndarray,   # 4x4, for height and gravity
                 params: DetectorParams) -> DetectResult
```

`DetectResult` carries the status (`OK`, `NO_CANDIDATE`, `AMBIGUOUS`), the
detection, every rejected cluster with its reason, and the surviving candidate
list.

Two consequences follow from keeping it free of `rclpy`, and both are the point
of the split:

- Tests run with no ROS, no hardware, and no bag — just numpy.
- The **same detector serves the offline map-anchoring step**
  ([mapping design §6.4](indoor_pcd_mapping_reflector_anchor.md)), so the board
  pose used to define the map origin and the board pose used at runtime come from
  identical code.

Python is appropriate here: the node runs once at startup rather than in a
control loop, so numpy is fast enough, and iteration speed matters more than
microseconds.

---

## 4. Node contract

| Role | Interface |
|------|-----------|
| Subscribe | `/sensing/lidar/top/pointcloud_raw_ex` — frame `velodyne`, carries `intensity` |
| TF | `base_link ← velodyne`, static, from the sensor kit calibration |
| Service client | `/localization/initialize`, `tier4_localization_msgs/srv/InitializeLocalization`, `method=AUTO` |
| Debug | `~/debug/board_points` (PointCloud2), `~/debug/board_pose` (PoseStamped), `~/debug/rejected` (MarkerArray, one marker per rejected cluster carrying its rejection reason) |
| Diagnostics | `OK` on success; `ERROR` with a reason on failure. Never a silent fallback pose. |

The rejected-cluster topic is not decoration. When detection fails on site, the
question is always "what did it see, and why was it thrown away". Without that
topic the answer requires a rebuild with extra logging, in the field.

---

## 5. Algorithm

### Stage 0 — accumulate

The vehicle is stationary at initialization, so accumulate N = 10 scans (1 s) in
the `velodyne` frame with no deskew. This multiplies the returns on the board and
averages down range noise. Abort and restart accumulation if
`/vehicle/status/velocity_status` reports above 0.05 m/s.

The scan count is a detector parameter, not just a node one, because the density
gate's expected return count scales with it. A node accumulating ten scans
against a detector assuming one rejects every real board as ten times too dense —
which is exactly what the first end-to-end run did.

### Stage 1 — cheap gates

```python
keep  = intensity >= 110                      # retroreflector band (§2)
keep &= (r >= 3.0) & (r <= 18.0)              # see below
keep &= (z_base >= 0.4) & (z_base <= 1.8)     # kills floor tape and ceiling signage
```

`z_base` requires the static TF, so the node waits for it before processing any
cloud.

**The 3 m minimum was measured, not chosen.** The obvious lower bound is
blooming, and it is the wrong one. The VLP-32C's elevation gaps run from 0.333°
to 9.36°, and the 9.36° gap sits at the bottom of the fan between −25.0° and
−15.6°. With the sensor at 1.6 m and the board centred at 1.075 m, the board's
lower edge crosses into that gap below about 3 m: its bottom third is then
sampled by a single isolated ring, fails to connect to the rest of the cluster,
and the extent gate rejects what is left. In simulation a board at 2 m yields an
observed height of 0.55 m against a nominal 1.0 m. Standing closer to the board
makes detection worse, not better.

### Stage 2 — cluster

Connected components over a voxel grid at the cluster tolerance, joined under
26-connectivity: O(N), deterministic, and free of any KD-tree dependency. It is
strictly more permissive than point-distance clustering at the same tolerance,
so a dense planar target never fragments unless there is a genuine gap of a full
voxel.

Tolerance 0.30 m, minimum 20 points. The tolerance is set by *across-ring*
spacing, not within-ring spacing. At 10 m the dense elevation band of the
VLP-32C gives roughly 6 cm between rings, but the sparse band is several times
that. A tolerance tuned to within-ring spacing splits the board into
disconnected horizontal stripes.

### Stage 3 — geometric scoring

Per cluster, PCA gives eigenvalues λ1 ≥ λ2 ≥ λ3 with eigenvectors e1, e2, e3.

| Test | Condition | What it rejects |
|------|-----------|-----------------|
| Planarity | √λ3 < 0.03 m | Vests, cones, curved and crumpled surfaces |
| Verticality | \|e3 · z_base\| < 0.25 | Floor tape, ceiling markers |
| Extent | in-plane extents within [0.6, 1.2] × nominal 0.8 × 1.0 m | Exit signs (too small), vehicle sides (too large) |
| Height | centroid z within 1.075 ± 0.30 m | Anything at the wrong mounting height |
| Density | point count at most 1.4× the count predicted for the measured range and height | A distant large panel masquerading as a near small one |

The density prediction counts the beams from the **actual elevation table** that
fall within the board's angular span, times the angular width over the azimuth
step, times the accumulated scan count. A mean-elevation-step approximation was
tried first and is wrong by a factor of three across the working range, in a
range-dependent direction — the board sits in the sparse part of the fan up
close and the dense part far away. With the real table the predicted count lands
within a few percent of the observed count at 5, 10, and 15 m.

The gate is an **upper bound only**. Yaw, occlusion, and dropout all legitimately
reduce the return count; nothing legitimately inflates it.

**Two or more survivors abort the detection with a diagnostic.** The map contains
exactly one board; ambiguity means that assumption has been violated, and
choosing the higher-scoring candidate would produce a confident wrong pose.
Refusing to initialize is the safe failure.

### Stage 4 — pose extraction

```
n  = e3, sign-flipped so that  n · (sensor_origin − centroid) > 0    # face the sensor
u  = normalize(z_base − (z_base · n) n)                             # gravity-up, projected into the plane
rt = u × n                                                          # completes a right-handed frame
```

Project the cluster onto (rt, u), fit the axis-aligned bounding rectangle in that
2D frame, and take its **centre** — not the centroid. The centroid is biased
whenever the board is partially observed, and partial observation is the normal
case at range.

Record which of the four edges were actually observed; an edge counts as seen
when points reach within one ring-spacing of the expected extent. A missing left
*and* right edge leaves the horizontal centre unconstrained, which must either
reject the detection or inflate that covariance term substantially. The same
applies vertically.

**Board frame convention.** ROS-style: x is the outward normal, y is to the
board's left as seen from the sensor, z is up.

**On board shape.** The 180° rotational symmetry of a rectangle is not a problem:
the normal's sign is fixed by facing the sensor and the up axis by gravity, so
the frame is fully determined. The reason to prefer a rectangle over a square is
Stage 3's extent test — with a square, width and height are interchangeable and
the test loses half its discriminating power.

### Stage 5 — compose and publish

```
T_map←base_link = T_map←board ∘ (T_velodyne←board)⁻¹ ∘ (T_base_link←velodyne)⁻¹
```

With the map anchored to the board per the mapping design §4, `T_map←board` is a
pure translation of the board's mounting height: the map origin sits on the floor
directly below the board centre, with map x along the board normal and map z up.
Floor-level rather than board-centre origin keeps vehicle poses near z = 0, which
is what the rest of the stack expects. It stays a parameter regardless, so an
un-anchored map remains usable.

Covariance is deliberately loose, since NDT align refines the guess:

```
σ_xy  = 0.15 + 0.03 · range          [m]
σ_z   = 0.10                         [m]
σ_yaw = 0.05 + plane_fit_residual / board_extent    [rad]
```

Then double it. An over-tight guess makes NDT align search too small a window; an
over-loose one costs a few hundred milliseconds.

### Stage 6 — state machine

```
WAIT_TF → ACCUMULATE → DETECT → CALL_SERVICE → DONE
              ↑           │
              └─ retry ───┘   K = 5 attempts, then ERROR and idle
```

An ambiguous result does **not** retry. Retrying a broken assumption just burns
attempts before reporting the same thing, so ambiguity fails immediately.

`dry_run` publishes the composed pose on `~/debug/initial_pose` instead of
calling the service. That is what makes the synthetic scenes useful on a desk:
the whole path — subscription, TF, accumulation, detection, composition — runs
with no localization stack present.

A fallback to `user_defined_initial_pose` after timeout is available but
**disabled by default**. Silent fallback to a fixed pose is the mechanism by
which a detector failure becomes a mislocalization report three weeks later.

---

## 6. Parameters

```yaml
# config/board_initializer.param.yaml
/**:
  ros__parameters:
    input_topic: /sensing/lidar/top/pointcloud_raw_ex
    sensor_frame: velodyne
    base_frame: base_link

    accumulate_scans: 10
    max_speed_for_init: 0.05          # [m/s]

    intensity_threshold: 110          # retroreflector band lower bound
    range_min: 1.5
    range_max: 15.0
    height_min: 0.4
    height_max: 1.8

    cluster_tolerance: 0.20
    cluster_min_points: 20

    board_width: 0.8
    board_height: 1.0
    board_centre_height: 1.075
    extent_tolerance: [0.6, 1.2]      # fraction of nominal
    planarity_max_thickness: 0.03
    verticality_max_dot: 0.25
    density_tolerance: 0.5

    board_pose_in_map: [0.0, 0.0, 1.075, 0.0, 0.0, 0.0, 1.0]   # identity translation-only when anchored

    max_attempts: 5
    fallback_to_user_defined_pose: false
```

---

## 7. Simulation and test strategy

The detector is testable without hardware, and the simulation can be exact rather
than approximate.

**Beam model from the real calibration table.**
`/opt/ros/humble/share/nebula_decoders/calibration/velodyne/VLP32.yaml` contains
all 32 lasers' `vert_correction` and `rot_correction` in radians — the same file
the Nebula driver uses. Reading it gives the genuine non-uniform elevation
distribution, which is precisely what determines how many rings land on the board
at a given range. Azimuth step is 0.2° at 600 rpm / 10 Hz.

**Scene.** An axis-aligned room (six planes) plus a board rectangle at a known
pose plus distractors. Ray–plane intersection per beam, nearest hit wins, rays
that escape are dropped.

**Intensity model**, mirroring the sensor's calibrated-reflectivity semantics so
the Stage 1 threshold is tested against the real contract:

```python
diffuse: I = clip(80 * cos(incidence) * (5 / r)**0.5 + N(0, 5),   0, 100)
retro:   I = clip(255 * cos(incidence)**0.5     + N(0, 10),     101, 255)
```

**Noise.** Range σ = 0.02 m, 2% dropout, and optionally **blooming** — a halo of
spurious points around the panel edges with range inflated by 3–5 cm. Blooming is
the failure mode most likely to bite on real hardware and the one a naive
simulator omits.

**Distractors**, to exercise Stage 3: an exit sign 0.3 × 0.2 m at 2.2 m, a floor
tape strip at z = 0, a safety-vest patch at 1.2 m, and a second full board.

**Output.** `sensor_msgs/PointCloud2` with `x, y, z, intensity, ring`, either
published live or written to a rosbag2 for repeatable regression runs.

### Test matrix

Ground-truth `T_velodyne←board` is known in every case.

| Axis | Values | Result |
|------|--------|--------|
| Range | 3, 5, 10, 15 m | Detect. Vehicle-pose error 1–8 cm |
| Range | 2 m | **No detection** — below the elevation-gap floor (§5 stage 1) |
| Yaw to board | 0°, ±30°, ±60° | Detect. Error under 4 cm throughout |
| Occlusion 30% horizontal | one side hidden | Detect, both horizontal edges flagged unobserved, covariance inflated. Error 22 cm |
| Occlusion 50% vertical | half hidden | **Clean reject** on the extent gate |
| Distractors only | exit sign, floor tape, vest | **No detection** — false-positive test |
| Two boards | — | **Ambiguity abort**, two candidates reported |
| Dirty board | returns capped near 130 | Detect; the 110 threshold has margin |
| Board tilted 10° | — | Detect; the verticality gate does not reject it |
| Blooming enabled | halo + 3–5 cm range inflation | Detect. Error 5 cm |
| Seed sweep | 5 noise seeds at 8 m, 15° bearing | Detect every time |

Assert position error below 0.20 m and yaw error below 5° for the nominal cases —
well inside what NDT align absorbs.

**The occluded case does not get the tight bound, and that is a real limit rather
than a tuning gap.** A one-sided view cannot say *which* edge is missing: the
bounding rectangle is a lower bound on the board, so the centre is biased by up
to half the hidden width. What the detector guarantees there is that the bias is
bounded and that the covariance advertises it — hence the assertion is 0.40 m
plus an inflated-covariance check, not 0.20 m.

---

## 8. Failure modes

| Mode | Handling |
|------|----------|
| No cluster survives gating | Retry up to `max_attempts`, then `ERROR` diagnostic and idle |
| Two or more clusters survive | Abort immediately with `ERROR`; do not choose between them |
| Board partially observed, centre unconstrained on an axis | Reject, or inflate that covariance term; never silently accept a biased centre |
| Blooming inflates range | Constant few-cm bias, absorbed by NDT align; keep paths outside 2 m of the board |
| TF or map not ready | State machine waits; does not consume clouds early |
| Vehicle moving | Accumulation restarts |
| Detector succeeds but NDT align fails | `pose_initializer` reports its own error; the node's job is finished either way |

---

## 9. Acceptance criteria

- ✅ Detector recovers the board pose within 0.20 m and 5° across the nominal test
  matrix rows, in simulation. 30 tests, about one second, no ROS required.
- ✅ Zero false positives on the distractor-only scene.
- ✅ Ambiguity abort fires on the two-board scene.
- ✅ Node runs end to end against synthetic scans: detection, ambiguity, and
  no-candidate paths all exercised through the live ROS graph.
- ✅ Diagnostics distinguish "no detection", "ambiguous", and "service failed".
- ⬜ Node initializes localization end to end in `logging_simulation` replay of an
  indoor bag, with no GNSS and no manual RViz input. Blocked on the indoor map
  from sub-phase B.

---

## 10. Open questions

**Shared detector packaging.** The offline anchoring step and this node should
share `detector.py`. Whether the anchoring tool imports it from this ROS package
or the detector moves to a standalone Python module that both depend on is
undecided. Sharing is clearly right; the packaging is not yet.

**Accumulation versus single scan.** Ten scans is a starting point chosen for
signal-to-noise, not measured. If a single scan proves sufficient at working
ranges, the state machine simplifies.

**Whether the node should self-verify.** After `pose_initializer` returns, the
node could compare the refined pose against its own guess and warn on a large
discrepancy — a cheap check that the board detection and NDT agree. Deferred
until there is real data on what a normal discrepancy looks like.

**Density model.** The Stage 3 density test needs a predicted hit count as a
function of range, derived from the VLP-32C elevation table. The simulator
produces exactly this, so the model should be fitted from simulation output
rather than derived analytically.
