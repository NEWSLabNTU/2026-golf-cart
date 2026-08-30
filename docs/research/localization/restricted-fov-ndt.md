# Can NDT localize on a Seyond Robin-W's field of view?

**Question.** The vehicle is to carry a Seyond Robin-W, a solid-state LiDAR that
sees a 120 degree wedge instead of the full circle a Velodyne sweeps. NDT scan
matching has always run here against 360 degree input. Does it still converge
when three quarters of the horizon is gone?

**No Robin-W recording exists**, so the only way to ask the question now is to
take a bag from a spinning sensor and throw away the returns a Robin-W would
never have received. This document is about how far that stands in for the real
thing, and then what the cropped runs measured.

## What is being emulated, and how honestly

| | Seyond Robin-W | Emulation source (Velodyne VLS128, sample bag) | verdict |
|---|---|---|---|
| horizontal FOV | 120 deg | 360 deg, cropped to 120 | **exact** |
| max range | 70 m @ 10% reflectivity | 250 m, cropped to 70 | **exact** |
| vertical FOV | 70 deg | 40 deg (-25 to +15) | **cannot emulate** |
| points/sec | > 1.28 M | ~2.3 M over 360 deg, so ~0.77 M in a 120 deg wedge | **cannot emulate** |
| scan pattern | solid-state, fixed repeating | spinning, uniform rings | **cannot emulate** |

Robin-W figures are the manufacturer's (seyond.com/products/robin-w/).

The two axes that cannot be emulated both fail in the *same direction*, and that
is what makes the study worth running:

- The VLS128 sees **40 degrees vertically where the Robin-W sees 70**. The source
  is narrower than the sensor being emulated, so no crop can reproduce it. The
  cropped cloud is missing structure a Robin-W would have returned.
- Within the wedge the VLS128 delivers roughly **0.77 M points/s against the
  Robin-W's 1.28 M**, about 60%. Again the emulation is the sparser of the two.

So the emulated sensor is strictly poorer than the real one on both counts.
**A result here is a lower bound**: if NDT holds on this, a Robin-W has more
vertical extent and more points to work with, not less. The converse does not
follow -- a failure here does not prove the Robin-W fails, because it may be
failing on the missing 30 degrees of elevation rather than on the horizontal
restriction that is the actual question.

The third gap does not have a direction. A solid-state scan pattern is fixed and
repeating rather than a uniform sweep, so voxel occupancy is distributed
differently, and nothing in this setup predicts which way that cuts.

**One thing runs the wrong way and has to be subtracted by hand.** The bag's rig
carries two VLP16s beside the top sensor, and they keep publishing whatever the
top sensor is cropped to. They are configured `max_range: 5.0`, so they see only
the vehicle's immediate surroundings, but that is still 360 degrees of near-field
structure a single forward-facing Robin-W would not have. Runs below are
therefore mildly optimistic, and quantifying that is listed at the end.

## Method

Nebula applies both crops **at decode**, so a restricted run produces exactly the
cloud a narrower sensor would have delivered, with no filtering stage bolted on
downstream and no cost anywhere in the pipeline.

The knobs live in the rosbag replay sensor kit
(`tests/rosbag_replay/rosbag_sensor_kit_launch/launch/lidar.launch.xml` in the
`cuda_ndt_matcher` submodule) and reach it through the environment, because the
installed `tier4_sensing_launch` chain between the top-level launch file and the
sensor kit forwards a fixed set of arguments and drops the rest. That is the same
wall `pointcloud_backend` and `camera_model` hit, and the same workaround.

```bash
# in src/localization/cuda_ndt_matcher
scripts/fov_study.sh <min_deg> <max_deg> <max_range_m> <label>
```

Everything else is the harness that is already known to localize this bag: the
`cuda_ndt_matcher` demo path, seeded initial pose, CUDA NDT. The repo's other
replay route (`logging_simulation.launch.yaml`) does **not** localize this bag
and is not used here.

`min_deg`/`max_deg` are degrees in the **sensor's own azimuth frame**, not
vehicle-relative, so which window points forward has to be established from a
run rather than assumed. `scripts/localization/fov_azimuth_probe.py` reads it
back out of a recorded run.

### The trap: scan_phase has to travel with the crop

The first restricted run produced **no top-sensor returns at all**, and did it
quietly. `scan_phase` is the azimuth at which the Velodyne decoder cuts one scan
from the next; the kit had it at 300 degrees, left over from the full-circle
configuration. Crop to `0..90` and that boundary is never inside the retained
data, so the decoder never completes a scan and publishes nothing.

