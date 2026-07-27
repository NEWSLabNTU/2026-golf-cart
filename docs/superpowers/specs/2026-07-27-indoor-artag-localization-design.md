# Indoor AR-Tag + NDT Localization — Design

**Status**: Sections 1–2 approved; Sections 3–10 written, pending review
**Date**: 2026-07-27
**Phase docs**: [3-indoor-localization.md](../../roadmaps/3-indoor-localization.md)

---

## 1. Goal and Context

Run the golf cart autonomously indoors, where GNSS is unavailable. Keep NDT scan
matching as the primary pose estimator, and replace every function GNSS currently
performs with camera-detected AR tags whose positions are recorded in the map.

GNSS currently serves three distinct purposes in this stack. All three must be
replaced, and they are not the same problem:

| GNSS function today | Where it enters | Indoor replacement |
|---------------------|-----------------|--------------------|
| Initial/global pose for cold start | `autoware_pose_initializer` | AR-tag initializer publishing `/initialpose` |
| Absolute correction bounding NDT drift | `ekf_localizer` pose input | AR-tag localizer poses merged into the EKF pose input |
| NDT regularization along degenerate axes | `ndt_scan_matcher` regularization pose | AR-tag poses fed to the same regularization input |

The third row is the one usually missed. Autoware's NDT already has a
`regularization` feature whose documented purpose is correcting **longitudinal
degeneracy in tunnels using GNSS**. An indoor corridor is the same geometry
problem as a tunnel. Currently:

```yaml
# src/launcher/golfcart_launch/config/localization/ndt_scan_matcher/ndt_scan_matcher.param.yaml:44
regularization:
  enable: false
  scale_factor: 0.01
```
```xml
<!-- src/localization/cuda_ndt_matcher/src/cuda_ndt_matcher_launch/launch/autoware_localization.launch.xml:39 -->
<arg name="input_regularization_pose_topic" value="/sensing/gnss/pose_with_covariance"/>
```

### Non-goals

- Outdoor operation. This design targets a single known indoor site.
- Replacing NDT. NDT stays primary; tags are a correction and initialization source.
- Tag-based heading correction. Tag yaw estimates are too noisy at useful ranges;
  heading stays with NDT + IMU. This matches upstream's `consider_orientation: false` default.
- LiDAR retroreflector markers. Evaluated and deferred — see Section 10.

### Operating envelope

- Single indoor site, known in advance.
- Tags are **placed per session** at roughly repeatable positions and removed
  afterwards. The tag map is therefore regenerated each session, not surveyed once.
- Low speed. Upstream scopes AR-tag localization to non-public-road use at
  ≤15 km/h; the golf cart indoors runs well under that.

---

## 2. Scope Decomposition

The work is four sub-projects with a real dependency order. This document fully
specifies **D**; A, B and C are specified to the level of their interface
contracts with D, and get their own phase docs.

```
A. Camera calibration          intrinsics per camera + camera→base_link extrinsics
      │                        (blocks everything downstream)
      ├──────────────┐
B. Indoor mapping    │         LiDAR SLAM → PCD + Lanelet2, NDT validated indoors
   (independent of A)│         with no GNSS anywhere in the pipeline
      └──────┬───────┘
             ▼
C. Tag map building            60cm tags' 4-vertex polygons into Lanelet2,
                               in map frame, without a total station
             ▼
D. Runtime integration         3× ar_tag_based_localizer + pose merger +
                               tag init path + preset/launch wiring + tuning
```

A and B are independent and can proceed in parallel.

### A — Camera calibration (contract for D)

Current state is a hard blocker. `usb_camera_left_calibration.yaml` and its
siblings contain placeholders, not calibration:

```yaml
camera_matrix:
  data: [1, 0, 960, 0, 1, 640, 0, 0, 1]   # focal length = 1 pixel
distortion_coefficients:
  data: [0, 0, 0, 0, 0]                    # no distortion model
```

