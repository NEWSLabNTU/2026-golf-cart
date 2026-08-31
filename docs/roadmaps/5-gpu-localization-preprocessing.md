# Phase 5 — GPU localization preprocessing

Move the three-stage point cloud chain that feeds NDT off the CPU, by adopting
the CUDA node Autoware already ships and writing the two it does not, in
C++/CUDA against the same package and conventions.

Background: [rust-cuda-blackboard-feasibility.md](../research/localization/rust-cuda-blackboard-feasibility.md),
which is where this phase came from and which explains what it does *not* buy.

Last updated: 2026-08-31. **L0 measured ~19% of a core, which closes the gate
this document set. L1–L4 were then built anyway, on an explicit call**: the
number cannot be checked on the cart's own sensors from here, and the switch is
what makes that check possible. Everything below is implemented, tested and
defaulted to `cpu`, so the CUDA path costs nothing until someone asks for it.

**Status: L1–L4 done.** `golfcart_cuda_preprocessor` provides the two filters
Autoware does not ship; `localization_pointcloud_backend:=cuda` selects the GPU
chain. 37 tests pass. What has *not* happened is the measurement that justifies
using it — see *What is still open* at the end.

---

## Why now

`pointcloud_backend:=cuda` moved the *sensing* preprocessing to the GPU and is
measured. The *localization* preprocessing was never touched, and it is a
separate chain that still runs entirely on the CPU:

```
tier4_localization_launch/launch/util/util.launch.xml
  -> CropBoxFilterComponent            (±60 m about base_link)   CPU
  -> VoxelGridDownsampleFilterComponent (0.5 m voxels)           CPU
  -> RandomDownsampleFilterComponent    (sample_num: 5000)       CPU
  -> /localization/util/downsample/pointcloud
  -> ndt_scan_matcher
```

All three are composable nodes in `pointcloud_container` with
`use_intra_process=true`, so they hand each other shared pointers. That is worth
knowing before optimising: there is no serialisation *between* them.

## L0 — measure the chain, and decide whether to continue

**This gates everything below, and it has never been done.**

Nobody has measured what these three filters cost. The available number is
`pointcloud_container` at 127.8% CPU (cpu backend) against 104.8% (cuda
backend) — but that container also holds CenterPoint, ground filtering,
clustering and the occupancy grid, so it says nothing about these three stages
in particular.

Do this first, with the guard that
[the Orin measurement notes](../handover/2026-08-30-cuda-ndt-on-orin.md)
describe: refuse to start beside a live stack, wait for the load average to
fall, and check the recorded path length before trusting any figure.

**Acceptance**: a per-stage CPU figure for crop box, voxel grid and random
downsample, taken on the Orin with the stack otherwise idle, on a bag where the
vehicle actually moves.

**Decision rule**: if the three together are under about 20% of a core, stop.
The rest of this phase is several weeks of CUDA work, and the alternative uses
of that time are better. Write the number into this document either way.

### L0 result — 2026-08-31, and it says stop

Measured on the Orin by loading the same three components, with this repo's own
parameter files, into a dedicated `component_container_mt` that holds nothing
else, alongside a normal `pointcloud_backend:=cuda` replay of Autoware's sample
bag. A container with only these three in it attributes exactly, which
`pointcloud_container` cannot — it also carries CenterPoint, ground filtering,
clustering and the occupancy grid.

| | |
|---|---|
| container total, two runs | 19.7%, 22.5% of one core |
| — of which worker threads | 15.9%, 18.8% |
| — of which DDS receive (`recvMC`) | 3.8%, 3.7% |
| clouds through each stage | 369, 369, 369 |
| crop box, self-reported `debug/processing_time_ms` | 1.906 ms mean, 1.863 p50, 7.184 p95 |

**Call it ~19% of one core.** The `recvMC` share is an artefact of the rig: the
isolated chain receives its input over DDS, while the real chain gets it
intra-process from the concatenator in the same container. So 22.5% is an upper
bound and ~18.8% is the closer figure.

**That is under the stop rule, and the wider context makes it weaker still.**
19% of one core is 1.6% of this 12-core machine, and the system was not
CPU-bound when it was measured — 73% across all cores. Converting the chain
would not even recover all of it: the GPU version still pays kernel launches and,
until the whole chain converts, transfers.

For comparison, four structural fixes to `cuda_ndt_matcher` in the same session
took that node from 40.0% of a core to 11.0% — about 1.5 cores' worth of the
same currency, for a fraction of the effort, and with no new CUDA code on a
safety-relevant path.

**Reasons this could still be worth doing**, none of which L0 supplies:

