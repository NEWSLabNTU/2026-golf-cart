# Autoware's CUDA point cloud chain, and why ours cannot join it yet

**Researched**: 2026-08-27, against Autoware universe `main` and `tier4/aip_launcher`,
plus the 1.5.0 (universe 0.48.0) install on this machine.

**Why**: to decide whether the golf cart's LiDAR preprocessing should move to GPU,
after `pointcloud_backend:=cuda` loaded successfully and then produced one cloud
where the CPU path produced 546.

**Answer up front**, and it is not the one the switch was built for:

1. The CUDA concatenator cannot be adopted on its own. Autoware has no mode in
   which CPU preprocessing feeds a CUDA concatenator, and the reason is
   structural, not a tuning gap.
2. The stage that would make it possible, `CudaPointcloudPreprocessorNode`, is
   exactly the stage this repo does not have **in any form, CPU or CUDA**.
3. So the real finding is not about CUDA. **The golf cart runs no per-sensor
   preprocessing at all**: no ego-vehicle crop box, no distortion correction, no
   ring outlier filter. Raw driver clouds go straight into concatenation and on
   to NDT.

Fixing (3) is worth doing on its own merits and happens to be the precondition
for (1).

---

## What Autoware actually builds

`tier4/aip_launcher`'s `aip_x2_gen2_launch/launch/nebula_node_container.launch.py`
is the authoritative implementation. It dispatches on a `pipeline_mode` argument
with four values:

```python
add_launch_arg(
    "pipeline_mode", "cuda",
    choices=["cuda", "cpu", "cuda-all-in-one", "cuda-with-cpu-concat"],
)
```

| mode | per-sensor preprocessing | where it runs |
|---|---|---|
| `cpu` | `make_preprocessor_nodes()`: crop box (self + mirror), distortion corrector, ring outlier filter | per-sensor container |
| `cuda` | `make_cuda_preprocessor_nodes()`: **one** `CudaPointcloudPreprocessorNode` doing all three on GPU | **shared** container |
| `cuda-all-in-one` | same, plus the Nebula driver itself | shared container |
| `cuda-with-cpu-concat` | same CUDA preprocessor | per-sensor container |

Two things follow that matter more than the mode names.

**Every CUDA mode replaces the whole per-sensor chain with a single node.** The
GPU win is not "the concatenator got faster", it is that crop, distortion
correction and outlier filtering stop being three nodes copying a cloud between
each other and become one kernel sequence over one device buffer.

**There is no `cpu-preprocess + cuda-concat` mode.** That combination is the one
`pointcloud_backend:=cuda` creates here, and its absence from the enum is not an
oversight.

## Why that combination cannot work

`CudaPointcloudPreprocessorNode` publishes two topics, not one:

```python
("~/output/pointcloud",      "pointcloud_before_sync"),
("~/output/pointcloud/cuda", "pointcloud_before_sync/cuda"),
```

The second is `negotiated_interfaces/msg/NegotiatedTopicsInfo`. `cuda_blackboard`
works by publishing a normal `sensor_msgs/PointCloud2` alongside a negotiation
topic advertising a `CudaPointCloud2` whose `data` field is a device pointer. A
`CudaBlackboardSubscriber` uses the negotiation topic to discover that the device
buffer exists and to take the pointer instead of the bytes.

The CUDA concatenator's own documentation is explicit that this is the only
difference from the CPU one:

> The only change, corresponds to the pointcloud topics, which instead of using
> the standard `sensor_msgs::msg::PointCloud2` message type, they use the
> `cuda_blackboard` mechanism.

On the golf cart, `pointcloud_before_sync` has no `/cuda` companion, because
nothing upstream is a cuda_blackboard publisher. Negotiation never happens, the
subscriber has no device pointer, and the run produced exactly what that
predicts:

```
transformed_raw_points[/sensing/lidar/top/pointcloud_before_sync] is nullptr,
skipping pointcloud publish.
```

