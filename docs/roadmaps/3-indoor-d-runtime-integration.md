# Phase 3D — Runtime Integration

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Full design spec: [2026-07-27-indoor-artag-localization-design.md](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md)

**Status: Design complete, implementation not started — blocked by sub-phase C**

Last updated: 2026-07-27

---

## Goal

Wire AR tags into the running localization stack at three injection points, so
that tags replace all three functions GNSS performs.

```
                 ┌──────────────────────────────────────────────┐
  cameras  ─────▶│ ar_tag_based_localizer × 3 (left/right/rear) │
  (L/R/rear)     │  ArUco detect → PnP → ego pose in map frame  │
                 └───────┬──────────────────────────────┬───────┘
                         │ pose_with_covariance ×3      │ detections
                         ▼                              ▼
                 ┌───────────────┐            ┌──────────────────────┐
                 │ pose_merger   │            │ ar_tag_pose_init     │ ① COLD START
                 │  (NEW)        │            │  (NEW)               │
                 └──┬────────┬───┘            └──────────┬───────────┘
   NDT pose ───────▶│        │                           │ /initialpose
                    │        │ ② EKF measurement         ▼
                    │        └────────▶ ekf_localizer ◀── autoware_pose_initializer
                    │                         │             (NDT-refines the seed)
                    │ ③ NDT regularization    ▼
                    └────▶ ndt / cuda_ndt   /localization/kinematic_state
```

---

## Current state

**Already wired, standard-NDT branch.**
`config/localization/ar_tag_based_localizer.param.yaml` exists and is already
forwarded at `tier4_localization_component.launch.xml:78`, alongside the
`lidar_marker_localizer/` config directory at lines 70–75. Someone stubbed this
plumbing. Wiring cost on that branch is near zero.

**Not wired, cuda_ndt branch.** The `cuda_ndt` group at
`tier4_localization_component.launch.xml:12` bypasses `tier4_localization_launch`
entirely and has none of the landmark plumbing.

**All upstream packages installed** at `/opt/autoware/1.5.0/share`:
`autoware_ar_tag_based_localizer`, `autoware_landmark_manager`,
`autoware_pose_estimator_arbiter`. Nothing to add or fork.

**NDT regularization is off and pointed at GNSS:**
```yaml
# ndt_scan_matcher.param.yaml:44
regularization:
  enable: false
  scale_factor: 0.01
```
```xml
<!-- cuda_ndt_matcher_launch/launch/autoware_localization.launch.xml:39 -->
<arg name="input_regularization_pose_topic" value="/sensing/gnss/pose_with_covariance"/>
```

---

## Two constraints that force new code

**1. `ekf_localizer` accepts exactly one pose topic.**
```xml
<arg name="input_pose_with_cov_name" default="in_pose_with_covariance"/>
```
Not a list. Two sources correcting continuously cannot both be wired to it.
`pose_estimator_arbiter` *switches* between sources rather than fusing them, so
it does not meet the requirement. → `golfcart_pose_merger`.

**2. `ar_tag_based_localizer` cannot self-initialize.** It gates its own output
against the EKF pose:
```yaml
ekf_time_tolerance: 5.0      # [s]
ekf_position_tolerance: 10.0 # [m]
```
With no EKF pose yet, it publishes nothing. This mirrors upstream, where
`yabloc_pose_initializer` is a separate package from the yabloc corrector.
→ `golfcart_ar_tag_pose_initializer`.

---

## Tasks

### New nodes

- [ ] **`golfcart_pose_merger`** — N pose inputs → EKF's single pose input.
      Per-source covariance scaling, staleness rejection, monotonic-stamp
      enforcement, future-stamp rejection, per-source diagnostics.
- [ ] **Acquisition ramp in the merger** — inflate a source's covariance ×10 on
      resume, decaying over ~1 s. Targets the documented upstream failure:
      *"the timing of when each AR tag begins to be detected can cause significant
      changes in estimation."*
- [ ] **`golfcart_ar_tag_pose_initializer`** — tag detections + landmark
      `tf_static` → `/initialpose`. Publishing to `/initialpose` means **zero
      forking** of `autoware_pose_initializer` — it is the same entry point
      RViz "2D Pose Estimate" uses.
