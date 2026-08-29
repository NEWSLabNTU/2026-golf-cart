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

- [x] Launch profile wiring D2's `pose_source:=aruco` stack with `aruco_sim_detector`
      substituted for the three real detectors.
- [x] Straight line, circle, and corridor-with-corner paths.
- [x] Automated error report: lateral, longitudinal and heading error against
      ground truth.

Runs in seconds, needs no map and no simulator, and catches nearly everything.
Most of D4's development should happen against this.

### Stage 2 — Autoware planning simulator

The fuller loop, exercising the parts stage 1 skips: the real launch graph, the
map loaders, planning and control consuming the fused pose, and the MRM path.

- [x] **Resolve the topic conflict first.** Done 2026-08-30, and it is worse
      than this item described: Autoware offers two modes through
      `tier4_simulator_launch` and *both* take a topic the chain under test must
      own. `full_motion` publishes `output/odometry` on
      `/localization/kinematic_state`, which is the EKF's output; `pose_only`
      publishes `output/pose` on
      `/localization/pose_estimator/pose_with_covariance`, which is the ArUco
      localizer's. A launch include cannot remap what happens inside it, so
      `components/planning_sim_vehicle.launch.xml` runs the node directly with
      upstream's parameters and input remappings and sends all three motion
      outputs to `/simulation/ground_truth/*`.

      Verified: the node advertises its seven vehicle status topics, publishes
      ground-truth odometry at 40 Hz once an initial pose arrives, and neither
      contested topic appears at all.

      The input remappings are copied from upstream and must be kept in step
      with it: they are the simulated vehicle's whole interface, and a missing
      one is a command the simulator ignores without complaint.
- [x] **A tag map placed against the simulated environment.** Done 2026-08-30.
      `scripts/aruco/generate_tag_map.py` reads a lanelet2 map, projects its
      nodes into the MGRS frame Autoware uses, takes the longest road lanelet
      chain as the route, and places facing pairs at a fixed arclength interval.
      `aruco_sim_detector/config/sample_map_tag_map.yaml` is the result for the
      sample map: 74 boards, 37 pairs, 3 m apart and 3 m off the lane centre.

      Generated rather than hand-placed for the reason the bench fixture
      records: boards must come in facing pairs to cold-start at all, and
      corners are where a hand-planned layout leaves a hole. Placing at a fixed
      arclength follows the lane through its curves and closes that hole by
      construction.

      `aruco_sim_detector/test/test_tag_map_geometry.py` checks both maps for
      square boards of the declared size, planarity, unique ids, and pairs whose
      normals actually oppose. A tag map is corner points and nothing else, so
      every one of those properties is otherwise unreadable, and a wrong one
      loads and localizes to the wrong place without complaint.
- [ ] A route for the vehicle to drive, and a start pose on it.
- [ ] Confirm planning and control engage on the ArUco-derived pose.
- [ ] Confirm the MRM path actually stops the vehicle when the localizer reports
      `FAULT` — the wiring from `/diagnostics` through to a stop request is easy
      to assume and easy to have wrong.

---

## Checks

### Launch correctness

- [x] `ros2 node list` shows the expected set and, more importantly, **does not**
      show `ndt_scan_matcher`, `cuda_ndt_matcher`, `pointcloud_map_loader`, the
      NDT preprocessing chain, or the upstream AR-tag stack. Worth asserting in a
      script rather than reading by eye.
- [ ] `pose_source:=ndt` and `cuda_ndt` still launch unchanged.
- [ ] No node crashes or restarts over a ten-minute run.

### Tracking

- [x] Position and heading error against ground truth, per trajectory.
- [ ] Error grows with range in the shape spec §2.2 predicts — depth quadratic,
      lateral linear.
- [ ] Cold start from a standing start succeeds without manual input, and the
      time to initialize is recorded.
- [ ] No pose discontinuity above 0.3 m at board acquisition.

### Faults — each mapped to a D3 injection

