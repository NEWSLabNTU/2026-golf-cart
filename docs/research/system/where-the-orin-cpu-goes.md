# Where the Orin's CPU actually goes

Analysis of the 2026-08-25 play_launch resource capture
(`play_launch_dds_comparison_2026-08-25.zip` on the NAS, unpacked to
`data/measurements/`, gitignored). Two sessions of the same stack on the master
Orin, 12 cores, R36.4.4, differing only in `--container-mode` and the DDS
profile — the capture that recorded commit d3c711c, "perf(dds): cut CPU load by
collapsing DDS participants".

The archive was taken to prove *that* change. Read for what else it contains, it
says something more useful: **most of the CPU on this machine is not being spent
on the driving stack.** The CUDA work so far has been optimising the part of the
budget that was never the problem.

## The headline number

| | isolated (pre-opt) | observable (post-opt) |
|---|---|---|
| host CPU, average | 89.5% | **73.9%** |
| host CPU, peak | 100% | 98.4% |
| memory used | 8.75 GB of 65.9 GB | 8.66 GB of 65.9 GB |
| swap | 0 | 0 |
| loopback DDS | ~51 Mbit/s each way | ~41 Mbit/s each way |
| GPU columns | empty | empty |

**CPU is the only scarce resource on this machine.** Memory sits at 13% with no
swap; the network is a rounding error. Any optimisation that trades memory for
CPU is free here, and any that trades CPU for memory is a mistake.

Only `system_stats.csv` compares the two runs on equal footing — see the
archive's own README for why the per-process numbers do not. Everything below
uses the **observable** run, where per-process figures are complete.

## Finding 1 — a do-nothing ROS 2 process costs 4.9% of a core

61 sampled processes. 16 are containers holding 84 composable nodes. The other
45 are standalone nodes.

33 of those 45 sit in a band from 4.72% to 5.45% of one core, median **4.88%**,
sustained for the whole run. The band contains nodes with no work to do:

```
empty_objects_publisher        5.17%     goal_pose_visualizer      4.73%
duplicated_node_checker        5.33%     robot_state_publisher     4.73%
service_log_checker_node-1     4.79%     map_projection_loader     4.72%
```

`empty_objects_publisher` publishes an empty message. It costs 4.9% of a core.

This is not a sampling artifact. `cpu_user_secs`, the cumulative counter out of
`/proc`, agrees independently:

```
goal_pose_visualizer     user  25.0s over 534s = 4.68% of one core
empty_objects_publisher  user  27.0s over 534s = 5.06% of one core
rviz2                    user 277.0s over 534s = 51.87% of one core
```

And it is not a transient: sampled every 40 s across the run, the trivial nodes
never leave the band.

**Composed nodes do not pay it.** 84 composable nodes plus all the real
pipeline work — concatenation, planning, control — come to 153.7% total across
16 containers, at most 1.83% per node *including* their work. 45 standalone
nodes come to 312.8%. If the floor were per-node rather than per-process, the
containers alone would have to draw 399%.

So the floor is the cost of *being a separate process*: one CycloneDDS
participant, its seven service threads, and its share of graph maintenance.

### What it is worth

Of the 45 standalone processes, **35 belong to packages that already register
`rclcpp` components** and could be loaded into a container instead. Checked
against `/opt/autoware/1.5.0/share/ament_index/resource_index/rclcpp_components`:

| composable today? | procs | CPU |
|---|---|---|
| yes — package registers components | 35 | 184.4% |
| no | 10 | 128.4% |

The ten that are not: `rviz2`, three `gscam`, `seyond`, our own
`golfcart_vehicle_interface`, `topic_tools relay`, `empty_objects_publisher`,
`robot_state_publisher`, `ublox_gps`.

That check is at package granularity, and one of the 35 fails it on inspection:
`autoware_map_loader` registers `PointCloudMapLoaderNode` and
`Lanelet2MapLoaderNode`, but the process running here is `map_hash_generator`,
which is not among them. Reading the registered class names against the
executables leaves **34** genuinely foldable. Every other package registers a
class matching the executable it is running.