- [ ] **Initializer quality gates** — min image area, max range (8 m, tighter
      than the 13 m detection limit), max view angle, 5 consecutive agreeing
      frames within 0.5 m, unique-ID requirement, republish cooldown.
      One bad init is worse than none: NDT will converge to a wrong local
      minimum and report confident nonsense.
- [ ] **Unit tests for both nodes** — pure functions of message streams, fully
      testable without hardware.

### Wiring

- [ ] **Three `ar_tag_based_localizer` instances** — left, right, rear. Per-camera
      params, `camera_info` topics, frame IDs.
- [ ] **`pose_source:=ndt_artag` and `cuda_ndt_artag`** in **both** branches of
      `tier4_localization_component.launch.xml`.
- [ ] **`config/localization/preset/indoor_artag_preset.yaml`**.
- [ ] **Enable NDT regularization** — `regularization.enable: true`, input
      repointed off `/sensing/gnss/pose_with_covariance`.
- [ ] **Disable GNSS end to end** — `gnss_enabled: false` in
      `pose_initializer.param.yaml`, `use_gnss:=false` throughout.
- [ ] **Expand `target_tag_ids`** past the current `['0'...'6']` to match the
      sub-phase C ID scheme.
- [ ] **Tag map staleness warning** — warn loudly when the loaded tag map's
      session stamp is older than the current session.

### Tuning

- [ ] **Covariance policy** — NDT at scale 1.0, tags at scale 4.0. Tags bound
      drift; they must never dominate NDT, because a stale tag map would
      otherwise drag the vehicle off the real trajectory with high confidence.
- [ ] **EKF tuning with heterogeneous measurement cadence** — `pose_smoothing_steps: 5`
      and the delay compensation assume regular cadence; interleaved irregular tag
      measurements are valid but change the tuning.
- [ ] **Measure CPU cost** of three ArUco detectors at 1920×1280 × 30 Hz on the
      Orin. Fallbacks if needed: reduced detection rate, `DM_FAST` mode,
      downscaled detection input.

---

## Correctness trap to avoid

Injection ③ must be fed **tag poses only**, never the merged NDT+tag stream.
Feeding the EKF's own input back into NDT, whose output then re-enters the EKF,
creates a feedback loop that will look like slow drift or oscillation rather
than an obvious bug. Recorded here so it is designed around, not discovered.

---

## Acceptance criteria

- Cold start with no GNSS and no manual RViz input succeeds in ≥90% of ≥20
  trials from varied starting positions, within 30 s.
- Longitudinal drift over the longest corridor materially flatter than NDT-only,
  demonstrated on a corridor where NDT-only measurably degrades.
- No pose discontinuity above 0.3 m attributable to tag acquisition.
- Clean degradation to NDT-only when tags are absent, with correct diagnostics
  and no estimator instability — verified by deliberately occluding cameras
  mid-run.
- Per-source diagnostics accurate.

### Metrics to record

- Lateral and longitudinal error vs the sub-phase B reference trajectory, for
  NDT-only / NDT+② / NDT+②+③.
- Drift growth over corridor length. **This is the headline number** — the whole
  design exists to flatten this curve.
- Cold-start success rate and time-to-initialized.
- Tag detection rate per camera; fraction of route with ≥1 tag visible.
- Count of EKF-gate-rejected tag measurements. A high count means the tag map or
  calibration is wrong — not that the gate is doing a good job.

---

## Expected accuracy

0.6 m tag, 1920×1280, correct calibration:

| Range | Position error | Yaw error |
|-------|----------------|-----------|
| ~5 m | a few cm | several degrees |
| ~13 m (`distance_threshold`) | ~10–30 cm | large |

Yaw is unusable at every range — hence upstream's `consider_orientation: false`.
**Tags correct position; NDT + IMU carry heading.** The pairing is complementary:
in a featureless corridor NDT is degenerate longitudinally, which is exactly the
axis side-wall tags constrain well, while tags say nothing about heading, which
NDT and the IMU handle fine.

Sub-10 cm *absolute* indoor accuracy is not achievable from this design — it is
capped by tag-map accuracy, which is capped by mapping-pass NDT. Bounded drift
is achievable, and that is what indoor autonomy needs.
