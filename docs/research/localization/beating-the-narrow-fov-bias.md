# Solving the narrow-FOV penalty: directions from the mechanism

[why-narrow-fov-costs-accuracy.md](why-narrow-fov-costs-accuracy.md) established
that the 1.4x penalty is **systematic bias, not noise**: a scan-to-map matcher
measures agreement with the map, that disagreement is fixed per surface, and a
full circle collects opposing pulls that cancel while a 120 degree wedge collects
pulls that share a direction and sum.

That mechanism makes predictions. Two of them were tested, both hold, and each
recovers about half the penalty. This document is the resulting map of the
solution space — deliberately not restricted to NDT, since the mechanism is
matcher-independent and so are most of the remedies.

## The two confirmations

| configuration | coverage | points kept | err p50 | err p95 |
|---|---|---|---|---|
| full circle | 360 deg | 100% | 0.076 | 0.247 |
| VLP-32C emulation | 360 deg | — | 0.093 | 0.227 |
| **Robin-W, single wedge** | 120 deg | 34% | **0.113** | 0.250 |
| two opposed wedges | 2 x 120 deg | 68.8% | **0.094** | 0.232 |
| one wide arc | 210 deg | 45% | **0.092** | **0.188** |
| single wedge, map built by the wedge | 120 deg | 34% | **0.095** | 0.321 |

**Angular diversity recovers half the gap, and it is the diversity and not the
points.** Two opposed 120 degree wedges reach 0.094 with 68.8% of the points; a
single contiguous 210 degree arc reaches 0.092 with 45%. Half again as many
points, the same result — while the single 120 degree wedge, with 34%, sits at
0.113. Coverage explains the ordering and point count does not, which is the
prediction the mechanism made and the opposite of what a variance-limited system
would do.

Both configurations land at **VLP-32C parity** (0.093). That is the first thing
in this campaign to do so.

**Map/scan consistency is worth about as much.** Rebuilding the map from the
wedge's own returns, so the map is made from the same viewpoints and incidences
that will later query it, moves a single wedge from 0.113 to 0.095 with no change
to sensor, matcher or parameters. Its p95 gets worse (0.321) because a
wedge-built map covers less, so the tails suffer where coverage runs out — the
median improvement is the map-consistency effect, the tail regression is a
coverage artifact of this particular test.

Two independent interventions, each predicted by the mechanism, each recovering
roughly half. They are also complementary: nothing about them overlaps.

## Directions, ranked by how directly they attack bias

### Tier 1 — restore angular diversity

**1a. A second sensor pointing away from the first.** Confirmed above: 2 x 120
degrees reaches VLP-32C parity. The cheapest version is not another Robin-W —
the measurement says what matters is *direction covered*, not points added, so a
modest rear or side unit should buy most of it. This is the single highest-value
item and it is hardware, not algorithms.

**1b. Exploit the vehicle's own rotation.** A wedge sweeps across directions when
the vehicle turns, so accumulating a local submap across a turn restores balance
that a single scan lacks. Note the limit carefully: **driving straight does not
help**, however long the window, because translation re-observes the same
surfaces at similar incidence and the bias persists. That is precisely why the
sliding-window experiment failed — the bench is mostly straight-line motion, and
a window averages noise while leaving bias untouched. Worth revisiting only on a
route with real turning, and worth pairing with 1a rather than instead of it.

**1c. Uncorrelated modalities.** A camera, a radar or GNSS carries a bias that is
independent of the LiDAR-to-map bias, so fusing them reduces the combined offset
in a way more LiDAR points cannot. GNSS regularization already exists in Autoware
and is switched off here.

### Tier 2 — remove the bias at its source

**2a. Map with the sensor that will localize.** Confirmed above, worth ~half the
penalty. Immediately actionable and currently untrue of this project: every map
it owns was built with a Velodyne. If a Robin-W will localize against it, survey
with a Robin-W.