Nothing about the failure says so. The pipeline stays up, the concatenator keeps
publishing at 10 Hz, and NDT keeps producing poses, because the rig's two VLP16s
are unaffected by the top sensor's crop and still deliver near-field points. A
run that had thrown away the entire sensor under test looked exactly like a run
that had merely narrowed it.

`fov_study.sh` therefore pins `scan_phase` to the start of the window. Any future
crop study on a spinning sensor needs the same, and needs to check point counts
rather than assume a live pipeline means live data.

### Where the azimuth window actually points

Measured, not assumed. Cropping the top sensor to `0..90` put returns at
**bearings -5 to +85 degrees in `base_link`**, and nowhere else:

```
      0..   30     1181 |#####################  <- ahead
     30..   60     2193 |########################################
     60..   90     1412 |#########################
```

A single window is not enough to fix a mapping, and reading identity into this
one is the mistake that cost the first sweep. Azimuth `0..90` landing on bearing
`-5..85` is equally consistent with `bearing = azimuth - 5` and with
`bearing = 85 - azimuth`, and those disagree about everything except this one
window. Six further windows separate them:

| window | predicted by identity | predicted by `85 - azimuth` | measured |
|---|---|---|---|
| `270..90` | -95..85 | -5..175 | -5..180 |
| `300..60` | -65..55 | 25..145 | 25..150 |
| `315..45` | -50..40 | 40..130 | 40..135 |
| `330..30` | -35..25 | 55..115 | 55..120 |
| `210..330` | -155..-35 | 115..235 | 115..240 |

**The mapping is `bearing = 85 degrees - azimuth`.** Velodyne counts azimuth
clockwise while ROS measures bearing counter-clockwise, so the two run in
opposite directions; the 85 degree offset is the sensor's mounting yaw. Straight
ahead is **azimuth 85**, not azimuth 0, and the windows the first sweep used as
"forward" were in fact centred about 90 degrees to the left.

## The blocker: a forward-facing wedge cannot be cut from this bag

Decode-time cropping cannot aim where the Robin-W will point, and the reason is
structural rather than a matter of finding the right numbers.

A window only produces any cloud at all if it **contains azimuth 0 or azimuth
300** -- the azimuth counter's wrap, and the cut the bag's original recording was
made at. Outside those the decoder never completes a scan and publishes nothing.
Measured across every window tried:

| window (sensor azimuth) | contains 0 or 300 | cloud |
|---|---|---|
| `0..90`, `270..90`, `300..60`, `315..45`, `330..30`, `210..330`, `0..360` | yes | yes |
| `25..145`, `100..220`, `145..265` | no | **empty** |

`25..145` was tried at four different `scan_phase` values and stayed empty, so
this is the window and not the phase.

Now combine that with the direction mapping. Azimuth 0 sits at bearing +85 and
azimuth 300 at bearing +145, so **every window that produces a cloud necessarily
contains bearing +85 or +145** -- both on the vehicle's left. A forward-centred
wedge is exactly the set of directions that excludes both. It is not reachable
this way at any width.

So the runs below restrict the field of view **to a wedge on the left**, not
ahead. That is a real restricted-FOV experiment and the width results stand on
their own, but it is not yet the Robin-W's geometry, and the last section shows
why that distinction has teeth.

## Results

All runs replay the same bag against the same map, scored with
`scripts/localization/fov_study_report.py`. `dev` is distance from the full-FOV
baseline's pose at the same stamp.

| run | azimuth | bearing arc seen | poses | path m | scatter p95 | dev p50 | dev p95 | dyaw p95 | NVTL |
|---|---|---|---|---|---|---|---|---|---|
| baseline, 360 deg, 250 m | 0..360 | all | 292 | 129.7 | 0.093 | - | - | - | 3.17 |
| 360 deg, **70 m** | 0..360 | all | 292 | 129.6 | 0.092 | 0.014 | 0.044 | 0.054 | 3.18 |
| 185 deg, 250 m | 270..90 | -5..180 | 295 | 129.4 | 0.087 | 0.020 | 0.082 | 0.098 | 3.15 |
| 125 deg, 250 m | 300..60 | 25..150 | 293 | 129.4 | 0.107 | 0.028 | 0.210 | 0.125 | 3.12 |
| **125 deg, 70 m** | 300..60 | 25..150 | 293 | 129.5 | 0.099 | 0.025 | 0.204 | 0.132 | 3.12 |
| 95 deg, 70 m | 315..45 | 40..135 | 255 | 128.9 | **0.713** | 0.035 | 0.292 | 0.334 | 3.11 |
| 65 deg, 70 m | 330..30 | 55..120 | **15** | - | - | - | - | - | - |
| 125 deg, 70 m, **rear** | 210..330 | 115..240 | 200 | 129.2 | **2.990** | 0.067 | 0.274 | 0.263 | 3.20 |