`sensor_kit_calibration.yaml` camera extrinsics are round-number guesses carrying
their own comments (`# 50cm forward from sensor_kit_base`, `# 30cm up`), with
roll and pitch hard-zeroed, expressed in what looks like a body frame rather than
a ROS camera optical frame.

AR-tag pose error scales directly with intrinsic and extrinsic error. With
identity intrinsics, tag-derived poses are not degraded — they are meaningless.

**Contract D depends on:**
- Real intrinsics per camera, `plumb_bob`, reprojection RMS ≤ 0.5 px.
- `camera→base_link` extrinsics accurate to ≤ 2 cm / ≤ 0.5°.
- Correct optical-frame convention (z forward, x right, y down) with the
  body→optical rotation explicit, not folded into a yaw guess.

This overlaps [ROADMAP.md](../../ROADMAP.md) Phase 3 Track A (LCTK LiDAR-camera
calibration). Reuse that work; do not duplicate it. Note that Phase 3 Track A
targets TIER IV cameras — if the indoor work runs on the current USB/GMSL
cameras, calibration must be done for those specific units.

### B — Indoor mapping (contract for D)

**Contract D depends on:**
- PCD point cloud map of the indoor site, in a map frame with a defined origin.
- Lanelet2 vector map covering the drivable indoor route.
- Evidence that NDT converges and tracks on that map indoors, with no GNSS
  anywhere in the pipeline, seeded by a manual RViz pose.

Note the inherited blocker: NDT needs vehicle velocity, which comes from the
Turing Drive DBW package. Per ROADMAP.md that package is undelivered and the
vehicle interface currently runs stubs (`velocity_report.py` publishes zeros).
Indoor localization cannot be validated until that lands. This is a
pre-existing critical-path blocker, not one introduced by this design.

### C — Tag map building (contract for D)

Tags move between sessions, so per-deployment total-station survey is not viable.

**Approach: survey-free tag mapping by NDT bootstrap.** During or after the B
mapping pass, drive the route with NDT localizing against the fresh PCD map, run
ArUco detection on all three cameras, and for every observation compute the tag
pose in the map frame:

```
T_map→tag  =  T_map→base_link (NDT)  ∘  T_base_link→camera (calibration)  ∘  T_camera→tag (PnP)
```

Accumulate many observations per tag across ranges and viewing angles, reject
outliers, average, and emit Lanelet2 4-vertex polygons. Redeployment becomes a
ten-minute drive rather than a survey crew.

This inverts the dependency usefully: mapping-time NDT bootstraps the tag map,
then the tag map bounds runtime NDT drift. It works because mapping-time NDT is
offline-quality — slow, batched, loop-closed — while runtime NDT is the thing
that drifts.

**Consequence for D, and it is important:** tag map accuracy is capped by
mapping-pass NDT accuracy plus extrinsic calibration error. Tags **bound drift;
they do not add absolute truth**. D must therefore treat tag poses as freshly
generated data of moderate accuracy, with conservative covariances and hard
outlier gating — not as survey ground truth. If true global accuracy is needed
later, add a handful of total-station-surveyed anchor tags and fit the rest
against them.

**Contract D depends on:**
- Lanelet2 map containing per-tag 4-vertex polygons, `type=pose_marker`,
  vertices counter-clockwise, consumable by `autoware_landmark_manager`.
- Unique tag IDs, no duplicates in the map.
- Per-tag observation-count and residual metadata, so D can weight or reject
  poorly-constrained tags.

---

## 3. Architecture

Three injection points for tag information, increasing in depth:

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

**① Cold start.** Tags produce a coarse ego pose, published to `/initialpose`.
`autoware_pose_initializer` NDT-refines it and seeds the EKF. This is the GNSS
init flow with tags substituted at the same entry point.

**② Continuous EKF correction.** Bounds NDT drift. Corrects position only —
heading stays with NDT + IMU.

