# Indoor PCD Map Creation with a Reflector-Anchored Origin — Design

**Status**: **Superseded 2026-08-17.** Sub-phase B is deleted — the ArUco
localizer needs no point cloud map — and the anchoring tool this describes went
with the `golfcart_board_initializer` package in the commit after `486bf5b`.
Kept for the reasoning: if a point cloud map is ever wanted again, the
anchored-origin argument and the GLIM findings still apply.
**Date**: 2026-08-11
**Phase docs**: [3-indoor-b-indoor-mapping.md](../roadmaps/3-indoor-b-indoor-mapping.md),
[3-indoor-localization.md](../roadmaps/3-indoor-localization.md)
**Related**: [lidar_marker_localization.md](../research/lidar_marker_localization.md),
[2026-07-27-indoor-artag-localization-design.md](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md)

---

## 1. Goal

Build the indoor PCD point cloud map required by sub-phase B without GNSS
anywhere in the pipeline, and give the resulting map an origin that can be
physically re-found at the start of every session.

The mechanism is a single retroreflective board — a flat rectangular panel
covered in 3M reflective sheeting — mounted permanently at the indoor site. Its
observed pose in the finished map defines the map frame origin, and its runtime
detection replaces GNSS as the cold-start pose source.

### Non-goals

- Replacing NDT. NDT stays the primary runtime pose estimator.
- Bounding NDT drift along the whole route. One board cannot do that; see §3.
- Georeferencing. The indoor map is a local metric frame with no geodetic datum.
- Replacing the AR-tag work in sub-phases C and D. This design covers map
  construction and cold start only, and composes with tags rather than competing
  with them.

---

## 2. Why GNSS is not needed for map construction

GNSS plays no part in offline point cloud map construction. Its two jobs during
mapping are georeferencing the map origin, and constraining accumulated drift on
long outdoor loops. Indoors, the first is unnecessary and the second is better
served by geometric loop closure: interior environments are rich in walls,
corners, doorways, and pillars, which is precisely the structure that place
recognition and ICP-based loop closure exploit.

The consequence is that the map origin is arbitrary and therefore free to be
chosen. Choosing it to coincide with a physical object that can be detected at
runtime is what makes the whole session repeatable — the vehicle's starting pose
relative to the map becomes known by construction rather than by manual RViz
input.

---

## 3. What the board can and cannot do

The board is tempting to overload. It should carry exactly two responsibilities.

| Function | Board suitable? | Reasoning |
|----------|-----------------|-----------|
| Map frame origin anchor | Yes — primary use | A permanently mounted, LiDAR-detectable object makes the origin physically re-findable across sessions and across map rebuilds. |
| Runtime cold-start pose | Yes | Detected at session start from a known parking position, it replaces the GNSS initial pose for `autoware_pose_initializer`. |
| SLAM loop closure during map build | Not needed | Indoor geometric loop closure is already strong. A single 0.8 m panel adds no constraint that wall and corner geometry does not already provide, and building the map's correctness on one detection is fragile. |
| Bounding NDT drift mid-route | No | The board constrains pose only while visible, roughly within 10 m. Corridors far from it stay degenerate. That problem belongs to sub-phase C/D tags, or to additional reflectors added later. |

The board is an *anchor*, not a *localizer*. Treating it as the latter with a
single panel would produce a system that is accurate near the entrance and
unbounded everywhere else.

---

## 4. Map frame definition

After SLAM produces a self-consistent cloud in an arbitrary frame, the cloud is
rigidly transformed so that:

- **Origin** — the point on the floor directly below the centre of the board's
  reflective face. Floor level rather than board-centre height keeps vehicle
  poses near z = 0, which is what the rest of the stack expects; the board centre
  then sits at (0, 0, 1.075), which is the initializer's `board_pose_in_map`
  default.
- **+X** — the board's outward surface normal, pointing into the drivable space.
- **+Z** — gravity-up, taken from the IMU's estimated gravity direction during
  the mapping run, not from the SLAM frame's nominal Z.
- **+Y** — completes the right-handed frame.

This transform is the map's definition and must be stored alongside the map, not
merely applied and discarded. If the map is ever rebuilt from the same bag, the
new build must land on the same origin, and that is only checkable against the
recorded transform.

Because the frame is metric-local with no geodetic datum, `map_projector_info.yaml`
must declare it as such:

```yaml
# data/<indoor-map>/map_projector_info.yaml
projector_type: Local
vertical_datum: WGS84
```

