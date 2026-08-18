# NDT tuning on the NTU campus map (CSIE-1)

Tuning record for the NTU replay: what was measured, what changed, and the
traps that cost the most time. Companion to
[ndt_parameter_tuning_coss_map.md](ndt_parameter_tuning_coss_map.md), which
covers the earlier COSS map study.

Reproduce with:

```bash
just ntu-test run CSIE-1      # bag, stack, RViz, pose init — in the only order that works
just ntu-test align           # scan-to-map residual
just ntu-test report          # pose scatter and yaw step
```

## Measure alignment, not the estimator's opinion of itself

Everything below is ranked on **scan-to-map residual**: transform each live scan
into the map frame with the pose the stack is publishing, and measure every
point's distance to the nearest map point (`just ntu-test align`).

NVTL cannot answer this question. It is computed by the same estimator under
test, against the same voxel grid, and it is a *mean per-point* likelihood — so
it moves with how the input is sampled, not only with how well the pose fits. It
cannot separate "the scan is on the map" from "the scan is confidently on the
wrong part of the map". This is not theoretical: the change that improved
accuracy most in this study **lowered** NVTL by a third.

Stationary and moving frames are reported separately. Stationary frames answer
"did initial convergence succeed", moving frames answer "is tracking holding".
The ~1 minute of parked time at the start of each NTU bag is what makes the
first question answerable at all.

## Results

Stationary frames, ~550 scans per configuration, CSIE-1:

| crop | voxel | sample | NVTL gate | p50 | p95 | mean | beyond 3 m |
|---|---|---|---|---|---|---|---|
| ±20 m | 0.5 | 2000 | 2.3 | 0.210 m | 1.661 m | 0.476 m | 0.0% |
| **±60 m** | 0.5 | 2000 | 2.3 | 0.145 m | **0.468 m** | 0.185 m | 0.0% |
| ±60 m | **3.0** | 1500 | 2.3 | 0.682 m | 2.590 m | 0.953 m | **12.1%** |
| **±60 m** | **0.5** | **2000** | **1.3** | **0.144 m** | **0.469 m** | **0.185 m** | **0.0%** |

Last row is what ships.

### The range was wrong

`±20 m` came from AutoSDV. Our VLP-32C returns reach about 29 m, so the box was
clipping real structure, and what survived sat in a narrow ring that constrains
rotation poorly. Restoring Autoware's `±60 m` cuts p95 by **72%**.

The p95 improving far more than the p50 is the tell: the worst-fitting points
gain the most, which is exactly what distant structure is for.

### The voxel size was already right

Autoware's stock `3.0 m` is much worse — p50 0.682 m and 12% of points beyond
3 m. It averages away the structure NDT matches on. The AutoSDV `0.5 m` stays.
Not every inherited value was wrong, and reverting wholesale to defaults would
have made this worse.

### min_z made no difference

`-1.0` and `-30.0` produced identical numbers (p50 0.145, p95 0.468 both ways),
so it was left alone rather than changed for tidiness.

## The NVTL gate is not portable

Widening the crop box **forced** the convergence threshold to move, and this is
the part that would have bitten later.

Spreading the same 2000 sampled points over nine times the area dropped NVTL
from ~3.2 to 1.44–2.31 (median ~2.0) **while the residual improved**. Left at
2.3, `ndt_scan_matcher` rejects poses measurably better than the ones it used to
accept, logs `Score is below the threshold`, and after `skipping_publish_num`
consecutive rejections stops publishing and **deactivates** — with the EKF
dead-reckoning on behind it. That is almost certainly the mid-drive failure seen
earlier on this same bag.

Shipped at `1.3`, below the observed minimum of 1.44 with margin.

**Re-derive this threshold whenever the crop box, voxel size, sample count or
`ndt.resolution` changes.** It encodes the input distribution, not a property of
the map.

## Traps

Each of these produced a confident wrong answer before it was understood.

**A failed initialization latches NDT off.** `pose_initializer` does
`change_node_trigger(false)` → `align` → `change_node_trigger(true)`. The align
returns failure when any input is missing (no map in NDT, no accepted scan, no
TF), `LocalizationModule::align_pose` throws, and the reactivate never runs.
`is_activated_` is written *only* by that trigger service, so nothing recovers
it. Meanwhile `/localization/kinematic_state` keeps publishing at 40 Hz and the
vehicle drives across the map on dead reckoning. `just ntu-test run` now verifies
activation with `check_ndt_activated.py` instead of trusting the service's
success code.

**Order of operations.** The bag must lead, paused, publishing `/clock` only.
Anything started before a clock exists sits at time 0 and is yanked ~4 days
forward when playback begins: RViz latches the maps at t=0 and drops them, and an
initial pose stamped in wall time is rejected by NDT as days away from every
scan. The pose must come last, because align needs a scan to match against —
seeding earlier leaves `pose_initializer` blocked in `Call align server` forever.

**ROS 2 parameter typing is strict.** Writing `min_x: -20` instead of `-20.0`
makes the crop-box node fail to load; the symptom is `no cloud on
/localization/util/downsample/pointcloud`, which reads as a missing topic rather
than a malformed number.

**Sensor clouds are BEST_EFFORT.** A default (RELIABLE) subscriber never
connects. rclpy reports it as a single "incompatible QoS" warning and the
callback simply never fires.

## Open

- **Moving-frame residual did not improve** (p50 ~0.5–0.7 m). Run-to-run samples
  cover different route segments (69–180 scans), so they are not comparable
  across configurations. Needs a fixed time window before ranking anything on it.
- **`iteration_num` still reaches its 30 cap** on some scans (median 20,
  `exe_time` median 15 ms against a ~143 ms budget at 7 Hz). `max_iterations` has
  real headroom if moving accuracy matters more than CPU.
- **`sensor_points_delay_time_sec` is 0.379** — at 18 km/h that is 1.9 m of
  travel between a scan's timestamp and its use, the right order of magnitude to
  explain the moving-frame degradation. Testable by binning residual against
  speed.
- **Map coverage thins along the route.** Near the seed pose there are 79,387 map
  points within 20 m; at a later position only 628. Sparse stretches are a
  mapping gap, not a tuning problem, and no parameter will fix them.
