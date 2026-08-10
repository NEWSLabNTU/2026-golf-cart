# ArUco Indoor Localizer — Design

**Status**: Draft, revised 2026-08-10 after scope change
**Date**: 2026-08-10
**Supersedes**: [2026-07-27-indoor-artag-localization-design.md](2026-07-27-indoor-artag-localization-design.md)
**Phase docs**: [3-indoor-localization.md](../../roadmaps/3-indoor-localization.md)

---

## 0. Scope

ArUco boards carrying one ID each are mounted around an indoor field. Their
poses are **measured by hand and supplied as data**. The vehicle detects
whatever boards are in view across all cameras and solves for its own pose.

**This is the sole pose source. NDT is not used.** No point cloud map, no scan
matching, no GNSS.

That is a deliberate simplification and a good fit for the problem: NDT indoors
is degenerate along exactly the axis a corridor is long, which was the entire
motivation for the regularization machinery in the previous design. If boards
supply absolute position directly, NDT adds a mapping pipeline, a tuning
surface, and a failure mode in exchange for a signal that is weakest where it
is most needed.

The cost is that **there is no longer a second opinion**. Sections 5 and 7 are
about paying that cost honestly rather than discovering it on the vehicle.

### What this scope change deletes

| Previously | Now |
|---|---|
| Sub-project B — indoor LiDAR mapping, PCD + NDT validation | **Deleted.** No point cloud map is needed at all. |
| Sub-project C — tag map bootstrap by NDT drive | **Deleted.** Poses are measured by hand and given. |
| Injection ③ — NDT regularization, and its feedback-loop hazard | **Deleted.** Nothing to regularize. |
| Injection ① — `/initialpose` seeding for NDT to refine | **Reduced.** Nothing to refine against; see §4.3. |
| Covariance inflation because the tag map is NDT-derived | **Deleted.** The map is measured, not inferred. |
| Tag-map staleness warnings, per-session regeneration | **Deleted** if boards are permanent; see §3. |
| `golfcart_pose_merger` | Already dropped; now doubly moot with one source. |

Sub-project A — camera calibration — is unchanged and is now the *only*
remaining prerequisite sub-project. The critical path shortened dramatically.

### What it makes harder

Three things get worse, and they are the whole of the remaining risk:

1. **Coverage becomes safety-critical.** No boards visible no longer means
   "degrade to NDT"; it means dead reckoning on gyro and wheel odometry, whose
   error grows without bound. §5.
2. **Heading has no other absolute source.** Previously NDT and the IMU carried
   yaw and boards corrected position only. Now yaw must come from the boards,
   which is precisely the channel where a single marker is worst. §2.3.
3. **A wrong map entry is uncontradicted.** A board that was mistyped or has
   been knocked askew will place the vehicle confidently in the wrong place,
   with nothing to disagree. §6 adds integrity monitoring for this.

---

## 1. The physical setup

Boards come from LCTK's `aruco_generator_node`, one ArUco ID each — in that
schema, `type = "multiple_arucos"` with `num_squares_per_side = 1` (there is no
separate single-marker path; `Config::SingleAruco` is `todo!()` and panics).
Geometry follows the generator's own formulas:

```
square_size = board_size − 2 × board_border_size
marker_size = square_size × marker_square_size_ratio
```

With LCTK's shipped values (500 mm board, 10 mm border, 0.8 ratio) a 1×1 board
carries a **384 mm** marker. `marker_size` is what enters PnP, and an error in
it scales every range estimate linearly.

> **Open — blocks parameter defaults:** the dictionary and the actual
> `board_size` / `border` / `ratio` used, and whether all boards are one size.
> LCTK's shipped configs use `DICT_5X5_1000`.

**Unique IDs are load-bearing.** `DICT_5X5_1000` gives a thousand codes for a
few dozen boards, so each detected ID maps to exactly one known pose and
association needs no prior. This is why the system can produce a global pose
from a standing start with nothing else running — see §4.3 — and it is worth
protecting: never reuse an ID within the field.

For contrast, Autoware's landmark format targets AprilTag 16h5, which has only
30 codes, and its map spec says outright that "if multiple tags of the same type
are to be placed in one environment, they should be assigned the same ID."
Everything awkward about that node — needing a prior to associate, inability to
self-initialize, picking the tag nearest the prior — descends from that scarcity.
It does not apply here.

---

## 2. Core algorithm

### 2.1 One joint solve

The unknown is `T_map→base` ∈ SE(3). Known: `T_map→tag_i` from the measured map,
`T_base→cam_c` from TF, `K_c` from each camera's `CameraInfo`.

For marker `i` in camera `c`, corner `j`:

```
P_ij  = T_map→tag_i · p_j                     known 3D point, map frame
x̂_ijc = π( K_c , (T_base→cam_c)⁻¹ · (T_map→base)⁻¹ · P_ij )
r_ijc = x̂_ijc − x_ijc                         measured, rectified pixels
```

Minimize `Σ ρ(‖r‖²)` by Levenberg–Marquardt with an analytic Jacobian, `ρ` a
Huber kernel applied **per marker** — all four corners of a marker share one
robust weight, because when a board is wrong (moved, mismeasured, wrong ID) all
four of its corners are wrong together. Rejecting at corner granularity lets
three bad corners hide behind the fourth.

Multi-camera is free: cameras differ only in `T_base→cam_c` and `K_c`. Near
markers self-weight, because they subtend more pixels and carry a larger
Jacobian. Covariance is `σ̂²(JᵀJ)⁻¹` with `σ̂²` from residuals at `dof = 2N − 6`.

