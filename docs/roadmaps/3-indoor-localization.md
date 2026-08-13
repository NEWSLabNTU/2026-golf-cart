# Phase 3 — ArUco Indoor Localization (master)

ArUco boards with hand-measured poses are the **sole** pose source indoors.
NDT is not used. No point cloud map, no scan matching, no GNSS.

Design spec: **[2026-08-10-aruco-indoor-localizer-design.md](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md)**

Last updated: 2026-08-13 (E implemented, B tooling done; A, C, D still design-phase)

---

## Scope change, 2026-08-10

This phase was previously "AR tags correct a primary NDT estimator." It is now
"ArUco boards *are* the estimator." Two decisions drove it: board poses are
**measured by hand and supplied as data**, and **NDT is dropped entirely**.

### What that deleted

| Sub-phase | Status |
|---|---|
| **A — camera calibration** | **Unchanged. Now the only prerequisite sub-phase.** |
| **B — indoor mapping** | **Deleted.** No point cloud map is needed. |
| **C — tag map building** | **Deleted.** Poses are measured by hand, not bootstrapped from an NDT drive. |
| **D — runtime integration** | **Rewritten.** See the spec; the phase doc's task list is stale. |

Also deleted: NDT regularization and its feedback-loop hazard, the
`golfcart_pose_merger`, the separate initializer node, tag-map staleness
handling, and the covariance inflation that existed because the map used to be
NDT-derived.

The critical path shortened a great deal. `B` was the item blocked on Turing
Drive DBW, and it is gone — DBW still gates the *fused* EKF output, since the
filter needs real twist, but the localizer's raw pose can be validated against
ground truth with no vehicle interface at all.

### What it made harder

Removing NDT removed the fallback. Three consequences, all covered in the spec:

1. **Coverage is safety-critical.** No boards visible means dead reckoning on
   gyro and wheel odometry, whose error grows without bound — not "degrade to
   NDT." The spec defines `NOMINAL` / `DEGRADED` / `DEAD_RECKONING` / `FAULT`
   states with a time budget and an MRM hook.
2. **Heading has no other absolute source.** A single board's orientation is
   unusable — 11.7° measured jitter — so **two well-spread boards must be
   visible often enough to bound gyro drift**. This is an availability
   requirement, not an accuracy target.
3. **A wrong map entry is uncontradicted.** The spec adds integrity monitoring:
   per-ID residuals across the session, flag and exclude, structured after GNSS
   RAIM.

---

## Work remaining

### Sub-phase A — camera calibration (prerequisite, unchanged)

See [3-indoor-a-camera-calibration.md](3-indoor-a-camera-calibration.md).
Hard blockers it must clear:

| Sub-phase | Doc | Status |
|-----------|-----|--------|
| A — Camera calibration | [3-indoor-a-camera-calibration.md](3-indoor-a-camera-calibration.md) | Not started |
| B — Indoor mapping | [3-indoor-b-indoor-mapping.md](3-indoor-b-indoor-mapping.md) | Tooling done and tested; field work waits on a site |
| C — Tag map building | [3-indoor-c-tag-map-building.md](3-indoor-c-tag-map-building.md) | Not started |
| D — Runtime integration | [3-indoor-d-runtime-integration.md](3-indoor-d-runtime-integration.md) | Design complete, not started |
| E — Board pose initializer | [3-indoor-e-board-initializer.md](3-indoor-e-board-initializer.md) | Implemented, passing in simulation; replay validation blocked by B |

- **No `*_optical_link` frames exist in the URDF.** PnP returns optical-convention
  poses; composing through the body-frame links rotates every observation ~90°.
- **All three camera calibration files are one file copied three times**, declaring
  `rational_polynomial` and internally inconsistent with the 1920×1280 stream.

### Board production and mounting

- Generate single-ID boards (LCTK, `num_squares_per_side = 1`)
- **Walk the route with a camera first** and produce the coverage survey — how
  many boards are visible where, and at what incidence. This sizes the job and
  is much cheaper than discovering the answer after mounting.
- Mount: ≥2 visible everywhere, ≥5 where accuracy matters, yawed ~30° off the
  wall, spread normals and depths.

### Survey

- Measure board poses. The **survey accuracy is now the system's accuracy
  ceiling**, so instrument and technique matter more than anything in software.
- Prefer the four-corner form over pose + quaternion — it is what a manual
  survey produces and it carries no frame convention to get wrong.

### Sub-phase D — implementation

Broken into seven phase docs, indexed at
**[3-indoor-d-runtime-integration.md](3-indoor-d-runtime-integration.md)**.
Infrastructure and the launch switch first, then the algorithm, then a
simulation smoke test; rosbag collection runs in parallel from day one.

| Phase | Doc | Status |
|---|---|---|
| D1 | [Infrastructure](3-indoor-d1-infrastructure.md) — msgs, package skeletons, tag map loader | **done** |
| D2 | [Launch switch](3-indoor-d2-launch-switch.md) — `pose_source:=aruco` | **done** |
| D3 | [Synthetic detection source](3-indoor-d3-sim-detection-source.md) — the ground-truth harness | **done** |
| D4 | [Localizer algorithm](3-indoor-d4-localizer.md) — the solve, integrity, states | **done** |
| D5 | [Detector](3-indoor-d5-detector.md) — vendored from LCTK into this repo | **done** |
| D6 | [Simulation smoke test](3-indoor-d6-sim-smoke-test.md) | stage 1 **done**, stage 2 open |
| D7 | [Rosbag collection](3-indoor-d7-rosbag-collection.md) | tooling **done**, recordings need hardware |

Per-phase detail, what shipped differently from the specification, and the two
decisions still outstanding are in the
[phase D index](3-indoor-d-runtime-integration.md#status). D5 moved: the
detector was vendored into this repo rather than left in LCTK, because the
message that is the detector-to-localizer contract could not live in a vehicle
package that a general toolkit depends on.

The ordering hinges on one decoupling: **the localizer does not need the
detector.** D3's synthetic source produces `ArucoDetectionArray` from a known
pose and the tag map, so the entire solve can be built and validated against
exact ground truth before a real image is processed — and against faults that
can be dialled in, which no rosbag provides.

### E — Board pose initializer, added 2026-08-12

Sub-phase E replaces GNSS for **cold start only**, using a LiDAR-detected
retroreflective board rather than a camera-detected tag. It exists because the
indoor map is anchored to that board
([mapping design §4](../design/indoor_pcd_mapping_reflector_anchor.md)), which
makes the map origin physically re-findable and the initial pose exact by
construction.

E is largely independent of A–D: its detector and simulator need no camera, no
map, and no vehicle, so it can proceed in parallel while the Orin work continues
elsewhere. It does not replace D — the board is not visible from most of the
route, so bounding drift remains the tags' job.

---

## Three things that can start today, with no hardware

- **D5's `corner_sigma_px` measurement.** Park in front of a board, record ~1000
  frames, take the standard deviation of corner positions. The whole covariance
  model scales on this constant and it is currently inferred from other people's
  data. Needs only a camera and a board.
- **D7's bench bags.** Four or five boards in a room, tape-measured.
- **The route coverage walk.** Sizes the board count and tells you whether the
  ≥2-visible-everywhere rule is satisfiable here, before anything is printed or
  drilled.
