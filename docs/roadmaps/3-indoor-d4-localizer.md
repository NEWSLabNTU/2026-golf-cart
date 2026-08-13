# Phase 3D-4 — Localizer algorithm

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §2, §5, §6

**Depends on**: D1, D3.
**Blocks**: D6.

---

## Goal

`golfcart_aruco_localizer`: detections from every camera in, one vehicle pose
with an honest covariance out, plus a localization state and integrity verdict.

The largest phase. It has a natural split — **get poses publishing first, then
add integrity and states.** Stage 1 is the solve; stage 2 is everything that
makes it safe to be the only pose source.

---

## Stage 1 — the solve

### Windowing

- [x] Buffer detections from all cameras over a window, default one frame period
      (~33 ms).
- [x] Motion-compensate each detection to a common reference stamp using EKF
      twist. Switchable off.
- [x] Output stamped with the **sensor** stamp, not receive time.

Compensation is cheap to build now and its absence shows up later as a
speed-dependent bias, which is miserable to diagnose after the fact.

### Candidate generation and flip consensus

- [x] For each detected marker and each of its two IPPE solutions, form a
      candidate `T_map→base`. N markers gives 2N candidates.
- [x] Cluster the candidates in SE(3).
- [x] Largest cluster is the consensus; membership assigns each marker's flip.
- [x] Markers with neither solution in the cluster are flagged, not silently kept.
- [x] Seed the solve from the cluster mean.
- [x] Tie between two equal clusters → publish nothing that window, WARN.
      **A tie is the expected outcome for coplanar boards**, whose flips agree
      with each other as well as the correct solutions do (spec §2.4). Detecting
      it is not an edge case, it is the safety net for a mounting mistake — so
      the WARN should say *coplanar boards* rather than just "ambiguous".

**Never pick the branch nearest the prior.** With ≥2 markers this needs no prior
at all, and choosing by proximity to the prior is precisely how the upstream
node produces a measurement biased toward confirming what the filter already
believes.

### Joint solve

- [x] Levenberg–Marquardt over `T_map→base` (6 parameters), analytic Jacobian.
- [x] Residuals are reprojection errors of every corner of every marker of every
      camera. Cameras differ only in `T_base→cam` and `K`.
- [x] Huber kernel applied **per marker** — all four corners of a marker share
      one robust weight, because a wrong board makes all four wrong together.
      Rejecting at corner granularity lets three bad corners hide behind the fourth.
- [x] Per-tag weight from `position_stddev` in the map.
- [x] Small dense problem — hand-rolled, no Ceres dependency, and direct access
      to `JᵀJ` for covariance and conditioning.

### Covariance

- [ ] `Σ = σ̂²(JᵀJ)⁻¹`, `σ̂²` from residuals at `dof = 2N − 6`.
- [x] **Eigendecompose and invert per eigendirection, saturating unobservable
      directions at a large variance cap.** Never `try_inverse()` unguarded —
      `JᵀJ` is routinely near-singular and that is a *result*, not an error.
- [x] **Never emit a zero variance.** Downstream reads it as exact.
- [ ] Build the covariance in the **camera frame and rotate it into map**, not
      axis-aligned in the vehicle frame. Depth error leaks laterally off-axis as
      `tanθ·σ_Z`, which dominates at the edge of a wide field of view.
      `lidar_marker_localizer.cpp:308` has the rotation helper to borrow.

One mechanism covers three situations that look different and are not: a single
ambiguous marker, a coplanar cluster at one depth, and healthy geometry. All
three are the same near-null direction of `JᵀJ`.

### Observability and DoF selection

- [x] Compute per solve: marker count and IDs, **angular spread of marker
      normals** (max pairwise, using `|dot|` so a flipped normal does not read as
      180° of spread), depth range, `cond(JᵀJ)`, reprojection RMS overall and per
      marker, `err₁/err₂` per marker.
- [x] Select DoF per window:

| Observability | Solve | Orientation |
|---|---|---|
| ≥2 markers in consensus, spread above threshold | full 6-DoF | estimated |
| ≥2 markers, coplanar or narrow spread | 6-DoF, eigen-saturated | estimated, weak axis saturated |
| 1 marker, `err₁/err₂ ≤ 0.2`, outside the ±25° cone | 3-DoF position | clamped to prior |
| 1 marker, ambiguous or inside the cone | reject | — |

One code path with a mask on the parameter vector, not three implementations.

**Do not rank on reprojection RMSE.** LCTK measured it inverting — degenerate
captures scored better than usable ones. Report it; rank on normal spread, which
was the only statistic that separated cleanly on real data and the only one that
tells an operator what to physically change.

### Output

- [x] `PoseWithCovarianceStamped` on
      `/localization/pose_estimator/pose_with_covariance`, `frame_id = "map"`.
- [ ] Debug `MarkerArray`s for mapped boards and boards used this solve.

---

## Stage 2 — integrity and states

