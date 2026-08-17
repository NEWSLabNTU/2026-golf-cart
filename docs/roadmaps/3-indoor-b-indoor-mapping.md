# Phase 3B — Indoor Mapping

> **SUPERSEDED 2026-08-10 — this sub-phase is deleted.**
>
> Board poses are now measured by hand and supplied as data, and NDT is not used
> at all, so neither the point cloud map nor the NDT-bootstrapped tag map is
> needed. See [3-indoor-localization.md](3-indoor-localization.md) and the
> [current spec](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md).
> Kept for history only — do not plan work from the content below.

---


Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 B](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#b--indoor-mapping-contract-for-d)
Mapping method: [indoor_pcd_mapping_reflector_anchor.md](../design/indoor_pcd_mapping_reflector_anchor.md)

Last updated: 2026-08-17 (superseded)

---

## Goal

Produce an indoor PCD point cloud map plus Lanelet2 vector map, and demonstrate
that NDT converges and tracks on it **with no GNSS anywhere in the pipeline**.

Independent of [sub-phase A](3-indoor-a-camera-calibration.md) — the two can run
in parallel.

---

## Current state

- No indoor map exists. `data/` holds the COSS practice map and the 華夏科大
  campus map slot, both outdoor.
- NDT has never been validated indoors on this vehicle.
- GNSS threading through localization is **fixed**: `gnss_enabled` now follows
  `use_gnss`. See the audit below for what it was doing before, and for the two
  GNSS dependencies that remain — the hardcoded NDT regularization topic and the
  system monitor's GNSS entries.

---

## Blocker

**Turing Drive DBW package.** `velocity_report.py` is a stub publishing zero
velocity. NDT needs wheel velocity for twist estimation; without it, NDT cannot
be validated on any map, indoor or outdoor. See [2-track-b.md](2-track-b.md).

This blocks the validation half of this sub-phase, not the mapping half — a
mapping run can be recorded and processed offline before DBW lands.

---

## Mapping method: reflector-anchored origin

The map origin problem below has a chosen answer. A single retroreflective board
is mounted permanently at the site; the finished map is rigidly transformed so
that the origin sits on the floor below the board's face centre, with its surface
normal as +X. This
makes the origin physically re-findable every session, and lets cold start
replace the manual RViz seed with a fixed parking position — or, later, with
`autoware_lidar_marker_localizer`.

The board is an **anchor, not a localizer**: it defines the origin and the start
pose. It does not bound NDT drift away from the entrance, and it is not used as
a SLAM loop closure feature — indoor geometric loop closure on walls and corners
is stronger than one 0.8 m panel.

Full method, board specification, detector retuning, and failure modes:
[indoor_pcd_mapping_reflector_anchor.md](../design/indoor_pcd_mapping_reflector_anchor.md).

---

## Tasks

### Not done

- [ ] **Choose the indoor site** and confirm vehicle access, lighting, and route.
- [ ] **Mount the reflective board** — rectangular (not square) 3M retroreflective
      face with a matte margin, permanently fixed, floor footprint marked. See
      the design doc §5.
- [ ] **Record a mapping rosbag** — VLP-32C + xsens IMU + all three cameras.
      Record `/sensing/lidar/top/pointcloud_raw_ex` specifically: intensity and
      per-point time are both needed. Record cameras even though mapping does not
      need them: sub-phase C replays this same bag to bootstrap the tag map, so
      tags should already be in place during this drive.
- [ ] **Build the PCD map** — offline LiDAR SLAM with GLIM
      (`ros2 run glim_ros glim_rosbag`, then `offline_viewer` to inspect and
      refine). Slow, batched, loop-closed; this is the accuracy ceiling for
      everything downstream. GLIM exports PLY; `anchor_map_to_board` reads it
      directly and writes PCD with the intensity field preserved.
- [ ] **Anchor the cloud to the board** — run `anchor_map_to_board` on the GLIM
      export. The tool exists and is tested; this task is running it on the real
      cloud and checking the reported extents and plane residual look sane.
- [ ] **Build the Lanelet2 vector map** covering the drivable indoor route, with
      the board as a `pose_marker` / `reflector` polygon.
- [ ] **Confirm `projector_type: Local`** in the indoor map's
      `map_projector_info.yaml`. `anchor_map_to_board` writes it; the task is not
      overwriting it with a copy of the outdoor map's `TransverseMercator`
      config, which is a silent-failure path.
- [ ] **Validate NDT indoors** — replay through `logging_simulation`, seed from
      the board-derived fixed start pose via `user_defined_initial_pose` (manual
      RViz seed as fallback), confirm convergence and tracking. A board *detector*
      is not needed for this: see design §7 stage 0.
- [ ] **Characterize NDT degeneracy** — identify which corridors NDT slides along.
      This directly drives tag placement in sub-phase C: tags go where NDT is weak,
      not where they are convenient to hang.
- [ ] **Verify no GNSS dependency remains** — `use_gnss:=false` end to end,
      `gnss_enabled: false` in `pose_initializer.param.yaml`, and the NDT
      regularization input repointed.

### Can do before DBW lands

- [ ] Site selection, board mounting, mapping run, PCD and Lanelet2 construction,
      board anchoring, projector config — all offline.
- [x] GNSS-dependency audit of the launch tree. **Done, and it found a real
      defect — see below.**
- [x] Indoor mapping bag recording script: `just bag-record-indoor`
      (`scripts/rosbag/record_indoor_mapping.sh`).
- [x] **Anchoring tool** — `ros2 run golfcart_board_initializer
      anchor_map_to_board <cloud> -o <map dir>`. Finds the board in a finished
      SLAM cloud, transforms the cloud so the board defines the map frame, and
      writes the anchored PCD, the transform, the board's Lanelet2 polygon, and
      a `projector_type: Local` projector file. Tested against synthetic map
      clouds built from several sensor poses in an arbitrary source frame.
- [x] **PLY to PCD conversion with intensity preserved** — GLIM exports PLY
      (field named `scalar_intensity`), Autoware wants PCD, and Open3D drops the
      channel silently. Handled by `pointcloud_io.py` inside the anchoring tool.

---

## GNSS-dependency audit

Done 2026-08-13, by tracing `use_gnss` through the launch tree.

**`use_gnss:=false` did not reach localization at all.** It is threaded from
`golfcart.launch.yaml` into sensing, so the GNSS driver stops — but
`golfcart_autoware.launch.xml:107` included the localization component with no
arguments, and `tier4_localization_component.launch.xml` never mentioned
`gnss_enabled`. Both localization stacks therefore kept the upstream default:

```xml
<!-- cuda_ndt_matcher_launch/launch/cuda_localization.launch.xml:28 -->
<arg name="gnss_enabled" default="true" .../>
<!-- tier4_localization_launch/launch/pose_twist_estimator/pose_twist_estimator.launch.xml:9 -->
<arg name="gnss_enabled" default="true" .../>
```

Two consequences indoors, neither of which announces itself:

1. `pose_initializer` runs with `gnss_enabled: true` and waits on a GNSS pose
   that will never arrive.
2. `automatic_pose_initializer` launches and asks for initialization from that
   same absent source, racing whatever else supplies the initial pose.

**Fixed** by declaring `gnss_enabled` in
`tier4_localization_component.launch.xml`, defaulting it to `$(var use_gnss)`,
and passing it into both the CUDA NDT and the standard Autoware branch. Verified
with a standalone launch-file pair: under `use_gnss:=false` the gated group does
not launch, under `use_gnss:=true` it does.

This also answers the open integration question in
[phase 3E](3-indoor-e-board-initializer.md): indoors `automatic_pose_initializer`
does not run, so the board initializer is the cold-start trigger rather than a
competitor to it.

### Still outstanding from the audit

- ~~`input_regularization_pose_topic` hardcoded to the GNSS topic.~~ **Fixed**:
  it is now a `regularization_pose_topic` argument on both cuda_ndt launch files
  and on the localization component, still defaulting to the GNSS topic so
  outdoor behaviour is unchanged. Verified the value threads through the include
  chain.

  Two caveats that outlive the fix. Indoors the replacement must be a
  **tag-only** pose — the merged pose that feeds the EKF would re-enter NDT
  whose output re-enters the EKF, and the loop is invisible from either end. And
  only the `cuda_ndt` branch honours the argument: the standard Autoware branch
  reaches the setting through `tier4_localization_launch`, which hardcodes the
  GNSS topic in its own `ndt_scan_matcher.launch.xml`, so with `pose_source:=ndt`
  indoors regularization must stay disabled until that is forked.
- ~~The system monitor watches five GNSS topics regardless.~~ **Fixed**: its
  `monitor_gps` parameter now defaults to `$(var use_gnss)`, and the launches
  that include it pass `use_gnss` through. An explicit `monitor_gps:=true` still
  wins. Verified all three cases.

  Fixing it surfaced a worse bug alongside. Both `logging_simulation.launch.yaml`
  and `sensor_only.launch.yaml` included
  `$(find-pkg-share golfcart_system_monitor)/launch/golfcart_system_monitor.launch.yaml`,
  but the package is still named `autosdv_system_monitor` and so is its launch
  file — a leftover from the rename. `find-pkg-share` raises on an unknown
  package, so both launches would have died at that include, unconditionally.
  `logging_simulation` is the file this sub-phase needs for NDT validation, so
  this would have been discovered at the worst moment. Both references now point
  at the real package; the rename itself belongs to
  [0-autosdv-to-golfcart-rename.md](0-autosdv-to-golfcart-rename.md).
- `data/COSS-map-planning/map_projector_info.yaml` uses `TransverseMercator`.
  The indoor map needs `projector_type: Local` — copying the outdoor file is the
  silent-failure path.

---

## Acceptance criteria

- PCD + Lanelet2 map of the indoor route exists, with `projector_type: Local` and
  the map origin at the board's face centroid.
- The cloud→map anchoring transform is stored with the map, so a rebuild from the
  same bag can be checked against it.
- NDT converges from the board-derived fixed start pose and tracks the full route
  in replay, with no GNSS in the pipeline.
- NDT degeneracy characterized per corridor, written up, and handed to sub-phase C
  as tag placement guidance.

---

## Why the accuracy of this sub-phase matters more than it looks

Sub-phase C derives tag poses from this map's NDT trajectory. Sub-phase D then
uses those tags to correct runtime NDT against the same map. So map error
propagates into tag error and the two are correlated — a poor map produces a
tag map that agrees with the poor map, and the failure presents at runtime as a
tag problem rather than a map problem.

Take the time here. It is cheaper than debugging it in D.


---

## What survives the deletion

The mapping run, the PCD map, the Lanelet2 route and the NDT validation are all
gone with the sub-phase. Three things built along the way are independent of it
and stay:

- **The GNSS-dependency fixes.** `gnss_enabled` following `use_gnss`, and the
  regularization topic becoming an argument, were about the launch tree rather
  than about mapping. The first still matters: any GNSS-denied operation needs
  it, ArUco or not. The second is now moot in the same way NDT is — kept because
  a hardcoded topic is wrong regardless.
- **The system monitor following `use_gnss`.** Same reasoning, and it is what
  turned up the broken monitor include that would have killed
  `logging_simulation`.
- **`just bag-record-indoor`.** Records LiDAR, IMU and all three cameras. Phase
  3D-7 has its own `record_aruco.sh` for its purposes; this one remains the
  recipe for a run that also wants LiDAR.

Two are **dormant, not dead**: `anchor_map_to_board` and the intensity-preserving
PLY↔PCD conversion in `golfcart_board_initializer`. They only matter if a point
cloud map is ever wanted again — for perception, for a NDT second opinion, or if
the ArUco-only architecture is revisited. They are tested and self-contained, so
that decision stays cheap.
