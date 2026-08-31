# Phase 6 — Localization on a Seyond Robin-W

Bring Autoware's localization to a sensor that is **narrow and dense** — 120 by
70 degrees, over 1.28 M points/s, 0.15 by 0.36 degree resolution — where every
parameter, and arguably the matcher itself, was chosen for a 360-degree
32-line Velodyne.

Ranked directions and the reasoning: [robinw-autoware-pipeline.md](../research/localization/robinw-autoware-pipeline.md).
Measurements: [restricted-fov-ndt.md](../research/localization/restricted-fov-ndt.md).
Literature: [narrow-fov-related-work.md](../research/localization/narrow-fov-related-work.md).

Last updated: 2026-08-31. **The phase has been re-ordered around a mechanism.**

R2, R4-a and R4-d all failed, and understanding *why* changed the plan. The
penalty is **systematic bias, not noise**: a scan-to-map matcher measures
agreement with the map, that disagreement is fixed per surface, and a full circle
collects opposing pulls that cancel while a wedge collects pulls that sum. See
[why-narrow-fov-costs-accuracy.md](../research/localization/why-narrow-fov-costs-accuracy.md).

Everything that failed reduced **variance**, and the error is not
variance-limited. Everything that has since worked attacks the **map**. Under a
single-forward-sensor constraint, two map changes took a 120 x 70 degree wedge
from 0.113 m to 0.057 m in the offline harness, past an equally-treated VLP-32C
at 0.067. The phases below are re-ordered accordingly: **R7 is now the active
work**, and R5 is out of scope because the vehicle carries one sensor.

**Scope: one forward-facing Robin-W.** A second sensor is not available. The
dual-wedge experiment stays on record because it identified the mechanism, not
as a proposal.

**Two matchers built on different principles lose the same fraction of accuracy
when the wedge narrows**, which is what a geometric limit looks like rather than
an algorithmic one. R4-d, sliding-window estimation with tight inertial coupling,
is now the only direction with an argument left, because it is the only one that
does not treat each scan independently.

**A VLP-32C baseline now exists**, emulated from the same OS0-128 bag against the
same map and reference: 0.055 m median matcher error, against the best Robin-W
configuration's 0.077 m. Every R2 lever was swept and **the 1.4x gap survived all
of them**, so the remaining work is R4 — estimator structure, not parameters.
Details and the three refuted hypotheses are in
[restricted-fov-ndt.md](../research/localization/restricted-fov-ndt.md).

**This roadmap is deliberately unfinished.** Every decision point below states
what will be measured and what the branches are, but **not the thresholds** —
those are set from the evaluation immediately before them, not guessed now. A
threshold written today would be a guess wearing a number's clothes, and this
project has been burned by exactly that: the earlier COSS tuning study ranked
configurations on NVTL and reached two conclusions that reversed when it was
re-scored on pose quality.

---

## What is already known

Two results carry most of the weight, both from the restricted-FOV campaign.

**A 120 by 70 degree forward wedge already localizes.** 0.082 m median error
against 0.050 m for the full sensor, on a third of the points, heading unchanged.
Independently corroborated: a published ablation reports 360 degrees as 2.94x the
accuracy of 90; we measured 2.34x on a different sensor, site and pipeline. **So
this phase is design, not rescue.**

**The prior dominated the field of view by two orders of magnitude.** Without a
twist source, one configuration gave 4.4 m, 7.3 m and 0.13 m median error across
three identical runs; with one, three runs agreed to a millimetre. Narrowing 360
to 120 degrees moved the median by 32 mm. Everything protecting the prior
outranks everything sharpening the matcher, and the ordering below reflects that.

Three further findings that constrain the work:

- **Direction beats width.** The same 120 degrees facing backwards was 30x worse
  in scatter. The Robin-W is forward-mounted, which is the good case.
- **Vertical restriction is free**, and so is cutting range from 250 m to 70 m.
- **Heading degrades before position**, in both the pose output and the Hessian,
  independently. Alarms go on heading.

