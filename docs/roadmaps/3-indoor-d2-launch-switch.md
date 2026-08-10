# Phase 3D-2 — Launch switch

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §4.4, §9

**Depends on**: D1 (package names only — stub nodes are fine here).
**Blocks**: D6.

---

## Goal

`pose_source:=aruco` brings up the ArUco localization stack and brings up
**nothing** related to scan matching. Stub nodes are acceptable throughout this
phase; what is being built and tested is the wiring, not the algorithm.

The acceptance test is as much about what is *absent* from `ros2 node list` as
what is present.

---

## Two findings that shape the work

**1. Copy the `cuda_ndt` pattern, do not extend upstream's.**
`tier4_localization_launch`'s pose_twist_estimator parses `pose_source` against
a fixed list — `['ndt','yabloc','eagleye','artag','lidar-marker']` — and
silently drops unknown tokens. Adding `aruco` there means patching an upstream
package. But `tier4_localization_component.launch.xml:12` already shows the
alternative: the `cuda_ndt` group bypasses `tier4_localization_launch` entirely
and includes its own stack. **The `aruco` group does the same.** No upstream
package is touched.

**2. The pointcloud map loader cannot be switched off from above.**
`tier4_map_launch/launch/map.launch.xml` composes
`autoware::map_loader::PointCloudMapLoaderNode` unconditionally — there is no
`use_pointcloud_map` argument to set false. `golfcart_autoware.launch.xml:90`
includes `tier4_map_component.launch.xml`, which includes that file. So a
golfcart-owned map component is required, bringing up only `lanelet2_map_loader`
and `map_projection_loader`.

Watch `map_tf_generator` while doing this — it derives its TF from the point
cloud, so it goes away with the PCD. Check whether anything downstream (RViz
viewer frame, planning) depends on the frame it publishes before dropping it.

---

## Tasks

### The `aruco` branch

- [ ] Add an `aruco` group to
      `src/launcher/golfcart_launch/launch/components/tier4_localization_component.launch.xml`,
      structured like the existing `cuda_ndt` group, that brings up:
      - three `aruco_detector` instances (left, right, rear) with per-camera
        remaps and frame IDs
      - one `golfcart_aruco_localizer`
      - `gyro_odometer` and `ekf_localizer`
      - `pose_initializer` (see the open decision below)
- [ ] Adjust the two existing groups so the `aruco` case does not fall through
      into the `unless cuda_ndt` branch. The current condition is a binary split;
      it needs to become a three-way selection.
- [ ] `config/localization/preset/aruco_preset.yaml`, following the existing
      `*_preset.yaml` naming convention (CLAUDE.md:259).

### Map component

- [ ] New `launch/components/golfcart_map_component.launch.xml` bringing up
      `lanelet2_map_loader` + `map_projection_loader` only.
- [ ] Switch `golfcart_autoware.launch.xml:90` to it when the pose source is
      `aruco`, or gate on a new `use_pointcloud_map` argument.
- [ ] Resolve `map_tf_generator` — keep, replace with a static transform, or drop.

### Parameters that must change

- [ ] `pose_initializer.param.yaml`: `ndt_enabled: false`, `gnss_enabled: false`.
- [ ] `ekf_localizer.param.yaml`: restore `pose_gate_dist` from its current
      `10000.0`. Upstream's default is `49.5`. **With one pose source this gate is
      the only remaining defence against a bad fix** — the value can be tuned
      later, but it must not stay disabled.
- [ ] Review `localization_error_monitor` and `pose_instability_detector`. Both
      are shaped around a scan-matching convergence signal that no longer exists.
      Retune, replace, or exclude — but decide deliberately rather than leaving
      them running against a signal they will never see.

### Dead arguments

`use_gnss`, `use_mapless_mode`, `lidar_model`, `camera_model`, `imu_source`,
`gnss_receiver`, `use_ntrip` and `sensor_suite` are all declared in
`golfcart.launch.yaml`, passed down, and consumed by nothing.

- [ ] Wire `use_mapless_mode` — it is now conceptually what this system runs in.
- [ ] Either wire or delete the rest. Leaving arguments that look like they work
      but do nothing is how the July design ended up assuming GNSS could be
      disabled by setting `use_gnss:=false`, which it cannot.

---

## Acceptance

Run `just launch pose_source:=aruco` with stub nodes and check `ros2 node list`.

**Present**: three `aruco_detector`, `golfcart_aruco_localizer`,
`gyro_odometer`, `ekf_localizer`, `pose_initializer`, `lanelet2_map_loader`,
`map_projection_loader`.

**Absent** — this is the part worth automating as a test:
`ndt_scan_matcher`, `cuda_ndt_matcher`, `pointcloud_map_loader`, the NDT
pointcloud preprocessing chain (crop box, voxel grid, random downsample),
`autoware_ar_tag_based_localizer`, `autoware_landmark_manager`,
`pose_estimator_arbiter`.

Also verify `pose_source:=ndt` and `pose_source:=cuda_ndt` still launch
unchanged — the three-way split is the easiest thing here to break silently.

---

## Open decision

**Keep `pose_initializer` in the chain, or publish `/initialpose3d` directly?**

With no NDT there is nothing to refine the seed against, so `pose_initializer`
becomes close to a passthrough and the localizer could publish `/initialpose3d`
itself. Direct is simpler. Keeping it preserves the AD API localization
initialization state.

Check what consumes `/api/localization/initialization_state` before cutting it
out — planning and the system monitor may be watching it, and a missing state
machine tends to surface as a vehicle that will not engage rather than as an
obvious error.