**Do not fuse by multiplying per-marker Gaussians.** Adámek et al. (Sensors
23(12):5746, 2023, §6.3) show the independence assumption breaks and the fused
variance comes out "unrealistically low" when several markers are visible — the
worst possible error now that nothing else can contradict it.

### 2.2 The noise model

Corner noise is close enough to i.i.d. in pixels that the anisotropy everyone
reports emerges from the Jacobian without a separate model:

```
σ_lat ≈ Z · σ_px / f                 linear in range
σ_Z   ≈ Z² · σ_px / (f · s)          QUADRATIC in range
σ_Z / σ_lat ≈ Z / s
```

Form and exponents from Fernández Llorca et al. (IET ITS 2021,
arXiv:2101.06159, Eq. 4), where the marker edge `s` plays the role of a stereo
baseline; confirmed for ArUco specifically by Adámek et al., who publish the
functional form but no fitted constants. A 384 mm board at 10 m gives a **26×**
depth-to-lateral error ratio.

**Off-axis coupling.** Depth error leaks laterally through the bearing off the
optical axis: `σ_X ≈ sqrt((Z·σ_px/f)² + (tanθ·σ_Z)²)`. At the edge of a wide
field of view this dominates. **Build the covariance in the camera frame and
rotate it into the map frame; never assume it is axis-aligned in the vehicle
frame.** `lidar_marker_localizer` has the rotation helper to borrow
(`rotate_covariance`, `lidar_marker_localizer.cpp:308`).

**`corner_sigma_px = 0.3`** to start, inflated to 0.5–1.0 under motion. No paper
publishes a measured corner σ for ArUco with sub-pixel refinement; the
circulating "0.05–0.5 px" is not traceable to a primary source. 0.3 is
back-solved from FMAC's synthetic depth errors (arXiv:2601.07723) and
cross-checked against STag's centre-jitter measurements (< 0.35 px at 720p,
< 0.20 px at 1080p). §8 measures it directly.

### 2.3 Heading is now the hard part

Previously NDT and the IMU carried yaw and boards corrected position only.
With NDT gone, **the boards are the only absolute heading reference**, and that
is the channel where a single marker is worst.

**Measured single-marker rotation jitter is 11.70° standard deviation** over
1000 frames (Benligiray et al., STag, *Image and Vision Computing* 2019) —
while corner localization in the same experiment stays under 0.35 px. Range
destroys pose stability far faster than it destroys corner stability, because
the geometry conditioning collapses, not because the pixels get noisier.

The cause is the planar two-solution ambiguity, and **it is worst looking
straight down the marker normal**:

| Finding | Source |
|---|---|
| Variance peaks at φ = 0; an order of magnitude lower at 40–70° | Adámek et al., Sensors 2023 |
| Rotation std ~12.5° at 3 m **at 0° viewing angle** | STag, Fig. 17a |
| Pitch indistinguishable anywhere in −10°…+10° | *Frontiers in Robotics and AI* 9:838128, 2022 |
| ±25° cone about the normal deliberately excluded from testing | Richter et al., IFAC 2022 |
| Accuracy sweet spot 25°–75° off normal | Abbas et al., Sensors 19(24):5480, 2019 |

Detection separately holds to 75° and collapses at 85° — 0 misses in 1000
frames to 75°, 416/1000 at 80°, total failure at 85° (STag, Table 5).

**So the operating strategy is: gyro carries heading between fixes, and every
multi-marker fix corrects it.** The EKF already estimates yaw bias
(`enable_yaw_bias_estimation: true`). What this demands of deployment is that
**two well-spread boards be visible often enough to bound gyro drift** — not
merely often enough to be useful. That is a coverage requirement with a number
attached, and §5 puts one on it.

### 2.4 Flip resolution by consensus

Given the above, a single marker's orientation cannot be trusted, and choosing
its branch by nearest-to-prior is how upstream ends up confirming its own prior.
Resolve jointly instead — the published rule, from Muñoz-Salinas &
Medina-Carnicer (*UcoSLAM*, Pattern Recognition 101:107193, 2020), is to select
the solution minimising reprojection error across all observations. Our version
resolves across *markers*, which is stronger because the map poses are known:

```
1. For each marker i and IPPE solution k ∈ {1,2}: candidate T_map→base^(i,k)
2. Cluster the 2N candidates in SE(3)
3. Largest cluster is the consensus; its membership assigns each flip
4. Seed the LM solve from the cluster mean, using consensus corners
```

With one marker there is no consensus, and the honest handling is a gate:
**reject when `err₁/err₂ > 0.2`** (PhotonVision's deployed threshold for
AprilTag 3D tracking; IPPE's own documentation prescribes a likelihood-ratio
test but publishes no number), and **reject or heavily inflate rotational
covariance when |φ| < 25°**.

#### Two markers is not automatically enough — they must not be coplanar

This is the subtlety that makes the mounting rule of §5 a correctness
requirement and not just an accuracy one.

Consensus works because each marker's *correct* solution maps to the same
vehicle pose — they are all watching one vehicle — while the *wrong* solutions
map to different poses, because each flip is a reflection about a plane through
that marker's own line of sight. Correct answers pile up; wrong ones scatter.