---

## R0 — Unblock the sensor

**Nothing downstream is real until the cloud is one Autoware will accept.** This
is plumbing, it is cheap, and it gates everything.

### R0-a. The point cloud is rejected by Autoware's preprocessing today

`NEWSLabNTU/seyond_ros_driver` already carries the work to emit Autoware's
`PointXYZIRC` (`8e99e38`, `point_xyzirc.h`, `POINT_TYPE PointXYZIRC`). It gets
the struct layout right and the **field names wrong**:

```c++
(std::uint8_t, intensity, I)       // published as "I"
(std::uint8_t, return_type, R)     // published as "R"
(std::uint16_t, ring,       C)     // published as "C"
```

`is_data_layout_compatible_with_point_xyzirc` in
`autoware_pointcloud_preprocessor/src/utility/memory.cpp` compares names
literally:

```c++
same_layout &= field_intensity.name == "intensity";
same_layout &= field_return_type.name == "return_type";
same_layout &= field_ring.name == "channel";
```

So the check fails on all three and every preprocessing node refuses the cloud
with "The pointcloud layout is not compatible with PointXYZIRCAEDT or
PointXYZIRC. Aborting" — logged by the filter, not by the node that appears
broken. Three string literals, plus renaming `ring` to `channel`.

The header's own comment claims the names match Autoware. They do not, and that
comment is why it went unnoticed.

**Acceptance:** a Seyond cloud passes through the crop box and appears on the
preprocessed topic, verified by message count rather than by absence of errors.

### R0-b. Per-point time, so the cloud can be deskewed

Prerequisite for R0-c and for anything measured at speed.

The vendor driver already carries the measurement — `seyond::PointXYZIT` with a
per-point `double timestamp`, its own default — so this is a conversion, not a
vendor request. Autoware's `PointXYZIRCAEDT` wants `time_stamp` as an offset from
the scan start rather than an absolute double, plus azimuth, elevation and
distance, all derivable from xyz or from the driver's `scan_id` / `scan_idx`.

Add `POINT_TYPE PointXYZIRCAEDT` beside the existing `PointXYZIRC` branch,
following the pattern already there.

**This repo has twice recorded that fixing this needs a vendor driver change.**
It does not, and both places are now corrected. Do not re-derive that conclusion.

**Why it matters more here than on the Velodyne:** undeskewed points smear by
roughly speed times scan period — about 0.28 m at 10 km/h and 10 Hz — against
errors of 0.08 m. Buying 0.15 degree resolution and then feeding NDT a smeared
cloud pays for structure that is then destroyed before use.

### R0-c. Put the Robin-W through the preprocessing chain

With R0-a and R0-b done, the sensor can take the path the Velodyne takes: crop
box, distortion corrector, ring outlier filter, then concatenation — CPU or CUDA.

**Acceptance:** deskew measurably changes the cloud at speed, and the CUDA and
CPU paths agree.

> **Decision point R0-X — is the density worth carrying?**
> Measure the preprocessing and NDT cost at full rate on the Orin.
> - Comfortably real-time → carry the full density into R2 and let R2-b decide.
> - Not → decimate at the driver, and R2-b becomes "how much can be discarded"
>   rather than "how much should be kept".

---

## R1 — Bench (done)

Two emulation benches, built because no Robin-W recording exists.

| bench | gives | blind to |
|---|---|---|
| Autoware sample bag | known-good Autoware pipeline at vehicle speed | vertical FOV: its VLS128 spans 40 degrees |
| TIERS OS0-128 `road01` | 360 x 90 degrees, so both axes croppable to spec; four baked fields of view; reference trajectory and prior map | vehicle speed — a walking-pace trolley |

Tooling in `scripts/localization/restricted_fov/`. Both benches are pessimistic
where they cannot be faithful — around 60% of the Robin-W's point rate inside the
wedge, and a spinning rather than solid-state scan pattern — so results are lower
bounds.

