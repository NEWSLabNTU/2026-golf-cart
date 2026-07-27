# Phase 3C — Tag Map Building

Part of [Phase 3 indoor localization](3-indoor-localization.md).
Design spec: [§2 C](../superpowers/specs/2026-07-27-indoor-artag-localization-design.md#c--tag-map-building-contract-for-d)

**Status: Not started — blocked by sub-phases A and B; blocks sub-phase D**

Last updated: 2026-07-27

---

## Goal

Get every AR tag's 4-vertex polygon into the Lanelet2 map, in the map frame,
**without a total station**, and repeatably enough to redo it every session.

---

## The constraint that shapes this sub-phase

Tags are placed per session at roughly repeatable positions and removed
afterwards. Surveying every tag with a total station on every deployment is not
viable. The tag map must be regenerable by driving.

## Approach: survey-free tag mapping by NDT bootstrap

Replay the sub-phase B mapping bag (or drive the route again with the finished
map). NDT localizes against the PCD map; ArUco detection runs on all three
cameras; for each observation, compute the tag pose in the map frame:

```
T_map→tag  =  T_map→base_link (NDT)  ∘  T_base_link→camera (calibration)  ∘  T_camera→tag (PnP)
```

Accumulate many observations per tag across ranges and viewing angles, reject
outliers, average, emit Lanelet2 4-vertex polygons. Redeployment becomes a
ten-minute drive rather than a survey crew.

This inverts the dependency usefully: mapping-time NDT bootstraps the tag map,
then at runtime the tag map bounds NDT drift. It works because mapping-time NDT
is offline-quality — slow, batched, loop-closed — while runtime NDT is the thing
that drifts.

### The honest caveat

Tag map accuracy is capped by mapping-pass NDT accuracy plus extrinsic
calibration error. **Tags bound drift; they do not add absolute truth.** Nothing
downstream can be more accurate than this step, and this step cannot be more
accurate than sub-phases A and B.

If true global accuracy is needed later, add a handful of total-station-surveyed
anchor tags and fit the rest against them. The design accommodates this without
restructuring.

---

## Tasks

### Not done

- [ ] **Choose the ArUco dictionary** — account for tag count on the route,
      inter-ID Hamming distance, and printability at 0.6 m.
- [ ] **Define the tag ID allocation scheme** — unique IDs, no duplicates.
      Duplicate IDs create localization ambiguity that the runtime cannot resolve.
- [ ] **Produce and mount the physical tags** — 0.6 m
      (`marker_size: 0.6` in `ar_tag_based_localizer.param.yaml`), on
      removable mounts. Foam board or poster stock, not permanent installation.
- [ ] **Plan tag placement from sub-phase B's NDT degeneracy analysis** — tags go
      where NDT is weak (long featureless corridors), on side walls where the
      left/right cameras see them broadside. A tag seen head-on constrains range
      poorly; a tag passing broadside constrains both lateral and longitudinal
      position well.
- [ ] **Write the tag-mapping tool** — offline, consumes a rosbag plus the PCD
      map, emits Lanelet2 polygons. Per-tag outlier rejection and averaging.
- [ ] **Emit per-tag quality metadata** — observation count, residual spread,
      range and viewing-angle distribution. Sub-phase D uses this to down-weight
      or reject poorly-constrained tags.
- [ ] **Validate the emitted Lanelet2** — vertices counter-clockwise,
      `type=pose_marker`, loadable by `autoware_landmark_manager`, unique IDs,
      no degenerate (non-planar) polygons.
- [ ] **Stamp the tag map with a session identifier** — sub-phase D warns when a
      stale tag map is loaded.

### Can do before A and B complete

- [ ] Dictionary choice, ID scheme, physical tag production.
- [ ] Tag-mapping tool skeleton and Lanelet2 emitter, testable against synthetic
      trajectories.

---

## Acceptance criteria

- Lanelet2 map containing per-tag 4-vertex polygons, loading cleanly in
  `autoware_landmark_manager` with `tf_static` published for every tag.
- Unique IDs verified programmatically.
- Per-tag observation count and residual spread recorded; tags below a minimum
  observation count flagged rather than silently included.
- Full regeneration from a fresh drive completes in ≤ 30 minutes end to end,
  including the drive. If it takes longer, the per-session model does not hold
  and the deployment plan needs revisiting.

---

## Foot-gun

Reusing a previous session's tag map after tags have been re-placed is the
sharpest failure mode in the whole phase: the vehicle would localize
**confidently** to the wrong position. Session stamping plus the staleness
warning in sub-phase D exist specifically for this.
