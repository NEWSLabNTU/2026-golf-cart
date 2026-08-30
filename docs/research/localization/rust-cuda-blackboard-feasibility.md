# A Rust cuda_blackboard: what it would take, and why it is not the lever

**Written**: 2026-08-31, after profiling `cuda_ndt_matcher` on an AGX Orin.
**Question asked**: could the Rust NDT node consume GPU-resident point clouds by
reimplementing `cuda_blackboard` in Rust, reusing existing work?

**Answer**: reimplementing it in Rust does not help, because the thing being
reimplemented is not a transport. And on the current graph the prize is zero,
because three CPU filters sit between the CUDA producer and the NDT node.

---

## What cuda_blackboard actually is

Not a transport. A **process-local singleton**:

```cpp
// /opt/autoware/1.5.0/include/cuda_blackboard/cuda_blackboard.hpp
template <typename T> class CudaBlackboard {
  static CudaBlackboard & getInstance();
  uint64_t registerData(const std::string & producer_name,
                        std::unique_ptr<const T> value, std::size_t tickets);
  std::shared_ptr<const T> queryData(uint64_t instance_id);
 private:
  std::unordered_map<uint64_t, CudaBlackboardDataWrapperPtr> instance_id_to_data_map_;
  std::mutex mutex_;
};
```

The payload is a raw device pointer owned by the producer's CUDA context:

```cpp
class CudaPointCloud2 : public sensor_msgs::msg::PointCloud2 {
  CudaUniquePtr<std::uint8_t[]> data;   // device memory
};
```

What crosses ROS is only a `std_msgs::msg::UInt64` **instance id**, plus a
`negotiated::NegotiatedSubscription` to agree on the type. The subscriber takes
that id and looks the pointer up in *its own process's* map.

So the mechanism is: publish an integer, look up a pointer locally. **Publisher
and subscriber must be in the same process.** A second implementation, in any
language, is a second map — it would never see the producer's entry.

That reframes the task. Reaching this data is not "reimplement in Rust", it is
"be inside that process, and call that C++ singleton".

## What would actually be required

All four, not any one:

| # | requirement | state |
|---|---|---|
| 1 | The Rust node runs **in the producer's process** | **Blocked.** rclrs 0.7.0 has no component support — no `rclcpp_components`, `LoadNode` or component registration anywhere in its source. A standalone process cannot participate. |
| 2 | The `negotiated` protocol, in Rust | Not started. No crate exists (`negotiated`, `ros2-negotiated`, `cuda_blackboard` are all absent from crates.io). Would be written against `negotiated_interfaces`. |
| 3 | Access to the **C++** singleton | FFI, not reimplementation. `libcuda_blackboard.so` exposes C++ templates over `std::shared_ptr`, `std::string` and `std::unordered_map` — no C ABI. Needs a hand-written C shim compiled with the C++ toolchain. |
| 4 | A GPU-resident cloud actually arriving at NDT | **Absent today.** See below. |

Item 1 is the expensive one and it is upstream work in rclrs, unrelated to CUDA.

## Status of the localization preprocessing chain

Checked against the installed Autoware 1.5.0, since item 4 turns on it.

`tier4_localization_launch/launch/util/util.launch.xml` loads three composable
nodes into `pointcloud_container`, with `use_intra_process=true`:

| stage | today | CUDA equivalent shipped in 1.5.0 |
|---|---|---|
| `CropBoxFilterComponent` (±60 m, base_link) | **CPU** | none standalone. Cropping exists only fused inside `CudaPointcloudPreprocessorNode`, which also does distortion correction and ring-outlier filtering and needs per-point time — not usable here |
| `VoxelGridDownsampleFilterComponent` (0.5 m) | **CPU** | **`CudaVoxelGridDownsampleFilterNode` — shipped, blackboard-native, and unused** |
| `RandomDownsampleFilterComponent` (`sample_num: 5000`) | **CPU** | none |

So one of the three has a drop-in, and it is the middle one.

Two things follow, and they are the reason this is not a quick win:

**A partial conversion costs more than it saves.**
`CudaVoxelGridDownsampleFilterNode` is blackboard-native — `CudaPointCloud2` on
both its input and its output. Inserting it between the CPU crop box and the CPU
random downsample would add a host→device transfer at its input and a
device→host at its output, two transfers to replace one CPU filter.

**The missing piece is at the end, which is the worst place for it.**
`RandomDownsampleFilterComponent` has no CUDA version, and it is the last stage.
Whatever precedes it, the cloud must come back to the host for it to run. It is
also why `cuda_ndt` always receives exactly 5000 points.

Converting this chain therefore means writing a CUDA random downsample (or
dropping that stage and getting the point budget from the voxel size instead),
plus a standalone CUDA crop box. Neither exists upstream today.

Note also that the three CPU stages already pass shared pointers between
themselves via intra-process comms. The only serialisation on this path is the
final hop out of the container into `cuda_ndt`'s own process — which is the
1.56 ms decode, and the only part transport work could remove.

## Item 4 is why the prize is currently zero

`cuda_ndt_matcher` subscribes to `/localization/util/downsample/pointcloud`. The
chain feeding it is Autoware's localization preprocessing — crop box, voxel grid
downsample, random downsample — all **CPU** `autoware_pointcloud_preprocessor`
nodes. That is why the node receives a constant ~5000 points.

```
CUDA concatenator (GPU)
      -> [ crop_box -> voxel_grid_downsample -> random_downsample ]   CPU
      -> /localization/util/downsample/pointcloud
      -> cuda_ndt_matcher
```

The cloud is already host-side, and already small, before NDT ever sees it. Even
a perfect GPU-resident subscription in the NDT node saves nothing until that
whole chain is GPU-native too. `pointcloud_backend:=cuda` covers the *sensing*
preprocessing, not this one.

## The prize, measured

From the callback profiling on the same hardware:

| | per scan |
|---|---|
| decode of the received `PointCloud2` | 1.56 ms |
| host→device upload of the source points | 1.58 ms |
| **total addressable** | **~3.1 ms** |
| the callback it sits in | ~48 ms |

So roughly 6% of the callback, and on CPU about 1.5–3% at 10 Hz. There is also
an unmeasured DDS serialise/deserialise cost outside the callback, real but not
large enough to change the order of magnitude.

Note also that 1.56 ms is **not** decode arithmetic. The decode loop itself
benchmarks at 0.034 ms per 5000-point cloud; the rest is first touch of a freshly
received 160 KB buffer. Zero-copy is the only thing that removes it — but it is
3 ms, not 30.

## If someone still wants cross-process GPU handoff

`cuda_blackboard` cannot do it, by design. The mechanism that can is **CUDA IPC**:
the producer exports a `cudaIpcMemHandle_t`, publishes it on a normal topic, and
the consumer imports it. `cudarc` already carries the raw bindings
(`cuIpcGetMemHandle`, `cuIpcOpenMemHandle_v2` in `driver::sys`), though with no
safe wrapper.

That avoids items 1–3 entirely. It costs instead:

- a change to the **C++ producer** to publish handles, which is upstream Autoware
- same-device and lifetime constraints, and a non-trivial per-open cost
- item 4 regardless — the CPU filter chain still stands in the way

## Recommendation

Do not build a Rust `cuda_blackboard`. It reimplements the wrong half: the map is
process-local, so the copy that matters is the C++ one, and reaching it is an
rclrs component-support problem rather than a CUDA one.

If the goal is the NDT node's CPU, the ordering by return on effort is:

1. **Already done.** Removing redundant scoring passes and the dead filter, and
   making the aligned-scan overlay lazy, took the node from 40.0% of a core to
   11.0% — roughly ten times what zero-copy could offer, for a fraction of the
   work.
2. **Make the localization preprocessing chain GPU-native** (item 4). This is
   the prerequisite for any of the rest and needs no Rust work — but it is not
   free either: one of its three stages has a shipped CUDA node, and the other
   two would have to be written, including the last stage in the chain. Scope it
   before starting; a partial conversion is worse than none.
3. Only then is transport worth revisiting — and CUDA IPC, not a Rust blackboard.