**The gap neither closes is a dense narrow sensor at vehicle speed on the
deployment route.** That is one recording once the hardware is mounted, and it is
what turns every number in this phase from a lower bound into a measurement.
Schedule it as early as the hardware allows; it is cheap and it is the only thing
that retires the emulation caveat.

---

## R2 — The cheap NDT revisions

Both are configuration or a sweep. Neither needs new data.

### R2-a. Anisotropic covariance into the EKF — TRIED, no gain, one run in three diverged

**Measured 2026-08-30 and it is not the free win it looked like.** The first
Robin-W run with `covariance_estimation_type: 1` beat every VLP-32C run at the
fused output. It did not replicate: of three runs one diverged outright, 12.95 m
matcher error and 158 degrees of yaw, a failure that never occurred in nine runs
with fixed covariance. The other two matched fixed covariance rather than beating
it.

Not necessarily a dead end — the instability may be in how the CUDA matcher
derives the 2x2 Laplace block rather than in the idea — but it is not a
configuration change any more, and it needs the cause found before it is retried.

The original reasoning, still sound:


`covariance_estimation_type: 0` — FIXED_VALUE — in both
`cuda_scan_matcher.param.yaml` and Autoware's own. Every pose carries the same
hardcoded covariance whatever the scan constrained, so the filter is told the
along-track axis, which a forward wedge constrains worst, is as trustworthy as
the across-track one — and then corrects the axis NDT knew least about.

Switch to `1` (Laplace, from the Hessian already computed) and confirm the CUDA
matcher honours it. Highest value per line changed on this whole roadmap, because
it improves the half of the system that dominates.

### R2-b. Spend the density deliberately — TRIED, both hypotheses refuted

**Resolution has a genuine optimum at 3.0**, not finer: 0.077 m against 0.082 at
2.0, with 1.0 and 1.5 far worse. Sweep the NVTL gate down with it or the sweep
measures the gate, which is calibrated for 2.0 and scales with voxel size.

**Point budget does nothing.** `sample_num: 5000` caps every scan, so both
sensors hand NDT the same point count; raising it to 50000 changed the error by
2 mm. NDT saturates far below that on this scene and cannot convert the Robin-W's
density into accuracy at all. Worth knowing before paying for density.

The original reasoning, still worth reading for the third question it raises
(*where* to keep points, which remains untested):


Voxel resolution, keep-fraction, and whether downsampling should stay uniform.
`resolution: 2.0` was chosen for a 32-line spinning sensor, and NDT is unusually
sensitive to this parameter.

Score on pose quality. **Never on NVTL** — in the FOV campaign the worst
configuration measured scored the highest NVTL of any restricted run.

> **Decision point R2-X — is NDT's parameter sensitivity a liability?**
> If R2-b's sweep shows a sharp optimum that moves between the two benches, that
> is an argument for a resolution-robust matcher and R4-a gains weight. If the
> optimum is broad and stable, NDT's tuning is a one-off cost and R4 can wait
> for R3's evidence instead.

---

## R3 — Does this site actually degenerate?

The scan matcher already publishes per-frame conditioning of both Hessian blocks
under `/localization/pose_estimator/degeneracy/`. It responded correctly to a
field-of-view sweep in replay: rotation anisotropy rose 2.8x against
translation's 1.2x.

**R3 is one drive of the campus route with it recording.** Everything measured so
far comes from 130 m of a sample route and 76 m of a Finnish car park. If the
campus never presents a long featureless stretch, most of R4 is unnecessary.

Also worth recording along the same route: where GNSS is usable, since R4-c
depends on it.

> **Decision point R3-X — the branch this whole phase turns on.**
> Measure anisotropy along the route, gated on heading.
> - **No degenerate stretches** → stop after R2. Re-check after any route change.
>   This is a real possible outcome and should not be treated as a disappointment.
> - **Occasional, bounded** → R4-c (regularization) and R4-b (covariance
>   inflation along the weak axis). Cheap, local, no architecture change.
> - **Frequent or sustained** → R4-a and R4-d become the phase. Budget
>   accordingly, and reconsider R5 hardware early rather than late.

