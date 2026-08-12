# Phase 3 — Indoor AR-Tag + NDT Localization (master)

Replaces GNSS with camera-detected AR tags for indoor operation, keeping NDT as
the primary pose estimator.

Design spec: [2026-07-27-indoor-artag-localization-design.md](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md)

Last updated: 2026-07-27 (design phase, no implementation started)

---

## Why

GNSS performs three separate jobs in this stack. Indoors, all three disappear at
once, and they need three different replacements:

1. **Cold-start pose** for `autoware_pose_initializer`
2. **Absolute correction** bounding NDT drift, via the EKF pose input
3. **NDT regularization** along geometrically degenerate axes

Item 3 is the one that matters most indoors and is easiest to miss. Autoware's
NDT already ships a `regularization` input whose documented purpose is fixing
longitudinal degeneracy **in tunnels, using GNSS**. An indoor corridor is the
same geometry problem. It is currently disabled:

```yaml
# config/localization/ndt_scan_matcher/ndt_scan_matcher.param.yaml:44
regularization:
  enable: false
```

---

## Sub-phase structure

```
A. Camera calibration          intrinsics + camera→base_link extrinsics
      │                        BLOCKS EVERYTHING DOWNSTREAM
      ├──────────────┐
B. Indoor mapping    │         LiDAR SLAM → PCD + Lanelet2, NDT validated
   (independent of A)│         indoors with no GNSS in the pipeline
      └──────┬───────┘
             ▼
C. Tag map building            tag polygons into Lanelet2, in map frame,
                               without a total station
             ▼
D. Runtime integration         3× ar_tag_based_localizer + pose merger +
                               tag init path + launch wiring + tuning
```

A and B are independent — two people can run them in parallel.

| Sub-phase | Doc | Status |
|-----------|-----|--------|
| A — Camera calibration | [3-indoor-a-camera-calibration.md](3-indoor-a-camera-calibration.md) | Not started |
| B — Indoor mapping | [3-indoor-b-indoor-mapping.md](3-indoor-b-indoor-mapping.md) | Not started |
| C — Tag map building | [3-indoor-c-tag-map-building.md](3-indoor-c-tag-map-building.md) | Not started |
| D — Runtime integration | [3-indoor-d-runtime-integration.md](3-indoor-d-runtime-integration.md) | Design complete, not started |
| E — Board pose initializer | [3-indoor-e-board-initializer.md](3-indoor-e-board-initializer.md) | Design complete, not started |

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

## Deployment model

Tags are **placed per session** at roughly repeatable positions and removed
afterwards. This drives two decisions that shape the whole design:

- Per-deployment total-station survey is not viable → sub-phase C builds the tag
  map by **NDT bootstrap** (drive the route, detect tags, back out tag poses from
  the NDT trajectory).
- Tag poses are therefore bootstrap-derived, not survey truth → sub-phase D
  inflates tag covariance so tags **bound drift** rather than dominating NDT.

Reusing a stale tag map from a previous session is the sharpest foot-gun in this
design: the system would localize confidently to the wrong place. Tag map files
carry a session stamp and D warns when the loaded map is stale.

---

## Blockers

| Blocker | Blocks | Owner |
|---------|--------|-------|
| **Turing Drive DBW package** — `velocity_report.py` still a stub publishing zeros | B, C, D — NDT cannot be validated without wheel velocity | Phase 2 Track B (pre-existing, see [2-track-b.md](2-track-b.md)) |
| Camera intrinsics are placeholders (`camera_matrix: [1,0,960, 0,1,640, 0,0,1]`) | C, D | Sub-phase A |
| No indoor PCD map exists | C, D | Sub-phase B |
| Indoor site not yet fixed | B (mapping run scheduling) | — |

The DBW blocker is inherited, not introduced by this work. It is on the critical
path for the entire phase and should be escalated rather than discovered during
integration.

---

## Exit criteria

- Cold start with no GNSS and no manual RViz input succeeds in ≥90% of trials, within 30 s.
- Longitudinal drift over the longest corridor is materially bounded relative to
  NDT-only, demonstrated on a corridor where NDT-only measurably degrades.
- No pose discontinuity above 0.3 m attributable to tag acquisition.
- Clean degradation to NDT-only when tags are absent, with correct diagnostics.

---

## Related work already in the repo

- [docs/research/lidar_marker_localization.md](../research/lidar_marker_localization.md) —
  Autoware reflector-marker writeup (LiDAR modality, deferred; see design §10)
- [docs/research/indoor_localization.md](../research/indoor_localization.md) —
  broad survey (SLAM, UWB, mocap, AprilTag, WiFi)

Both carry AutoSDV-era historical notes; sensor specifics are stale, method
content is not.

All required Autoware packages are already installed at `/opt/autoware/1.5.0/share`:
`autoware_ar_tag_based_localizer`, `autoware_landmark_manager`,
`autoware_lidar_marker_localizer`, `autoware_pose_estimator_arbiter`. No upstream
package needs adding or forking.