**③ NDT regularization.** Keeps NDT itself from sliding along a corridor axis.
This one prevents *divergence*; ② only corrects *error*. They are not redundant:
if NDT diverges, ② is fighting a diverging estimate, whereas ③ stops the
divergence at its source.

### Why not the obvious alternatives

**`pose_estimator_arbiter`** (`pose_source:=ndt_artag`) is upstream-supported and
needs no new code, but it *switches* between sources rather than fusing them.
The requirement is continuous correction, which switching does not provide.
Switching at tag acquisition also amplifies the documented upstream failure mode:

> "the timing of when each AR tag begins to be detected can cause significant
> changes in estimation" — Autoware `ar_tag_based_localizer` docs

Additionally, the `cuda_ndt` branch at
`tier4_localization_component.launch.xml:12` bypasses the standard
`tier4_localization_launch` path entirely, so arbiter + cuda_ndt would need
rework regardless — the "free" saving mostly evaporates.

**Downstream second-stage corrector** (consume `/localization/kinematic_state`,
apply tag corrections after the fact) requires no changes to Autoware
localization internals, but cascades two filters over correlated estimates,
producing optimistic covariances, and forces planning to consume a non-standard
topic. Cheap to build, expensive to trust.

### The constraint that forces a new node

```xml
<!-- /opt/autoware/1.5.0/share/autoware_ekf_localizer/launch/ekf_localizer.launch.xml:8 -->
<arg name="input_pose_with_cov_name" default="in_pose_with_covariance"/>
```

`ekf_localizer` accepts exactly one pose topic — not a list. Two sources
correcting continuously cannot both be wired to it directly. A merge node is
required. This is legitimate rather than a hack: the EKF is a sequential
measurement filter, interleaved asynchronous measurements are precisely what it
handles, and `pose_gate_dist: 49.5` already provides Mahalanobis outlier
rejection.

---

## 4. Components

### 4.1 New: `golfcart_pose_merger`

Merges N pose sources onto the EKF's single pose input.

**Subscribes**
- `~/input/pose0` … `~/input/poseN` (`geometry_msgs/PoseWithCovarianceStamped`),
  configured as a list of named sources.

**Publishes**
- `~/output/pose_with_covariance` (`geometry_msgs/PoseWithCovarianceStamped`) →
  remapped to `ekf_localizer`'s `in_pose_with_covariance`.
- `/diagnostics` — one status entry per source.

**Parameters**

```yaml
/**:
  ros__parameters:
    sources:
      - name: ndt
        topic: /localization/pose_estimator/pose_with_covariance
        covariance_scale: 1.0        # trust upstream covariance as-is
        stale_timeout: 1.0           # [s] mark source stale after this gap
        required: true               # merger reports ERROR if absent
      - name: artag_left
        topic: /localization/pose_estimator/ar_tag_left/pose_with_covariance
        covariance_scale: 4.0        # inflate; tag map is bootstrap-derived, not surveyed
        stale_timeout: 30.0
        required: false
      # artag_right, artag_rear likewise

    enforce_monotonic_stamps: true
    max_future_stamp: 0.1            # [s] reject clock-skewed messages
    acquisition_ramp:
      enable: true
      duration: 1.0                  # [s] after a source resumes
      initial_scale: 10.0            # extra covariance inflation, decays to 1.0
```

**Behaviour**

1. Republish each accepted message immediately — no synchronization, no barrier.
   The EKF timestamps and orders measurements itself.
2. Reject messages older than the last published stamp when
   `enforce_monotonic_stamps` is set, and messages stamped in the future beyond
   `max_future_stamp`.
3. Scale each source's covariance by `covariance_scale` before republishing.
4. **Acquisition ramp**: when a source resumes after being stale, inflate its
   covariance by `initial_scale`, decaying to 1.0 over `duration`. This directly
   targets the documented pose-jump-at-tag-acquisition failure: the first
   observation after a gap is admitted gently rather than yanking the estimate.