---

## R4 — Structural options, ordered by cost

Only entered on R3's evidence. All four are measurable on the existing benches;
`data/tiers/baked_odo/` holds one sequence at four fields of view and
`compare_to_reference.py` scores anything that consumes a bag and emits poses.

**R4-a. VGICP instead of NDT — TRIED, does not close the gap.** Measured
2026-08-30 offline against the same map and reference: it loses accuracy to a
narrow wedge at the same rate as NDT, 1.49x against 1.54x relative to each
matcher's own full-FOV run. Better worst case (0.46 m against 0.81) and roughly
ten times faster, but not differentially better under a restricted field of view.
Details in [restricted-fov-ndt.md](../research/localization/restricted-fov-ndt.md).
The original reasoning:
 Reported as accurate as GICP, faster, and robust
to voxel resolution — it deletes R2-b's first question rather than answering it.
Against it: NDT is what Autoware ships and what this project's CUDA work
accelerates. Nothing measured here says VGICP handles a wedge better; that is the
comparison.

**R4-b. Degeneracy-aware update.** Constrain the optimization along directions the
geometry does not observe. Read [Informed, Constrained,
Aligned](https://arxiv.org/pdf/2408.11809) first — its criticism lands on the
naive implementation, and one threshold cannot serve translation and rotation.
**Try the soft form first:** inflate covariance along the weak axis and let the
EKF arbitrate. That is R2-a generalized per-axis, needs no optimizer change, and
fails gracefully.

**R4-c. GNSS regularization.** `regularization.enable: false` today, and our own
config comments it as penalizing longitudinal deviation from GNSS — a description
of the corridor failure. Outdoors only; `scale_factor` untuned. Tune against R3's
measurements, not blind.

**R4-d. Sliding-window prior-map localization with tight IMU coupling — TRIED,
bench cannot answer it.** Implemented with the matcher's own information matrix
weighting each scan factor, which is the threshold-free form of the
degeneracy-aware update. It changed nothing until the scan information was
scaled down (an unnormalised `H` outweighs a plausible motion prior by five
orders of magnitude), and once motion had real weight the result got monotonically
worse. The cause is the bench: a handheld trolley's motion is not described by
the (v_x, omega_z) model available, so integrating it injects more error than the
scan's weak directions contain. **Untested rather than refuted** — it needs a
platform whose relative motion genuinely beats its scans, which means the vehicle.
 The
structural fix and the strongest theoretical case for a narrow sensor: a
direction unobserved in one frame is usually observed a second later. Replaces
the pose-estimator/EKF split rather than a component inside it, which is the
whole cost.

> **Decision point R4-X — one matcher, or the architecture?**
> Run R4-a and R4-d on the benches at 120 by 70 degrees.
> - R4-a alone closes the gap → take it, keep the architecture, done.
> - Only R4-d closes it → this is a re-architecture and needs its own phase.
> - Neither closes it → the geometry is the limit, not the estimator. Go to R5.

---

## R7 — The map (ACTIVE)

The confirmed direction, and the only one that has moved the number. All of it is
achievable with one forward sensor. Measured in the offline VGICP harness unless
stated; the same levers are being re-tested inside the Autoware NDT pipeline,
which is what the phase's acceptance depends on.

### R7-a. Map resolution — largest single effect

Robin-W, original map, sweeping the resolution the *matcher* voxelises the map
at:

| map voxel | 0.5 m | 1.0 m | 2.0 m |
|---|---|---|---|
| err p50 | **0.078** | 0.113 | 0.164 |

Monotonic, and it collapsed the Robin-W's penalty against the VLP-32C from
**1.21x to 1.03x**. It helps every sensor and helps the wedge most, exactly as
the bias mechanism predicts: a coarse cell displaces a surface by an amount that
depends on which part of it was seen, and only a full circle averages those
displacements away.

**Note the direction disagreement with NDT**, which got catastrophically worse at
fine resolution (3.900 m at 1.0). The suspected cause is interaction with
`random_downsample_filter`'s cap of 5000 points: fine voxels need a dense scan to
populate them, and NDT's was being thinned first. Resolving that is R7-d.

**Acceptance:** know what the deployed map resolution is, and whether NDT can use
a fine one once the scan is dense enough.

### R7-e. Do not over-downsample the survey map — THE ACTIVE LEVER

**Constraint, stated 2026-08-31: the point cloud map comes from a survey company,
scanned with a different sensor, and this project downsamples it.** Surveying
with the Robin-W (R7-b below) is therefore not available. That removes the
headline lever and replaces it with a better one, because the remaining knob is
the one this project already controls.

Robin-W against a map built by a **different, wider sensor**, varying only the
downsample voxel:

| map downsample | 0.05 m | 0.10 m | **0.20 m** | 0.40 m |
|---|---|---|---|---|
| Robin-W err p50 | **0.048** | 0.061 | 0.082 | 0.104 |
| Robin-W err p95 | 0.147 | 0.168 | 0.223 | 0.248 |
| map size, 76 m route | 104 MB | 22 MB | 4.6 MB | 1.0 MB |

**At 0.05 m the Robin-W reaches 0.048, beating the deployed VLP-32C baseline of
0.055, on a map from a different sensor.** No change of provenance, no survey
with the vehicle's own LiDAR, no new matcher. The current 0.2 m is simply too
coarse, and it is too coarse for the VLP-32C as well: that sensor goes 0.055 to
**0.040** on the same 0.05 m map.

The wedge gains more, 41% against the VLP-32C's 27%, exactly as the bias
mechanism predicts — a coarse map cell displaces a surface by an amount depending
on which part of it was seen, and only a full circle averages those displacements
away.

**What "downsample voxel" means in actual spacing**, since the setting and the
resulting density are not the same thing:

| map | voxel | points | size | nearest-neighbour p50 | points/m2 |
|---|---|---|---|---|---|
| current | 0.20 m | 301k | 4.6 MB | 0.112 m | 115 |
| | 0.10 m | 1.47M | 22.4 MB | 0.062 m | 560 |
| | 0.05 m | 6.82M | 104 MB | 0.033 m | 2607 |
| | 0.40 m | 64k | 1.0 MB | 0.194 m | 25 |

Nearest-neighbour spacing tracks the voxel at roughly 0.6x it all the way down to
0.05 m, which says the **voxel is the binding constraint, not the source data**.
The accumulated cloud can fill 5 cm cells, so downsampling to 0.2 m is discarding
detail that exists rather than smoothing noise that does not.

That matters for the vendor conversation. A survey company's mobile mapping
system typically delivers 1 to 3 cm spacing, and a terrestrial scanner finer, so
the density this result needs is **below what such a map already contains**. The
question to ask is not whether they can supply it but what this project should
keep.

**Cost is the real decision, not accuracy.** Extrapolating this route, 0.05 m is
about 1.4 MB per metre and 0.10 m about 0.3 MB per metre, so a 2 km campus route
is roughly 2.7 GB against 600 MB. Autoware loads the map by radius rather than
whole, so runtime memory is bounded, but the target build cost and the map
loading are not free. **0.10 m looks like the sweet spot pending on-vehicle
timing** — it recovers half the improvement for a fifth of the size — and 0.05 m
is worth it only if the Orin can carry it.

**Acceptance:** the deployed map's downsample voxel is known, chosen
deliberately, and justified against measured on-vehicle load and align time
rather than inherited.

**Caveat that bounds the numbers.** The map here was built from the same pass
that is then scored against it, so its error is correlated with the reference in
a way a real survey map's is not. The *absolute* values are therefore optimistic.
The *trend* should transfer, because it is about discretisation rather than
correlation, and discretisation does not care where the map came from.

### R7-b. Survey with the deployment sensor — OUT OF SCOPE

On top of a fine map, building it from the wedge's own returns takes 0.078 to
**0.057**. It helps the VLP-32C too, 0.076 to 0.067, so it is not
wedge-specific — but the wedge gains **27% against 12%**, since less angular
averaging means less capacity to hide a viewpoint mismatch.

**Not available: the map is bought, not made.** Kept for two reasons. It is the
experiment that separated map/scan mismatch from every other candidate cause,
and it bounds what the mismatch is worth should provenance ever be negotiable.

Note also that its measured gain is partly an artifact: the self-built map was
made from the same pass that was then scored against it, so map error and
reference error cancelled. R7-e does not have that problem to anything like the
same degree, since the map there comes from a different sensor.

**Unmeasured risk:** a self-built map is a map of a route already driven. In
service the map is older than the drive, and nothing here says how the advantage
decays as the world changes.

### R7-c. Viewpoint-invariant map representation

The principled version of R7-a and R7-b together. A map stored as *points*
carries the sampling pattern of whatever built it; a map stored as **surfaces** —
planes, surfels, Gaussian mixtures, a signed or Gaussian distance field — gives
the same answer for the same geometry however it was sampled. Removes the
cross-sensor mismatch and the discretisation bias at once, and would make R7-b
unnecessary rather than merely cheaper.

Only matters if NDT is kept. The resolution sweep and the point-budget sweep were
run separately and neither alone helped; the hypothesis is that they interact,
because fine voxels need points and the chain throws points away before the
matcher sees them.

> **Decision point R7-X — RESOLVED 2026-08-31: the map closes it.**
> Median parity reached inside the real Autoware NDT pipeline, three runs, no
> spread. The branch taken is the first one: the remaining work is operational.
> The p95 caveat below is the one thing that keeps it from being unconditional.

### R7-X result: 0.055 m, matching VLP-32C NDT

Autoware NDT replay, Robin-W wedge, scored against the same reference:

| configuration | err p50 | err p95 | note |
|---|---|---|---|
| **VLP-32C, original map** (the bar) | **0.055** | 0.131 | as deployed today |
| Robin-W, original map, resolution 3.0 | 0.077 | 0.175 | best before R7 |
| Robin-W, original map, stock res + dense | 0.082 | 0.226 | **dense alone is worse than stock** |
| Robin-W, **surveyed map**, res 3.0 | 0.064 | 0.168 | survey alone |
| **Robin-W, surveyed map, stock res + dense** | **0.055 / 0.055 / 0.055** | 0.210 | **parity, 3 runs** |
| the same, with the stock convergence gate too | 0.054 | 0.208 | gate change was inert |
| VLP-32C, its own surveyed map | 0.053 | 0.132 | the bar, equally treated |

**In stock terms the whole recipe is two changes**: build the prior map with the
Robin-W, and raise `random_downsample_filter`'s `sample_num` from 5000 to 50000.
Stock resolution, stock convergence gate, stock matcher. The parity runs above
used a param file that also lowered the NVTL gate from 2.0 to 0.5, left over from
the resolution sweep; re-running with the stock gate gives 0.054, so it
contributed nothing.

**What did the work, in order:**

1. **Surveying with the wedge is necessary and sufficient to start.** It alone
   takes 0.077 to 0.064. Without it, nothing else helps: the same dense, finer
   configuration on the original map scores 0.082, *worse* than the stock
   settings.
2. **Surveying removes the need for the resolution tuning, rather than shifting
   it.** `resolution: 2.0` is the **stock** value. On the original map it had to
   be tuned up to 3.0 to reach 0.077; on the surveyed map stock 2.0 beats the
   tuned 3.0, 0.055 against 0.064. The 3.0 was compensating for map/scan
   mismatch, not for the sensor, and once the mismatch is gone the compensation
   costs accuracy. That is the bias mechanism showing its face: coarse voxels are
   only worth having when the map disagrees with the scan at a coarser scale than
   the voxels themselves.
3. Point budget matters **only in combination**. Raising it on the original map
   changed nothing, as it had every previous time.

**Two honest limits on the claim:**

- **The tail is still 1.6x worse.** p95 is 0.210 against the VLP-32C's 0.131.
  Median parity, tail not. If the vehicle cares about worst case rather than
  typical case, this is not yet parity.
- **Against an equally-treated VLP-32C it is 4% behind**, 0.055 against 0.053,
  because surveying helps that sensor too. Parity is against the bar as
  deployed, which is the question that was asked, not a claim of superiority.

**Refuted along the way:** the hypothesis that NDT's catastrophic failure at
resolution 1.0 was starvation by `random_downsample_filter`. With the budget
raised tenfold it still fails, 3.79 m on the surveyed map and 3.89 on the
original. The cause is inside NDT, not upstream of it, and R7-d is closed
unresolved rather than solved.

### R7-d. Make NDT able to use a fine map — CLOSED, cause not found

---

## R8 — Match what does not slide

The mechanism is specifically about **surfaces**: a plane observed at slightly
the wrong incidence pulls the estimate *along itself*. Point-like and line-like
features do not slide. A pole, a sign, a curb corner or a tree trunk has a
position, and matching it constrains the pose without an along-surface ambiguity
to be biased along.

This is also the only direction that makes the Robin-W's density pay. **0.15
degree resolution is what makes a pole detectable at range**, and the campaign
measured that the same density buys nothing at all for dense surface matching —
a tenfold point budget moved the error 2 mm. The sensor's advantage is real and
is currently spent on an algorithm that cannot use it.

Ranked after R7 only because R7 is confirmed and cheaper, not because it is
weaker. If R7-X lands on "not close", this is the phase.

---

## R5 — Sensor configuration (OUT OF SCOPE)

**The vehicle carries one forward sensor**, so this is recorded rather than
planned.

Kept because it is the experiment that identified the mechanism: two opposed 120
degree wedges reach 0.094 where one reaches 0.113, and a single 210 degree arc
reaches 0.092 using *fewer points than the two wedges*. Coverage explained the
ordering and point count did not, which is what established that the penalty is
bias and not variance.

It also bounds what coverage alone is worth, should the constraint ever change.

## R5 — Sensor configuration, original notes

Reached when the algorithm work cannot close the gap, or earlier if R3 says the
route is badly degenerate.

A rear or side sensor constrains the axes the front one does not. The campaign's
direction table is the evidence that different directions carry very different
information — a rear wedge *alone* was 30x worse in scatter, which argues against
a rear sensor alone, not against a second one.

Least algorithm risk of anything in R4-R5, and if the route is genuinely
degenerate it may be cheaper than the estimator work.

---

## R6 — Relocalization, running in parallel

Separate subsystem, separate failure, does not compete with R2-R5 for the same
effort.

Everything above measures **tracking**, from a seeded initial pose. Nothing says
how the vehicle acquires or recovers a pose on a Robin-W. Scan Context, the
standard place-recognition descriptor, degrades under a restricted field of view,
and initial-pose estimation has the same problem from the other end: a narrow
wedge discriminates less well between candidate poses, so a Monte Carlo search
has a flatter objective.

Do not inherit the full-circle result. Score recall at fixed precision as the
field of view narrows, on any dataset with revisits.

---

## Open questions this roadmap does not answer

- **What sensor builds the production map?** Every map this project has —
  COSS, NTU campus — was built with a Velodyne, and every measurement in the
  campaign localized against a map built by the *same* sensor that then localized
  against it. A Robin-W against a Velodyne-built map is untested and differs in
  density, pattern and intensity. NDT is more forgiving of this than a
  feature-based matcher; forgiving is not verified. The cost of finding out late
  is a re-survey, so decide before the production map is made.
- **What is the vehicle's actual speed envelope?** R0-b's importance scales with
  it, and both benches are slower than a golf cart in service.
- **Does the Robin-W's scan pattern change any of this?** Both benches emulate it
  with a spinning sensor. Nothing here predicts which way a fixed repeating
  pattern cuts, and only the real sensor answers it.