**That argument fails when the markers are coplanar.** Two boards on the same
wall are one planar point set, and a planar set has the two-fold ambiguity as a
set. Their flips are very nearly the same transformation, so the wrong
solutions agree with *each other* as well as the right ones do. The result is
two clusters of equal size and no way to choose — a tie, not a consensus.

It is a matter of degree rather than a cliff. Coplanar boards spread widely
across the field of view do partially break the tie, because a wide planar set
gives perspective more to work with; coplanar boards clustered together do not
break it at all. Non-coplanar boards break it cleanly, because a non-coplanar
point set has no planar ambiguity to begin with.

So:

| Visible | Flip resolvable? |
|---|---|
| 1 marker | No. Gate on `err₁/err₂` and covariance. |
| ≥2, same wall, close together | **No** — near-tie. Detect and publish nothing. |
| ≥2, same wall, widely separated in the image | Weakly. Treat with suspicion. |
| ≥2, different normals | Yes, cleanly. This is the design point. |

The tie detection in §8 is the safety net, not the plan. **The plan is the
mounting rule: two boards visible everywhere is the floor, but they must have
different normals for the floor to mean anything.** Two boards on one wall
satisfy "≥2 visible" and still leave the flip unresolved.

### 2.5 Degeneracy, and one mechanism that covers it

Perturb the pose by `(δθ, δt)`; a correspondence at `p` moves by `δθ × p + δt`.
Write `p = p̄ + Δ` about the correspondence centroid and choose `δt = −δθ × p̄`,
and the residual collapses to `δθ × Δ`. **A rotation about the centroid of the
correspondences is a near-null direction of the cost, damped only by their
spread.** The cost function will not complain.

Three situations are the same phenomenon: one visible marker (four coplanar
points, the IPPE ambiguity); several markers all on one wall at one depth; and
well-spread markers. So they get one mechanism, not three special cases —
**eigendecompose `JᵀJ`, invert per eigendirection, saturate unobservable
directions at a large variance cap.**

Never emit a zero variance and never invert unguarded. LCTK's `M-13` records
both traps: `try_inverse()` bails on exactly the singular case the covariance
exists to describe, and **a zero variance reads downstream as "exact"**, which
with no second source is now the most dangerous output the system can produce.

### 2.6 Degrees of freedom, chosen per window

| Observability | Solve | Orientation |
|---|---|---|
| ≥2 markers in consensus, normal spread above threshold | full 6-DoF | Estimated. **The nominal state.** |
| ≥2 markers, coplanar or narrow spread | 6-DoF, eigen-saturated | Estimated, weak axis saturated |
| 1 marker, `err₁/err₂ ≤ 0.2`, outside the ±25° cone | 3-DoF position | Clamped to prior — **degraded, see §5** |
| 1 marker, ambiguous or inside the cone | reject | — |

One code path with a mask on the parameter vector. Note the third row is now
materially worse than it was under the previous scope: the clamped orientation
comes from gyro propagation with no absolute correction, so time spent there is
time heading drifts. It is a stopgap between multi-marker fixes, not a mode to
dwell in.

### Observability diagnostics

Per solve: number of distinct markers used and their IDs; **angular spread of
marker normals** (max pairwise, using `|dot|` so a flipped normal does not read
as 180° of spread); depth range; `cond(JᵀJ)`; reprojection RMS overall and per
marker; `err₁/err₂` per marker.

**Do not rank on reprojection RMSE.** LCTK measured it inverting — their
degenerate captures scored 3.46 px against 8.12 px for the only usable set.
Report it; normal spread was the only statistic that separated cleanly on real
data and the only one that tells an operator what to physically change.

---

## 3. The tag map

Measured by hand, supplied as data. A standalone YAML file living beside the
vector map:

```yaml
# data/<site>/aruco_tag_map.yaml
frame_id: map
survey:
  date: "2026-08-10"
  method: "laser distance meter + plumb line"
  stated_accuracy: 0.02          # [m] 1σ, applies to all tags unless overridden

defaults:
  dictionary: DICT_5X5_1000
  marker_size: 0.384             # [m] MARKER edge, not board edge

tags:
  - id: 696
    position:    {x: 12.340, y: -3.210, z: 1.500}
    orientation: {x: 0.0, y: 0.0, z: 0.70711, w: 0.70711}
    position_stddev: 0.02        # optional per-tag override

  - id: 64                       # convention-free alternative form
    corners: [[x,y,z], [x,y,z], [x,y,z], [x,y,z]]   # counter-clockwise
```

**The `corners` form is preferred for hand measurement.** Four measured corner
points fix position, orientation *and* size with no frame convention to
document or mis-implement. Supplying a quaternion by hand requires deciding what
the tag's local axes mean and getting it right; supplying four corners does not.
This is the one genuinely good idea in Autoware's Lanelet2 landmark format, and
with a manual survey it is the natural output anyway.

If the pose form is used, the convention is pinned here and asserted in a unit
test — OpenCV's marker frame, origin at centre, **X right, Y up, Z out of the
face toward the viewer**, corners in `TL, TR, BR, BL` order:

```
p_TL = (−s/2, +s/2, 0)   p_TR = (+s/2, +s/2, 0)
p_BR = (+s/2, −s/2, 0)   p_BL = (−s/2, −s/2, 0)
```

LCTK's `M-14` is the cautionary tale: corner order defined twice, in two
languages, with nothing checking they agreed. A corner permutation is a silent
90° or 180° pose error that still "succeeds."

