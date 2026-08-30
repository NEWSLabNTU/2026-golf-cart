# Phase 6 — Localization on a Seyond Robin-W

Bring Autoware's localization to a sensor that is **narrow and dense** — 120 by
70 degrees, over 1.28 M points/s, 0.15 by 0.36 degree resolution — where every
parameter, and arguably the matcher itself, was chosen for a 360-degree
32-line Velodyne.

Ranked directions and the reasoning: [robinw-autoware-pipeline.md](../research/localization/robinw-autoware-pipeline.md).
Measurements: [restricted-fov-ndt.md](../research/localization/restricted-fov-ndt.md).
Literature: [narrow-fov-related-work.md](../research/localization/narrow-fov-related-work.md).

Last updated: 2026-08-30. **R1 and R2 are done.** R2 did not close the gap.

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

**R4-a. VGICP instead of NDT.** Reported as accurate as GICP, faster, and robust
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

**R4-d. Sliding-window prior-map localization with tight IMU coupling.** The
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

## R5 — Sensor configuration

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