The cuda_blackboard README says a traditional publisher *is* converted for a
CUDA subscriber under the hood, so this is not a flat incompatibility in
principle. It did not happen here, and the two candidate reasons are that the
conversion path needs the negotiation handshake to have taken place at all, and
that the upstream CPU nodes in our container had intra-process comms enabled
(below). Either way the practical conclusion is unchanged: **do not wire a CPU
preprocessing chain into the CUDA concatenator.**

## The intra-process constraint, confirmed twice

`pointcloud_backend:=cuda` originally failed to load at all:

```
Component constructor threw an exception:
intraprocess communication allowed only with volatile durability
```

That is not a golf-cart problem. aip_launcher hits it too, and its fix is to
simply not set the option on that node:

```python
# The whole node can not set use_intra_process due to type negotiation internal topics
# extra_arguments=[{"use_intra_process_comms": LaunchConfiguration("use_intra_process")}],
```

The cuda_blackboard README states the same rule at container scope: all nodes
must be in one process, and `use_intra_process_comms` cannot be true. Note the
tension between those two: cuda_blackboard needs same-process to pass pointers,
but it cannot use rclcpp's own same-process mechanism, because the negotiation
topics are transient_local and rclcpp refuses transient_local with intra-process.
cuda_blackboard is a *replacement* for intra-process transport, not an addition
to it.

Our sensor kits now disable intra-process on the CUDA concatenator specifically,
which is correct and necessary but, per the above, not sufficient.

Worth noting for later: `common_sensor_launch/velodyne_VLS128.launch.xml:33`
hardcodes `use_intra_process` to `true` for the whole Nebula container, so a
CUDA adoption that reuses those stock per-sensor launches has no way to turn it
off without its own copy.

## The finding that actually matters

Autoware's `cpu` mode runs, per sensor, before concatenation:

- crop box against the ego vehicle body, and again against its mirrors
- distortion correction, using IMU and twist
- ring-based outlier filter

The golf cart runs **none of them**. Our concatenator takes the driver topics
directly:

```yaml
input_topics: [
    "/sensing/lidar/falcon/iv_points",
    "/sensing/lidar/vlp32/velodyne_points",
]
```

and the only point cloud nodes that existed in the 2026-08-25 run were
`concatenate_data` plus three nodes under `/localization/util/`
(`crop_box_filter_measurement_range`, `random_downsample_filter`,
`voxel_grid_downsample_filter`). Those are NDT's own input downsampling, not
per-sensor preprocessing. `crop_box_filter_measurement_range` crops to NDT's
working radius; it is not the ego-vehicle crop.

What that costs, in the order I would worry about it:

**No distortion correction.** A 10 Hz spinning LiDAR paints one revolution over
100 ms. At 5 m/s the vehicle moves half a metre during it, so a scan is smeared
by up to that much, and NDT matches a warped cloud against a rigid map. Our
concatenator does set `is_motion_compensated: true`, but that aligns the two
LiDARs' clouds to a common timestamp using twist; it does not undo the
within-revolution smear, which needs the per-point time offsets the
`PointXYZIRCAEDT` layout carries. This is a direct, quantifiable localization
error source, and it is the one to fix first.

**No ego-vehicle crop box.** Points on the cart's own bodywork are rigidly fixed
to the sensor, so they match the map identically at every candidate pose. They
contribute nothing to the gradient but do contribute to the score, which both
biases the solution and inflates NVTL, making the health metric read better than
the localization actually is.

**No ring outlier filter.** Rain, dust and low-intensity returns pass through to
NDT unfiltered.

## What I would do

1. **Add the CPU per-sensor chain first.** Crop box, distortion corrector, ring
   outlier filter, per LiDAR, matching Autoware's `cpu` mode. This is a
   correctness fix for NDT and is independent of any GPU question. It is also
   the only way to find out what our clouds look like once they are clean.
2. **Then reconsider CUDA as a whole-chain swap**, not a concatenator swap:
   replace those three nodes with one `CudaPointcloudPreprocessorNode` and put it
   in the same container as the concatenator, which is what `pipeline_mode:=cuda`
   does. At that point the negotiation topic exists and the CUDA concatenator
   becomes usable.