**`survey.stated_accuracy` now sets the system's accuracy ceiling**, and it is
the single number most worth getting right. Under the previous scope the ceiling
was mapping-pass NDT accuracy, which was unknowable in advance; under manual
measurement it is knowable and controllable. It enters the solve as a per-tag
weight, so a few carefully-measured anchor boards can legitimately outweigh
roughly-placed ones.

> **Open — needed to set expectations honestly:** what instrument, and what
> accuracy? A tape measure over a large hall accumulates error very differently
> from a laser distance meter worked off a fixed baseline, and a total station
> differs again. §6's accuracy claims are conditional on this.

**Lanelet2 is not used for landmarks.** Six of the seven reasons Autoware has
for it are Autoware-specific — non-unique IDs needing many-poses-per-ID, latched
`LaneletMapBin` distribution across machines, geo-referencing consistency,
sharing an abstraction with the LiDAR retroreflector localizer, Vector Map
Builder authoring, and arbiter zones in the same file. None applies here. The
seventh, that a polygon is what a survey produces, is real and is kept as the
`corners` form above.

A vector map is still required for **planning**, and `map_projection_loader`
still runs. What is no longer required is the point cloud map.

---

## 4. Components

```
 camera left  ─┐
 camera right ─┼─▶ aruco_detector ×3 ─── ArucoDetectionArray ──┐
 camera rear  ─┘   (corners, K, IPPE pair)                     │
                                                               ▼
   aruco_tag_map.yaml ────────────────────▶ golfcart_aruco_localizer
   TF base_link ← camera_*_optical ───────▶   window · consensus · joint LM
   /localization/kinematic_state (twist) ─▶   covariance · integrity · gates
                                                    │              │
                                    pose_with_covariance      localization state
                                                    ▼              ▼
   IMU + wheel odom ──▶ gyro_odometer ──────▶ ekf_localizer     system / MRM
                                                    │
                                                    ▼
                                        /localization/kinematic_state
```

One pose source, one twist source, one filter. That is the whole of it.

### 4.1 `aruco_detector` — one per camera

Pure corner detection: no map, no TF, no map-frame pose.

Subscribes `~/input/image` via `image_transport` with `transport:=compressed`
(the gscam pipeline is jpeg-only — no raw `sensor_msgs/Image` exists on these
topics, so subscribing compressed avoids both a decompressor node and a topic
round-trip) and `~/input/camera_info`. Publishes `~/output/detections` and,
when enabled, `~/debug/image`.

**The detection sequence, copied verbatim from LCTK:**

```
1. detect on the RAW, distorted frame        cv::aruco::detectMarkers
2. sub-pixel refine on the RAW frame         CORNER_REFINE_SUBPIX
3. map corners to the rectified frame        cv::undistortPoints(R=I, P=K,
                                               TermCriteria(COUNT|EPS, 20, 1e-8))
4. PnP with ZERO distortion                  corners are already rectified
```

Steps 1–2 run raw because undistorting the image resamples bilinearly and blunts
exactly the gradients refinement needs (LCTK `H-08`). Step 3 needs `P = K` or it
silently returns *normalized* coordinates, and the iterative variant because
OpenCV's default 5 iterations leave real residual error. Step 4 must pass zero
distortion — passing `D` again double-corrects, which LCTK measured at **40 px**
of displacement on a ~900 px image (`C-03`), radius-dependent, poisoning exactly
the wide-FoV observations this design depends on.

Three LCTK bugs collapse into that four-step sequence. It is the single
highest-value carryover.

**Distortion passed in full, never truncated.** OpenCV accepts 4/5/8/12/14-length
`D`; these cameras publish 12. LCTK `L-03` is the bug of slicing to 5 and
dropping rational-polynomial `k4`–`k6`. Also **validate `distortion_model`** and
refuse unknown values rather than assuming `plumb_bob`.

**Per-marker PnP** must keep both solutions and both reprojection errors, since
`err₁/err₂` is the ambiguity metric §2.4 gates on. `estimatePoseSingleMarkers`
throws the second away, which is why LCTK has no confidence metric at all
(`score: 1.0` hardcoded).

> **Measured, and it changes the recipe.** `solvePnPGeneric` with
> `SOLVEPNP_IPPE_SQUARE` on OpenCV 4.5.4 returns poses that *do not reproject* —
> on noiseless synthetic corners the better solution was off by 2.84 px at a
> 0.5 rad tilt and 115 px viewed fronto-parallel, where the right answer
> reprojects to zero by construction. `estimatePoseSingleMarkers` looks fine only
> because on this version it quietly uses the iterative solver, not IPPE.
>
> So the working recipe is: take candidates from *both* `SOLVEPNP_ITERATIVE` and
> `SOLVEPNP_IPPE_SQUARE`, refine every one with `solvePnPRefineLM`, score them
> with a reprojection error computed in our own code, and deduplicate before
> reporting the alternate. That recovers the true pose to ~1e-5 px across every
> geometry tested, and makes the ambiguity ratio mean something. Reference
> implementation: `aruco_sim_detector/marker_pnp.hpp`. Detail in phase doc 3D-5.

**Detector parameters constructed in exactly one validated function** (LCTK
`L-11`, where a copy-pasted five-line block set the same field twice and tuned a
refiner that never ran). Defaults from LCTK's measured sweep: `SUBPIX`,
`win_size 5`, `max_iterations 30`, `min_accuracy 0.01`; adaptive threshold
`13/33/10`. SUBPIX beat NONE by 25–60% at every apparent marker size from 54 px
to 302 px.

