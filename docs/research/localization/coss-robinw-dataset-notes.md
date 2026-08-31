# COSS Robin-W / VLP-32C recordings: what they are, and what blocks their use

Four recordings from `2025-11-14 AutoSDV Localization RosBags in COSS`, copied to
`data/coss/` (gitignored, 9.5 GB): `robin_1`, `robin_2`, `vlp32_1`, `vlp32_2`.

They are the first **real Robin-W data** this project has, recorded alongside a
VLP-32C on the same day, and were expected to retire the emulation caveats in
[restricted-fov-ndt.md](restricted-fov-ndt.md). Two findings block that, and both
need someone with site knowledge rather than more analysis.

## Confirmed: the sensor is a Robin-W, and its envelope matches the spec

From `/sensing/lidar/concatenated/pointcloud`, frame `base_link`:

- **116 degrees azimuth by 61 degrees elevation, forward-facing.** That is the
  120 x 70 envelope the campaign has been emulating, measured from real data for
  the first time.
- Raw topic `/sensing/lidar/iv_points`, frame `robin_w`.
- Range p50 2.1 m, p99 92.8 m. 85k points per scan.

**The point layout is already correct**, which corrects a claim made earlier in
this campaign. Both topics carry `intensity` / `return_type` / `channel`, the
names Autoware compares against literally. The pinned `seyond_ros_driver`
submodule registers them as `I` / `R` / `C`, and **no branch of that fork has the
corrected names**. So the driver that produced this data is not the one this
repository pins. The naming defect is real for the pinned code and is *not* a
description of the vehicle as it ran on 2025-11-14. Phase 6's R0-a should be read
that way.

## Blocker 1: all four recordings are stationary

Not "parked at the start" -- stationary throughout. Established three ways, the
last of which does not depend on any vehicle topic:

| bag | duration | max speed | kinematics path | displacement by registration |
|---|---|---|---|---|
| robin_1 | 153.4 s | 0.00 | 0.0 m | 0.01 m over 152.7 s |
| robin_2 | 74.6 s | 0.00 | 0.0 m | 0.00 m over 74.2 s |
| vlp32_1 | 28.5 s | 0.00 | 0.0 m | 0.05 m over 28.2 s |
| vlp32_2 | 28.7 s | 0.00 | 0.0 m | 0.00 m over 27.8 s |

The last column registers the final scan against the first; it would read metres
if the vehicle had moved. `/vehicle/status/velocity_status` is flat at zero and
`/api/vehicle/kinematics` is frozen at a single constant value, so neither can
serve as a reference trajectory or as a seed of known provenance. GNSS wanders
1.5 to 6 m, which is ordinary non-RTK noise for a static receiver.

A stationary bag is not useless -- true motion of zero is perfect ground truth
for the *noise* half of the error, and comparing Robin-W against VLP-32C that way
would be clean. It cannot measure the *bias* half, which is what the campaign
found the field-of-view penalty to be.

## Blocker 2: the COSS map does not match these recordings

Localizing `robin_1` from the only available seed diverged by 38 m, so the fit
was searched for exhaustively instead: **832 starting poses spanning the entire
map**, every 10 m in x and y and every 45 degrees of yaw.

- Median error per inlier across all 832 starts: **48.7** (robin_1), **48.3**
  (vlp32_1).
- Best non-degenerate candidate: 37.0, against a median of 48.3. No sharp
  optimum anywhere.
- A correct registration scores well under 1.

**Re-run after finding a flaw in that search.** The grid steps 10 m while the
correspondence distance was 3 m, so a true pose between grid points would have no
correspondences and could not converge -- the flat score was partly the search
failing to reach anything. Repeated at a 20 m correspondence distance and 60
iterations: median 41.7 and 50.6, best non-degenerate 40.5 with 1424 inliers,
which is a mean squared residual around 40 and so an RMS near 6 m. Still not a
fit. The conclusion survives the correction.

**Three other explanations ruled out**, so this is not a guess:

- *The clouds are not tilted.* Fitting a plane to near-field ground gives a
  normal 0.4 to 0.5 degrees from vertical on both sensors, with ground at
  z = -0.4 to -0.75. They are level and genuinely in `base_link`, so an
  unapplied extrinsic is not the cause.
- *The frame is right.* `configed/merge_downsampled.pcd` and its `_shift`
  twin differ by exactly `(-304731.375, -2768113.5, 0)` with zero variance,
  which is the TWD97-to-local shift. The deployed map is already in the local
  frame and the seed lies inside it.
- *The map area is right.* `20251226/output_downsampled.pcd`, 5.46 M points,
  has exactly the deployed map's extent, so the deployed map is an edit of it
  rather than a different region.

So the scan does not fit this map at any pose. The map itself is sound and
unusually dense -- 4.9 M points, 3.8 cm nearest-neighbour spacing, 130 x 75 m --
so this is a correspondence problem, not a quality one. Candidate causes, in
order of suspicion:

1. A **different area** of the COSS site than these bags were recorded in.
2. A **coordinate origin shift**. The map directory contains
   `lanelet2_map_orig_v10_axis_shift.osm` beside `lanelet2_map.osm`, which says
   an axis shift was applied to this map at some point.
3. A different map version than the vehicle was running on 2025-11-14.

## The survey pipeline, for the density question

Tracing the map to source also answers the density question raised separately:

| stage | artefact | size |
|---|---|---|
| survey delivery, TWD97 | `pt01/02/03_TWD97.pcd` | **133.1 M points**, 2.6 GB |
| merged | `configed/merged.pcd` | 450 MB |
| ground-only, downsampled | `merge_downsampled{,_shift}.pcd` | 42.7 k points |
| 0.2 m version | `pt04_merge_0.2.pcd` | 108.8 k points |
| 2025-12 rebuild | `20251226/output_downsampled.pcd` | 5.46 M points |
| **deployed** | `data/COSS-map-planning` | **4.90 M points**, 3.8 cm spacing |

**The survey supplies 133 M points and the vehicle uses 4.9 M**, a 27-fold
reduction. The deployed 3.8 cm spacing already sits at the good end of the
density sweep, so COSS is not over-downsampled -- but the headroom is there, and
the same vendor pipeline for a future site can clearly deliver whatever density
is asked for.

## What is needed

Two answers, either of which unblocks work that is otherwise ready to run:

- **Which point cloud map pairs with these recordings**, or which transform
  relates them.
- **A recording where the vehicle moves.** Everything in the campaign that
  matters -- the bias term, deskew, the prior chain -- needs motion. Other
  candidates on the NAS include `2024-11-26-CoSS-Sensor-data-collection`.

The tooling is in place: `scripts/localization/restricted_fov/` will run the
comparison as soon as a map and a moving bag are paired.