At 4.88% per process, folding those 34 into existing containers releases about
**1.7 of 12 cores — roughly 14 percentage points of host CPU**, and removes
~300 threads.

For scale: that is more than four times what moving the whole point cloud
preprocessing and concatenation stage to CUDA was worth.

### The cost of collecting it

None of the 35 are declared in our launch files. All come from installed
`tier4_*_launch` / `autoware_*` launch packages, which run them as `<node>`
despite shipping the component. Upstream does this to itself:
`tier4_localization_launch` runs `ekf_localizer`, `ndt_scan_matcher`,
`gyro_odometer` and `pose_initializer` as standalone processes, and only
`util.launch.xml` and `lidar_marker_localizer.launch.xml` in that whole package
use a container at all.

Collecting the win therefore means overlaying upstream launch files — and makes
a good upstream contribution in its own right, on the same footing as the CUDA
filter PR: a launch-file change worth 14 points of a 12-core Orin.

`play_launch` cannot do this for us. `--container-mode` only decides how
*already-composable* nodes are hosted; a `<node>` is an executable and stays a
process.

## Finding 2 — the GNSS node respawned 137 times, which taints Finding 1's price

`ublox` reads 0.00% CPU in both runs. It is not idle. It is crash-looping:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  U-Blox: Could not open serial port :/dev/ublox-gps open: No such file or directory
```

The receiver was not plugged in for this capture. That is a property of the
capture, not a defect in the stack, and needs no fix.

It is recorded here because of what it does to the *rest* of the numbers.
Distinct PIDs on the `ublox` row:

| run | spawns | duration | one every |
|---|---|---|---|
| isolated | 56 | 318 s | 5.7 s |
| observable | **137** | 534 s | **3.9 s** |

Each spawn creates a DDS participant, announces it over SPDP to every peer, then
dies and forces a participant-removal in every peer — 274 graph-churn events in
nine minutes, each of which every one of the other 60 processes does work for.

Discovery churn at that rate is exactly the shape that produces a uniform
per-process floor, so **some unknown part of Finding 1's 4.88% may be this
node's fault rather than an inherent per-process cost.** The archive cannot
separate the two. Re-read the floor from any capture taken with the receiver
present before committing large work to Finding 1; the number can only come
down.

## Finding 3 — rviz2 is the single largest consumer

63.86% of a core on average, 102.82% peak, 517 MB. Larger than any container,
larger than the entire sensing pipeline.

It runs because `$DISPLAY` was set: `justfile:270` passes `rviz:=false` only
when there is no display. On a vehicle with a screen attached, the viewer is the
biggest thing on the machine.

The archive's README notes rviz2 averaged 29.3% in the isolated run — it was
*starved* there (loadavg 276 on 12 cores), not cheaper. 63.9% is what it wants.

This is an operating decision rather than a defect, but it should be a deliberate
one: run RViz on the other machine over the DDS link, or default it off on the
master and opt in. Worth about 5 points of host CPU.

## Finding 4 — the Seyond driver throws away 60% of the LiDAR

The stderr volume is what draws the eye:

| process | stderr | lines | rate |
|---|---|---|---|
| `seyond_node-1` | 17.1 MB | 79,708 | 149/s |
| `pointcloud_container` | 2.8 MB | 28,714 | 54/s |

Every line is a formatted string, a write, **and a `/rosout` DDS publish**.
`pointcloud_container`'s share is Autoware's concatenator running at INFO,
printing per-cloud arrival latency and per-collector timing — debug output left
switched on, and free to turn off.

The Seyond half is not a logging problem. 37,701 of its lines are

```
[WARN] stage_client_deliver.cpp:61 drop data in deliver stage.
```

and the SDK prints that once per **ten** drops (`stats_dropped_jobs_ % 10 == 1`).
Its own cumulative counters, on the last line of the run:

```
deliver queue#0  added=628,636  finished=251,406  dropped=377,005  blocked=0
                 active_time=507,917ms / elapsed=535,932ms  ratio=94.77%