**2b. Viewpoint-invariant map representations.** The deeper form of 2a. A map
stored as *points* carries the sampling pattern of whatever built it, so a
different sensor queries a different sampling. A map stored as **surfaces** does
not: plane and surfel maps, Gaussian mixtures, or continuous fields such as a
signed distance field or a Gaussian distance field give the same answer for the
same physical geometry regardless of how it was sampled. This removes both the
cross-sensor mismatch *and* the discretisation bias, and it is the direction with
the strongest theoretical claim on the problem.

**2c. Intensity-aided matching.** Geometry alone cannot fix where a scan sits
along a featureless surface; reflectivity can. It adds a constraint that is
orthogonal to the geometric one, and it is a place where the Robin-W's density is
a genuine asset rather than a wasted one.

### Tier 3 — match things that do not slide

**3a. Landmark, pole and edge based localization.** The bias mechanism is
specifically about *surfaces*: a plane observed at a slightly wrong incidence
pulls the estimate along itself. **Point-like and line-like features do not
slide.** A pole, a sign, a curb corner or a tree trunk has a position, and
matching it constrains two or three degrees of freedom without an along-surface
ambiguity to be biased along. This is well established for road vehicles and is
targeted at exactly the failure measured here.

It is also where the Robin-W's density stops being useless and becomes the
enabling property: **0.15 degree resolution is what makes a pole detectable at
range**, and the campaign showed that same density buys nothing at all for dense
surface matching. The sensor's advantage is real; it is being spent on the wrong
algorithm.

**3b. Semantic or object-level constraints.** The same idea one level up, with
the same rationale.

### Tier 4 — estimate the bias rather than fight it

**4a. Model it as a state.** The bias is slowly varying and spatially structured,
which is exactly what an estimator can carry. Autoware's fusion filter already
distinguishes a biased pose from a corrected one; extending that to a
map-referenced bias field is a natural fit. Cheaper than a new matcher, and it
degrades gracefully.

**4b. Weight by measured conditioning.** Already available via the degeneracy
monitor. Note the caveat this campaign earned the hard way: **it addresses
variance, not bias**, so expect it to improve consistency and honest covariance
rather than accuracy.

## What will not work, with reasons

Each of these was measured, and the mechanism says why each had to fail:

| tried | result | why |
|---|---|---|
| 10x the point budget | 2 mm | more samples of the same biased surfaces |
| finer voxels | much worse | conditioning, not bias |
| Laplace covariance | no gain, one run diverged | variance, not bias |
| a different matcher (VGICP) | same 1.5x degradation | same map-consistency problem |
| sliding-window smoothing | removed noise, left bias | averaging cannot cancel a constant |

The common thread: **every one of them reduces variance, and the error is not
variance-limited.** Any future proposal should be checked against that question
first, because it is cheap to ask and it would have saved most of this campaign.

## Recommended order

1. **Map with the deployment sensor** (2a). Confirmed, free of hardware, and a
   decision that gets expensive to reverse once a production map exists.
2. **A second sensor covering elsewhere** (1a). Confirmed, reaches VLP-32C parity,
   and no algorithm work.
3. **Pole and edge landmarks** (3a), because it is the one direction that turns
   the Robin-W's density from a liability into the reason to have bought it.
4. **Surface-based or continuous map representation** (2b), as the principled
   version of 1 and the thing that makes cross-sensor mapping safe in general.
5. Everything else, and nothing that only reduces variance.

## Caveats

- One site, 76 m, a car park at walking pace. The bias mechanism should scale
  with map error and with how one-sided the surfaces are; both vary by site.
- The reference is the LiDAR odometry the map was built from, so these numbers
  measure agreement with the map rather than absolute accuracy. That is the right
  frame for the question, but it means "bias" here includes map error by
  construction — which is the point, not a flaw.
- The dual-wedge and wide-arc runs emulate extra coverage by *keeping* returns the
  single wedge discarded, so they share one sensor's noise, calibration and
  timing. A real second sensor adds extrinsic error the emulation does not.