The existing outdoor practice map uses `TransverseMercator` with a lat/lon
origin:

```yaml
# data/COSS-map-planning/map_projector_info.yaml
projector_type: TransverseMercator
vertical_datum: WGS84
map_origin:
  latitude: 25.0201
  longitude: 121.5423
  altitude: 25.0
```

Copying that file to the indoor map and leaving the projector type unchanged is
a silent-failure path: several nodes read this field and will place the map in a
geodetic frame that does not exist indoors.

### Board immobility

The board defines the origin. If it is moved after mapping, every subsequent
session localizes confidently into the wrong frame, and the failure presents at
runtime as a localization problem rather than an infrastructure problem. Mitigations:

- Bolt or otherwise permanently fix the board; do not rely on a stand.
- Mark its floor footprint so displacement is visible on inspection.
- Record a session stamp with the map, mirroring the staleness warning already
  designed for the tag map in
  [3-indoor-localization.md](../roadmaps/3-indoor-localization.md).

---

## 5. Board specification

The detection requirements come from `autoware_lidar_marker_localizer`, whose
parameters are documented in
[lidar_marker_localization.md](../research/lidar_marker_localization.md).

| Property | Value | Reasoning |
|----------|-------|-----------|
| Reflective face | 0.8 m wide × 1.0 m tall, **rectangular, not square** | A square face is 90°-symmetric; shape alone then leaves a yaw ambiguity about the surface normal. A rectangle plus gravity-up resolves the full orientation. |
| Material | 3M high-intensity retroreflective sheeting | Returns saturate near intensity 255 against indoor wall returns of roughly 5–40, giving a wide separation for threshold-based detection. |
| Non-reflective margin | ≥ 0.15 m of matte border on both sides | `intensity_pattern` matching expects low-intensity cells flanking the high-intensity region. Without the margin, the pattern must be rewritten. |
| Mounting height | Face centre near 1.075 m above ground | Matches the upstream default and sits inside the VLP-32C's dense ring band at working ranges. |
| Orientation | Face perpendicular to the approach path | Maximises returned rings and reduces the incidence-angle intensity falloff. |
| Standoff | No planned path closer than ≈2 m | See the blooming note in §8. |

---

## 6. Pipeline

### 6.1 Record the mapping bag

Adapt `scripts/rosbag/record_outdoor.sh`, dropping the GNSS topics and keeping:

- `/sensing/lidar/top/pointcloud_raw_ex` — carries `intensity`, `ring`, and
  per-point timestamps. Intensity is needed for board detection and per-point
  time for motion deskew; the non-`_ex` topic is not sufficient.
- `/sensing/imu/imu_raw` — raw IMU, so the offline pipeline can apply its own
  bias handling rather than inheriting the runtime corrector's.
- `/tf_static`
- All three cameras. Mapping does not need them, but sub-phase C replays this
  same bag to bootstrap the tag map, so the tags should already be installed
  during this drive.

### 6.2 Drive the route

- Speed at or below 1 m/s, with smooth steering. Deskew quality and IMU
  preintegration both degrade with aggressive motion.
- Close every loop. An open-ended out-and-back gives loop closure nothing to
  work with.
- Pass the board at the start, at least once mid-run, and at the end.
- Keep pedestrians out of the environment. Moving bodies survive into the map as
  smeared surfaces and later corrupt NDT scoring.

### 6.3 Offline LiDAR-inertial SLAM — GLIM

VLP-32C at 10 Hz with the xsens IMU. **GLIM** (v1.2.2, koide3/AIST, MIT) is the
chosen framework. It is sensor-agnostic — no ring count or scan pattern
assumptions — GPU-accelerated, and upstream-tested on Jetson Orin under
JetPack 6.1, one minor version below ours.

Install on the Orin from the maintainer's PPA. JetPack 6.2 ships CUDA 12.6:

```bash
sudo apt install -y ros-humble-glim-ros-cuda12.6
```

Source builds require GTSAM 4.3a0 and gtsam_points, in that order.

Offline processing, which is what this phase needs:

```bash
ros2 run glim_ros glim_rosbag <bag>   # auto-throttles playback; no data drop
ros2 run glim_ros offline_viewer      # open /tmp/dump, inspect, refine, export
ros2 run glim_ros map_editor          # remove pedestrians and dynamic ghosts
```

The mapping pass is offline-quality on purpose: slow, batched, loop-closed. Its
accuracy is the ceiling for the tag map built in sub-phase C and for every
runtime correction in D.

