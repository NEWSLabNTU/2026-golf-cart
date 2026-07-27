# Phase 3B — Indoor Mapping

Prerequisite for [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 B](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#b--indoor-mapping-contract-for-d)

**Status: Not started — blocked by DBW; blocks sub-phases C and D**

Last updated: 2026-07-27

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

## Tasks

### Not done

- [ ] **Choose the indoor site** and confirm vehicle access, lighting, and route.
- [ ] **Record a mapping rosbag** — VLP-32C + xsens IMU + all three cameras.
      Record cameras even though mapping does not need them: sub-phase C replays
      this same bag to bootstrap the tag map, so tags should already be in place
      during this drive.
- [ ] **Build the PCD map** — offline LiDAR SLAM. Slow, batched, loop-closed;
      this is the accuracy ceiling for everything downstream.
- [ ] **Build the Lanelet2 vector map** covering the drivable indoor route.
- [ ] **Define and record the map origin** — no GNSS means no automatic
      georeferencing; the map frame origin must be chosen and documented.
- [ ] **Validate NDT indoors** — replay through `logging_simulation`, seed with a
      manual RViz "2D Pose Estimate", confirm convergence and tracking.
- [ ] **Characterize NDT degeneracy** — identify which corridors NDT slides along.
      This directly drives tag placement in sub-phase C: tags go where NDT is weak,
      not where they are convenient to hang.
- [ ] **Verify no GNSS dependency remains** — `use_gnss:=false` end to end,
      `gnss_enabled: false` in `pose_initializer.param.yaml`, and the NDT
      regularization input repointed.

### Can do before DBW lands

- [ ] Site selection, mapping run, PCD and Lanelet2 construction — all offline.
- [ ] GNSS-dependency audit of the launch tree.

---

## Acceptance criteria

- PCD + Lanelet2 map of the indoor route exists, with a documented map origin.
- NDT converges from a manual seed and tracks the full route in replay, with no
  GNSS in the pipeline.
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
