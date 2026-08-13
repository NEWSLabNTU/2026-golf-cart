# Phase 3D — Implementation (index)

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: **[2026-08-10-aruco-indoor-localizer-design.md](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md)**
Node architecture: [aruco-node-architecture.typ](../design/aruco-node-architecture.typ)

Last updated: 2026-08-10

---

## Status

Last updated 2026-08-13, on branch `feat/aruco-indoor-localizer`.

| Phase | State | Open | Blocked on |
|---|---|---|---|
| D1 Infrastructure | **done** | 0 | — |
| D2 Launch switch | **done** | 1 | a decision on what `use_mapless_mode` means here |
| D3 Synthetic detections | **done** | 5 | scenarios, not mechanisms |
| D4 Localizer | **done** | 4 | see its bookkeeping note |
| D5 Detector | **done** | 3 | hardware: the `corner_sigma_px` measurement |
| D6 Smoke test | **stage 1 done**, stage 2 untouched | 16 | the Autoware planning simulator |
| D7 Rosbag collection | **tooling done** | 19 | hardware, and the site |

The pipeline runs end to end. Against synthetic detections through the real
launch graph it tracks ground truth to **3 mm lateral, 9 mm along-track and
0.04° heading** (median), with 6/6 graded scenarios passing including fault
injection, and 112 unit tests. `pose_source:=aruco` was verified on the full
`golfcart.launch.yaml`: 151 nodes, no launch exceptions, the tag map reaching
the localizer, and the entire NDT stack absent.

**Two things need a decision rather than more work:**

1. **One fix in 876 published a 179.92° yaw error with a confident covariance.**
   Position was correct to 5 cm. The obvious mitigation is an innovation gate
   against the prior, and it sits against a stated principle of this design —
   that the branch is never chosen by proximity to the prior. Gating the
   published *output* is not the same act as choosing the *branch*, but the line
   is thin enough to be worth drawing deliberately. Recorded in
   [D4](3-indoor-d4-localizer.md).

2. **`corner_sigma_px` is still 0.3, inferred from other people's data.** Every
   covariance this system publishes scales on it. The measurement needs one
   camera, one board and a tripod — about an hour, no vehicle and no site.

**Two budgets are placeholders**: `dead_reckoning_budget_s` and
`degraded_budget_s` must follow from measured gyro drift against an allowable
position error, not from the round numbers currently in the config.

What the open counts mean: they are the items genuinely not done. Each phase doc
ends with a bookkeeping note saying which were left open and why, and — where it
matters more than the tick — which shipped **differently from what the phase doc
originally specified**. D4 has three of those, including a covariance formula
that was wrong as written.

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