- [x] Board displaced → integrity flags that ID, excludes it, names it; no other
      board is flagged.
- [x] All boards blacked out → `DEAD_RECKONING`, budget counts down, `FAULT` and
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

## Stage 1 — done. 6/6 scenarios pass.

`scripts/check/aruco_smoke_test.py` launches `sim_smoke.launch.xml` per scenario,
records the fused pose against ground truth, and asserts the outcome each one is
meant to produce. It exits non-zero, so it can gate a merge.

Measured against ground truth, error rotated into the vehicle frame:

| scenario | lateral p50 | long. p50 | heading p50 | outcome asserted |
|---|---|---|---|---|
| straight | 0.003 m | 0.009 m | 0.04° | NOMINAL, no fault |
| circle | 0.014 m | 0.018 m | 0.51° | no fault |
| corridor | 0.006 m | 0.012 m | 0.11° | no fault (see corner note) |
| blackout | 0.011 m | 0.016 m | 0.40° | DEAD_RECKONING → FAULT → `/diagnostics` ERROR |
| displaced_board | 0.002 m | 0.009 m | 0.02° | board 100 flagged, no other |
| clock_skew | — | — | — | UNINITIALIZED, no fixes at all |

Lateral and longitudinal are reported separately because the two have different
causes: a longitudinal error is a board-range error, a lateral one is usually
heading. A single Euclidean number hides which.

### What running it found

Nine defects. None were visible from unit tests, and most presented as silence
rather than as an error.

**The fusion chain was dead end to end.** Four separate breaks, each of which
alone was enough, and each of which left every node reporting healthy:

1. `gyro_odometer` was passed `output_twist_with_covariance` — the real argument
   is `output_twist_with_covariance_topic`. ROS 2 XML launch accepts unknown
   include arguments in silence, so it kept its default output name and the EKF
   subscribed to a topic nobody published.
2. The simulated IMU published `SensorDataQoS` (best-effort) while
   `gyro_odometer` subscribes reliably. ROS refuses to connect those, logging
   "offering incompatible QoS. No messages will be sent to it."
3. No `base_link → imu_link` transform, so `gyro_odometer` dropped every IMU
   message it did receive.
4. **Publishing `/initialpose3d` does not initialize Autoware.** `pose_initializer`
   *publishes* that topic; it does not listen to it. Initialization arrives
   through the `/localization/initialize` service, and `pose_initializer` is what
   then calls the EKF's `trigger_node` service to bring it out of its dormant
   state. The localizer now calls that service. `pose_initializer` was also never
   launched on this branch; it is now, with NDT and GNSS initialization off.

**The view-angle gate did not exist.** `min_view_angle_deg` and
`max_view_angle_deg` were declared, cross-validated against each other at
startup, and never applied to a single observation. Phase 3D-5 measured that
this gate — not the ambiguity ratio — is the only thing protecting against
near-fronto-parallel views, and it was not there. Now applied, with the same
convention the simulator uses.

**`initialization.max_range` and `max_view_angle_deg` were also dead**, so cold
start ran on the ordinary tracking gates while appearing to be guarded.

**Normal spread scored the best geometry as the worst.** `normalSpreadDeg` took
`|dot|` of the two board normals, so boards on *facing* walls — opposite
normals, the most informative arrangement available — reported **0°** spread,
identical to two boards side by side. A corridor with facing pairs could not
cold-start: every solve reported 0.0° against a 20° requirement. The absolute
value was guarding the flip degeneracy of parallel planes, which is a real
concern but a different one: `resolveFlips` already detects a tied consensus and
refuses to publish, and conditioning is measured by the condition number.

**The dead-reckoning budget ran before the first fix.** From UNINITIALIZED an
empty window fell through to DEAD_RECKONING, so the clock started while the graph
was still coming up and the vehicle latched FAULT and requested an MRM seconds
after launch, before it had ever localized. UNINITIALIZED now absorbs empty
windows: "I do not know where I am yet" and "I knew, and have been losing it"
are different conditions.