- The cart's sensors are not this bag. One VLP-32C plus a Seyond, at a different
  point count, could move the number. Re-run the rig on vehicle data before
  concluding for the vehicle.
- If the Orin becomes CPU-bound for another reason, 0.19 cores stops being
  noise. It is not today.
- If the chain has to become blackboard-native anyway to serve something else,
  this work comes along with it rather than being justified on its own.

The rig is reusable: an isolated container launch plus per-thread sampling of
its process. It is the right way to re-answer this on the vehicle.

## What already exists, and what does not

Checked against the installed Autoware 1.5.0:

| stage | CUDA equivalent | state |
|---|---|---|
| crop box | none standalone | must be written |
| voxel grid downsample | `autoware::cuda_pointcloud_preprocessor::CudaVoxelGridDownsampleFilterNode` | **ships, unused** |
| random downsample | none | must be written, or the stage eliminated |

The cropping that does exist on the GPU is fused inside
`CudaPointcloudPreprocessorNode` together with distortion correction and
ring-outlier filtering, and it needs a per-point time field. It is not reusable
as a standalone crop.

**The order matters more than the count.** The stage with no CUDA version is the
*last* one, so today the cloud must return to the host whatever precedes it.
That is also why `ndt_scan_matcher` always receives exactly 5000 points.

**A partial conversion is worse than none.**
`CudaVoxelGridDownsampleFilterNode` is blackboard-native — `CudaPointCloud2` on
both its input and output. Dropping it in between the two CPU filters adds a
host→device transfer at its input and a device→host at its output: two transfers
to replace one CPU stage. Either the chain converts end to end or it does not
convert.

## Work items — all done

### L1 — CUDA crop box

A standalone component doing what `CropBoxFilterComponent` does — keep points
inside an axis-aligned box in a named frame, with `negative` to invert — reading
and writing `cuda_blackboard::CudaPointCloud2`.

Follow the package that already holds the CUDA nodes rather than starting a new
one: `autoware_cuda_pointcloud_preprocessor`, `ament_cmake_auto` +
`autoware_cmake`, namespace `autoware::cuda_pointcloud_preprocessor`, registered
through `rclcpp_components_register_node`, parameters in
`config/<node>.param.yaml` with a matching `schema/*.json`, launch in
`launch/<node>.launch.xml`. `CudaVoxelGridDownsampleFilterNode` is the model to
copy; its interface is `~/input/pointcloud`, `~/output/pointcloud`, and
parameters `voxel_size_{x,y,z}` plus `max_mem_pool_size_in_byte`.

**Acceptance**: identical output to the CPU crop box on a recorded cloud, point
for point, for the same parameters — not a visual check.

### L2 — CUDA random downsample, or remove the stage

`RandomDownsampleFilterComponent` takes `sample_num: 5000`. Two routes, and the
second is worth considering seriously before writing any CUDA:

- **Write it.** A GPU random sample to a fixed count. Note that "random" makes
  bit-exact comparison against the CPU version impossible, so acceptance has to
  be distributional, not point-for-point.
- **Delete it.** Its only job is capping the point count. The voxel grid stage
  ahead of it can produce a similar budget by raising `voxel_size` — which is
  deterministic, cheaper, and removes a stage instead of porting one. This
  changes which points NDT sees, so it needs the localization quality check
  below, but if it holds it is strictly the better outcome.

**Acceptance**: NDT quality unchanged — NVTL, and trajectory RMSE against the
current chain over a bag where the vehicle moves. The thresholds already in use
are NVTL ~3.14 and RMSE ~3 cm against Autoware's NDT.

### L3 — adopt the shipped voxel filter

Only meaningful once L1 and L2 exist. Swap
`VoxelGridDownsampleFilterComponent` for `CudaVoxelGridDownsampleFilterNode` and
wire the three CUDA stages blackboard-to-blackboard.

Note the shipped defaults are `0.3/0.3/0.1`, while this repo runs `0.5/0.5/0.5`
(`cuda_ndt_matcher_launch/config/pointcloud_preprocessor/voxel_grid_filter.param.yaml`).
Carry the repo's values across; do not inherit the package defaults.

**Acceptance**: `/localization/util/downsample/pointcloud` still published, point
counts in the same range, and NDT quality unchanged by the same measure as L2.

### L4 — a launch switch, matching the one that already exists

The sensing chain is selected by `pointcloud_backend:=cpu|cuda`, whole-stage,
with the two halves refusing to mix. Do the same here rather than inventing a
second idiom, and keep CPU reachable: this chain feeds localization, and a GPU
regression must be revertible from the command line.

## What was built