**Typed messages, not `vision_msgs/Detection2DArray`.** LCTK's `C-01` is a
critical bug that happened *because* corners were smuggled through a message
with no field for them — consumers reconstructed them as `centre ± size/2` and
every correspondence was wrong, up to 20 px, for any non-fronto-parallel view.
Then `H-10` re-created it through a dump/load path that forgot to serialize the
smuggled field.

```
# ArucoDetection.msg
uint32   id
float64[8] corners_rectified       # TL,TR,BR,BL as u,v
geometry_msgs/Pose pose_1          # camera-optical frame, IPPE solution 1
geometry_msgs/Pose pose_2
float64  reprojection_error_1
float64  reprojection_error_2

# ArucoDetectionArray.msg
std_msgs/Header header             # stamp = capture; frame_id = camera optical frame
float64[9] k                       # the K used — self-contained, replayable
ArucoDetection[] detections
```

Carrying `k` makes a recorded detection stream replayable without the camera,
and detections are small enough that a bag of them is a practical tuning
artifact where a bag of three 1920×1280 streams is not.

#### Build here, or extend LCTK's node?

LCTK is ours and can be modified. `ros/aruco_locator_node` is already most of
this: it subscribes image and `CameraInfo`, rebuilds its detector on
calibration, runs the four-step sequence correctly, and publishes per-marker
corners. Three gaps:

1. **`rational_polynomial` unsupported** — `DistortionModel` is a one-variant
   enum and the MRPT loader hard-errors past coefficient 5. The detector core
   already passes `d` through in full, so this is a loader fix.
2. **Wrong entry point wired** — `detect_markers()` gates all-or-nothing on the
   detected ID set exactly equalling the configured set, right for calibration
   against one board, wrong for a localizer. `detect_single_aruco()` has the
   right semantics and is unused.
3. **No per-marker pose or ambiguity metric** — `estimate_pose()` is dead code
   that calls `estimatePoseSingleMarkers` and passes non-zero `D` against
   already-rectified corners.

All three are improvements LCTK wants on its own terms (`L-03`, `L-12` record
the first and third). The Rust-in-an-ament-repo objection does not bite:
`src/localization/cuda_ndt_matcher` is already a Cargo workspace in this build,
and ROS integration is at the topic level.

**Recommendation: extend LCTK's node**, consume it as a submodule, keep the
localizer here. Messages belong in a small standalone package both can depend
on. One thing needs coordinating rather than deciding unilaterally: whether
LCTK's `Detection2DArray` output is retained or replaced, since that is a
breaking change to its calibration pipeline.

### 4.2 `golfcart_aruco_localizer` — one instance

Subscribes the N detection topics, `/localization/kinematic_state` for twist,
and TF. Reads the tag map at startup.

Publishes `~/output/pose_with_covariance` →
`/localization/pose_estimator/pose_with_covariance`, `/initialpose3d` (§4.3),
`~/debug/{mapped_tags,used_tags}` as `MarkerArray`, `~/status` (§5), and
`/diagnostics`.

**Windowing.** Cameras are not hardware-synchronized. Detections are buffered
over a short window (default one frame period, ~33 ms), motion-compensated to a
common reference stamp via the EKF twist, and solved jointly. Compensation is
switchable — at indoor speeds the intra-window displacement is small — but its
absence would appear as a speed-dependent bias, which is miserable to debug
later.

**Solve** as §2. Six parameters and a handful of markers is a small dense
problem: hand-rolled LM, no Ceres dependency, and direct access to `JᵀJ` for
covariance and conditioning.

**Output contract**, matched to upstream so nothing downstream changes:
`PoseWithCovarianceStamped`, `header.frame_id = "map"`, stamped with the
**sensor** stamp. Note the EKF multiplies the published covariance by
`pose_smoothing_steps` (5) before its update and Mahalanobis-gates it — budget
for both.

### 4.3 Initialization

Under the previous scope, `/initialpose` fed `autoware_pose_initializer`, which
NDT-aligned the seed. With no NDT there is nothing to align against, and the
pose the localizer produces from a standing start is already the answer — unique
IDs make association prior-free and the solve is a global resection.

