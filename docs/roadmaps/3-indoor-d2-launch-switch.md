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

- [x] Add an `aruco` group to
      `src/launcher/golfcart_launch/launch/components/tier4_localization_component.launch.xml`,
      structured like the existing `cuda_ndt` group, that brings up:
      - three `aruco_detector` instances (left, right, rear) with per-camera
        remaps and frame IDs
      - one `golfcart_aruco_localizer`
      - `gyro_odometer` and `ekf_localizer`
      - `pose_initializer` (see the open decision below)
- [x] Adjust the two existing groups so the `aruco` case does not fall through
      into the `unless cuda_ndt` branch. The current condition is a binary split;
      it needs to become a three-way selection.
- [x] `config/localization/preset/aruco_preset.yaml`, following the existing
      `*_preset.yaml` naming convention (CLAUDE.md:259).

### Map component

- [x] New `launch/components/golfcart_map_component.launch.xml` bringing up
      `lanelet2_map_loader` + `map_projection_loader` only.
- [x] Switch `golfcart_autoware.launch.xml:90` to it when the pose source is
      `aruco`, or gate on a new `use_pointcloud_map` argument.
- [x] Resolve `map_tf_generator` — keep, replace with a static transform, or drop.

### Parameters that must change

- [x] `pose_initializer.param.yaml`: `ndt_enabled: false`, `gnss_enabled: false`.
- [x] `ekf_localizer.param.yaml`: restore `pose_gate_dist` from its current
      `10000.0`. Upstream's default is `49.5`. **With one pose source this gate is
      the only remaining defence against a bad fix** — the value can be tuned
      later, but it must not stay disabled.
- [x] Review `localization_error_monitor` and `pose_instability_detector`. Both
      are shaped around a scan-matching convergence signal that no longer exists.
      Retune, replace, or exclude — but decide deliberately rather than leaving
      them running against a signal they will never see.

### Dead arguments

`use_gnss`, `use_mapless_mode`, `lidar_model`, `camera_model`, `imu_source`,
`gnss_receiver`, `use_ntrip` and `sensor_suite` are all declared in
`golfcart.launch.yaml`, passed down, and consumed by nothing.

- [ ] Wire `use_mapless_mode` — it is now conceptually what this system runs in.
- [x] Either wire or delete the rest. Leaving arguments that look like they work
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

## Health and diagnostics integration

Three gaps closed. Each was of the same kind: something that looked wired and
was not, so the failure would have been silence rather than an error.

### The localizer now publishes `/diagnostics`

`~/status` is the human-readable channel; `/diagnostics` is the one that can
stop the vehicle, because `diagnostic_graph_aggregator` consumes it and rolls it
into `HazardStatus`, which drives the MRM. The state machine was computing
`request_mrm`, logging it, and reaching nothing.

Levels, chosen so the vehicle is not stopped for conditions it is designed to
drive through:

| state | level |
|---|---|
| NOMINAL | OK |
| DEGRADED, in-budget DEAD_RECKONING, UNINITIALIZED | WARN |
| FAULT (expired budget or failed integrity) | ERROR |

Verified end to end by blacking out the sim detector: the status goes
DEAD_RECKONING, the budget expires, and `/diagnostics` reports
`level: 2` with `FAULT: fault latched; needs an explicit reset` under the name
`aruco_localizer: aruco_localization_status`. That name was read off a running
node rather than assumed — the graph has to match it exactly.

`bench_sim.launch.xml` gained a `blackout` argument to drive that path.

### The diagnostic graph no longer demands a scan matcher

Upstream's `localization.yaml` gates `/autoware/localization` on
`ndt_scan_matcher: scan_matching_status`. There is no scan matcher on this path,
so that diagnostic never publishes and the whole localization subtree sits
stale — reporting a fault while the vehicle localizes perfectly, and reporting
exactly the same thing when it does not.

`config/system/diagnostics/localization-aruco.yaml` replaces that one link with
the ArUco status. `autoware-main-aruco.yaml` is a verbatim copy of upstream's
graph with only the localization include swapped; every other section is pulled
from `autoware_launch` rather than from `$(dirname)`, deliberately — see below.
Both validated with `ros2 run autoware_diagnostic_graph_aggregator tree`.

The error monitor's `accuracy` link is deliberately **not** in the gating list.
Its ellipse thresholds were chosen for a LiDAR pose source, this repo already
records that they caused false MRM stops, and ArUco covariance has a different
shape — it saturates in unobservable directions by design. It publishes and is
observable; move it into the list once 3D-7 supplies measured thresholds.

### Two pre-existing bugs found on the way, neither ArUco-specific

- **`diagnostic_graph_aggregator_graph_path` was declared and never passed.**
  `golfcart_autoware.launch.xml` declared the argument at line 43 and included
  `tier4_system_component.launch.xml` with no arguments at all, so the aggregator
  used its own upstream default and the argument did nothing. Now forwarded, and
  switched to the ArUco graph when `pose_source:=aruco`.

- **This repo's `config/system/diagnostics/*.yaml` are dead files.** They differ
  from upstream deliberately — the `/adapi/mrm_request/delegate` links are
  removed, and `localization.yaml` disables the accuracy check with a comment
  explaining why — but nothing has ever loaded them, so none of those decisions
  has taken effect. **Left as-is on purpose.** Making them live would change
  behaviour for every pose source, including removing MRM delegate gating, and
  that is a safety-relevant decision that should be made deliberately rather
  than as a side effect of this work. `autoware-main-aruco.yaml` therefore
  references upstream for everything except localization.

### The two health monitors now run on this branch

`localization_error_monitor` and `pose_instability_detector` live inside
`tier4_localization_launch`, which this branch bypasses, so neither was running.
Both are pose-source agnostic — the error monitor reads only
`/localization/kinematic_state`, the instability detector compares filter output
against dead reckoning — so there was no reason for ArUco to go without them.

### Also fixed: the ArUco launch files were not well-formed XML

`--` is illegal inside an XML comment, and both `aruco_localization.launch.xml`
(from phase 3D-5) and the new block in `golfcart_autoware.launch.xml` contained
it. The 3D-5 file would have failed to parse at launch. Every launch file in
`golfcart_launch` and the localization packages is now checked well-formed.

## Bookkeeping

Ticked above: implemented and verified by running the full
`golfcart.launch.yaml` with `pose_source:=aruco` (151 nodes, no exceptions, NDT
stack absent, tag map loaded).

Still open, and why:

- **Wire `use_mapless_mode`.** The argument is declared and forwarded from
  `golfcart.launch.yaml`, but nothing on the ArUco path consumes it. Deciding
  what it should mean when ArUco *is* the localization needs a call: it
  currently reads as "run without localization", which is no longer the only
  alternative to a point cloud map.

`map_tf_generator` is resolved as **dropped**, with the reasoning recorded in
`golfcart_map_component.launch.xml`: it derives its transform from the point
cloud, and there is no point cloud on this path.

Dead launch arguments are now checked mechanically rather than by eye:
`just audit-launch`. Two of mine were found and fixed; three more live in the
`golfcart_sensor_kit_launch` submodule and are reported there rather than
changed cross-repo.
