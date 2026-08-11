# Indoor PCD Map Creation with a Reflector-Anchored Origin — Design

**Status**: Draft, pending review
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

- **Origin** — the centroid of the board's reflective face.
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

### 6.3 Offline LiDAR-inertial SLAM

VLP-32C at 10 Hz with the xsens IMU. Candidates, in rough order of preference:

- **GLIM** — GPU-accelerated, built-in loop closure, well suited to the Orin.
- **FAST-LIO2 + `interactive_slam`** — FAST-LIO2 for the odometry pass,
  `interactive_slam` to add loop closure constraints and correct drift by hand.
  The manual step is appropriate here because the site is small and mapped once.
- **LIO-SAM** — loop closure built in, but expects a 9-axis IMU.

The mapping pass is offline-quality on purpose: slow, batched, loop-closed. Its
accuracy is the ceiling for the tag map built in sub-phase C and for every
runtime correction in D.

### 6.4 Anchor the cloud to the board

In the finished cloud:

1. Threshold on intensity to isolate retroreflective returns.
2. Cluster, then reject clusters whose planarity, dimensions, or height above
   ground do not match the board specification in §5.
3. Fit a plane and a bounding rectangle to the surviving cluster; take the
   centroid and the surface normal.
4. Compose the rigid transform of §4 and apply it to the whole cloud and to the
   SLAM trajectory.
5. Persist the transform.

Step 2 is not optional. See §8.

### 6.5 Post-process and tile

- Voxel downsample at 0.2 m.
- Remove residual dynamic-object ghosts.
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

Two options. Implement the first, upgrade to the second if the accuracy is
insufficient.

**Option 1 — fixed start pose.** Park the vehicle at a marked position facing
the board and publish a constant initial pose; NDT converges from there. No new
code, and the board-at-origin frame makes the constant exact rather than
approximate. This should be the first thing tried, because it validates the map
and the NDT configuration without also debugging a detector.

**Option 2 — `autoware_lidar_marker_localizer`.** Real detection, launched via
`pose_source:=lidar-marker` or `pose_source:=ndt_lidar-marker`. The upstream
defaults assume a corridor densely populated with markers and need retuning for
a single board and a VLP-32C:

| Parameter | Default | Indoor single-board starting point | Reasoning |
|-----------|---------|-----------------------------------|-----------|
| `vote_threshold_for_detect_marker` | 20 | 8–10 | The VLP-32C's 32 rings are non-uniformly spaced. A 1 m board at 10 m falls across roughly 10–17 rings; at 3 m it is comfortably covered. The default rejects valid detections at useful ranges. |
| `limit_distance_from_self_pose_to_marker` | 2.0 | 8–10 | 2 m is a tracking-refinement range, not an acquisition range. Cold start needs to see the board from the parking position. |
| `limit_distance_from_self_pose_to_nearest_marker` | 2.0 | matched to the above | Same reasoning. |
| `intensity_pattern` | `[-1,-1,0,1,1,1,1,1,0,-1,-1]` | keep, given the §5 matte margin | The pattern presumes low-intensity flanks; the board's margin supplies them. |

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
- NDT converges from the fixed start pose of §7 Option 1 and tracks the full
  route in `logging_simulation` replay, with no GNSS in the pipeline.
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
the node reuses the runtime detector and therefore validates it.

**Validation blocker.** NDT needs wheel velocity from the Turing Drive DBW
package; `velocity_report.py` still publishes zeros. Map construction (§6.1–6.6)
is unaffected and can proceed. Validation (§9) cannot.
