# Phase 3D-3 — Synthetic detection source

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §2, §5, §6

**Depends on**: D1.
**Blocks**: D4 (this is its test fixture), D6.

---

## Goal

A node that turns a known vehicle pose into `ArucoDetectionArray` messages, as
if three cameras had seen the boards. It is the harness the whole localizer is
developed against.

This is not a nice-to-have that comes after the algorithm. **It comes before**,
because it gives two things no rosbag can:

- **Exact ground truth.** The true vehicle pose is an input, so localizer error
  is measured directly rather than inferred against another estimate.
- **Dialable geometry and faults.** Displace one board relative to the map, force
  coplanar-only visibility, black out all boards for twenty seconds. Every branch
  in D4's state machine and integrity monitor has a switch that reaches it.

---

## Tasks

### `aruco_sim_detector`

- [x] Subscribe a ground-truth vehicle pose (see the source question below).
- [x] Read the same `aruco_tag_map.yaml` the localizer reads, via D1's loader.
- [ ] Read camera intrinsics and extrinsics from `CameraInfo` and TF, so the sim
      and the real path share one source of truth for geometry. **Do not
      hard-code a second copy of the camera model** — a divergence between the
      sim's camera and the real one produces a localizer that works perfectly in
      simulation and not at all on the vehicle.
- [x] Per camera, per board, decide visibility:
      - inside the image after projection
      - within `max_range`
      - incidence angle `|φ|` between the board normal and the line of sight
        inside the detectable band (detection collapses past ~85°)
      - optional per-board occlusion flag
- [x] Project the four corners, add Gaussian noise with `corner_sigma_px`.
- [x] Run IPPE on the noisy corners to produce **both** solutions and both
      reprojection errors, so the message carries the same ambiguity structure
      the real detector produces. Do not synthesize a single clean pose — the
      flip ambiguity is the thing D4 exists to resolve, and a fixture that hides
      it tests nothing.
- [x] Publish one `ArucoDetectionArray` per camera, on the same topics the real
      detectors use, with realistic per-camera timing offsets (the cameras are
      not hardware-synchronized).

### Fault injection

Each of these maps to a specific D4 behaviour. Expose them as parameters or a
service so they can be triggered mid-run.

- [x] **Board displacement** — offset one board's true pose from its map entry.
      Tests integrity monitoring: the per-ID residual should flag that board and
      no other.
- [x] **Board blackout** — drop all detections for N seconds. Tests
      `DEAD_RECKONING` entry, the time budget, and the MRM request.
- [x] **Single-board stretch** — allow only one board visible. Tests `DEGRADED`
      and the 3-DoF path with clamped orientation.
- [x] **Coplanar-only** — allow only boards on one wall at one depth. Tests
      covariance saturation on the unobservable direction, **and the flip tie**:
      coplanar boards flip together, so two equal clusters are the correct
      outcome and the localizer must publish nothing rather than pick one
      (spec §2.4). Vary their separation across the image — widely separated
      coplanar boards partially break the tie, clustered ones do not.
- [ ] **Fronto-parallel approach** — drive the line of sight down a board normal.
      Tests the `err₁/err₂ > 0.2` ambiguity gate and the ±25° cone rejection.
- [ ] **Noise sweep** — raise `corner_sigma_px` and confirm reported covariance
      grows correspondingly. If it does not, the covariance is decoration.
- [ ] **Clock skew** — stamps in the future, out-of-order arrivals.

### Ground-truth trajectory source

Two stages, simplest first.

- [x] **Stage 1 — scripted pose publisher.** Straight line, circle, and a
      corridor-with-corner path, published as a pose at a fixed rate. No Autoware
      simulator, no map, nothing else running. This is enough for all of D4's
      development and most of its tests, and it starts in minutes.
      `src/vehicle/control_test/` already has straight and circle trajectory
      tooling to follow for conventions.
- [ ] **Stage 2 — Autoware planning simulator.** Deferred to D6. Note the
      conflict to resolve there: `simple_planning_simulator` publishes
      `/localization/kinematic_state` itself, which is the topic our chain is
      supposed to produce. It needs remapping to
      `/simulation/ground_truth/kinematic_state` so the real topic stays free.

### Error reporting

- [x] Publish the ground-truth pose on a debug topic alongside the detections,
      so a comparison node or a plot can difference it against
      `/localization/kinematic_state` without replaying the trajectory script.

---

## Acceptance

- With zero noise, no faults, and a well-spread board layout, D4's localizer
  recovers the ground-truth pose to within numerical tolerance. **This is the
  end-to-end correctness test for the entire geometry chain** — map convention,
  corner order, TF composition, optical frame, and solve. If it does not close
  to millimetres with zero noise, something is wrong in the transforms, not the
  tuning.
- With `corner_sigma_px` set to a realistic value, the error distribution
  matches the `σ_lat ≈ Zσ/f`, `σ_Z ≈ Z²σ/(f·s)` scaling of spec §2.2 within a
  factor of about two.
- Each fault injection produces the intended state transition or diagnostic in
  D4, and nothing else.

---

## Why the zero-noise test matters more than it sounds

Every one of the following errors produces a result that looks plausible and
converges happily: a 90° corner permutation, a missing optical-frame rotation, a
transform composed in the inverse direction, or a tag-frame convention mismatch
between the map file and the solver.

LCTK hit two of these for real. `M-14` is the corner-order one — the order was
defined twice in two languages with nothing checking they agreed. `M-01`, still
open there, is the inverse-transform one: `solvePnP` returns `p_cam = R·p_obj + t`,
and that raw result was labelled as a TF in the direction that means its inverse.
Both stayed self-consistent internally and produced believable numbers.

A zero-noise round trip through synthetic detections catches all of them at
once, on the first day, in a test that runs in a second.

## Bookkeeping

Still open, and why:

- **Read camera intrinsics and extrinsics from `CameraInfo` and TF.** Shipped
  differently: the simulator defines its cameras in its own parameter file and
  *broadcasts* their extrinsics as TF, rather than reading either. That is a
  weaker guarantee than the item asked for — the sim cannot disagree with a real
  `CameraInfo` because it never reads one — and it is worth closing once real
  calibration files exist.
- **Fronto-parallel approach** and **noise sweep** — the mechanisms exist
  (`fault.visible_board_ids`, `corner_sigma_px`) but no scenario drives them.
- **Out-of-order arrivals.** Future stamps are rejected and tested; arrival
  order is not exercised.
- **Stage 2, the Autoware planning simulator** — deferred to D6, still deferred.

The single-board and coplanar-only cases are ticked as *capabilities*
(`fault.visible_board_ids` restricts what may be seen); the scenarios that
exercise them belong to D6 and are listed as open there.