#### Loop closure — which mechanism, and its limits

GLIM ships two global-mapping backends plus an extension, and they close loops in
materially different ways.

**`global_mapping` (default, GPU).** No place recognition. It finds submap pairs
by proximity and overlap, then adds direct matching-cost factors:

```json
// config/config_global_mapping_gpu.json
"max_implicit_loop_distance": 100.0,
"min_implicit_loop_overlap": 0.2
```

A loop closes whenever accumulated drift is still small enough that the two
submaps overlap by at least 20%. On a small indoor site with LiDAR-inertial
odometry, drift stays well inside that capture range, so this works. It fails
when drift exceeds the overlap range — multi-floor routes, or long featureless
runs returning from far away.

**`global_mapping_pose_graph` (CPU).** Classic pose graph with *explicit* loop
detection, VGICP-validated and robust-kernelled. Carries a trap for a small site:

```json
// config/config_global_mapping_pose_graph.json
"min_travel_dist": 50.0,
"max_neighbor_dist": 5.0
```

An indoor loop shorter than 50 m of travel generates no loop candidate at all.
If this backend is used, `min_travel_dist` must come down to match the site.

**`glim_ext` ScanContext loop detector.** Appearance-based explicit detection —
the genuine large-drift fallback. The DBoW variant in the same repo is
unmaintained.

**Manual loop closing** in `offline_viewer` lets constraints be added by hand.
The site is mapped once, so this is a legitimate safety net rather than a
workaround.

Recommended order: default GPU backend with implicit closure, inspected visually
in the offline viewer; manual constraints if a seam is visible; ScanContext only
if implicit closure demonstrably fails.

Note what loop closure does *not* provide: it makes the map self-consistent in a
relative sense. It says nothing about where the vehicle is in that map at t=0.
That is the board's job, and no improvement in closure quality changes it.

#### Intensity survives to the exported map

This matters because the board must be findable in the finished cloud:

```
config/config_sensors.json:62        "intensity_field": "intensity"
src/glim/preprocess/cloud_preprocessor.cpp:98    frame->add_intensities(...)
src/glim/mapping/global_mapping.cpp:652          export_intensities
src/glim/viewer/offline_viewer.cpp:249-261       PLY written with intensities
```

**The export is PLY, not PCD.** Autoware needs PCD, so a conversion step is
required and it must preserve the intensity field — `pcl_ply2pcd` keeps scalar
fields; Open3D silently drops intensity and must not be used for this step.

### 6.4 Anchor the cloud to the board

Implemented as `anchor_map_to_board` in `golfcart_board_initializer`:

```bash
ros2 run golfcart_board_initializer anchor_map_to_board glim_export.ply -o data/huaxia-indoor
```

It writes the anchored `pointcloud_map.pcd`, `board_anchor.yaml` (the transform,
so a rebuild can be checked against it), `board_polygon.osm`, and
`map_projector_info.yaml` with `projector_type: Local`. In the finished cloud:

1. Threshold on intensity to isolate retroreflective returns.
2. Cluster, then reject clusters whose planarity, dimensions, or height above
   ground do not match the board specification in §5.
3. Fit a plane and a bounding rectangle to the surviving cluster; take the
   centroid and the surface normal.
4. Compose the rigid transform of §4 and apply it to the whole cloud and to the
   SLAM trajectory.
5. Persist the transform.

Step 2 is not optional. See §8.

Two details the implementation settled:

- **The floor fit needs an inlier refit.** Fitting a plane to everything within
  0.3 m of the lowest points also catches wall bases and floor markings, whose
  centroid sits above the floor: the first fit came out 8.5 cm high and tilted,
  and the whole map inherits that. Refitting on points within 5 cm of the
  current plane pulls it onto the floor.
- **The map cloud needs different detector gates than a live scan.** Range is
  measured from an arbitrary origin rather than a sensor, and the density gate's
  expected return count assumes a single viewpoint. Both are disabled for
  anchoring; every geometric gate still applies, and those are what separate the
  board from the exit signage anyway.

### 6.5 Post-process and tile

- Convert the exported PLY to PCD, preserving intensity (§6.3).
- Voxel downsample at 0.2 m.
- Remove residual dynamic-object ghosts. GLIM's `map_editor` does this
  interactively — MinCut segmentation for objects, region growing for planes, a
  gizmo box for everything else — so this is GUI work rather than a script.