**The cold-start agreement test measured travel, not disagreement.** It required
five consecutive solves within a fixed 0.5 m radius; at 1 m/s five windows cover
half a metre, so a perfectly consistent cold start failed for driving forwards.
The allowance now grows with the time the samples span.

**The initial pose left z, roll and pitch at zero variance**, stating them as
exactly known — the same mistake the solver's own covariance code is written to
avoid.

**A board rejected by consensus was never named.** Such a board never reaches the
solve, so it produces no residual and the integrity monitor never saw it: it
could disagree on every frame and still be reported healthy. Silently dropped,
never named, nobody sent to look at it — which is exactly what a board knocked
off its mount looks like. Consensus outliers now feed the monitor, judged as a
proportion of appearances rather than a raw count, so a board at the edge of its
view window is not slowly condemned for occasional rejection.

### Fixture defects, which are findings in their own right

- The `straight` pattern flipped yaw by π at its turnaround while reporting
  zero angular rate — a motion no vehicle can perform. It now reverses.
- The `corridor` pattern used `fmod`, teleporting back to the start at the end
  of the route. It now clamps.
- The simulated cameras' yaws disagreed with their names: "left" pointed
  straight ahead and "right" pointed backwards, so nothing ever looked at the
  right-hand wall.
- The board layout could not cold-start. See `bench_tag_map.yaml`: a wall board
  is only init-eligible over a window about 2 m long, and two must satisfy that
  *simultaneously* with different normals. Staggered boards never do; facing
  pairs at equal offset do.
- 27 stray ROS nodes from earlier runs were publishing onto the same topics and
  quietly blending two simulations into one measurement. The harness now refuses
  to start if any of its own node names are already up.

### Known gap: corners

Corridor tracks to 1.2 cm median and spikes to ~2.9 m along-track while turning
through the corner, recovering immediately after. Arm A's boards ended before
arm B's began, and the vehicle crossed the turn on single-board DEGRADED fixes
with no heading correction. Four boards were added at the corner and the
excursion narrowed but did not vanish.

This is a board-layout property, not a localizer defect, and it is the most
transferable lesson here for the real site: **straights look after themselves,
corners are where coverage fails.** A layout planned by walking the straights
will have exactly this hole. The scenario asserts a tight median and an
explicitly wide tail rather than hiding it behind a relaxed threshold.

## Stage 2 — not started

The Autoware planning simulator path is untouched. Stage 1 covers the launch
graph, the fusion chain, the health states and the fault injections; stage 2
adds planning and control consuming the fused pose, and the MRM actually
stopping the vehicle. The `/diagnostics` → `HazardStatus` half of that is now in
place and verified as far as the ERROR (see phase 3D-2), but nothing has yet
confirmed a vehicle stopping as a result.

## Bookkeeping

Stage 1 is complete: 6/6 scenarios pass, and the launch-correctness assertions
were re-verified against the real `golfcart.launch.yaml`, not only the sim.

Still open in stage 1, and honest about it:

- **`cuda_ndt` still launches unchanged** — `ndt` was verified (159 nodes, scan
  matcher and point cloud map loader present, no ArUco nodes); `cuda_ndt` was
  not, because the package is not built here.
- **No node crashes over a ten-minute run** — longest observed run is about two
  minutes.
- **Error grows with range in the shape §2.2 predicts** — not analysed. The
  fixture holds range nearly constant, so it cannot answer this.
- **Cold start time recorded** — cold start works and is verified end to end,
  but the time to initialize is not measured.
- **No pose discontinuity above 0.3 m at board acquisition** — not measured.
- **Single-board, coplanar-only, fronto-parallel and per-camera occlusion
  scenarios** — the simulator supports all four through
  `fault.visible_board_ids`; no scenario drives them yet.
- **The three EKF-interaction items** — `pose_gate_dist` rejection count,
  `pose_smoothing_steps` budgeting and `enable_yaw_bias_estimation` behaviour
  are all unmeasured.

Stage 2 is untouched.