5. Emit per-source diagnostics: last-seen age, accepted/rejected counts,
   current effective covariance scale.

The merger does **not** implement its own outlier rejection beyond staleness and
stamp sanity. Statistical rejection belongs in the EKF, which already has a
tuned Mahalanobis gate. Two independent rejection layers with different
thresholds is a debugging trap.

### 4.2 New: `golfcart_ar_tag_pose_initializer`

Produces the cold-start pose that GNSS would otherwise provide.

**Why a separate node.** `autoware_ar_tag_based_localizer` cannot self-initialize.
It gates its own output against the EKF pose:

```yaml
# config/localization/ar_tag_based_localizer.param.yaml
ekf_time_tolerance: 5.0     # [s]
ekf_position_tolerance: 10.0 # [m]
```

With no EKF pose yet, there is nothing to compare against, so it publishes
nothing. This mirrors upstream's own structure, where `yabloc_pose_initializer`
is a separate package from the yabloc corrector.

**Subscribes**
- Tag detections (`~/input/detected_tags` from the localizer debug output, or a
  dedicated ArUco detector instance — decided in implementation, see Section 10).
- `tf_static` landmark poses published by `autoware_landmark_manager`.

**Publishes**
- `/initialpose` (`geometry_msgs/PoseWithCovarianceStamped`).

Publishing to `/initialpose` means **zero forking of `autoware_pose_initializer`**.
That is the same entry point RViz's "2D Pose Estimate" uses, and pose_initializer
already NDT-refines whatever arrives there.

**Quality gates before firing** — one bad initialization is worse than none,
because NDT will happily converge to a wrong local minimum and the system will
report confident nonsense:

```yaml
/**:
  ros__parameters:
    min_tag_image_area_ratio: 0.005   # tag must occupy this fraction of image
    max_range: 8.0                    # [m] closer than distance_threshold; init needs quality
    max_view_angle: 50.0              # [deg] off tag normal
    consecutive_frames: 5             # agreeing observations required
    agreement_radius: 0.5             # [m] spread across those frames
    require_unique_id: true           # refuse ambiguous IDs
    republish_cooldown: 10.0          # [s] do not spam /initialpose
    output_covariance_xy: 1.0         # [m^2] honest, coarse — NDT refines from here
```

Multi-frame agreement is the important gate. A single PnP solution on a
marginally-visible tag can be badly wrong, including sign-flipped pose
ambiguity; five consecutive observations agreeing within 0.5 m are not.

### 4.3 Reused unmodified

`autoware_ar_tag_based_localizer` ×3, `autoware_landmark_manager`,
`autoware_pose_initializer`, `autoware_ekf_localizer`, `ndt_scan_matcher` /
`cuda_ndt_matcher`.

All are already installed at `/opt/autoware/1.5.0/share`. No upstream package
needs to be added or forked.

### 4.4 Camera instances

One `ar_tag_based_localizer` node per camera. Three instances: left, right, rear.

The side-facing cameras are an advantage here, not a compromise. Tags mounted on
corridor walls pass broadside through the left and right camera views, which
constrains both lateral and longitudinal position well. A front camera sees wall
tags nearly edge-on at poor geometry, and sees end-of-corridor tags head-on where
range is weakly observable.

Current camera config, from `usb_camera_left.yaml`:

```yaml
image_width: 1920
image_height: 1280
framerate: 30.0
auto_exposure: true        # must become false for tag cameras
auto_white_balance: true   # must become false for tag cameras
```

Auto-exposure hunting plus motion blur is the leading cause of intermittent
ArUco detection. Tag detection wants fixed exposure and a short shutter, traded
against gain noise. This needs a per-site tuning pass under the actual indoor
lighting.

### 4.5 Configuration and launch

- New `config/localization/preset/indoor_artag_preset.yaml`.
- New `pose_source` values `ndt_artag` and `cuda_ndt_artag`, handled in **both**
  branches of `tier4_localization_component.launch.xml` — the standard branch
  (line 23) and the cuda_ndt branch (line 12).