3. **Do not expect much from step 2 on current numbers.** Concatenation measured
   12.5 ms against a 510 ms pipeline latency, and the whole preprocessing
   container averaged 13.8% of one core out of twelve. Adding the missing stages
   will raise that CPU cost, which is the thing that would change the arithmetic;
   measure after step 1, not before.
4. **Instrument the GPU before betting on it.** Every `gpu_*` column in
   play_launch's `system_stats.csv` is empty and `gpu_monitor` errors, so there
   is currently no way to see what a GPU move costs. On Orin the iGPU shares
   memory bandwidth with the CPU, so it is a trade rather than free capacity.

Note that even TIER IV does not always take the CUDA concatenator: the XX1 Gen2
platform runs CUDA preprocessing with **CPU** concatenation
(`cuda-with-cpu-concat`), keeping the per-sensor containers separate for fault
isolation. Concatenating on the GPU requires every producer in one process, and
that trades fault tolerance for latency.

## Sources

- [autowarefoundation/cuda_blackboard](https://github.com/autowarefoundation/cuda_blackboard)
- [tier4/aip_launcher `aip_x2_gen2_launch/launch/nebula_node_container.launch.py`](https://github.com/tier4/aip_launcher/blob/main/aip_x2_gen2_launch/launch/nebula_node_container.launch.py)
- [Nebula-Based LiDAR Pipeline, DeepWiki](https://deepwiki.com/tier4/aip_launcher/3.2-nebula-based-lidar-pipeline)
- [`autoware_cuda_pointcloud_preprocessor` docs](https://autowarefoundation.github.io/autoware_universe/main/sensing/autoware_cuda_pointcloud_preprocessor/)
  and its `docs/cuda-concatenate-data.md`, `docs/cuda-pointcloud-preprocessor.md`
- [Point cloud pre-processing design, Autoware Documentation](https://autowarefoundation.github.io/autoware-documentation/main/design/autoware-architecture/sensing/data-types/point-cloud/)
- [Discussion #5396, type adaptation and negotiation for the CUDA pipeline](https://github.com/orgs/autowarefoundation/discussions/5396)

---

# Addendum: can every stage move to CUDA?

**Asked 2026-08-27**: move all stages to GPU including the Nebula Velodyne
driver, accepting that the Seyond driver stays on CPU.

Short answer: **the driver cannot, and the Seyond half of the pipeline cannot
either, for a reason that has nothing to do with CUDA.** What can move is the
Velodyne preprocessing plus concatenation and downsampling. The ceiling on the
whole exercise is 2.6% of this machine.

## Stage by stage

| Stage | CUDA implementation | Available to us? |
|---|---|---|
| Velodyne decode (Nebula) | none | **No.** See below |
| Seyond decode | none (vendor CPU driver) | No, as accepted |
| Per-sensor crop / distortion / ring outlier | `CudaPointcloudPreprocessorNode` | **Velodyne only.** Seyond blocked, see below |
| Concatenation | `CudaPointCloudConcatenateDataSynchronizerComponent` | Yes, once at least one input is a cuda_blackboard publisher |
| Voxel grid downsample | `CudaVoxelGridDownsampleFilterNode` | Yes |
| Polar voxel outlier | `CudaPolarVoxelOutlierFilterNode` | Yes |
| NDT | `cuda_ndt_matcher` (ours) | Already exists |

## Blocker 1: there is no CUDA Velodyne decoder

Nebula has exactly one CUDA decode effort, [PR #421 `feat(hesai): add
CUDA-accelerated point cloud decoder`](https://github.com/tier4/nebula/pull/421):

- **Hesai only**, validated on Pandar128E4X. Nothing for Velodyne.
- **Open since 2026-03-19, last touched 2026-04-20**, not merged.
- Opt-in twice: `-DBUILD_CUDA=ON` at build, `NEBULA_USE_CUDA=1` at runtime.

Its own measurements are the argument against waiting for it. On an RTX 5080
with ~72k points per scan:

| | median | P5 | P95 |
|---|---|---|---|
| CPU | 6.80 ms | 6.62 ms | 7.28 ms |
| GPU (PR #421) | **2.48 ms** | 2.41 ms | **12.77 ms** |

The median improves 2.8x and the **P95 gets worse**, because the distribution is
bimodal: 43% of scans hit a slow path dominated by the bulk device-to-host copy
of the output buffer. The PR says a follow-up will remove that copy by keeping
points on the GPU via cuda_blackboard. **That follow-up does not exist yet**: a
search of the repository's issues and PRs finds no zero-copy successor.

So even for Hesai, today, the merged-someday version trades a better median for a
worse tail. For a localization pipeline the tail is what sets the deadline.

Also note that aip_launcher's `cuda-all-in-one` mode does *not* mean a CUDA
driver. `make_nebula_node(context, as_composable_node)`'s second argument is a
placement flag, and the node it builds is the ordinary `nebula_ros`
`<Make>RosWrapper` publishing a plain `PointCloud2`. "All in one" means the
driver joins the shared *container*, not that it decodes on the GPU.

**This is not a blocker for the rest of the chain.** `pipeline_mode:=cuda` runs a
CPU Nebula driver into a CUDA preprocessor today; the upload happens at the
preprocessor's input. A CPU driver does not prevent GPU preprocessing.

## Blocker 2: Seyond cannot enter the CUDA preprocessor at all

This is the more serious one, and it is a data-layout problem rather than a GPU
one.

`CudaPointcloudPreprocessorNode` states its input contract plainly:

> This node expects that the input pointcloud follows the
> `autoware::point_types::PointXYZIRCAEDT` layout and the output pointcloud will
> use the `autoware::point_types::PointXYZIRC` layout.

`PointXYZIRCAEDT` carries, beyond XYZ and intensity, four fields the CPU chain
also needs: `azimuth`, `elevation`, `distance`, `time_stamp`.

**Velodyne is fine.** Nebula's native `velodyne_points` is what Autoware renames
to `pointcloud_raw_ex` (`nebula_node_container.launch.py:145`), and the `_ex`
suffix is precisely this extended layout. Our
`/sensing/lidar/vlp32/velodyne_points` is already the right type.

**Seyond is not.** `seyond_ros_driver/.../driver/point_xyzirc.h` registers:

```cpp
POINT_CLOUD_REGISTER_POINT_STRUCT(
    seyond::PointXYZIRC,
    (float, x, x)(float, y, y)(float, z, z)
    (std::uint8_t, intensity, I)
    (std::uint8_t, return_type, R)
    (std::uint16_t, ring, C))
```

That is `PointXYZIRC`: **no azimuth, no elevation, no distance, and no
per-point time**. Consequences, in order:

1. It cannot be fed to `CudaPointcloudPreprocessorNode`, so the Seyond branch
   cannot be GPU-preprocessed no matter what we do to the driver.
2. More importantly, and independent of CUDA, **the Seyond cloud can never be
   distortion-corrected**, by CPU or GPU. Distortion correction needs a per-point
   time offset to know where the vehicle was when each point was measured, and
   that field does not exist in this message. Fixing this means changing the
   driver to emit `PointXYZIRCAEDT`.

There is a third, separate discrepancy in the same file. The field *names* are
`I`, `R`, `C`, while Autoware's `PointXYZIRC` registers `intensity`,
`return_type`, `channel` (`autoware/point_types/types.hpp:171`). The header's
comment claims "Field names match Autoware's expected format: x, y, z, I, R, C",
and that claim is wrong. Whether anything downstream currently reads those fields
by name is unverified; it is worth checking with `ros2 topic echo --field` on a
live Seyond cloud before assuming it is harmless.

## What is achievable, and what it is worth

Achievable today, with no upstream work:

```
Velodyne (CPU decode, PointXYZIRCAEDT)
    -> CudaPointcloudPreprocessorNode        [GPU: crop + distortion + outlier]
    -> pointcloud_before_sync{,/cuda}
                                              \
                                               -> CudaPointCloudConcatenate...  [GPU]
                                              /      -> CudaVoxelGridDownsample [GPU]
Seyond (CPU decode, PointXYZIRC)  -----------/            -> NDT
    (plain PointCloud2, uploaded at the concatenator)
```

The concatenator can take one negotiated CUDA input beside one plain input;
cuda_blackboard converts the latter. All of it must sit in one container with
intra-process comms off.

The payoff ceiling, from the 2026-08-25 bundle:

| process | CPU, share of one core |
|---|---|
| `velodyne_ros_wrapper_node` | 6.75% |
| `seyond_node-1` | 10.48% |
| `pointcloud_container` (concat + NDT downsampling) | 13.76% |
| **total** | **30.99% of one core = 2.6% of a 12-core machine** |

Moving *everything* in that table to the GPU, including the driver decode that is
not possible, would return 2.6% of the machine, which currently sits at 74% with
26% headroom. The GPU is also uninstrumented here, so the cost side of that trade
cannot be measured at all yet.

## Recommendation

Unchanged in order, sharpened in content:

1. **Add the missing preprocessing for Velodyne**, and do it as
   `CudaPointcloudPreprocessorNode` directly rather than building the CPU chain
   first. The Velodyne already has the right point type, this is the stage the
   pipeline is missing, and it is the stage that unlocks the CUDA concatenator.
   Do it for the correctness win, not the throughput one.
2. **Fix the Seyond point type** to `PointXYZIRCAEDT` in the driver. Until then
   that branch cannot be distortion-corrected by any means, which is a
   localization accuracy problem today, not a GPU problem. Check the `I`/`R`/`C`
   field naming at the same time.
3. **Do not wait on Nebula CUDA decode.** Velodyne is not implemented, the Hesai
   PR is unmerged and stale, and its current form worsens P95.
4. **Instrument the GPU before step 1 lands**, so the before/after is measurable.

---

# Addendum: measured against NDT, 2026-08-29

Everything above scores the pipeline on clouds. This is the first measurement
that scores it on **localization**, which is what the pipeline exists for.

`just ntu-test`, CSIE-1 merged bag, scored with
`scripts/localization/ndt_quality_report.py` over 120 s. That script ranks on
pose quality and deliberately does **not** rank on NVTL, because NVTL rises with
coarser voxels and tighter crops whether or not the pose improves. NVTL is
reported below only because it appears earlier in this session's notes.

| | poses | path | scatter p50 / p95 | yaw step p50 / p95 | NVTL p50 |
|---|---|---|---|---|---|
| `pointcloud_backend:=cpu` | 4798 | 647.3 m | 0.001 / **0.038** m | 0.017 / **0.179** deg | 1.24 |
| `pointcloud_backend:=cuda` | 4771 | 604.1 m | 0.001 / **0.035** m | 0.015 / **0.167** deg | 1.21 |

**The two backends localize equivalently.** CUDA is marginally ahead on both p95
figures, but the runs covered different distances (647 m against 604 m) so they
sampled different stretches of the route, which is enough to account for a
difference that size. Read this as "no regression", not as "CUDA is better".

Both runs loaded what they claimed to: the CUDA run's container log shows
`CudaPointcloudPreprocessorNode` and
`CudaPointCloudConcatenateDataSynchronizerComponent`.

**What this validates.** The per-sensor preprocessing chain added on 2026-08-27
runs a full NDT replay without breaking localization, in both modes. Until now
every measurement in this campaign had been resolution, build success or cloud
counts.

**What it does not.** Still a desktop with a discrete RTX 3090, not the Orin,
so the GPU cost side remains unmeasured. And scatter of 1 mm at p50 against a
smoothed path is a self-consistency measure, not accuracy against ground truth;
it catches jitter and slip, not a systematically wrong pose.

One caveat on the numbers above. The CSIE-1 bag is **stationary for its first
90 seconds**, and a report taken there returns 1.5 m of path with scatter and
yaw step of exactly 0.000, which looks like a flawless result and means
nothing. Both rows here were taken after that.
