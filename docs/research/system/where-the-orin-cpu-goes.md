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

## Finding 2 — the GNSS node respawned 137 times, and may be paying for Finding 1

`ublox` reads 0.00% CPU in both runs. It is not idle. It is crash-looping:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  U-Blox: Could not open serial port :/dev/ublox-gps open: No such file or directory
```

The receiver was not plugged in. Distinct PIDs on the `ublox` row:

| run | spawns | duration | one every |
|---|---|---|---|
| isolated | 56 | 318 s | 5.7 s |
| observable | **137** | 534 s | **3.9 s** |

Each spawn creates a DDS participant, announces it over SPDP to every peer, then
dies and forces a participant-removal in every peer. That is 274 graph-churn
events in nine minutes, and *every one of the other 60 processes does work for
each of them.*

Two consequences.

First, it is a straightforward bug: the node should not be launched when the
device is absent, or should back off instead of respawning at 0.26 Hz.

Second, and more important for Finding 1: **discovery churn at this rate is
exactly the shape that produces a uniform per-process floor.** The floor may be
substantially this node's fault rather than an inherent ROS 2 tax. The archive
cannot separate the two — but the experiment that can is cheap and needs no
vehicle motion:

> Bring the stack up with the ublox node not launched. Re-read the trivial
> nodes' `cpu_user_secs`. If the 4.88% band drops, Finding 1's price tag drops
> with it and the composition work should be re-costed before it is started.

Note the direction of the rate change: the respawn interval got *shorter* after
participants were collapsed (5.7 s → 3.9 s), consistent with each restart cycle
being gated on discovery latency.

**Do this before acting on Finding 1.**

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

## Finding 4 — 200 log lines a second, and one of them reports data loss

| process | stderr | lines | rate |
|---|---|---|---|
| `seyond_node-1` | 17.1 MB | 79,708 | 149/s |
| `pointcloud_container` | 2.8 MB | 28,714 | 54/s |

Every line is a formatted string, a write, **and a `/rosout` DDS publish**.

The `seyond` total breaks down as 37,716 INFO lines of per-frame convert/callback
statistics and — the part that matters —

```
37,701  [WARN] stage_client_deliver.cpp: drop data in deliver stage.
```

**The Seyond driver dropped data ~70 times a second for the entire run.** That
is a correctness finding, not a logging one, and it is invisible unless someone
reads the stderr file. It deserves its own investigation; the pipeline-starvation
research (`docs/research/sensing/lidar-pipeline-starvation.md`) is the place to
start.

`pointcloud_container`'s share is Autoware's concatenator running at INFO,
printing per-cloud arrival latency and per-collector timing. That is debug output
left switched on.

## Finding 5 — there is no GPU telemetry, and there cannot be

Every `gpu_*` column is empty in both sessions. The archive README calls this "a
limitation of the capture". It is worse than that: it is structural.

```
$ ls /usr/lib/aarch64-linux-gnu/libnvidia-ml*
(nothing)
```

`play_launch` samples GPU state through NVML. **NVML does not exist on Jetson.**
`tegrastats` is the only source of `GR3D_FREQ`, `VDD_GPU_SOC` and friends on this
board, and nothing in the capture path reads it.

This blocks U0 of the CUDA upstreaming phase
(`docs/roadmaps/5-upstream-cuda-preprocessor.md`), which needs the CUDA chain
timed on the vehicle. Until a tegrastats sampler exists, every GPU number this
project quotes comes from a hand-run `tegrastats` beside the stack, not from the
run record — which is why the A/B numbers in
`docs/roadmaps/5-gpu-localization-preprocessing.md` had to be gathered by hand.

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

| # | finding | worth | confidence | cost |
|---|---|---|---|---|
| 2 | ublox respawn storm | unknown, gates #1 | certain | trivial |
| 1 | compose 35 standalone nodes | ~14 pp host CPU | high, pending #2 | upstream launch overlays |
| 3 | rviz2 on the vehicle | ~5 pp host CPU | certain | policy |
| 4 | Seyond dropping data at 70/s | correctness | certain | investigation |
| 4b | log spam, ~200 lines/s | small | certain | trivial |
| 5 | no GPU telemetry on Jetson | blocks CUDA U0 | certain | write a tegrastats sampler |
| 6 | `--sched` affinity / RT priority | latency, not throughput | untested | a platform YAML |

## Method

`data/measurements/` is gitignored; the NAS holds the archive of record. The
per-process ranking was produced with `scripts/analysis/rank_play_launch.py`
against the observable session. Component registration was checked against the
installed Autoware's `ament_index` rather than assumed from package names.

Two claims here rest on a single capture of one stack configuration and should
be re-measured before large work is committed to them: the size of the per-process
floor (Finding 1, gated on Finding 2), and whether the floor holds at the same
value once the respawn storm is gone.