- Per-camera `ar_tag_based_localizer` param overrides: three instances, three
  `camera_info` topics, three frame IDs.
- `regularization.enable: true` in `ndt_scan_matcher.param.yaml`, with
  `input_regularization_pose_topic` repointed off `/sensing/gnss/pose_with_covariance`.
- `gnss_enabled: false` in `pose_initializer.param.yaml`; `use_gnss:=false` throughout.
- Fixed-exposure gscam profiles for the tag cameras.
- `target_tag_ids` expanded beyond the current `['0','1','2','3','4','5','6']`,
  plus an explicit ArUco dictionary choice and a tag-ID allocation scheme.

Good news on wiring: `config/localization/ar_tag_based_localizer.param.yaml`
already exists and is already forwarded at
`tier4_localization_component.launch.xml:78`, alongside the `lidar_marker_localizer/`
config directory at lines 70–75. The standard-NDT branch is largely stubbed
already. The `cuda_ndt` branch has none of it.

---

## 5. Data Flow and Initialization State Machine

### Steady state

```
VLP-32C ──▶ ndt / cuda_ndt ──▶ pose_with_covariance ──┐
                    ▲                                  │
                    │ ③ regularization pose            ├──▶ pose_merger ──▶ ekf_localizer
                    │                                  │                          │
cameras ──▶ ar_tag_based_localizer ×3 ────────────────┘                          ▼
                    │                                                  /localization/kinematic_state
xsens IMU + DBW twist ──▶ gyro_odometer ──────────────────────────────▶ ekf_localizer (twist)
```

The ③ regularization feed is the *merged tag pose*, not the raw per-camera pose,
so NDT sees one consistent external constraint rather than three.

### Initialization state machine

```
        ┌──────────────┐
        │ UNINITIALIZED│  no EKF pose; ar_tag localizers silent (self-gated)
        └──────┬───────┘
               │ tag observed, all quality gates pass, N frames agree
               ▼
        ┌──────────────┐
        │ SEED_PUBLISHED│  /initialpose emitted with coarse covariance
        └──────┬───────┘
               │ autoware_pose_initializer NDT-aligns the seed
               ▼
        ┌──────────────┐
        │  ALIGNING    │  NDT converging; EKF seeded
        └──────┬───────┘
               │ NDT score above threshold, EKF covariance below threshold
               ▼
        ┌──────────────┐
        │   RUNNING    │  ar_tag localizers pass their own EKF gate → ② and ③ live
        └──────────────┘

  Escapes:
    SEED_PUBLISHED / ALIGNING timeout  → back to UNINITIALIZED, diag WARN,
                                          retry after republish_cooldown
    Repeated failure past N attempts   → diag ERROR, fall back to manual
                                          RViz "2D Pose Estimate"
```

Manual RViz initialization remains available at every state, unchanged. It is
the documented fallback, not a workaround.

### Covariance policy

| Source | Policy | Reasoning |
|--------|--------|-----------|
| NDT | upstream covariance, `scale 1.0` | Already tuned; NDT reports its own convergence quality |
| AR tag | `base_covariance` distance-scaled by the localizer, then `scale 4.0` in merger | Tag map is bootstrap-derived from mapping-pass NDT, so its errors are correlated with map error and it must never dominate NDT |
| AR tag, first 1 s after acquisition | additional `×10`, decaying | Damps the documented acquisition jump |

The `×4` inflation is a deliberate stance: tags are trusted as a *drift bound*,
not as ground truth. If tags were allowed to dominate, a stale tag map from a
previous session's tag placement would drag the vehicle off the real trajectory
with high confidence — the worst possible failure shape.

Baseline tag covariance, distance-scaled internally by the localizer:

```yaml
base_covariance: [0.2, 0, 0, 0, 0, 0,     # x  [m^2]
                  0, 0.2, 0, 0, 0, 0,     # y
                  0, 0, 0.2, 0, 0, 0,     # z
                  0, 0, 0, 0.02, 0, 0,    # roll  — unused, consider_orientation: false
                  0, 0, 0, 0, 0.02, 0,    # pitch — unused
                  0, 0, 0, 0, 0, 0.02]    # yaw   — unused
```

---

## 6. Expected Accuracy

For a 0.6 m tag at 1920×1280 with correct calibration:

| Range | Position error | Yaw error |
|-------|----------------|-----------|
| ~5 m | a few cm | several degrees |
| ~13 m (`distance_threshold`) | roughly 10–30 cm | large |

Yaw is unusable at every range, which is exactly why upstream ships
`consider_orientation: false`. The design consequence is stated once and applies
throughout: **tags correct position, NDT + IMU carry heading.**

The pairing is complementary rather than redundant. In a long featureless
corridor NDT is degenerate longitudinally — precisely the axis tags constrain
well when mounted on side walls. Conversely tags say nothing useful about
heading, which NDT and the IMU handle well even when position is degenerate.

Note the ceiling: fused accuracy cannot exceed tag-map accuracy, which cannot
exceed mapping-pass NDT accuracy plus calibration error. Sub-10 cm absolute
indoor accuracy is not achievable from this design alone. It is achievable as a
*drift bound* — the vehicle will not walk away over a long corridor — which is
what indoor autonomy actually needs.

---

## 7. Failure Modes and Handling

| Failure | Detection | Handling |
|---------|-----------|----------|
| No tags visible for an extended stretch | Merger staleness timer | Source marked stale, NDT-only operation, diag WARN. Expected and normal between tag clusters. |
| Tag physically moved since the mapping drive | Tag-derived pose disagrees with EKF | `ar_tag_based_localizer` self-gates at `ekf_position_tolerance: 10.0`; EKF Mahalanobis gate catches the rest. Persistent per-ID disagreement → diag WARN naming the ID → re-run sub-project C. |
| Duplicate tag IDs in the map | C validation, plus runtime ambiguity | C enforces unique IDs. `require_unique_id` in the initializer refuses ambiguous init. |
| Pose jump at tag acquisition | Documented upstream behaviour | Merger acquisition ramp (Section 4.1). |
| NDT diverges along a corridor | NDT score drop, `pose_instability_detector` | Regularization injection ③ prevents it at source; if it still occurs, EKF continues on tags and twist while NDT re-converges. |
| Camera exposure hunting, motion blur | Detection rate per camera in diagnostics | Fixed-exposure camera profiles, tuned per site. |
| Bad camera calibration | Systematic tag-vs-NDT offset that grows with range | Caught by sub-project A acceptance gates before D runs. If it reaches D, the range-correlated signature identifies it. |
| Systematic tag-vs-NDT disagreement across many tags | Diagnostics aggregate | Indicates a bad tag map from C, not a runtime fault. Re-run the bootstrap drive. |
| Bad cold-start init (wrong local minimum) | NDT score low after alignment | ALIGNING timeout → retry → manual RViz fallback. Quality gates in 4.2 make this rare. |
| No vehicle velocity (DBW stubs) | Zero twist from `velocity_report.py` | Pre-existing blocker. NDT cannot be validated at all. Owned by ROADMAP Phase 2 Track B. |

---

## 8. Testing and Acceptance

### Unit tests

`golfcart_pose_merger` — covariance scaling, staleness transitions, monotonic
stamp enforcement, future-stamp rejection, acquisition ramp decay curve, per-source
diagnostic output. Pure function of message streams; fully testable without hardware.

`golfcart_ar_tag_pose_initializer` — each quality gate independently, multi-frame
agreement logic, cooldown behaviour, ambiguous-ID refusal.

### Integration, rosbag replay

Record an indoor drive with tags in place and all three cameras running. Replay
through `logging_simulation` and compare:

