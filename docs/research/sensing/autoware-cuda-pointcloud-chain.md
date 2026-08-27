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