Widths are the measured arcs, which run about 5 degrees over the configured
window because the histogram bins at 5 degrees.

**Range is free.** Cutting 250 m to the Robin-W's 70 m, with the full circle
retained, moved the pose by 44 mm at p95 and changed nothing else. Whatever the
restricted FOV costs, it is not the range.

**NDT tolerates losing most of the horizon.** At 185 degrees it is
indistinguishable from the baseline. At 125 degrees -- the Robin-W's horizontal
width -- it still tracks the full-FOV solution to 0.20 m at p95 over 130 m of
path, with scatter and yaw step unchanged. That is the headline: **the width the
Robin-W offers is not, by itself, the problem.**

**The floor is between 125 and 95 degrees.** At 95 degrees scatter jumps sevenfold
to 0.71 m and 37 frames are lost outright. At 65 degrees it does not localize at
all, 15 poses for the whole run, and that reproduced on a repeat and at a second
`scan_phase`.

**Direction matters more than width at the margin.** The rear-facing 125 degree
wedge sees the same amount of the world as the left-facing one and is far worse:
scatter 2.99 m against 0.099, a third of the frames gone. A Robin-W's forward
wedge is a third direction, measured by neither, and this row is the evidence
that it cannot be assumed to behave like the left-facing one.

**NVTL earned its exclusion again.** The worst run in the table, the rear wedge,
scores the *highest* NVTL of any restricted run, 3.20 against the baseline's
3.17. Anything ranking on NVTL would have picked it as the best.

### What this says about the Robin-W

Read against the fidelity table at the top: the emulated sensor is poorer than a
real Robin-W in both respects that could not be reproduced -- 40 degrees of
vertical extent against 70, and about 60% of the point rate. A 125 degree wedge
survived that handicap with 0.20 m of deviation.

That is genuine encouragement and it is not a green light, because the wedge
tested faces left and the rear-facing run shows direction is worth more than the
remaining margin.

## Forward-facing wedges: the run that answers the question

`scripts/localization/fov_restrict_node.py` filters the concatenated cloud by
bearing in `base_link`, measured about the sensor mount rather than the vehicle
origin, so it can aim anywhere. `scripts/fov_bearing_study.sh` drives it.

It is **stricter** than the decoder crop above, not merely different: it clips
the two VLP16s to the same wedge, so these runs have none of the leftover
full-circle near-field the decoder-side runs kept. This is a single narrow
forward sensor, which is the rig actually being considered.

| bearing window | width | points kept | poses | path m | scatter p95 | dev p50 | dev p95 | dyaw p95 |
|---|---|---|---|---|---|---|---|---|
| full circle, 250 m (control) | 360 | 100.0% | 202 | 124.0 | 0.595 | 0.014 | **0.056** | 0.058 |
| -90..+90, 70 m | 180 | 41.4% | 292 | 129.8 | 0.104 | 0.031 | 0.194 | 0.202 |
| **-60..+60, 70 m** | **120** | **25.5%** | 293 | 129.7 | 0.107 | 0.055 | **0.220** | 0.256 |
| -45..+45, 70 m | 90 | 17.6% | 293 | 129.6 | 0.112 | 0.090 | 0.222 | 0.313 |
| -30..+30, 70 m | 60 | 10.4% | 292 | 132.2 | 0.122 | 0.106 | 0.335 | 0.538 |

**Every forward wedge localized, down to 60 degrees.** Deviation from the
full-FOV solution grows smoothly with narrowing -- 0.19, 0.22, 0.22, 0.34 m at
p95 -- and heading is the first thing to suffer, with `dyaw` p95 rising 2.7x
across the sweep while scatter barely moves. Nothing collapses.

**Read those against the control's 0.056 m**, which is this filter's own noise
floor: a full-circle pass through the same Python node still differs from the
unfiltered baseline by that much. So the Robin-W width costs roughly 0.22 m
against a 0.06 m floor. Real, small, and nothing like a failure.

The control is also the *worst* run in the table for frame retention, losing 90
of 292 poses, because passing every point through a Python node at 10 Hz does not
keep up. The restricted runs keep all their frames precisely because they publish
less. Absolute latency here is a harness artifact and should not be read as a
property of narrow FOV.

### Direction is worth more than width

Putting the two methods side by side at the same width, about 120 degrees:

| wedge centre | scatter p95 | dev p95 | poses |
|---|---|---|---|
| forward (0 deg) | 0.107 | 0.220 | 293 |
| left (+88 deg) | 0.099 | 0.204 | 293 |
| **rear (178 deg)** | **2.990** | 0.274 | 200 |

Forward and left are equivalent. Rear is a different regime: 30x the scatter and
a third of the frames lost, on the same bag with the same amount of world
visible. Whatever a narrow sensor is pointed at, it should not be pointed
backwards on this route.

That also settles the doubt the earlier sweep left. The decoder-crop runs failed
at 65 degrees while these survive 60, and the difference is not the width -- it is
that those wedges faced left-and-behind at the narrow end and these face
forward.

## What this says about the Robin-W

The fidelity table at the top says the emulation is poorer than a real Robin-W in
both respects it could not reproduce: 40 degrees of vertical extent against 70,
and roughly 60% of the point rate. A 120 degree forward wedge survived that
handicap at 0.22 m p95 deviation over 130 m, holding every frame.

**So a forward-facing Robin-W is not disqualified by its field of view**, on this
route, against a prior map, with the rest of the Autoware localization chain
intact. The margin is thinner than the full circle's and the failure mode to
watch is heading rather than position.

Three caveats that this study cannot retire, in order of how much they could
change the answer:

1. **One bag, one route, 130 m.** A wedge that never faces a featureless
   corridor has not been tested against one. The route's geometry does the work
   here, and a different site can remove it.
2. **The scan pattern is wrong.** Uniform spinning rings, not a solid-state
   repeating pattern. Nothing here predicts which way that cuts.
3. **EKF help is excluded by design.** These numbers are the scan matcher's own
   output. On the vehicle the fusion filter would smooth some of the heading
   noise -- and would also hide it.

## The TIERS OS0-128 attempt: pipeline built, results not yet usable

The sample-bag study can only crop horizontally, because the VLS128 spans 40
degrees vertically against the Robin-W's 70. The TIERS dataset's Ouster OS0-128
is 360 by 90 and is wider in both axes, so it can emulate the whole envelope.

**The pipeline works end to end** and is reusable:

| step | tool |
|---|---|
| ROS 1 bag to ROS 2, OS0 only, frames and stamps fixed | `scripts/localization/tiers_extract_os0.py` |
| trajectory | `kiss_icp_pipeline`, 1106 poses, 76.1 m |
| prior map from the full FOV | `scripts/localization/build_pcd_map.py`, 301k points |
| bake a field of view into a bag | `scripts/localization/fov_bake_bag.py` |
| replay | `cuda_ndt_matcher/scripts/tiers_baked_run.sh`, `tiers_sensor_kit` |
| score against the trajectory | `scripts/localization/compare_to_reference.py` |

### First attempt: unusable, and why

**Superseded by the results below. Kept because the fault took three fixes to
find and would otherwise be rediscovered.**

Running the identical configuration repeatedly gives:

| run | median error | 95th | yaw p95 |
|---|---|---|---|
| Robin-W spec, attempt 1 | 4.385 m | 14.07 | 97.8 deg |
| Robin-W spec, attempt 2 | 7.326 m | 45.30 | 174.6 deg |
| Robin-W spec, attempt 3 | **0.129 m** | 6.83 | 0.94 deg |
| vertical crop only, attempt 1 | 15.811 m | 36.39 | 0.97 deg |
| vertical crop only, attempt 2 | **0.044 m** | 0.13 | 0.88 deg |

Same bag, same map, same parameters. Run-to-run variance is larger than any
effect the study is trying to measure, so **no number from this arm means
anything yet** and none should be quoted.

The first sweep also read as non-monotonic in a way that gave it away before the
repeats did: the vertical-only crop, which keeps 88% of the points and the entire
horizon, failed, while a 90 by 70 degree wedge keeping 29% tracked to 0.105 m.
A narrower sensor outperforming a wider superset is not a field-of-view result.

Two harness faults are already ruled out:

- **Throughput.** The live filter is a Python node that cannot pass a 2048x128
  cloud at 10 Hz. The unrestricted run fell to 5 Hz while a 120 degree run held
  10, so the runs keeping the most points had the fewest poses and lost
  localization -- an ordering manufactured entirely by the harness, and it
  reversed the expected result. Fixed by baking each field of view into its own
  bag; every run now completes ~1100 poses.
- **Timestamps.** The Ouster clouds are stamped in sensor-boot time, not ROS
  time, so every frame failed pose interpolation and NDT never published. Fixed
  in the extractor.