1. NDT-only fused trajectory
2. NDT + tags (② only)
3. NDT + tags + regularization (② and ③)

against the mapping-pass reference trajectory.

### Metrics

- Lateral and longitudinal error vs reference trajectory, per configuration.
- Drift growth over corridor length, NDT-only vs NDT+tags. This is the headline
  number — the whole design exists to flatten this curve.
- Cold-start success rate and time-to-initialized, over ≥20 trials from varied
  starting positions.
- Tag detection rate per camera, and fraction of route with at least one tag visible.
- Count of EKF-gate-rejected tag measurements. A high count means the tag map or
  calibration is wrong, not that the gate is working well.

### Acceptance criteria

- Cold start succeeds without manual RViz input in ≥90% of trials, within 30 s.
- Longitudinal drift over the longest corridor on the route is bounded — NDT+tags
  materially flatter than NDT-only, with the improvement demonstrated on a corridor
  where NDT-only measurably degrades.
- No pose discontinuity above 0.3 m attributable to tag acquisition.
- System degrades to NDT-only cleanly when tags are absent, with correct
  diagnostics and no estimator instability.
- Diagnostics report per-source health accurately, verified by deliberately
  occluding cameras during a run.

---

## 9. Risks

**Tag map accuracy ceiling.** The bootstrap approach cannot exceed mapping-pass
NDT accuracy. If the indoor PCD map is poor, everything built on it is poor, and
the failure will look like a tag problem rather than a map problem. Mitigation:
sub-project B has its own NDT-quality acceptance gate before C runs.

**Calibration is a single point of failure.** Extrinsic error propagates directly
into every tag observation, and its signature (range-correlated offset) is easy to
misdiagnose as a tuning problem. Mitigation: A has explicit numeric acceptance
criteria, and D's diagnostics report tag-vs-NDT residual as a function of range.

**DBW blocker is inherited, not introduced.** No wheel velocity means no
validated NDT means nothing in this design can be tested end to end. This should
be stated loudly in planning rather than discovered during integration.

**Per-session tag placement drift.** "Roughly repeatable positions" means the tag
map must be regenerated per session. If someone skips the bootstrap drive and
reuses last session's tag map, the system will confidently localize to the wrong
place. Mitigation: tag map files carry a session stamp; D warns loudly when the
loaded tag map is older than the current session.

**Three camera instances of a GPU-free ArUco detector at 1920×1280 × 30 Hz.**
CPU cost on the Orin is not yet measured. Mitigation: measure early; fall back
to reduced detection rate, `DM_FAST` detection mode, or downscaled detection
input if needed.

---

## 10. Open Questions and Deferred Decisions

**Tag detection source for the initializer.** Either consume the existing
localizer's debug detection output, or run a dedicated ArUco detector instance.
The first avoids duplicate detection cost; the second decouples the initializer
from a debug-topic contract. Decide during implementation, after CPU cost is
measured.

**ArUco dictionary and tag ID allocation.** Not yet chosen. Needs to account for
the number of tags on the route, inter-ID Hamming distance, and printability at
0.6 m.

**LiDAR retroreflector markers, deferred.** `autoware_lidar_marker_localizer` is
installed and its config directory is already wired at
`tier4_localization_component.launch.xml:70`. Reflectors are lighting-independent
and would pair naturally with the VLP-32C. Deferred because the chosen deployment
model is per-session removable markers, where printed tags are far more practical
than mounted retroreflective boards. The landmark abstraction is shared, so
adding this later is additive rather than a rewrite.

**Where the merged tag pose enters NDT regularization.** Injection ③ needs the
merged tag pose, but the merger's output currently feeds the EKF. Whether the
merger publishes a second topic for regularization, or regularization taps the
same topic, is an implementation detail with a correctness implication: feeding
the EKF's own input back into NDT, whose output then re-enters the EKF, creates
a loop. The regularization feed must be **tag-only**, never the merged
NDT+tag stream. Stated here so it is not discovered as a bug.
