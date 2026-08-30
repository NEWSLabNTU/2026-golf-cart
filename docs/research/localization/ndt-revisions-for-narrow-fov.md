# Revising NDT for a forward-facing Robin-W

The Robin-W is mounted forward. [restricted-fov-ndt.md](restricted-fov-ndt.md)
measured what plain NDT does at that width on the Autoware sample route: a 120
degree forward wedge tracked the full-circle solution to 0.22 m at p95 over 130 m
and lost no frames. So nothing here is a rescue. It is the list of changes worth
making because the margin is thinner than the full circle's, ordered by what they
cost.

Two measured facts drive the whole list:

- **Heading degrades before position.** Across the forward sweep, position
  deviation went 0.19 / 0.22 / 0.22 / 0.34 m as the wedge narrowed 180 to 60
  degrees, while frame-to-frame yaw error rose 2.7x. Whatever fails first will
  be angular.
- **Direction dominates width.** The same 120 degrees facing backwards gave 2.99 m
  scatter against 0.107 forward. The geometry the wedge happens to face is worth
  more than how wide it is, and that is exactly the quantity that varies along a
  route and cannot be fixed by tuning.

Papers behind every direction below:
[narrow-fov-related-work.md](narrow-fov-related-work.md).

## Tier 1: two config lines, both currently set the wrong way for a narrow FOV

These are defaults inherited from a full-circle sensor. Neither is code.

### Stop telling the EKF a lie about which axis to trust

`covariance_estimation_type: 0` -- FIXED_VALUE -- in both
`cuda_scan_matcher.param.yaml` and Autoware's own
`ndt_scan_matcher.param.yaml`. Every pose NDT publishes carries the **same**
covariance matrix, hardcoded, regardless of what the scan actually constrained.

On a full-circle sensor that is a tolerable approximation, because the geometry
constrains most directions most of the time and the error is roughly isotropic.
On a 120 degree forward wedge it is not, and it is the wrong lie in the wrong
direction: the fusion filter is told the pose is equally trustworthy in the
along-track direction -- the one a forward wedge constrains worst -- as across it.
The EKF then happily corrects the axis that NDT knew least about.

The alternatives are already implemented upstream: `1` (Laplace approximation,
derived from the Hessian), `2` (multi-NDT), `3` (multi-NDT score). Laplace is
nearly free because the Hessian is already computed -- our own `AlignResult`
carries it and comments it as being for exactly this. The multi-NDT modes cost
extra registrations per frame and buy a better-conditioned estimate.

**This is the highest-value change on the list**, because it does not make NDT
more accurate; it makes the rest of the stack correctly sceptical of NDT
precisely when the wedge is facing nothing useful. Verify the CUDA matcher
honours the setting before assuming it does.

### Turn on the regularization built for this exact failure

`regularization.enable: false`, with a comment in our own config saying it
"penalizes deviation from GNSS pose in longitudinal direction."

That is a description of the corridor problem. A forward wedge in a straight
featureless stretch is unconstrained *along travel*, which is the one direction
this feature constrains from an external prior. It is off, and it was off because
the sensor it was tuned around did not need it.

Caveats worth stating before switching it on: it needs a trustworthy GNSS, which
is what the golf cart's u-blox is for outdoors and is exactly what is missing
indoors; and `scale_factor: 0.01` is a default nobody here has tuned, so it needs
a sweep alongside the degeneracy monitor rather than being switched on blind.

## Tier 2: use the degeneracy signal now being published

The scan matcher now publishes, per frame, the conditioning of the registration
problem split into translation and rotation blocks
(`cuda_ndt_matcher/src/node/degeneracy.rs`; topics under
`/localization/pose_estimator/degeneracy/`). It is diagnostic only -- nothing is
gated on it, because no threshold has been measured.

Three uses, in order:

1. **Find out whether the problem exists on the real route.** The whole
   restricted-FOV study rests on 130 m of one sample bag, and the honest caveat
   is that the route may never present a degenerate stretch. Recording anisotropy
   along the campus route answers that directly, before any algorithm work is
   justified.
2. **Set the covariance from it** if the upstream modes above prove unsuitable.
   The eigenvector of the smallest eigenvalue names the weak direction; inflating
   covariance along it is the same idea as Laplace, done explicitly.
3. **Solution remapping.** The established treatment: project the update onto the
   well-constrained subspace and leave the weak directions to the prior, instead
   of letting the optimizer wander along them. This is a real code change in the
   optimizer and should not be attempted before 1 has shown it is needed.

## Tier 3: structural, only if Tier 1 and 2 are not enough

