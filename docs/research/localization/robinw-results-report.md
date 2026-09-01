# Robin-W localization: results

The golf cart replaces a 360° VLP-32C with a forward-facing Seyond Robin-W,
120° × 70°. It can localize as well — **0.048 m against the VLP-32C's 0.055 m** —
with one change, and it is not to NDT.

---

## The working configuration

Change the map. Leave NDT alone.

| | value | note |
|---|---|---|
| **map downsample** | **0.05 m** | currently 0.20 m — this is the whole change |
| `ndt.resolution` | 2.0 | stock |
| `sample_num` | 5 000 | stock |
| `covariance_estimation_type` | 0, fixed | stock |
| NVTL gate | 2.0 | stock |

| | err p50 | err p95 | map size / 76 m |
|---|---|---|---|
| **Robin-W, this config** | **0.048** | **0.147** | 104 MB |
| Robin-W, 0.10 m map | 0.061 | 0.168 | 22 MB |
| Robin-W, 0.20 m map *(today)* | 0.082 | 0.223 | 4.6 MB |
| *VLP-32C, 0.20 m — the bar* | *0.055* | *0.131* | |

Beats the deployed VLP-32C on p50 **and** p95. **0.10 m is the pragmatic point**:
0.061 at a fifth of the size.

The same change helps the VLP-32C too — it reaches 0.040 — so this is not a
Robin-W trick. But the wedge gains more, **41% against 27%**.

> **COSS is already at 3.8 cm and needs no change.** This is guidance for the next
> site. The survey company delivers 133 M points; the vehicle keeps 4.9 M.

**Best achievable by NDT tuning alone: 0.077.** The rest of this report is why.

---

## Setup

No Robin-W recording paired with a map exists, so both sensors are **emulated
from one recording** by discarding the returns each would not have received.

| | |
|---|---|
| Recording | TIERS `Road01` — Ouster OS0-128, 2048×128 @ 10 Hz. 110 s, 76 m, walking pace, outdoor car park |
| Robin-W | crop to 120°×70°, 70 m → 34% of points |
| VLP-32C | 360°, −25..+15°, 32 rings, 200 m → 16.6% of points |
| Map | built from the **full** 360° cloud along a KISS-ICP trajectory |
| Pipeline | Autoware NDT replay, CUDA scan matcher |
| Score | median error vs the KISS-ICP trajectory, 1106 frames |

The 2.0× density ratio between the emulations matches the real sensors' 2.1×.
The bar is three runs: 0.055 / 0.055 / 0.056.

> **Limits.** Emulation, not the sensor. Walking pace, so deskew is untested. The
> reference is the LiDAR odometry that also built the map, so this measures
> agreement with the map's frame, not absolute accuracy, and the values are
> optimistic. Row-to-row comparisons hold; the metres are not field accuracy.

---

## NDT parameters: what each one is worth

Robin-W wedge throughout. One parameter varies per table; everything else stock.

### `ndt.resolution` — the matcher's voxel size

| resolution | err p50 | err p95 | frames | |
|---|---|---|---|---|
| 1.0 | 3.900 | 5.332 | 1078 | diverges |
| 1.5 | 1.527 | 3.531 | 827 | diverges |
| 2.0 *(stock)* | 0.082 | 0.223 | 1106 | |
| **3.0** | **0.077** | **0.175** | 1106 | best |
| 4.0 | 0.114 | 0.340 | 1106 | |

Optimum is **coarser** than stock, not finer — the opposite of the intuition that
a denser sensor affords finer voxels. A narrow wedge sees fewer voxels, and fine
ones hold too few points to condition a distribution. Below 2.0 it collapses.

Swept with the NVTL gate lowered to 0.5, because the gate is calibrated for 2.0
and NVTL scales with voxel size — leaving it alone measures the gate, not the
geometry.

### `sample_num` — points reaching the matcher

| sample_num | Robin-W p50 | VLP-32C p50 |
|---|---|---|
| 5 000 *(stock)* | 0.077 | 0.055 |
| 20 000 | 0.077 | 0.054 |
| 50 000 | 0.075 | 0.055 |

**Ten times the points moves the error 2 mm.** NDT saturates far below 5 000
points on this scene and cannot convert the Robin-W's density into accuracy.
Worth knowing before paying for a dense sensor.

### `covariance_estimation_type` — fixed vs Laplace

| setting | run 1 | run 2 | run 3 |
|---|---|---|---|
| 0, fixed *(stock)* | 0.077 | 0.077 | 0.077 |
| 1, Laplace | 0.073 | **12.950** | 0.077 |

No gain, and **one run in three diverged** — a failure absent from nine runs with
fixed covariance. The first Laplace run looked like a win; it did not replicate.

### NVTL convergence gate

| gate | err p50 |
|---|---|
| 2.0 *(stock)* | 0.054 |
| 0.5 | 0.055 |

Inert at these settings. It matters only when sweeping resolution, where it
silently rejects fine-voxel runs.

### Combinations

| config | err p50 | err p95 |
|---|---|---|
| stock | 0.082 | 0.223 |
| res 3.0 | 0.077 | 0.175 |
| res 2.0 + 50 000 points | 0.082 | 0.226 |
| res 1.0 + 50 000 points | 3.790 | 5.347 |

Dense sampling alone is **worse than stock**. Fine voxels still fail with ten
times the points, so their collapse is not starvation by the downsampler.

---

## Why parameters can't fix it and the map can

The penalty is **bias, not noise**.

- Noise is the same for every sensor: 0.050 / 0.057 / 0.058.
- Bias nearly doubles from full circle to wedge, and lands **cross-track**.
- The Robin-W carries **more** information than the VLP-32C, pins its
  worst-constrained axis **1.7× better**, and is **better conditioned** — and is
  still worse. So it is not an observability problem.

A scan-to-map matcher measures agreement with the map, and map disagreement is
fixed per surface. A full circle collects opposing pulls that cancel; a 120°
wedge has no opposing side, so they sum. Coarse map cells are one such
disagreement — hence the map resolution is the lever, and the wedge gains most
from fixing it.

Confirmed independently: two opposed wedges reach 0.094 where one reaches 0.113,
and a 210° arc reaches 0.092 using **fewer points** than the two wedges. Coverage
explains the ordering; point count does not.

### Everything that failed, and the pattern

| attempt | outcome |
|---|---|
| NDT resolution swept | 0.077, small gain |
| point budget ×10 | 2 mm |
| Laplace covariance | no gain, 1 run in 3 diverged |
| VGICP instead of NDT | degraded at the same rate, 1.49× vs 1.54× |
| sliding-window smoothing | worse — removed noise, left bias |
| survey the map with the Robin-W | 0.055 — works, but the map is bought |

**Every one of them reduces variance.** The error is not variance-limited. That
question is cheap to ask and would have saved most of this campaign.

---

## Open

**Real Robin-W data is blocked.** Four COSS recordings exist. All four are
stationary, and their scans do not register to the COSS map at any of 832 poses
searched across it. Cause unresolved — the map's area, frame, and the scans'
levelness all check out.

Next: a moving Robin-W recording paired with its correct map. Everything that
matters — bias at speed, deskew, the prior chain — needs motion.