### Integrity monitoring

The redundancy is *between boards*. With ≥2 visible, the solve is
over-determined and each marker's post-solve residual is a consistency check.
Structurally this is the GNSS RAIM problem — N redundant measurements, detect
and exclude the faulty one — and that literature is where to look rather than
inventing a scheme.

- [x] Per-ID normalized residual, EWMA across the session.
- [x] Persistent exceedance → flag, exclude from the solve, name the board in
      diagnostics. **The message should say which physical board to go and look
      at**, because this is a maintenance event, not a tuning problem.
- [x] Track and publish whether a fix was **checked** or **unchecked**. With
      exactly two markers, excluding one leaves an unchecked solve; with one
      there is no check at all. An unchecked fix is a different thing from a
      checked one even when both look fine.
- [x] Unmapped detected IDs: count and WARN listing them. **Never synthesize a
      pose.** The upstream node returns a default-constructed zero pose with
      `q.w = 0` in this case, which a large map's distance gate happens to
      swallow — an indoor map near the origin does not.

### State machine

- [x] `NOMINAL` — ≥2 markers in consensus, spread above threshold.
- [x] `DEGRADED` — 1 usable marker, or ≥2 with poor spread. Time-limited.
- [x] `DEAD_RECKONING` — 0 usable markers. Hard time budget.
- [x] `FAULT` — budget expired, or integrity check failed. Requests MRM.
- [x] Publish on `~/status` and to `/diagnostics`. Diagnostics is the machine
      path to MRM; `~/status` is the human and TUI path.
- [x] Recovery from every state except `FAULT` when boards are reacquired.

The dead-reckoning budget is a configured duration derived from **measured** IMU
drift and odometry error against an allowable position error. It must not be
guessed — that number is what stands between a coverage gap and the vehicle
driving on a stale estimate.

### Initialization mode

- [x] Gates from spec §4.3: `min_markers: 2`, minimum normal spread,
      `max_range: 8.0`, `max_view_angle: 50.0`, 5 consecutive solves agreeing
      within 0.5 m, `max_condition_number`, republish cooldown.
- [x] Publish `/initialpose3d` (or via `pose_initializer` — decided in D2).
- [x] Never seed from a single ambiguous marker.

---

## Tests

All of these run against D3's synthetic source, no hardware.

- [x] **Zero-noise round trip** — recovers ground truth to numerical tolerance.
      This is the whole geometry chain: map convention, corner order, TF
      composition, optical frame, solve direction.
- [x] **Degeneracy sweep** — one marker, coplanar cluster, well-spread. Assert
      reported covariance grows in the directions that are genuinely
      unobservable, and does not in the others.
- [x] **Singular `JᵀJ`** — covariance saturates rather than throwing or
      returning zeros.
- [x] **Noise scaling** — covariance tracks `corner_sigma_px`.
- [x] **Flip consensus** — with ≥2 markers, resolves correctly with no prior;
      with a deliberate tie, publishes nothing.
- [x] **Integrity** — one displaced board is flagged and excluded, its neighbours
      are not, and the fix is reported as unchecked when redundancy runs out.
- [x] **State machine** — every transition, including budget expiry to `FAULT`
      and the MRM request, driven by D3's blackout injection.
- [ ] **Stamp handling** — future stamps and out-of-order arrivals rejected.

---

## Sequencing note

Stage 1 is publishable and demonstrable on its own: a pose tracking a scripted
trajectory in simulation is a real milestone and worth landing before stage 2
starts. But **stage 2 is not optional polish.** With one pose source and no
cross-check, the state machine and integrity monitor are what make the system
safe to drive behind. Do not let stage 1 working well be mistaken for the phase
being finished.

## Stage 2 results, and what running the loop changed

Stage 2 added integrity monitoring and the localization state machine, and the
first end-to-end run against the synthetic bench changed five things. All five
were defects in what was designed, not in how it was coded, and none would have
been found by unit tests alone.

### Measured, against ground truth

879 fixes over a 10 m straight run, three cameras, 0.3 px corner noise, seven
boards with spread normals:

| | p50 | p95 | max |
|---|---|---|---|
| position error | 0.017 m | 0.030 m | 0.610 m |
| yaw error | 0.08° | 0.23° | 179.92° |
| reported sigma | 0.028 m | 0.228 m | — |

Position holds inside the 0.02 m survey accuracy, which is the ceiling on
everything downstream. The max column is the interesting one; see the open
item below.

### `max_range` was set by eye and was roughly 60 % too far

The limit belongs where the ambiguity gate stops keeping flipped boards out, not
where the detector stops seeing boards — it sees them considerably further than
it can orient them. Measured for a 0.384 m board at f = 900 under 0.3 px corner
noise, over the 25–75° view window, the share of boards that *pass* the
ambiguity gate and are still flipped:

| range | 7 m | 8 m | 9 m | 11 m | 13 m |
|---|---|---|---|---|---|
| flipped among gate-passing | 0.00 % | 0.14 % | 2.3 % | 16.5 % | 24.2 % |

The gate holds to about 8 m and then comes apart. `max_range` moved 13 → 8 m.
The figure scales with `f · marker_size / pixel_noise`; re-measure if any of the
three change.

### The condition number was computed in mixed units

The increment is ξ = (δt, δθ): three metres and three radians. The condition
number of an information matrix whose blocks carry different units is not a
property of the geometry — it changes if translation is expressed in
centimetres — so no fixed threshold on it means anything. The raw value was
being compared against 1e4 and reported "ill-conditioned" on nearly every window
of a healthy fixture. Substituting δθ = δθ′/L for a characteristic lever L (the
mean board range, which is exactly the lever by which an angular error becomes a
positional one) puts the rotation block in metres of arc and makes the threshold
meaningful.

### The integrity monitor faulted the vehicle when it succeeded

`integrity_failed` was `!flagged.empty()`, so the first board the monitor
excluded latched FAULT and requested an MRM stop. This is backwards: a flagged
board has already been dropped from the solve and the fix continues without it,
which is the entire point of having redundancy. Detection *and exclusion* is the
remedy. What warrants a stop is being unable to isolate — more exclusions than
`residual_max_excluded`, past which "several bad boards" is a worse explanation
than something common to all of them (extrinsics, marker size, map frame).

### The ratio test alone flagged healthy boards

Residuals differ between boards for reasons of geometry rather than health, and
a board at several times the cohort median is still fine when every residual
involved is sub-pixel. A board must now also exceed the median by
`residual_flag_margin_px` in absolute terms.

### Two tolerances were nearly widened to hide a symptom

Intermittent "no two boards agree" looked like tolerances set below the
single-board rotation jitter the design itself cites (11.7°). Both the
consensus rotation tolerance and a range-scaled position gate were written, and
both were wrong: measured over the admitted view window, two boards at 5.5 m
disagree by 0.27 m and 2.8° at the 99th percentile, so the original 0.5 m / 10°
tolerances were already generous. The 11.7° figure characterizes the *ungated*
near-fronto-parallel case, which `min_view_angle_deg` exists to exclude. The
real cause was too-generous `max_range` admitting boards that could not be
oriented; widening the gate would have traded a stalled fix for a confidently
wrong one. Both changes were reverted and the reasoning pinned in tests.

## Open item: one flipped fix in 876, published confidently

One fix carried a 179.92° yaw error with position correct to 0.051 m and a
reported sigma of 0.152 m — a heading reversal that looked trustworthy. At
roughly 0.1 % this is well outside what the covariance advertises, and a
reversed heading is not a degraded fix, it is a dangerous one.

The obvious mitigation is an innovation gate on the output: compare the solve
against the propagated prior and refuse, or heavily inflate, when they disagree
by more than the covariance allows. **This needs a decision before it is built**,
because it sits against a stated principle of the design — that the branch is
never chosen by proximity to the prior, since that is how an estimator ends up
confirming what the filter already believes. Gating the *published output* is
not the same act as choosing the *branch*, and is standard practice, but the
line between them is thin enough to be worth agreeing on deliberately rather
than discovering later in a log.

Interim position: the EKF's `pose_gate_dist` (49.5) is the only thing currently
standing between this and the filter. That is a backstop, not a design.

## Bookkeeping

39 of 43 items ticked, all covered by the 69 unit tests plus the D6 smoke suite.

Three shipped **differently from the specification**, and the difference matters
more than the tick would:

- **`Σ = σ̂²(JᵀJ)⁻¹` is wrong and was not implemented.** The weight matrix
  already carries `1/σ²ₚₓ`, so scaling by a residual-derived `σ̂²` counts the
  noise twice — and collapses the covariance to zero whenever the data happens
  to fit well. What shipped is `Σ = (JᵀWJ)⁻¹`, with `σ̂²` kept as a diagnostic
  that sits near 1 when the assumed corner noise matches reality. The box is
  left unticked because ticking it would record the wrong formula as done.
- **The consensus tolerances** are not the ones the spec implies. Measured
  board-to-board disagreement inside the admitted view window is 0.27 m and
  2.8° at p99, so the original values were already generous; the spec's 11.7°
  single-marker jitter describes an ungated regime this system does not operate
  in.
- **`ambiguity_ratio_max` does not do what the spec assumed.** Measured in D5:
  it is a *resolution* gate, not a *geometry* gate, and reports maximum
  confidence exactly at the fronto-parallel views that are least reliable.
  `min_view_angle_deg` is what protects those.

Still open:

- **Build the covariance in the camera frame and rotate it into map.** Not
  implemented; it is built directly in the solve frame.
- **Debug `MarkerArray` for boards used this solve.** Only `~/debug/mapped_tags`
  exists.
- **Out-of-order arrivals.** Future stamps are rejected and tested; ordering is
  not.