**Tighten the inertial coupling.** Autoware registers with NDT and fuses
afterwards in `ekf_localizer`. The narrow-FOV literature is close to unanimous
that the sensors should be fused *inside* the estimator, so the IMU carries the
solution through the frames where the wedge constrains nothing and the scan
corrects when structure returns. This is the biggest architectural difference
between this stack and the systems that live on 70-to-80 degree Livox sensors.
See [narrow-fov-localization-methods.md](narrow-fov-localization-methods.md).

**Sliding-window optimization on the prior map.** Registering a window of frames
jointly rather than one at a time. A direction unconstrained in one frame is
usually constrained a second later, and a window recovers what frame-by-frame
registration discards. Largest change, best evidence, correct last resort.

**A second sensor, pointed anywhere but forward.** The measurements say a
rear-facing wedge alone is very poor, but that is not an argument against a rear
sensor -- it is an argument against a rear sensor *alone*. The value of a second
wedge is that it constrains the axes the front one does not, and the study's own
direction table is the evidence that different directions carry very different
information. If Tier 1 and 2 do not close the gap, this is likely cheaper and
more certain than any algorithm work.

## What not to do

**Do not tune on NVTL.** In this study the *worst* configuration measured -- the
rear-facing wedge, 30x the scatter of any other -- scored the *highest* NVTL of
any restricted run. NVTL rises when far and imperfect returns are cropped away,
which is what restricting a field of view does by definition. Anything selected
by maximising it will select for narrower crops and coarser voxels irrespective
of whether the pose improved. The repo has been here before: the earlier COSS
tuning study reached two conclusions that reversed when it was re-scored on pose
quality instead.

**Do not reach for voxel resolution first.** It is the obvious knob and it is
mostly orthogonal to this problem. A narrow FOV fails because some directions are
unobserved, not because the voxels are the wrong size, and coarser voxels raise
NVTL while doing nothing about it -- see above.

**Do not read the per-frame timings from the restricted runs as evidence.** The
FOV filter is a Python node; the full-circle control lost 90 of 292 frames to it
while the narrow runs kept all of theirs simply because they publish fewer
points. That ordering is a harness artifact and says nothing about the cost of a
narrow sensor.

## Ranked directions

Ordered by expected value divided by cost, for **this vehicle on Autoware**, not
in general. The measurements behind the reasoning are in
[restricted-fov-ndt.md](restricted-fov-ndt.md); the papers are in
[narrow-fov-related-work.md](narrow-fov-related-work.md).

The ranking is shaped by one result more than any other: **the prior dominated
the field of view by two orders of magnitude.** On the TIERS rig without a twist
source, one configuration gave median errors of 4.4 m, 7.3 m and 0.13 m across
three identical runs. With a twist source, three runs agreed to a millimetre.
Narrowing the field of view from 360 to 120 degrees, by comparison, moved the
median from 0.050 m to 0.082 m. Everything that protects the prior therefore
outranks everything that improves the matcher.

| # | direction | cost | why here |
|---|---|---|---|
| 1 | Fix the IMU | low | the prior chain is already degraded, before the sensor changes |
| 2 | Decide the map's sensor | low now, high later | untested assumption baked into a deliverable |
| 3 | Anisotropic covariance to the EKF | one line | the narrow-FOV failure mode, directly |
| 4 | Measure degeneracy on the real route | one drive | decides whether 6-9 are needed at all |
| 5 | Re-tune NDT for a dense narrow cloud | a sweep | current values were tuned for a different sensor |
| 6 | GNSS regularization | a sweep, outdoors | the corridor case, using Autoware's own feature |
| 7 | Re-check initialization and recovery | medium | untested under a restricted field of view |
| 8 | Tighter IMU coupling / different matcher | high | the real fix if 1-6 are not enough |
| 9 | A second sensor | hardware | strongest guarantee, least algorithm risk |

### 1. Fix the IMU

`config/sensors.conf` says `IMU_SOURCE=zed` because **the Xsens MTi is broken and
publishes nothing**. The fallback is the ZED X's IMU, which lives on the orin and
crosses the DDS link at 100 Hz, where `gyro_odometer` time-syncs it against
vehicle twist — so link jitter becomes twist noise.

That is a degraded prior on a vehicle that is about to become far more dependent
on its prior. It is also the cheapest item on this list and the only one that is
already broken rather than merely unproven. Nothing below is worth measuring
until the thing that dominates the result is healthy.

Same category, same reason: confirm `VelocityReport` stays fresh throughout
operation. It is gated on CAN frame freshness, so `ros2 topic hz` is the check,
not the assumption.

### 2. Decide what sensor builds the map

**Every map this project has — COSS, NTU campus — was built with a Velodyne.**
Every measurement in this campaign localized against a map built by the *same*
sensor that then localized against it. A Robin-W localizing against a
Velodyne-built map is a combination nobody has tested, and it differs in point
density, scan pattern and intensity response.

NDT is more forgiving of this than a feature-based matcher, because it models
distributions per voxel rather than matching structures. Forgiving is not the
same as verified.

