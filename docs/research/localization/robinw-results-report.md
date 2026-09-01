# Robin-W localization: results

**Question.** The golf cart replaces a 360-degree VLP-32C with a forward-facing
Seyond Robin-W, 120 x 70 degrees. Can Autoware's NDT localize as well?

**Answer.** Yes, with one change to the map. Robin-W reaches **0.048 m** against
the VLP-32C's **0.055 m**.

---

## Setup

No Robin-W recording paired with a map exists, so both sensors are **emulated
from one recording** by discarding returns each would not have received.

| | |
|---|---|
| Recording | TIERS `Road01`, Ouster OS0-128, 2048 x 128 @ 10 Hz |
| | 110 s, 76 m, walking pace, outdoor car park |
| Robin-W | crop to 120 x 70 deg, 70 m -> 34% of points |
| VLP-32C | 360 deg, -25..+15 deg, 32 rings, 200 m -> 16.6% of points |
| Map | built from the **full** 360-degree cloud along a KISS-ICP trajectory |
| Pipeline | Autoware NDT replay, CUDA scan matcher, stock config |
| Score | median error against the KISS-ICP trajectory |

The 2.0x density ratio between the emulations matches the real sensors' 2.1x.

**Limits.** Emulation, not the sensor. Walking pace, so deskew is untested. The
reference is the LiDAR odometry that also built the map, so this measures
agreement with the map's frame, not absolute accuracy, and absolute values are
optimistic. Comparisons between rows are sound; the metres are not field accuracy.

---

## Result

Only the map's downsample voxel changes. Stock NDT throughout.

| map downsample | err p50 | err p95 |
|---|---|---|
| 0.40 m | 0.104 | 0.248 |
| **0.20 m — current** | **0.082** | 0.223 |
| 0.10 m | 0.061 | 0.168 |
| **0.05 m** | **0.048** | 0.147 |
| *VLP-32C, 0.20 m — the bar* | *0.055* | *0.131* |

**0.05 m beats the deployed VLP-32C on both p50 and p95.** 0.10 m is the
pragmatic point: 0.061, at 22 MB per 76 m against 104 MB.

The same change helps the VLP-32C too — it reaches 0.040 — so this is not a
Robin-W trick. But the wedge gains more, 41% against 27%.

**COSS is already at 3.8 cm spacing and needs no change.** This is guidance for
the next site: the survey company delivers 133 M points and the vehicle currently
keeps 4.9 M.

---

## What failed first

| attempt | err p50 | why it failed |
|---|---|---|
| stock NDT | 0.082 | the 1.5x gap |
| NDT resolution swept | 0.077 | small gain |
| point budget x10 | 0.075 | nothing |
| Laplace covariance | unstable | 1 run in 3 diverged |
| VGICP instead of NDT | — | degraded at the same rate, 1.49x vs 1.54x |
| sliding-window smoothing | worse | removed noise, left bias |
| survey the map with the Robin-W | 0.055 | works, but the map is bought |

Every one of them **reduces variance**. That was the mistake.

---

## Why the map is the answer

The penalty is **bias, not noise**.

- Noise is the same for every sensor: 0.050 / 0.057 / 0.058.
- Bias nearly doubles from full circle to wedge, and lands **cross-track**.
- The Robin-W carries **more** information than the VLP-32C, pins its
  worst-constrained axis **1.7x better**, and is **better conditioned** — and is
  still worse. So it is not an observability problem.

A scan-to-map matcher measures agreement with the map, and map disagreement is
fixed per surface. A full circle collects opposing pulls that cancel. A 120-degree
wedge has no opposing side, so they sum. Coarse map cells are one such
disagreement, which is why the map's resolution is the lever and why the wedge
gains most from fixing it.

Confirmed independently: two opposed wedges reach 0.094 where one reaches 0.113,
and a 210-degree arc reaches 0.092 using **fewer points** than the two wedges.
Coverage explains it; point count does not.

---

## Open

**Real Robin-W data is blocked.** Four COSS recordings exist (`data/coss/`). All
four are stationary, and their scans do not register to the COSS map at any of
832 poses searched across it. Cause unresolved — the map area, frame and the
scans' levelness all check out.

Next: a moving Robin-W recording paired with its correct map. Everything that
matters — bias at speed, deskew, the prior chain — needs motion.