```

**60% of everything the driver received never reached ROS.** The drop count is
not a rate that settled — it started at zero (`total_dropped=0` seven seconds in)
and climbed for the whole run, reaching 65% in the final window.

`docs/research/sensing/lidar-pipeline-starvation.md` recorded the same counter
and left it there, reasoning that it "is inside the vendor driver, upstream of
ROS entirely". **That is not correct, and it is why the trail went cold.** The
deliver stage's consume callback is the ROS publish. Following it through the
vendored SDK:

```
StageClientDeliver::process_job_        drops when the queue hands it prefer=false
  -> DriverLidar::lidar_data_callback   per packet
     -> frame_publish_cb_               once per frame, on the same thread
        -> ROSAdapter::publishFrame     pcl -> PointCloud2 -> publish()
```

The deliver stage is a **single worker** (`worker_num = 1`, hardcoded in
`lidar_client.cpp`) and it was **busy 94.77% of the whole run**. `blocked=0`
says it never waited on a downstream queue of its own: it simply could not
finish jobs fast enough, so the producer marked the backlog non-preferred and
`process_job_` freed the buffers instead of parsing them.

Where the time goes is the interesting part. The driver's own per-callback
histogram:

```
callback mean/std/max = 2.10ms / 20.28 / 770.06
convert_xyz    mean/std/max/total = 0.00ms / 0.00 / 0.00 / 0
```

Sphere-to-XYZ conversion never ran — this Falcon sends XYZ directly. The
per-point work left is a coordinate swizzle and a `push_back` into a vector
whose capacity survives `clear()`, which cannot cost 2 ms for the 787 points in
a packet. And a standard deviation ten times the mean, with a **770 ms**
maximum, is not steady cost at all: it is a small number of very long stalls.

The stall has a candidate, and it is one this repo built itself. The driver
publishes:

```cpp
rclcpp::QoS qos(rclcpp::KeepLast(10));
qos.reliable();
inno_frame_pub_ = node_ptr_->create_publisher<sensor_msgs::msg::PointCloud2>(...);
```

190,263,198 points over 3,677 frames is 51,743 points per frame, and
`publishFrame` writes them at `point_step = 16`: **828 kB per message**. Against
that, `config/cyclonedds/*.xml` sets

```xml
<Watermarks><WhcHigh>500kB</WhcHigh></Watermarks>
```

`whc_high` counts *unacknowledged* bytes, and Cyclone blocks the writer above it
— the string is in `libddsc` verbatim:

```
writer %x:%x:%x:%x waiting for whc to shrink below low-water mark (whc %zu low=%u high=%u)
```

A single Seyond frame is 1.6x the high watermark on its own. If the subscriber
is slow to acknowledge — and the concatenator in `pointcloud_container` is busy
enough to be printing 54 log lines a second — `publish()` blocks in the deliver
thread, the queue behind it fills, and the producer starts dropping. That
matches every measured symptom, including the one the earlier document found
puzzling: **giving the machine 15 points of CPU back did not help**, because the
thread is not waiting for CPU, it is waiting for acknowledgements.

This is a hypothesis with strong support, not a proven cause. The stall could
also be allocation, or preemption on a host that peaked at 98%. Three cheap
tests, in order:

1. Turn on Cyclone's throttle trace (`<Tracing><Category>throttle</Category>`)
   and look for the `waiting for whc to shrink` line on the Seyond writer. This
   settles it outright.
2. Publish best-effort, or `KeepLast(1)`, and re-read `total_dropped`. A
   best-effort writer has nothing to wait for.
3. Raise `WhcHigh` past one frame — 4 MB — and re-read the same counter.

None needs the vehicle to move. Note that (3) trades against the reason
`WhcHigh` was left at 500 kB in the first place, so prefer (2) if it holds:
a LiDAR frame is worthless by the time a retransmit would deliver it, and every
other point cloud publisher in the stack is already best-effort.

Whatever the fix, the size of the prize is fixed: NDT currently sees a
concatenated cloud that is missing 60% of one of its two sensors.

## Finding 5 — there is no GPU telemetry, and it is a 30-line script away

Every `gpu_*` column is empty in both sessions. The archive README calls this
"a limitation of the capture". It is narrower than that, and much easier to fix
than it sounds.

`play_launch` reads GPU state through NVML. **NVML does not exist on Jetson:**

```
$ ls /usr/lib/aarch64-linux-gnu/libnvidia-ml*
(nothing)
```

That is not a missing package — there is no NVML on Tegra at all, and no version
of `play_launch` can fill those columns on this board. The consequence is that
**no run record this project has ever taken carries a GPU number.** Every GPU
figure in `docs/roadmaps/5-gpu-localization-preprocessing.md` was read off a
hand-run `tegrastats` beside the stack, which is why they exist for two
deliberate A/B sessions and for nothing else.

But everything wanted is in sysfs, root-free, and it is the same set of rails
`tegrastats` prints:

```
/sys/devices/platform/gpu.0/load              GPU busy, per-mille
/sys/class/devfreq/17000000.gpu/cur_freq      GPU clock, Hz
/sys/class/hwmon/hwmon1/  (ina3221)           VDD_GPU_SOC, VDD_CPU_CV, VIN_SYS_5V0
/sys/class/thermal/thermal_zone*/             per-zone temperature
```

Verified on this board rather than assumed. Idle, then under a CUDA kernel:

```
gpu load=  0.6%   VDD_GPU_SOC= 3987 mW   gpu-thermal=48.0 C
gpu load= 99.8%   VDD_GPU_SOC=19928 mW   gpu-thermal=52.0 C
gpu load= 99.8%   VDD_GPU_SOC=24710 mW   gpu-thermal=52.5 C
```

`scripts/profiling/jetson_gpu_sampler.py` (`just profile gpu`) writes those to
CSV on play_launch's own 2 s cadence, with an ISO-8601 timestamp column in
play_launch's format so the two files join on time. Run it beside a capture and
the GPU columns stop being empty.

That unblocks U0 of the CUDA upstreaming phase
(`docs/roadmaps/5-upstream-cuda-preprocessor.md`), which needs the CUDA chain
timed on the vehicle, and it removes the reason every GPU comparison so far had
to be staged by hand.

## Finding 6 — `play_launch --sched` is available and unused

`play_launch launch --sched <platform.yaml> --target posix --sched-apply warn`
applies SCHED_FIFO/RR priority and CPU affinity per spawned process, validated
offline by `play_launch check --sched`.

Nothing in this repo uses it. With 716 threads on 12 cores and the host at 98%
peak, NDT and control currently compete with 45 processes that have nothing to
do. Affinity alone — pinning the sensing and localization chain away from the
idle crowd — would buy latency stability without removing a single process, and
it is complementary to Finding 1 rather than an alternative to it.

## Ranked

| # | finding | worth | cost |
|---|---|---|---|
| 5 | no GPU telemetry on Jetson | unblocks CUDA U0 | **done** — `just profile gpu` |
| 4 | Seyond drops 60% of its packets | NDT sees a crippled cloud | one QoS line, if the WHC theory holds |
| 1 | compose 34 standalone nodes | ~14 pp host CPU | upstream launch overlays |
| 3 | rviz2 on the vehicle | ~5 pp host CPU | policy |
| 4b | log spam, ~200 lines/s | small | trivial |
| 6 | `--sched` affinity / RT priority | latency, not throughput | a platform YAML |

## Method

`data/measurements/` is gitignored; the NAS holds the archive of record. The
per-process ranking was produced with `scripts/analysis/rank_play_launch.py`
against the observable session. Component registration was checked against the
installed Autoware's `ament_index` rather than assumed from package names.

Two claims here rest on a single capture of one stack configuration and should
be re-measured before large work is committed to them: the size of the per-process
floor (Finding 1, gated on Finding 2), and whether the floor holds at the same
value once the respawn storm is gone.
