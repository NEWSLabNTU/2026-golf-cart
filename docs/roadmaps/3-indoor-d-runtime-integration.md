# Phase 3D — Implementation (index)

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: **[2026-08-10-aruco-indoor-localizer-design.md](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md)**
Node architecture: [aruco-node-architecture.typ](../design/aruco-node-architecture.typ)

Last updated: 2026-08-10

---

## Build order

Infrastructure and the launch switch first, then the algorithm, then a
simulation smoke test. Rosbag collection runs in parallel from day one.

```
D1 infrastructure ──┬─▶ D2 launch switch ────────────┐
  msgs, skeletons,  │     pose_source:=aruco,        │
  tag map loader    │     stubs are fine here        │
                    │                                ├─▶ D6 simulation
                    ├─▶ D3 synthetic detection ──┐   │      smoke test
                    │     ground-truth harness   │   │
                    │                            ▼   │
                    │                    D4 localizer ┘
                    │                       the solve
                    │
                    └─▶ D5 detector  (LCTK, independent of D3/D4)

D7 rosbag collection — parallel, starts now, no dependency on any of the above
```

| Phase | Doc | Depends on | Can start |
|---|---|---|---|
| D1 | [Infrastructure](3-indoor-d1-infrastructure.md) | — | **now** |
| D2 | [Launch switch](3-indoor-d2-launch-switch.md) | D1 (package names only) | after D1 skeletons |
| D3 | [Synthetic detection source](3-indoor-d3-sim-detection-source.md) | D1 | after D1 |
| D4 | [Localizer algorithm](3-indoor-d4-localizer.md) | D1, D3 | after D3 |
| D5 | [Detector](3-indoor-d5-detector.md) | D1 | **now**, in LCTK |
| D6 | [Simulation smoke test](3-indoor-d6-sim-smoke-test.md) | D1–D4 | after D4 |
| D7 | [Rosbag collection](3-indoor-d7-rosbag-collection.md) | — | **now** |

---

## The decoupling that shapes this order

**The localizer does not need the detector.** It consumes
`ArucoDetectionArray`, and D3's synthetic source produces that message from a
known vehicle pose and the tag map. So the entire solve — consensus, covariance,
integrity, state machine, EKF wiring — can be built and validated against exact
ground truth before a single real image is processed.

That is why D3 comes before D4 rather than after: it is the localizer's test
fixture, not an afterthought. It also gives something no rosbag can, which is
**ground truth you can dial** — displace one board to test integrity, force
coplanar-only visibility to test covariance saturation, black out all boards to
test the dead-reckoning budget and the MRM hook.

D5 sits on a separate track in a separate repo and blocks nothing until D6.

---

## What "done" means for phase D

- `pose_source:=aruco` brings up the localization stack with no scan matcher,
  no pointcloud map loader, and no NDT preprocessing anywhere in the node list.
- The localizer tracks a scripted trajectory in simulation within the error
  budget, with correct state transitions under injected faults.
- The detector produces corners from recorded real images, with the rectify
  contract tests passing.
- `corner_sigma_px` is a measured number, not a literature-anchored guess.

Vehicle integration and on-site tuning are **not** in phase D — they need the
boards mounted and surveyed, and the DBW velocity stub replaced.

---

## Standing constraints

These apply to every phase below and are not repeated in each doc.

- **Build**: `colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release`, or `just build`.
- **Commits**: Conventional Commits (`feat`, `fix`, `chore`, `docs`, `refactor`).
- **Thresholds**: warn before rejecting until a threshold is justified by measured
  data. LCTK's `C-04` is the cautionary tale — a gate set below the noise floor
  silently published empty detections for months. The exceptions are the safety
  gates in D4 (dead-reckoning budget, integrity exclusion), which must reject.
- **Never emit a zero covariance.** Downstream reads it as *exact*, and with one
  pose source there is nothing to contradict it.