`src/sensing/golfcart_cuda_preprocessor`, following the conventions of
`autoware_cuda_pointcloud_preprocessor` (which was fetched to
`~/repos/autoware_universe_ref` as the reference the earlier draft asked for):

| | |
|---|---|
| `CudaCropBoxFilterNode` | L1. Axis-aligned crop, inclusive bounds, `negative` to invert. Drops non-finite points in **both** polarities — a NaN compares false against every bound, so a naive `negative` would keep it. |
| `CudaRandomDownsampleFilterNode` | L2. Exact `sample_num` by random-key sort, not thresholding: thresholding gives a binomial count around the target, and the CPU component promises *at most* `sample_num`. Output preserves input order; the seed is a call counter, so a replay is reproducible. |
| `CudaVoxelGridDownsampleFilterNode` | L3. Autoware's, adopted unchanged, with this repo's 0.5 m voxel parameters rather than the package's 0.3/0.3/0.1 defaults. |
| `localization_pointcloud_backend` | L4. `cpu` (default) or `cuda`, whole-stage. |

Both new nodes read and write `cuda_blackboard::CudaPointCloud2`, so the three
chain GPU-resident. The blackboard publisher also carries a plain `PointCloud2`
on a compatible topic, which is how the chain still feeds `cuda_ndt_matcher` —
an rclrs node that cannot read the blackboard — without any change to it.

**Verified**: 37 tests, 0 failures (12 GPU gtest cases plus copyright, cppcheck,
lint_cmake, xmllint). The gtest cases cover inclusive bounds on all six faces and
at the corners, NaN and ±inf in both polarities, byte-exact whole-point survival
including padding, exact output counts, order preservation, distinct subsets
across calls, empty input, and unreadable layouts. They skip rather than fail
where there is no GPU. End to end on the Orin over Autoware's sample bag, both
branches publish `/localization/util/downsample/pointcloud` at the same rate
(388 clouds cpu, 398 cuda) with point counts in the same range (mean 1193 against
1254, both capped at 2000).

## What is still open

**The measurement that would justify turning it on.** L0 said ~19% of a core on
*this* bag and *this* sensor set. The reason to build anyway was that the cart's
VLP-32C plus Seyond may produce a materially larger cloud than the sample's
119k points at the crop box, and the chain scales roughly with input points.
Nobody has recorded the cart's concatenated point count.

So the next step is not more code. It is: record
`/sensing/lidar/concatenated/pointcloud` on the vehicle, read `width × height`,
re-run the L0 rig, and then compare `localization_pointcloud_backend:=cpu`
against `:=cuda` on vehicle data. If the cloud is around 120k like the sample,
leave the default alone.

### Measured, 2026-08-31: the CUDA chain neither helps nor hurts here

Full-pipeline A/B on the Orin, Autoware's sample bag, `pose_source:=cuda_ndt`
held constant in every arm so the matcher is not a variable, and the NDT input
verified at 5000 points in every arm so the work is equal.

| | sensing cpu<br/>localization cpu | sensing cuda<br/>localization **cpu** | sensing cuda<br/>localization **cuda** |
|---|---|---|---|
| system CPU, 12-core mean | 67.1% | 62.9% | **60.6%** |
| GPU `GR3D_FREQ` | 46.7% | 52.5% | 53.6% |
| `VDD_CPU_CV` | 8204 mW | 7408 mW | 6934 mW |
| `VDD_GPU_SOC` | 6550 mW | 7393 mW | 7226 mW |
| NDT `exe_time_ms` | 48.9 | 27.1 | 28.3 |
| NVTL | **2.124** | 3.108 | 3.106 |
| poses published | **70** of 192 | 198 | 193 |
| path | 137.2 m | 127.7 m | 127.6 m |

**Read the middle two columns against each other — that is this phase.** Holding
sensing on CUDA and swapping only the localization chain moves system CPU 62.9%
to 60.6%, about 2 points of twelve cores, with NVTL and `exe_time` identical to
three digits. So the CUDA chain is *equivalent in quality* and its cost saving is
at the edge of what this measurement resolves.

That is exactly what L0 predicted. 19% of one core is 1.6% of this machine, and
a 2-point move across a 60% baseline is not distinguishable from run-to-run
drift. **Nothing here argues for changing the default**, and nothing argues the
work was wrong either — it argues the question has to be asked on a sensor set
that produces a bigger cloud.

**What the first column shows is not this phase's doing.** See below.

## A separate finding: `pointcloud_backend:=cpu` degrades `cuda_ndt`

