# Phase 3B — Indoor Mapping

Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 B](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#b--indoor-mapping-contract-for-d)
Mapping method: [indoor_pcd_mapping_reflector_anchor.md](../design/indoor_pcd_mapping_reflector_anchor.md)

**Status: Not started — blocked by DBW; blocks sub-phases C and D**

Last updated: 2026-08-11

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
- GNSS is threaded through the localization stack in several places that must be
  switched off together — `pose_initializer.param.yaml` has `gnss_enabled`, and
  the cuda_ndt launch hardcodes the NDT regularization input to
  `/sensing/gnss/pose_with_covariance`:

  ```xml
  <!-- cuda_ndt_matcher_launch/launch/autoware_localization.launch.xml:39 -->
  <arg name="input_regularization_pose_topic" value="/sensing/gnss/pose_with_covariance"/>
  ```

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
that the board's face centroid is the origin and its surface normal is +X. This
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
      everything downstream. GLIM exports PLY — convert to PCD with the
      intensity field preserved.
- [ ] **Anchor the cloud to the board** — detect the board by intensity, gate on
      planarity/size/height, transform the cloud so the board is the origin, and
      store the transform with the map.
- [ ] **Build the Lanelet2 vector map** covering the drivable indoor route, with
      the board as a `pose_marker` / `reflector` polygon.
- [ ] **Set `projector_type: Local`** in the indoor map's
      `map_projector_info.yaml`. Copying the outdoor map's `TransverseMercator`
      config is a silent-failure path.
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

- `input_regularization_pose_topic` remains hardcoded to
  `/sensing/gnss/pose_with_covariance` at `cuda_localization.launch.xml:49` and
  `autoware_localization.launch.xml:39`. Harmless while
  `ndt_scan_matcher.param.yaml` has `regularization.enable: false`, and a
  correctness bug the moment corridor degeneracy forces it on.
- `golfcart_system_monitor` still monitors five GNSS topics
  (`config/monitor_topics.yaml:10-15`), so an indoor run will show them all as
  failed. Cosmetic, but it trains operators to ignore the monitor.
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