- **Keep the ceiling and walls.** Outdoor mapping habits favour stripping
  overhead structure; indoors, ceilings and walls are the geometry NDT relies on,
  and removing them manufactures the exact degeneracy this phase is trying to avoid.
- Tile with `autoware_pointcloud_divider`, producing the tiled PCD set and
  `pointcloud_map_metadata.yaml`.

### 6.6 Lanelet2 vector map

Cover the drivable indoor route, and add the board as a landmark polygon:
four vertices in counter-clockwise order, `type=pose_marker`,
`subtype=reflector`, with `local_x`, `local_y`, and `ele` tags. The polygon
format and vertex ordering rules are in
[lidar_marker_localization.md](../research/lidar_marker_localization.md).

Because the board is at the origin by construction, its polygon coordinates are
known exactly rather than surveyed — a useful self-check on the anchoring step
in §6.4.

---

## 7. Runtime cold start

The recommended runtime configuration is **NDT as the pose estimator, with the
board supplying only the initial pose**. NDT is what the rest of the stack
already expects, and indoor geometry — walls, corners, ceilings — is good NDT
terrain. Tracking is not the indoor problem. The initial guess is.

### 7.1 Why the upstream marker localizer cannot do this

`autoware_lidar_marker_localizer` is the obvious candidate and it does not fit.
It subscribes to `/localization/pose_twist_fusion_filter/biased_pose_with_covariance`
and gates detections on `limit_distance_from_self_pose_to_marker` and
`self_pose_timeout_sec` — that is, it associates a detection with a map marker
*using the pose that cold start does not yet have*. It is a tracking corrector,
not an initializer.

A dedicated node is therefore genuinely required for detection-based
initialization. Its job is easier than the upstream package's: one board, so
association is trivial and there are no marker IDs to disambiguate.

### 7.2 Staging

**Stage 0 — fixed user-defined pose. No new code.** With the board at the origin,
the parking pose is a known constant, and `autoware_pose_initializer` already
accepts one:

```yaml
# src/launcher/golfcart_launch/config/localization/pose_initializer.param.yaml:3
user_defined_initial_pose:
  enable: $(var user_defined_initial_pose/enable)
  pose: $(var user_defined_initial_pose/pose)
```

One wrinkle: `automatic_pose_initializer` is launched only when GNSS is enabled
(`cuda_ndt_matcher_launch/launch/cuda_localization.launch.xml:28,86`), so under
`gnss_enabled:=false` nothing calls `/localization/initialize` on startup. Either
launch it unconditionally, or issue one service call at startup.

Do this stage first. It validates the map, the NDT configuration, and the
no-GNSS launch path without simultaneously debugging a detector.

**Stage 1 — board pose initializer node.** Designed in
[board_pose_initializer.md](board_pose_initializer.md), tracked in
[3-indoor-e-board-initializer.md](../roadmaps/3-indoor-e-board-initializer.md).
Detect the board in the current scan, compute the vehicle pose, call
`/localization/initialize` with a `PoseWithCovarianceStamped`:

```
T_map←base_link = T_map←board ∘ (T_base_link←lidar ∘ T_lidar←board)⁻¹
```

`T_map←board` is identity by construction (§4), which is the payoff of anchoring
the map to the board. Detection must gate on planarity, size, and height band,
exactly as in §6.4 — the same false-positive population applies at runtime.

This removes the "park exactly here" requirement and is the version that
genuinely replaces GNSS initialization.

**Stage 2 — optional, only with more boards.** Mount two or three additional
boards in the corridors where sub-phase B's degeneracy characterisation shows NDT
is weakest, and enable `autoware_lidar_marker_localizer` as a *corrector* via
`pose_source:=ndt_lidar-marker`. Its upstream defaults assume a densely marked
corridor and need retuning for a VLP-32C:

| Parameter | Default | Indoor starting point | Reasoning |
|-----------|---------|----------------------|-----------|
| `vote_threshold_for_detect_marker` | 20 | 8–10 | The VLP-32C's 32 rings are non-uniformly spaced. A 1 m board at 10 m falls across roughly 10–17 rings; at 3 m it is comfortably covered. The default rejects valid detections at useful ranges. |
| `limit_distance_from_self_pose_to_marker` | 2.0 | 8–10 | 2 m is a tracking-refinement range, not an acquisition range. |
| `limit_distance_from_self_pose_to_nearest_marker` | 2.0 | matched to the above | Same reasoning. |
| `intensity_pattern` | `[-1,-1,0,1,1,1,1,1,0,-1,-1]` | keep, given the §5 matte margin | The pattern presumes low-intensity flanks; the board's margin supplies them. |

