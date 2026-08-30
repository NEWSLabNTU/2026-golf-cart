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

## Order of work

1. Record the campus route and plot degeneracy anisotropy along it. Cheap, and it
   decides whether anything below is needed.
2. Switch `covariance_estimation_type` to Laplace; confirm the CUDA matcher
   honours it; check the EKF's behaviour changes in the direction expected.
3. Sweep `regularization.scale_factor` with GNSS available, outdoors only.
4. Re-run the FOV sweep on the TIERS OS0-128 data, which unlike the Autoware
   sample bag is wider than the Robin-W in *both* axes and can therefore emulate
   the vertical field of view as well as the horizontal.
5. Everything in Tier 3, in the order given, and only on evidence from 1.
