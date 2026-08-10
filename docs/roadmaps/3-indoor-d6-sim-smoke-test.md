# Phase 3D-6 — Simulation smoke test

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §10

**Depends on**: D1, D2, D3, D4. (D5 not required — this path is synthetic.)

---

## Goal

Run the whole localization stack against synthetic detections and confirm it
holds together: the launch switch brings up the right nodes, the localizer
tracks, the EKF accepts its poses, and the state machine responds correctly to
injected faults.

This is a smoke test, not an accuracy validation. Accuracy against real optics
comes from D7's rosbags and, ultimately, the vehicle.

---

## Two stages

### Stage 1 — scripted trajectory, no Autoware simulator

The fast loop. D3's scripted pose publisher drives synthetic detections into the
localizer; the EKF fuses; compare `/localization/kinematic_state` against the
script's ground truth.

- [ ] Launch profile wiring D2's `pose_source:=aruco` stack with `aruco_sim_detector`
      substituted for the three real detectors.
- [ ] Straight line, circle, and corridor-with-corner paths.
- [ ] Automated error report: lateral, longitudinal and heading error against
      ground truth.

Runs in seconds, needs no map and no simulator, and catches nearly everything.
Most of D4's development should happen against this.

### Stage 2 — Autoware planning simulator

The fuller loop, exercising the parts stage 1 skips: the real launch graph, the
map loaders, planning and control consuming the fused pose, and the MRM path.

- [ ] **Resolve the topic conflict first.** `simple_planning_simulator` publishes
      `/localization/kinematic_state` itself — that is exactly the topic our chain
      is supposed to produce. Remap the simulator's output to
      `/simulation/ground_truth/kinematic_state` so the real topic stays free for
      the EKF, and feed `aruco_sim_detector` from the ground-truth topic.
- [ ] A tag map placed against the simulated environment, and a route.
- [ ] Confirm planning and control engage on the ArUco-derived pose.
- [ ] Confirm the MRM path actually stops the vehicle when the localizer reports
      `FAULT` — the wiring from `/diagnostics` through to a stop request is easy
      to assume and easy to have wrong.

---

## Checks

### Launch correctness

- [ ] `ros2 node list` shows the expected set and, more importantly, **does not**
      show `ndt_scan_matcher`, `cuda_ndt_matcher`, `pointcloud_map_loader`, the
      NDT preprocessing chain, or the upstream AR-tag stack. Worth asserting in a
      script rather than reading by eye.
- [ ] `pose_source:=ndt` and `cuda_ndt` still launch unchanged.
- [ ] No node crashes or restarts over a ten-minute run.

### Tracking

- [ ] Position and heading error against ground truth, per trajectory.
- [ ] Error grows with range in the shape spec §2.2 predicts — depth quadratic,
      lateral linear.
- [ ] Cold start from a standing start succeeds without manual input, and the
      time to initialize is recorded.
- [ ] No pose discontinuity above 0.3 m at board acquisition.

### Faults — each mapped to a D3 injection

- [ ] Board displaced → integrity flags that ID, excludes it, names it; no other
      board is flagged.
- [ ] All boards blacked out → `DEAD_RECKONING`, budget counts down, `FAULT` and
      MRM request on expiry, clean recovery if boards return first.
- [ ] Single board only → `DEGRADED`, 3-DoF with clamped orientation, and heading
      error visibly growing (this is the state the coverage rules exist to avoid).
- [ ] Coplanar boards only → covariance saturates on the weak axis, EKF
      de-weights accordingly.
- [ ] Fronto-parallel approach → ambiguity gate rejects, no wild pose is published.
- [ ] Cameras occluded one at a time → per-camera diagnostics accurate.

### EKF interaction

- [ ] The restored `pose_gate_dist` from D2 is not rejecting good fixes. A high
      rejection count means the covariance model or the map is wrong, **not** that
      the gate is doing a good job.
- [ ] Remember the EKF multiplies published covariance by `pose_smoothing_steps`
      (5) before its update — budget for it when reading these numbers.
- [ ] `enable_yaw_bias_estimation` behaves sanely with intermittent heading
      corrections rather than a continuous stream.

---

## Acceptance

- Zero-noise, well-spread: tracks ground truth to numerical tolerance.
- Realistic noise: error within the spec §2.2 envelope, no divergence over a
  full lap.
- Every fault injection produces its intended state transition and nothing else.
- MRM stop reached from `FAULT` in stage 2.
- Launch node-list assertions pass for all three `pose_source` values.

---

## What this does *not* prove

Worth stating so the milestone is not over-read. The synthetic path shares its
camera model, tag map and geometry conventions with the localizer, so a
consistent error in any of them cancels out and passes.

The things simulation cannot catch: real lens distortion against the real
`rational_polynomial` calibration, detection rate under actual lighting and
motion blur, CPU cost of three real detectors on the Orin, exposure hunting, and
whether the board layout actually delivers ≥2 visible everywhere on the route.

All of those come from D7's rosbags and the site. Passing D6 means the software
is coherent, not that the system works.