Only at this stage does the upstream package earn its place.

### 7.3 Everything else that must change with it

The initializer is the only new *code*. It is not the only change:

| Change | Where | Why |
|--------|-------|-----|
| `projector_type: Local` | indoor map `map_projector_info.yaml` | §4. Copying the outdoor map's `TransverseMercator` config is a silent-failure path. |
| `gnss_enabled:=false` | launch | Otherwise the initializer waits on a GNSS pose that never arrives. |
| Repoint `input_regularization_pose_topic` | `cuda_localization.launch.xml:49`, hardcoded to `/sensing/gnss/pose_with_covariance` | Harmless while `regularization.enable: false`, but lands the moment corridor degeneracy forces regularization on. |
| Detection gating | initializer node | Intensity thresholding alone finds exit signage, safety vests, and floor tape (§8). |

---

## 8. Failure modes

**Retroreflector blooming.** Velodyne returns from 3M sheeting saturate the
receiver and produce a halo of spurious points around the panel, with the panel's
measured range inflated by a few centimetres. Consequences: keep planned paths
outside roughly 2 m of the board, and expect a small constant bias. The bias is
largely common to the mapping pass and the runtime pass, so it partially cancels
in the map-relative pose — but it does not cancel in the map's absolute geometry.

**False positives from other retroreflectors.** Indoor sites are full of them:
exit signage, fire equipment markings, safety vests, license plates, floor tape.
Intensity thresholding alone will find all of them. Detection must gate on
planarity, physical dimensions, and height band, per §6.4 step 2. This applies to
the offline anchoring step *and* to the runtime detector.

**Yaw ambiguity.** Addressed by specifying a rectangular rather than square face
(§5). If a square board is used anyway, an asymmetric tape pattern on the face is
required to break the symmetry.

**Board displacement between mapping and runtime.** Addressed in §4.

**Projector type mismatch.** Addressed in §4.

---

## 9. Acceptance criteria

- A tiled PCD map and a Lanelet2 map of the indoor route exist, with
  `projector_type: Local`.
- The map origin coincides with the board's face centroid, and the
  cloud→map transform is stored with the map.
- The board's Lanelet2 polygon coordinates agree with its physical dimensions
  about the origin, within a documented tolerance.
- The exported cloud reaches PCD with its intensity field intact, so the board is
  visible in the delivered map.
- NDT converges from the §7 stage 0 fixed start pose and tracks the full route in
  `logging_simulation` replay, with no GNSS in the pipeline.
- NDT degeneracy is characterised per corridor and handed to sub-phase C as tag
  placement guidance, per
  [3-indoor-b-indoor-mapping.md](../roadmaps/3-indoor-b-indoor-mapping.md).

---

## 10. Open questions

**Number of boards.** This design assumes one, and scopes it to origin anchoring
plus cold start accordingly. Adding two or three more along the route would let
`autoware_lidar_marker_localizer` bound drift in the corridors where NDT is
weakest, at the cost of permanent mounting in each location. Worth revisiting
once sub-phase B's degeneracy characterisation shows where the weak corridors
actually are.

**Reflector versus AR tag for drift bounding.** The AR-tag design deferred
reflectors because the deployment model called for per-session removable markers
(see that design's §10). A permanently mounted board changes that premise. If the
indoor site permits permanent infrastructure, reflectors are lighting-independent
and share the LiDAR the vehicle already depends on. The two share the
`autoware_landmark_manager` abstraction, so supporting both is additive.

**Anchoring tooling.** Whether §6.4 is a small offline Python script over the
finished PCD or a ROS node replaying the bag is undecided. The script is simpler;
the node reuses the §7 stage 1 detector and therefore validates it. Sharing the
detection code between the offline anchoring step and the runtime initializer is
attractive — the two solve the same geometry problem — but it couples an offline
tool to a runtime node's build.

**GLIM version pinning.** GLIM is under active development; the PPA tracks
releases and the config schema has changed across versions (the GTSAM base
version changed in 2025/06). The map build should record the GLIM version and the
config directory used, so a rebuild is reproducible.

**Validation blocker.** NDT needs wheel velocity from the Turing Drive DBW
package; `velocity_report.py` still publishes zeros. Map construction (§6.1–6.6)
is unaffected and can proceed. Validation (§9) cannot.
