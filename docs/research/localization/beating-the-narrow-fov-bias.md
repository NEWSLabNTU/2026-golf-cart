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

## Confirmed in the real pipeline: 0.055 m, matching VLP-32C NDT

The offline result below was re-tested inside the full Autoware NDT replay, which
is the number that counts. **Robin-W reaches 0.055 m, the VLP-32C NDT baseline,
across three runs with no spread.**

Surveying the map with the wedge is what makes it possible: alone it gives 0.077
to 0.064, and the same dense finer configuration *without* it scores 0.082, worse
than stock. A finer matcher resolution only becomes usable once the map stops
disagreeing with the scan at a coarser scale than the voxels themselves.

Caveats that matter: p95 is still 1.6x worse than the VLP-32C's, 0.210 against
0.131, so this is median parity and not tail parity; and an equally-surveyed
VLP-32C reaches 0.053, so the claim is parity with the bar as deployed rather
than superiority. Full table in
[the phase roadmap](../../roadmaps/6-robinw-localization.md), section R7-X.

## Scope: one forward sensor

The vehicle carries **one forward-facing Robin-W**, and that is the constraint
the problem is set under. A second sensor is therefore not a solution here. It
still appears below, because emulating one is what *proved* the mechanism, and a
diagnostic that cannot be deployed is still evidence.

Everything in the recommendation at the end is achievable with the single
forward sensor.

## The headline: a single forward wedge can beat the VLP-32C

Same harness, same prior, same matcher, map voxel resolution 0.5 m throughout:

| configuration | err p50 | err p95 | err max |
|---|---|---|---|
| full 360 x 90, original map | 0.071 | 0.145 | 0.245 |
| VLP-32C, original map | 0.076 | 0.151 | 0.233 |
| VLP-32C, **its own** map | 0.067 | 0.134 | 0.231 |
| Robin-W, original map | 0.078 | 0.181 | 0.335 |
| **Robin-W, its own map** | **0.057** | 0.152 | 0.313 |

**A single forward 120 x 70 degree wedge reaches 0.057 m, beating the VLP-32C
even when the VLP-32C is given the same advantage.** No second sensor, no change
of matcher, no change of sensor. Two changes to how the *map* is made and stored.

### Change 1: the map's resolution was a dominant bias source

Sweeping the map's voxel resolution, Robin-W on the original map:

| map voxel | 0.5 m | 1.0 m | 2.0 m |
|---|---|---|---|
| err p50 | **0.078** | 0.113 | 0.164 |

Monotonic and large. It improved every sensor — full circle 0.076 to 0.071,
VLP-32C 0.093 to 0.076 — but it improved the **wedge most**, and in doing so it
collapsed the Robin-W's penalty against the VLP-32C from **1.21x to 1.03x**.

This is the discretisation term of the bias, and it behaves exactly as the
mechanism says it should: a coarse map cell averages a surface over half a metre,
which displaces it by an amount that depends on which part of the surface the
sensor happened to see. A full circle averages those displacements over all
directions; a wedge cannot.

### Change 2: mapping with the deployment sensor

On top of the finer map, building it from the wedge's own returns takes 0.078 to
**0.057**. The same change helps the VLP-32C too, 0.076 to 0.067, so it is not
unique to a narrow field of view — but the wedge gains **27% against the
VLP-32C's 12%**, which is what the mechanism predicts: a sensor with less
angular averaging has less capacity to hide a viewpoint mismatch.

The two changes are complementary and neither requires new hardware.

## What did not work, in scope

**Accumulating scans over motion made it far worse**: 0.113 at one scan, 5.0 m at
five, 20.1 m at fifteen. Two reasons, and the first is mine. The implementation
places each retained scan using the *prior* pose rather than its optimised one,
so the submap smears with every frame it holds. The second is the mechanism: this
route is largely straight, and translation re-observes the same surfaces at the
same incidence, so accumulation adds smear without adding directions. It is worth
retrying only on a route with real turning, and only with poses taken after
optimisation.

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

### Tier 1 — the map, which is where the confirmed wins are

**1a. Store the map finely enough.** Confirmed, and the single largest effect
measured: map voxel 1.0 m to 0.5 m took the Robin-W from 0.113 to 0.078 and cut
its penalty against the VLP-32C from 1.21x to 1.03x. Check what the deployed map
resolution actually is before anything else.

**1b. Map with the deployment sensor.** Confirmed, worth a further 0.078 to
0.057. Free of hardware and expensive to reverse once a production map exists,
which makes it the most urgent decision on this list rather than the largest.

**1c. Out of scope but worth recording: a second sensor.** Two opposed 120 degree
wedges reach 0.094 where one reaches 0.113, and a 210 degree arc reaches 0.092
with fewer points than the two wedges use. Not available under a single-sensor
constraint; kept because it is the experiment that identified the mechanism, and
because it bounds what coverage alone is worth.

**1d. Exploit the vehicle's own rotation.** A wedge sweeps across directions when
the vehicle turns, so accumulating a local submap across a turn restores balance
that a single scan lacks. Note the limit carefully: **driving straight does not
help**, however long the window, because translation re-observes the same
surfaces at similar incidence and the bias persists. That is precisely why the
sliding-window experiment failed — the bench is mostly straight-line motion, and
a window averages noise while leaving bias untouched. Worth revisiting only on a
route with real turning, and worth pairing with 1a rather than instead of it.

**1e. Uncorrelated modalities.** A camera, a radar or GNSS carries a bias that is
independent of the LiDAR-to-map bias, so fusing them reduces the combined offset
in a way more LiDAR points cannot. GNSS regularization already exists in Autoware
and is switched off here.

### Tier 2 — go further on the map representation

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

## Recommended order, single forward sensor

1. **Check and lower the map resolution** (1a). Largest measured effect, a
   parameter rather than a project, and it alone brings the Robin-W to within 3%
   of the VLP-32C.
2. **Survey with the Robin-W** (1b). Takes it past the VLP-32C. Costs nothing but
   is the decision that gets expensive to reverse.
3. **Pole and edge landmarks** (3a), the one direction that turns the sensor's
   density from a liability into the reason to have bought it.
4. **Surface-based or continuous map representation** (2b), the principled
   version of 1 and 2 together.
5. Everything else, and nothing that only reduces variance.

The first two are confirmed on this bench and need no new hardware, no new
matcher and no new estimator. That is the answer to the original question: **a
single forward Robin-W can localize at least as well as the VLP-32C it replaces,
provided the map is built for it.**

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
- The headline runs are single runs, not repeats. This harness has been
  deterministic where it was checked — VGICP and the window smoother reproduced
  to three decimals — so repetition adds little, but the differences quoted are
  larger than anything that determinism would hide, not smaller.
- These are offline VGICP numbers, not the Autoware replay's. They are internally
  comparable and are not comparable to the NDT figures elsewhere in the campaign.
- A self-built map is also a map of a route the vehicle has already driven. In
  service the map is older than the drive, and nothing here measures how the
  advantage decays as the world changes.
