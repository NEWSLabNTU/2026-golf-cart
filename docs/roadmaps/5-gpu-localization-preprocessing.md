# Phase 5 — GPU localization preprocessing

Move the three-stage point cloud chain that feeds NDT off the CPU, by adopting
the CUDA node Autoware already ships and writing the two it does not, in
C++/CUDA against the same package and conventions.

Background: [rust-cuda-blackboard-feasibility.md](../research/localization/rust-cuda-blackboard-feasibility.md),
which is where this phase came from and which explains what it does *not* buy.

Last updated: 2026-08-31. **L0 is done and it closes the gate.** The three
filters cost about 19% of one core. The stop rule written below says stop, so
L1–L4 are not started and should not be without a reason that L0 does not
supply. The measurement and its rig are recorded so the decision can be
revisited on the cart's own sensors.

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

## Work items — not started, gated by L0 above

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