This ranks second on timing rather than difficulty: it is a decision being made
now, and the cost of discovering it late is a re-survey. Either map with the
Robin-W, or test cross-sensor localization deliberately before committing to a
Velodyne-built production map.

### 3. Give the EKF an anisotropic covariance

`covariance_estimation_type: 0` — FIXED_VALUE — in both our
`cuda_scan_matcher.param.yaml` and Autoware's own. Every pose carries the same
hardcoded covariance regardless of what the scan constrained.

On a full circle that is a tolerable approximation. On a forward wedge it is the
wrong lie in the worst direction: the filter is told the along-track axis, which
a forward wedge constrains worst, is as trustworthy as the across-track one.

Options `1` (Laplace, from the Hessian we already compute), `2` and `3`
(multi-NDT) exist upstream. This does not make NDT more accurate; it makes the
rest of the stack correctly sceptical of NDT exactly when the wedge is facing
nothing. Verify the CUDA matcher honours the setting.

### 4. Measure degeneracy on the real route

The monitor is in place and publishes under
`/localization/pose_estimator/degeneracy/`. It responded correctly to a
field-of-view sweep in replay, with rotation anisotropy rising 2.8x against
translation's 1.2x.

One drive of the campus route with it recording answers the question the whole
study cannot: **does this site actually present degenerate geometry?** Every
number so far comes from 130 m of a sample route and 76 m of a Finnish car park.
If the campus never presents a long featureless stretch, items 6 to 9 are
unnecessary. If it does, this says where and how often.

Gate any alarm on **heading**, not position. Both the pose output and the Hessian
say rotation degrades first, independently.

### 5. Re-tune NDT for a dense, narrow cloud

`resolution: 2.0` and the downsample settings were chosen for a 360-degree
Velodyne. The Robin-W delivers over 1.28 M points/s into a quarter of the
azimuth, so the point density per voxel changes substantially, and NDT is
[unusually sensitive to voxel resolution](https://arxiv.org/pdf/2003.12841).

Cheap, and it is the one item where being on NDT specifically creates work that a
resolution-robust matcher such as VGICP would not need.

**Score it on pose quality, never on NVTL.** In this campaign the worst
configuration measured scored the highest NVTL of any restricted run.

### 6. GNSS regularization

`regularization.enable: false`, with our own config commenting that it
"penalizes deviation from GNSS pose in longitudinal direction" — a description of
exactly the corridor failure a forward wedge has. Needs trustworthy GNSS, so
outdoors only, and `scale_factor: 0.01` is untuned.

Below 4 because it is worth tuning against measured degeneracy rather than blind.

### 7. Re-check initialization and recovery

Two separate things, both untested at 120 degrees:

- **Global relocalization.** Scan Context, the standard descriptor for this,
  [degrades under a restricted field of
  view](https://arxiv.org/pdf/2503.17005). Whatever recovers the vehicle from a
  lost state should not be assumed to survive the sensor change.
- **Initial pose.** The Monte Carlo align path searches over particles, and a
  narrow wedge is a weaker discriminator between candidate poses. The CUDA
  matcher's initialization has been separately worked on; re-measure it under a
  restricted field of view rather than inheriting the full-circle result.

### 8. Tighter coupling, or a different matcher

The structural fix, and the one the literature is most unanimous about: fuse the
IMU **inside** the estimator rather than registering with NDT and fusing
afterwards in `ekf_localizer`. For a prior map the concrete form is [sliding
window factor graph optimization](https://arxiv.org/pdf/2402.05540).

A cheaper probe in the same direction is swapping the matcher for
[VGICP](https://staff.aist.go.jp/shuji.oishi/assets/papers/preprint/VoxelGICP_ICRA2021.pdf),
which is reported as accurate as GICP, faster, and robust to the voxel resolution
item 5 exists to tune.

Both are measurable now without new recordings: `data/tiers/baked_odo/` holds one
sequence at four fields of view and `compare_to_reference.py` scores anything
against a common trajectory. A candidate only has to consume a bag and emit
poses.

This is ranked eighth on cost, not on merit. If item 4 shows genuinely degenerate
stretches on the campus route, it moves up.

### 9. A second sensor

The measurements say a rear-facing wedge alone is very poor — 2.99 m scatter
against 0.107 forward. That is an argument against a rear sensor *alone*, not
against a second one. The value of a second wedge is that it constrains the axes
the front one does not, and the direction table is the evidence that different
directions carry very different information.

Last on this list because it costs hardware, but it carries the least algorithm
risk of anything in 8-9, and if the campus route turns out to be genuinely
degenerate it may be cheaper than the estimator work.

## If you only do three

1, 2 and 4. The first is already broken, the second is a decision with a
re-survey behind it, and the fourth tells you whether anything below it matters.