So initialization is a **mode inside the localizer**, publishing to
`/initialpose3d` (the EKF's own initial-pose input) once gates pass:

```yaml
initialization:
  min_markers: 2                   # a single ambiguous marker must not seed
  min_normal_spread_deg: 20
  max_range: 8.0                   # [m] tighter than the tracking limit
  max_view_angle: 50.0             # [deg] off marker normal
  consecutive_solves: 5            # agreeing solves required
  agreement_radius: 0.5            # [m] spread across those solves
  max_condition_number: 1.0e4
  republish_cooldown: 10.0         # [s]
```

**Decision to confirm during implementation:** publish `/initialpose3d`
directly, or keep `autoware_pose_initializer` in the chain as a passthrough with
`ndt_enabled: false, gnss_enabled: false`? Direct is simpler; keeping it
preserves the AD API localization state machine that planning and the system
monitor may observe. Check what consumes `/api/localization/initialization_state`
before cutting it out.

Manual RViz "2D Pose Estimate" stays available as a fallback in every state.

### 4.4 What is reused unmodified

`ekf_localizer`, `gyro_odometer`, `map_projection_loader`, the lanelet2 map
loader. No upstream package is forked or patched.

**Not used:** `ndt_scan_matcher`, `cuda_ndt_matcher`, `pointcloud_map_loader`,
the NDT pointcloud preprocessing chain, `autoware_ar_tag_based_localizer`,
`autoware_landmark_manager`, `autoware_pose_estimator_arbiter`.

`localization_error_monitor` and `pose_instability_detector` are NDT-shaped and
need review rather than blind reuse — their thresholds assume a scan-matching
convergence signal that no longer exists.

The LiDARs remain on the vehicle for **perception**. They are also the obvious
fallback if §5's coverage requirement proves hard to satisfy in practice, which
is worth remembering before anyone removes them.

---

## 5. Coverage, degradation, and MRM

This section exists because deleting NDT deleted the fallback. It is the most
important new work in this revision.

### Localization states

| State | Condition | Behaviour |
|---|---|---|
| `NOMINAL` | ≥2 markers in consensus, spread above threshold | Full 6-DoF fixes. Heading corrected. |
| `DEGRADED` | 1 usable marker, or ≥2 with poor spread | Position fixed, heading on gyro. Time-limited. |
| `DEAD_RECKONING` | 0 usable markers | Gyro + wheel odometry only. Error grows without bound. Hard time budget. |
| `FAULT` | Integrity check failed (§6), or dead-reckoning budget exhausted | Request MRM. |

The localizer publishes this on `~/status` and to `/diagnostics`. The
dead-reckoning budget is a configured duration derived from measured IMU drift
and odometry error against an allowable position error — **it must be set from
measurement, not guessed**, and when it expires the vehicle stops. The repo's
existing MRM configuration ([docs/guides/mrm_configuration.md](../../guides/mrm_configuration.md))
is the hook.

### The coverage survey is a required deliverable

Before the vehicle drives, walk the route with a camera at the mounting height
and record, for every point on it, how many boards are visible and at what
incidence. The output is a coverage map identifying:

- stretches with **< 2 boards** visible — these are `DEGRADED` and must be short
  enough that gyro drift stays inside budget
- stretches with **0 boards** — these are `DEAD_RECKONING` and should not exist
  on a route the vehicle is allowed to drive autonomously
- boards mounted so the driving line views them within the ±25° cone

This replaces the previous design's "≥5 boards where accuracy matters," which
was an accuracy target. **It is now an availability requirement**, and it is
strictly stronger.

### Mounting rules

1. **≥2 boards with *different normals* visible everywhere on the route.**
   Hard floor, not a target. The count alone is not the requirement: two boards
   on the same wall are coplanar, their flips agree, and the ambiguity stays
   unresolved (§2.4). Below this, heading is uncorrected.
2. **≥5 where accuracy matters.** The measured knee: 1→7 markers took x-RMSE
   from 45.29 cm to 2.97 cm, with diminishing returns past seven
   (arXiv:2509.17345).
3. **Yaw boards ~30° off the wall**, so the driving line never sits inside the
   ambiguity cone.
4. **Spread normals and depths.** Five coplanar boards at one depth are worth
   far less than three on different walls.

Rules 1–2 want boards clustered; rule 4 wants them apart. Corners and junctions
satisfy both. Long straight runs satisfy neither easily and need the most boards
and the most thought.

> **Sizing question that should be answered before printing:** how many boards
> does rule 1 imply for this field? At useful detection ranges and incidences,
> ≥2-visible-everywhere over an open hall is a very different count from a
> corridor network. Walking the route with a camera answers it in an afternoon
> and is much cheaper than discovering it after mounting.

---

## 6. Integrity monitoring

With one pose source, a wrong map entry or a knocked board places the vehicle
confidently in the wrong place and nothing disagrees. That is the characteristic
failure of this architecture and it needs an explicit defence.

**The redundancy is between markers.** When ≥2 are visible, the joint solve
over-determines the pose and each marker's post-solve residual is a consistency
check. A board that has moved, or whose map entry is mistyped, shows a large
persistent residual for that ID while others stay small.

This is exactly the GNSS **RAIM** problem — N redundant measurements, detect and
exclude the faulty one — and that literature is where to look for the
fault-detection-and-exclusion structure rather than inventing one.

Implementation:

- **Per-ID residual EWMA**, maintained across the session. A board whose
  normalized residual persistently exceeds threshold is flagged, named in
  diagnostics, and excluded from the solve.
- **Exclusion requires redundancy.** With exactly 2 markers, excluding one
  leaves an unchecked solve; with 1, there is no check at all. The status
  published in §5 must reflect *checked* versus *unchecked* fixes, because an
  unchecked fix is a different thing from a checked one even when both look
  fine.
- **Startup validation** of the map file: duplicate IDs are a hard error;
  boards closer together than a threshold are a warning (association is by ID so
  it is safe, but it usually means a typo); board poses far outside the field
  bounds are a warning.
- **A flagged board is a maintenance event, not a tuning problem.** The
  diagnostic should say which physical board to go and look at.

---

## 7. Expected accuracy

**The ceiling is now the survey**, not a mapping pass. Fused accuracy cannot
exceed the accuracy of the measured board poses, and that number is set by
instrument and technique rather than by anything in this design. This is a
genuine improvement in *knowability* — it can be stated in advance and improved
by re-measuring, where the previous scope's ceiling depended on NDT quality that
could only be assessed after the fact.

Against that ceiling, the vision system contributes:

| Condition | Expectation |
|---|---|
| 1 marker | Position tens of cm at range; **heading unusable** (11.7° jitter) |
| 2–4 markers, spread | Position ~5–10 cm; heading usable |
| ≥5 markers, spread | Position ~3 cm; the measured knee |

The closest published analogue — Muñoz-Salinas et al., *Mapping and Localization
from Planar Markers* (Pattern Recognition 73:158–171, 2018), which builds a
marker map and localizes against it — reports absolute corner error **2.1 cm**
over a 90-marker lab sequence and trajectory error **44.7–69.4 mm**, against
LSD-SLAM and ORB-SLAM2 baselines of 117–913 mm. A few centimetres is the right
expectation when geometry and survey are both good.

Add the survey error and the vision error in quadrature for the honest figure.
A 2 cm survey and 3 cm vision gives ~3.6 cm; a 10 cm survey makes the vision
accuracy nearly irrelevant, which is the argument for measuring carefully once.

---

## 8. Failure modes

| Failure | Detection | Handling |
|---|---|---|
| 0 boards visible | Marker count | `DEAD_RECKONING`, time-budgeted, then MRM stop. **No longer a benign state.** |
| 1 board visible | Marker count | `DEGRADED`: position fixed, heading on gyro, time-limited. |
| Board moved or mismeasured | Per-ID residual EWMA (§6) | Flag, name the board, exclude, request inspection. |
| Single board, IPPE-ambiguous | `err₁/err₂ > 0.2` | Reject. No branch selection by prior. |
| Board viewed inside the ±25° cone | `\|φ\|` from normal | Rotational covariance inflated or observation dropped. Systematic occurrence means bad mounting. |
| Flip consensus splits evenly | Cluster sizes | Publish nothing that window; WARN. Usually means the visible boards are **coplanar** — their flips agree with each other, so both clusters are equal (§2.4). Persistent occurrence at one place is a mounting problem, not a tuning one. |
| Only coplanar boards visible | Normal spread, `cond(JᵀJ)` | Covariance saturates on the unobservable axis; EKF de-weights automatically. |
| Duplicate ID in map | Startup validation | Hard error naming the ID. Uniqueness is load-bearing. |
| Wrong `marker_size` | Range error scales linearly → offset grows with range | Range-correlated signature. Distinguish from extrinsic error by whether it affects all cameras equally. |
| Bad camera calibration | Range-correlated offset, per camera | Caught by sub-project A gates; per-camera residual breakdown identifies which. |
| Detections with no map entry | Explicit unmapped-ID counter | WARN listing the IDs. **Never synthesize a pose** — this is upstream's zero-pose bug, and an indoor map near the origin is where it bites. |
| Exposure hunting, motion blur | Per-camera detection rate | Fixed-exposure gscam profiles; `auto_exposure`/`auto_white_balance` are currently `true` and must become `false`. |
| CPU saturation | Per-frame processing time | Reduce rate before resolution — corner precision is what the whole error model scales on. Less headroom than before, since this is now the only pose source. |

**Policy note, from LCTK `C-04`:** a gate whose threshold sat *below* the sensor
noise floor could never pass, and the detector published empty detections for
months unnoticed. Measure the noise floor first; default to warning rather than
rejecting until a threshold is justified by data. The exceptions are the safety
gates in §5 and §6, which must reject.

---

## 9. Prerequisites and blockers

**1. No optical frames — hard blocker.** `sensor_kit.xacro` defines
`camera_left/right/rear` as body-frame links, yaw-only, `roll = pitch = 0`, with
no `*_optical_link` anywhere, while gscam publishes `frame_id: camera_left` in
`CameraInfo`. PnP returns an optical-convention pose, so composing through a
body-frame TF rotates every observation ~90°. Fix in sub-project A by adding
optical children with `RPY = (−π/2, 0, −π/2)`. **The localizer resolves the
optical frame by name at startup and fails loudly if TF cannot** (LCTK `H-04`).

**2. Camera intrinsics are one file copied three times.**
`camera_{left,right,rear}_calibration.yaml` are byte-identical but for
`camera_name`, declare `rational_polynomial` with 12 coefficients, and are
inconsistent with the declared 1920×1280 — `cx = 712` against a centre of 960,
`fx` differing 25% between `K` (986) and `P` (735). Must be redone per camera.

**3. `sensor_kit_calibration.yaml` exists twice and the copies disagree.** The
authoritative one is under
`src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/`.
It also names a `usb_camera_front` with no xacro link and no launch node.

**4. `ekf_localizer.param.yaml` sets `pose_gate_dist: 10000.0`**, disabling
Mahalanobis rejection. Upstream's default is 49.5. With no second pose source
this gate is now the EKF's only defence against a bad fix — restore it.

**5. Dead launch arguments.** `use_gnss`, `use_mapless_mode`, `lidar_model`,
`camera_model`, `imu_source`, `gnss_receiver`, `use_ntrip`, `sensor_suite` are
declared, passed down, and consumed by nothing. `use_mapless_mode` is now
conceptually what this system runs in and should be wired properly.

**6. Launch surgery.** A new `pose_source:=aruco` must bring up the detectors,
the localizer and `gyro_odometer`, and must **not** bring up
`ndt_scan_matcher`, its pointcloud preprocessing, or `pointcloud_map_loader`.
Both branches of `tier4_localization_component.launch.xml` currently assume a
scan matcher.

**7. DBW publishes zero velocity.** `velocity_report.py` stubs a zero
`VelocityReport` at 20 Hz. The EKF needs real twist, so the *fused* output is
blocked — but note the localizer's raw pose output can be validated against
ground truth without any vehicle interface, so this blocks integration rather
than development.

**8. `CLAUDE.md` Autoware paths are wrong.** It names 2025.02 at
`/home/aeon/repos/autoware/2025.02-ws`, which does not exist. The real tree is
`/home/aeon/repos/autoware/1.5.0-ws`, universe 0.48.0, with the binary install
at `/opt/autoware/1.5.0/share`.

---

## 10. Testing

**Unit, no hardware.** Corner-order array against OpenCV's ordering (`M-14`).
Distort → detect → undistort round-trip, built by inverting `undistortPoints`
into a `remap` table — port LCTK's `rectify_contract.rs`, including the test
that fails with *"SUBPIX and NONE produced the same corners, so corner
refinement is not running at all"* and the one catching a `P`-less
`undistortPoints`. Solver convergence on synthetic constellations. Covariance
saturation on a deliberately singular `JᵀJ`. Rational-polynomial 12-coefficient
handling. Map loader: duplicate IDs, missing fields, malformed quaternions,
both pose and corners forms agreeing.

**Solver quality, synthetic.** Generate constellations spanning the degeneracy
axis — one marker, coplanar cluster, well-spread — and assert reported
covariance grows in the directions that are genuinely unobservable. This proves
§2.5's central claim.

**Integrity, synthetic.** Corrupt one board's map entry, confirm the per-ID
residual flags that board and not its neighbours, and confirm the system reports
an *unchecked* fix when redundancy is insufficient to run the check.

**Bench validation, no Autoware.** Measure four or five boards in a room, drive
or carry the camera rig through it, compare against independently measured
positions. This validates the entire localizer — consensus, covariance, DoF
switch, integrity — with no map, no DBW and no vehicle.

**Measure `corner_sigma_px` rather than trusting it.** Park stationary, record
~1000 frames, take the standard deviation of corner positions. Repeat at two
ranges and while moving. An hour of work that converts the constant the whole
covariance model rests on from a literature-anchored guess into a measurement.

**Route coverage survey** (§5) — a deliverable, not a test, but it gates
autonomous driving.

**Acceptance.**

- Cold start with no manual input in ≥90% of ≥20 trials from varied positions
  within 30 s.
- Position error against independently measured ground truth within the
  quadrature sum of survey and vision error, at ≥5 points on the route.
- Heading error bounded across a full route lap — the metric that matters most
  now that nothing else corrects it.
- `DEGRADED` and `DEAD_RECKONING` states entered and exited correctly, verified
  by deliberately occluding cameras mid-run; MRM requested when the budget
  expires.
- A deliberately displaced board is detected, named, and excluded within a
  bounded number of observations.
- No pose discontinuity above 0.3 m at board acquisition.

---

## 11. Risks

**Coverage is the dominant risk and it is a physical problem, not a software
one.** Every stretch of route without two visible boards is a stretch where
heading drifts uncorrected. This is discoverable cheaply — walk the route with a
camera before mounting anything — and expensive to discover late.

**Survey error propagates directly and invisibly.** A systematic error in the
measured board poses appears as a systematic pose error with no signature that
distinguishes it from a calibration problem. Mitigation: measure a few boards
twice by different means, and keep the per-board residuals from §6 under review
early in deployment, when a bad measurement is still cheap to fix.

**Single point of failure by construction.** There is no independent check on
the localization solution as a whole — §6's integrity monitoring checks boards
against *each other*, which catches a moved or mistyped board but not a
systematic error affecting all of them (a wrong `marker_size`, a wrong extrinsic,
a map frame offset). The LiDARs are still on the vehicle and remain the obvious
route to an independent check if one is later wanted.

**Calibration is upstream of everything.** Extrinsic error propagates into every
observation with a range-correlated signature easy to misdiagnose as tuning.
Sub-project A's numeric gates are the defence.

**CPU on the Orin is unmeasured**, and there is less headroom than before,
because reducing detection rate now directly reduces the rate of the only
absolute pose source.

**TF direction convention.** LCTK's `M-01` — `solvePnP` returns
`p_cam = R·p_obj + t`, and that raw `rvec`/`tvec` stuffed into a
`TransformStamped` labelled `frame_id=lidar, child_frame_id=camera` means the
*inverse* in ROS TF. Still open in that repo. Every pose here composes four
transforms; get the direction right on day one and assert it, because a
consistently inverted chain still produces plausible numbers.

---

## 12. Open questions

1. **Survey instrument and accuracy** — sets the system's accuracy ceiling
   (§3, §7). Needed to state expectations honestly.
2. **Dictionary, board size, border, ratio** used for the printed boards, and
   whether all are one size — blocks parameter defaults (§1).
3. **Board count and layout** implied by the ≥2-visible-everywhere rule (§5).
   Answer by walking the route before printing.
4. **Dead-reckoning time budget** — derived from measured IMU drift and odometry
   error against an allowable position error. Must be measured (§5).
5. **`/initialpose3d` direct, or `pose_initializer` as passthrough?** Check what
   consumes the AD API localization state before cutting it out (§4.3).
6. **`localization_error_monitor` and `pose_instability_detector`** — both are
   NDT-shaped. Review, retune, or replace (§4.4).
7. **Whether LCTK's `Detection2DArray` output is retained or replaced** — a
   breaking change to its calibration pipeline, needs coordinating (§4.1).
8. **Thresholds for the §2.6 DoF switch and §6 integrity gates** — set against
   measured data, warning before rejecting per `C-04`.