The leftmost column above is not "the CPU pipeline costs more". It is the CPU
*sensing* chain failing to feed `cuda_ndt` usable clouds: NVTL 2.124 against
3.106, only **70 of 192 alignments passing the convergence gate**, and
`exe_time` 48.9 ms against 28.3 — the matcher working harder and still being
rejected.

The middle column isolates it. With sensing on CUDA and localization on CPU,
everything returns to normal (NVTL 3.108, 198 poses). **So the localization chain
is not implicated at all; the CPU sensing chain is.**

Not a cloud-size problem: exactly one cloud out of 290 came in under 4000 points,
so the content differs rather than the count. Distortion correction is the first
place to look — the CPU chain runs `distortion_corrector` as its own component
where the CUDA path fuses deskew into one kernel sequence.

**This contradicts nothing that was previously measured, and that is the trap.**
The existing "cpu and cuda sensing are equivalent" result (0.038 m against
0.035 m scatter) was taken with *Autoware's* NDT on the NTU bag. A run here with
`pose_source:=ndt` and CPU sensing is also healthy — NVTL 3.141, 293 poses. The
degradation appears only in the combination `pointcloud_backend:=cpu` with
`pose_source:=cuda_ndt`, which nothing had exercised before.

Anyone running `use_cuda:=false` while asking for `cuda_ndt` by name would hit
it, and would see a plausible-looking pose stream at a third of the rate rather
than an error.

## Two defects this measurement exposed in the switch — both fixed

`pose_source` and the pointcloud backends are independent choices. The switch did
not honour that.

**It did not reach `pose_source:=ndt` at all.** That path went through
`tier4_localization_launch/launch/localization.launch.xml`, and Autoware includes
the preprocessing chain from inside `pose_twist_estimator.launch.xml` guarded by
`use_ndt_pose`, with no way to substitute it. An installed file cannot be edited,
and loading a second chain beside it would collide on node names and be silently
dropped.

Fixed by routing `pose_source:=ndt` through this repo's existing drop-in,
`cuda_ndt_matcher_launch/launch/autoware_localization.launch.xml`, which launches
the same node set and goes through the `util.launch.xml` that carries the switch.
`yabloc` and `eagleye` still take Autoware's path. Every parameter is passed
explicitly from `loc_config_path`, so this changes which launch file runs and
nothing else.

**And flipping the switch moved the parameters, not just the hardware.** The CUDA
branch read its own files while the CPU branch read the caller's — 2000 points
against 5000 on the `ndt` path, and different crop bounds too. So a measurement
across the switch compared two different amounts of work. That is how the first
attempt at the table above came out meaningless, and why every arm in it holds
`pose_source` fixed.

Fixed by having both branches take the same
`ndt_scan_matcher/pointcloud_preprocessor/*_param_path` the caller passes. That
required the CUDA crop box to declare the two extra keys the CPU component's file
carries: `output_frame`, which it asserts rather than honours since it does not
transform, and `processing_time_threshold_sec`, which it ignores.

Verified with `pose_source:=ndt` on both backends: same point budget (2000
either way), NVTL 3.086 against 3.089, path 125.4 m against 126.5 m. The switch
now changes hardware and nothing else, for either localizer.

## What this phase does not do

**It does not remove the 1.56 ms decode in `ndt_scan_matcher`.** That cost is
the final hop out of `pointcloud_container` into the NDT node's own process.
`cuda_ndt_matcher` is an rclrs node; it cannot join a C++ component container
and cannot read the blackboard, so the chain must still hand it a host-side
`PointCloud2` at the boundary. The reasons are in the feasibility document, and
none of them are affected by this phase.

So the benefit here is **the three filters' own CPU, and nothing else**. That is
exactly what L0 measures, and why L0 gates the phase.

## Honest caveats

- Everything measured so far on this hardware used Autoware's 30 s sample bag,
  three Velodynes, a good GNSS prior, and a stationary opening. The cart's own
  chain is one VLP-32C plus a Seyond. Numbers from that bag set expectations,
  not budgets.
- Two of the three stages are new CUDA code on a safety-relevant path. The
  acceptance criteria above are deliberately "identical output" or "quality
  unchanged" rather than "looks right in RViz", because this chain decides what
  NDT sees.
- The Autoware source for `autoware_cuda_pointcloud_preprocessor` is **not** on
  this machine — only the installed binaries. Fetch the upstream package before
  starting L1; the conventions above were read off the installed artefacts and
  the source is the authority.
- Upstream is moving these filters: `autoware_downsample_filters` now carries
  `RandomDownsampleFilter` and `VoxelGridDownsampleFilter`, while the
  localization launch still uses the older `autoware_pointcloud_preprocessor`
  plugins. Check which package upstream expects new work in before writing it.