The leading remaining suspect is that **this rig has no odometry**. The golf
cart's chain feeds `vehicle_velocity_converter` into `gyro_odometer` into
`ekf_localizer`; a handheld TIERS trolley has no wheel encoder, so the EKF runs
without twist and NDT gets a weak prior every frame. That fits what is seen:
median iteration count 10 against 3 on the sample bag, and divergence that
starts sometimes and not others. Testing it means synthesising a twist -- from
the OS0's own IMU, or from the KISS-ICP trajectory as a stand-in for a wheel
encoder -- and rerunning with repeats.

### The missing twist was the cause, and fixing it settled the arm

`scripts/localization/tiers_add_odometry.py` adds the OS0's own IMU on
`/sensing/imu/imu_data` and a **synthesised** vehicle velocity on
`/sensing/vehicle_velocity_converter/twist_with_covariance`, differentiated from
the reference trajectory. Mean speed 0.66 m/s, max 2.48 -- a walking pace rig.

The synthesised velocity is a stand-in and has to be read as one: it comes from
KISS-ICP, which also produced the map, so it is not independent, and it is
*better* than a real wheel encoder -- no slip, no scale error, no quantisation.
It stands in for the odometry a vehicle has and this trolley does not, which puts
the replay in the regime the golf cart is actually in.

Every configuration, three runs each, scored against the reference trajectory:

| field of view | points kept | err p50 (3 runs) | err p95 | yaw p95 |
|---|---|---|---|---|
| 360 x 90 deg, 100 m (full) | 100% | 0.050 / 0.050 / 0.050 | 0.126 - 0.130 | 0.89 - 0.92 |
| 360 x **70** deg, 100 m | 88.0% | 0.047 / 0.047 / 0.047 | 0.128 - 0.131 | 0.88 - 0.90 |
| **120 x 70 deg, 70 m (Robin-W)** | **34.0%** | **0.082 / 0.082 / 0.083** | **0.223 - 0.228** | 0.89 - 0.92 |
| 90 x 70 deg, 70 m | 29.4% | 0.117 / 0.118 / 0.117 | 0.264 - 0.271 | 0.94 - 0.97 |

Run-to-run spread collapsed from **metres to a millimetre**, which confirms the
diagnosis: the instability was the missing prior, not the field of view. The
ordering is now monotonic in how much the sensor can see, and every configuration
localizes for the whole sequence.

**The vertical restriction is free.** Cutting 90 degrees of elevation to the
Robin-W's 70, keeping the full horizon, changed the median error by -3 mm. This
is the measurement the Autoware sample bag could not make at all, and it says the
vertical axis is not where the risk is.

**The Robin-W's full envelope costs a factor of 1.6.** 120 by 70 degrees at 70 m,
on 34% of the points, tracks the reference to 82 mm median and 0.23 m at p95
against the full sensor's 50 mm and 0.13 m. Heading is unchanged, 0.9 degrees at
p95 in both.

That is a second dataset, a different sensor, a different site, with the vertical
axis emulated properly and three repeats per point, agreeing with the sample-bag
conclusion: **a forward-facing Robin-W is not disqualified by its field of view.**

### The degeneracy monitor sees it, and sees it in the right axis

Median per-frame conditioning from the same runs, via
`/localization/pose_estimator/degeneracy/`:

| field of view | translation anisotropy | rotation anisotropy | translation min eigenvalue |
|---|---|---|---|
| 360 x 90 | 5.14 | 2.96 | 27070 |
| 360 x 70 | 4.91 | 3.48 | 24852 |
| 120 x 70 (Robin-W) | 5.47 | 5.98 | 8841 |
| 90 x 70 | 6.41 | 8.40 | 6574 |

Two things worth having:

- **It responds to the field of view** rather than to the point count alone.
  The minimum eigenvalue tracks how many points were matched, as expected, but
  anisotropy is the ratio and is not supposed to; it still rises as the wedge
  narrows.
- **Rotation degrades faster than translation**, 2.8x against 1.2x across the
  sweep. That is the same asymmetry the sample-bag sweep found in the pose
  output, arrived at independently from the Hessian, and it is why a monitor for
  a narrow-FOV vehicle should be gated on heading.

## Still to do
- Repeat on a route with a long featureless stretch, which is where a forward
  wedge should fail first.
- Narrow the floor below 60 degrees, now that direction is controlled.
- Port the filter to C++ if it is ever wanted in a live pipeline; the Python node
  cannot pass a full cloud at 10 Hz and only kept up here because it discards
  most of it.
