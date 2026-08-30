# Why a denser, narrower LiDAR localizes worse

The campaign measured a 1.4x accuracy penalty for a 120 x 70 degree forward wedge
against an emulated VLP-32C, and the penalty survived a change of matcher, a
change of estimator structure, and every parameter swept. This asks what it
actually is, from measurement rather than argument.

The intuition under test: a Robin-W sees a quarter of the azimuth but samples it
twice as densely, so density might buy back what coverage loses. **It does not,
and the reason is not the one that seems obvious.**

Tooling: `tools/observability_analysis.py` for the per-frame geometry, and the
error decomposition below. Measurements from the TIERS OS0-128 bench with all
three sensors emulated from the same recording.

## First: it is not the range

Worth removing before anything else, because it is the natural first guess. The
Robin-W wedge was run at 70 m and at 200 m and scored identically, 0.077 either
way, because this sequence is a car park with nothing beyond 70 m. On this bench
the range difference between the sensors does no work at all. What differs is
**azimuthal coverage and density**.

## The observability metrics say Robin-W should win

Per-frame geometry, medians over sampled frames, against the real map:

| sensor | points | inliers | tr(H_trans) | min eigenvalue | H_trans anisotropy | measured error |
|---|---|---|---|---|---|---|
| full 360 x 90 | 148903 | 3594 | 3.60e6 | 4.04e5 | 5.21 | 0.050 |
| VLP-32C emul | 18402 | 1298 | 1.30e6 | 1.59e5 | 4.56 | **0.055** |
| Robin-W emul | 46036 | 1570 | **1.57e6** | **2.67e5** | **2.92** | **0.077** |

Read the Robin-W row against the VLP-32C row. It carries **more** translational
information, its worst-constrained direction is pinned down **1.7x better**, and
it is **better conditioned**. Its per-point yaw leverage is also the highest of
the three, because the wedge discards near-field ground and side returns and
keeps a longer median lever arm, 7.0 m against 4.9.

**By every per-frame measure of what a scan can observe, the Robin-W should
localize better than the VLP-32C. It measures 1.4x worse.**

That is the central result here, and it eliminates a whole family of
explanations. The penalty is not weak observability, not poor conditioning, not
degeneracy in the sense the literature means, and not a shortage of information.

## And density cannot recondition anything

Halving the points and comparing the *shape* of the normal-scatter matrix, with
scale divided out:

| sensor | relative change in shape |
|---|---|
| full | 0.014 |
| VLP-32C | 0.023 |
| Robin-W | 0.011 |

One to two percent. Extra points re-sample the same surfaces at the same
incidences; they multiply the information without redistributing it. Density
therefore shrinks the *nominal covariance* while leaving the geometry of what is
observable untouched.

This is the mechanism behind a result the campaign already had and could not
explain: raising the matcher's point budget tenfold, from 5000 to 50000, moved
the error by 2 mm.

## Where the error actually lives: bias, not noise

Decomposing each run's error in the vehicle frame into a slowly varying
component, a five-second moving average, and the residual it removes:

| run | total | **bias** | noise | along-track | cross-track |
|---|---|---|---|---|---|
| full 360 x 90 | 0.076 | **0.037** | 0.050 | 0.056 | 0.037 |
| VLP-32C | 0.093 | **0.066** | 0.057 | 0.067 | 0.047 |
| Robin-W | 0.113 | **0.073** | 0.058 | 0.069 | **0.064** |

**The noise term is essentially the same for all three: 0.050, 0.057, 0.058.**
Everything that separates them is bias, which nearly doubles from the full circle
to the wedge. And the Robin-W's excess is concentrated **cross-track**, 0.064
against the full sensor's 0.037, while along-track barely moves.

So the field of view is not making the estimate noisier. It is making it
*consistently offset*, and offset sideways.

## The explanation, and why it fits everything

A scan-to-map matcher does not measure the pose. It measures **agreement between
the live scan and the map**, and those disagree for reasons that are systematic
rather than random: the map carries its own construction error, it is
discretised, and surfaces are sampled at different incidence angles and ranges
than when they were mapped. Each visible surface pulls the estimate by a small,
*fixed* amount that depends on where that surface is.

With 360 degrees of coverage, those pulls come from all around the vehicle and
largely cancel. A wall on the left biasing the pose one way is opposed by
whatever is on the right. **The full circle is not more informative so much as
more balanced.**

Restrict to a 120 degree forward wedge and there is no opposing side left. The
surviving surfaces all sit within one narrow cone, their pulls share a direction,
and what used to cancel now sums. The result is exactly what the table shows: the
same per-frame noise, a doubled systematic offset, and the offset lying
cross-track, because a forward wedge's surfaces are distributed asymmetrically to
either side rather than fore and aft.

This single mechanism accounts for every negative result in the campaign:

- **Density does nothing.** More samples of the same biased surfaces estimate the
  same biased answer more precisely. Averaging does not remove a bias.
- **Better conditioning does not help.** Bias is not a conditioning property.
  The Robin-W is better conditioned *and* worse, which is only contradictory if
  the error were variance-limited.
- **The matcher does not matter.** VGICP lost the same fraction, 1.49x against
  NDT's 1.54x, because both are solving the same map-consistency problem with the
  same asymmetric evidence.
- **Sliding-window smoothing does not help.** A window averages over time, and a
  bias that is stable over a five-second window is exactly what averaging cannot
  touch. It removed noise and left the bias.
- **Direction beats width.** A rear-facing wedge was 30x worse in scatter, which
  is not explicable by coverage alone but is entirely explicable if the surfaces
  behind the vehicle disagree with the map more than those ahead.

## What this predicts would work

The prediction is specific: **restore angular diversity, do not add points or
sharpen the estimator.**

- **A second sensor pointing away from the first** is the direct remedy, because
  it restores the opposing pull that a single wedge lacks. It should recover most
  of the gap, and by this account it is the only cheap thing that will.
- **Map/scan consistency work** attacks the bias at its source: build the map
  with the sensor that will localize against it, so incidence and density match.
  The campaign never tested cross-sensor mapping, and every map this project owns
  was built with a Velodyne.
- **Longer-baseline accumulation** helps only insofar as the vehicle *rotates*.
  Turning sweeps the wedge across directions and restores balance; driving
  straight does not, no matter how long the window.

And what will not work, with a reason rather than a shrug: anything that lowers
variance. That includes density, finer voxels, more iterations, and smoothing.

## Caveats

- **The reference is the map's own source.** The trajectory scored against was
  produced by the LiDAR odometry the map was built from, so "bias" here includes
  map error and is measured relative to the map's frame rather than to truth.
  That is the right frame for this question -- a localizer's job is to agree with
  its map -- but the absolute magnitudes are not absolute accuracy.
- **One site, 76 m, walking pace, a car park.** The bias mechanism should be
  stronger where map error is larger and where surfaces are more one-sided; both
  vary by site.
- The bias/noise split uses a five-second window. A slower-varying bias would be
  partly counted as bias in all three runs equally, so the comparison holds even
  if the split point is arguable.
