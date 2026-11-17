# Autoware 2.1.0 validation on the workstation (phase 11, step 10)

**Date**: 2026-11-17. **Branch**: `autoware-2.1.0` (4cf62ee and the commit
that adds this file). **Where**: the shared development workstation
(x86_64, RTX 5090), not a cart host. **Roadmap**:
[11-autoware-2.1.0-migration.md](../../roadmaps/11-autoware-2.1.0-migration.md),
step 10.

The question: does the stack run on Autoware 2.1.0, and does it behave like
1.5.0? Every comparison below runs the same check twice, once per version,
with each version's own launch layer:

- **2.1.0**: this branch, `install-2.1.0`.
- **1.5.0**: `install-1.5.0` with `main`'s `golfcart_launch` overlaid
  (origin/main 0ae3bc0, built from a scratch worktree into a scratch install).
  This branch's `golfcart_launch` names 2.1.0 paths and does not start on
  1.5.0 (`Included launch file not found: .../component_map.launch.xml`), so
  `main` is the 1.5.0 baseline.

Both workspaces were rebuilt at c35a393 first. play_launch 0.37.0,
`--container-mode observable`, no web UI, no RViz, scratch domains 87 and 89.
Runs were sequential, never both versions at once.

**The host was busy.** Other users kept the GPU at 95 % (CARLA, two Python
training jobs) and the load average near 50 with the swap full. That moved
timing-sensitive results, and one comparison had to be repeated at half
bag rate; the section says where.

## Summary

| Check | Result |
|---|---|
| Planning simulator, Ming-Da loop (`slow_indoor`) | Same on both: the same legs arrive in the same times (±1 s) with the same speeds. The loop's goal file has a goal both versions refuse. The east-to-start leg sometimes stalls on `path_optimizer` on both versions: 2 of 4 tries on 1.5.0, 1 of 4 on 2.1.0. |
| Planning simulator, NTU r01 | Same on both, to 0.1 s and 0.01 m/s, under the stock preset and under `slow_indoor` |
| `slow_indoor` takes effect over upstream's | Yes. The running values are the preset's on both versions and identical between them |
| `-no-perception` graph on 2.1.0 | Works. The aggregator stays up, the perception subtree is removed, nothing in it gates autonomous, and the MRM is NORMAL |
| cuda_ndt with `publish_loaded_map` | Starts and tracks. cuda_ndt never declares the key, so it is ignored without a word |
| Perception on, 2.1.0, Python parser | CenterPoint and the clustering detector both publish, and the tracker merges them into `/perception/object_recognition/objects`. Found and fixed: the logging sims ran the base CenterPoint model, not tiny (4cf62ee) |
| NTU replay against the 1.5.0 scores | Not possible: the NTU bags are not on this machine |
| Ming-Da replay, 1.5.0 against 2.1.0 (substitute) | Same: pose difference 0.09 cm p95, 0.88 cm max, and the same NVTL distribution |
| 1.5.0 before and after step 9 | Same node, parameter and remap sets for `@mingda-loop` and `@ntu-r01`. The only difference is the link bridge's config path, and `data_path` reaches no node with perception off |

## 1. Planning simulator

`just sim planning`'s command (`play_launch launch golfcart_launch
planning_sim.launch.xml`, arguments from `scripts/launch/args.py --no-rviz`),
Rust parser. AD API driving through `scripts/testing/sim_loop_drive.py` (the
Ming-Da loop as specified) and a small driver doing the same calls (initialize,
clear route, set route, engage, wait for ARRIVED) that also records the
distance driven.

### Startup

| | 2.1.0 | 1.5.0 (`main`) |
|---|---|---|
| Ming-Da: entities | 98 (49 processes, 8 containers, 41 composables), all up in 2.3 s | 118 (33, 15, 70), all up in 2.3 s |
| NTU r01: entities | 98, 48 of 49 processes up | 118, 69 of 70 composables loaded |
| Died | NTU only: `pointcloud_map_loader`, no PCD in `data/ntu-campus-planning/r01` | the same, as a failed composable load |
| MRM | NORMAL / NONE | NORMAL / NONE |

The NTU r01 directory is a planning map with no point cloud. Both versions
lose the loader for the same reason, and planning does not need it:

```
2.1.0  [map.pointcloud_map_loader]: invalid path: ./data/ntu-campus-planning/r01/pointcloud_map.pcd
       what():  PCD metadata file not found: ./data/ntu-campus-planning/r01/pointcloud_map_metadata.yaml
1.5.0  [map.map_container]: Component constructor threw an exception: PCD load failed: ./data/ntu-campus-planning/r01/pointcloud_map.pcd
```

Errors both versions log (simulator noise, not failures):
`costmap_generator`'s `Could not find a connection between 'map' and
'base_link'` before initialization, and on 2.1.0 `vehicle_cmd_gate`'s
`[VehicleCmdFilter] ... limit` lines, which 2.1.0 logs at ERROR.

One 2.1.0-only error, at aggregator start:

```
[system.aggregator]: Mode path not found: 1002 /autoware/modes/autonomous/available
```

2.1.0's aggregator parameters (`use_driving_mode_mappings: true`,
`driving_mode_available` in its `default.param.yaml`) name
`/autoware/modes/autonomous/available`. No graph has that path, not
autoware_launch's own `autoware-main.yaml` and not ours. The aggregator
leaves the autonomous item out of `/system/driving_mode/available`. The
mismatch is upstream's and costs nothing visible here: engaging works.
Before anything starts to read that topic, either the graph gains the unit
or the mapping is overridden.

### Ming-Da loop, `@sim-mingda-loop` (`slow_indoor`)

`sim_loop_drive.py --laps 1`, the loop as specified
(`data/mingda-basement/loop_goals_cw.yaml`):

| leg | 2.1.0 | 1.5.0 |
|---|---|---|
| start → west side | ARRIVED, 0.106 m, 20 s, v max 1.48 / min 1.38 m/s, steer 29.8° | ARRIVED, 0.060 m, 20 s, 1.48 / 1.39, 29.8° |
| → east side | ARRIVED, 0.069 m, 39 s, 1.48 / 0.77, 28.9° | ARRIVED, 0.077 m, 39 s, 1.48 / 0.77, 29.0° |
| → south-east corner (20.53, -0.36, -95.4°) | **REFUSED** | **REFUSED** |

The third goal is refused by both versions, so this is the goal file's
problem, not 2.1.0's:

```
[planning.mission_planning.mission_planner]: Goal's footprint exceeds lane!Goal is not valid! Please check position and angle of goal_pose
FAIL: lap 1 leg 3 (south-east corner): route refused: /api/routing/set_route_points: The planned route is empty.
```

The file's own header lists the third goal as "bottom, s = 77.3, 3 m short of
start" and says "no leg ends in a corner". Its `goals:` list has a
south-east corner goal instead. `sim_loop_drive.check_goal_placement` passes
it, but Autoware's footprint check refuses it. The goal came in with
c91ff3d (the refitted lane) and is on `main` as well.

To drive a full lap anyway, the driver ran start → west → east → start
(the third goal is the start pose):

| run | west (20.1 m) | east (34.6 m) | back to start (21.8 m) | lap |
|---|---|---|---|---|
| 2.1.0 #1 | 19.3 s, 0.08 m | 39.6 s, 0.09 m | 21.3 s, 0.06 m | PASS, 88 s |
| 2.1.0 #2 | 19.4 s, 0.07 m | 39.0 s, 0.07 m | 23.0 s, 0.08 m | PASS, 84 s |
| 2.1.0 #3 | 19.2 s, 0.06 m | 38.9 s, 0.04 m | 20.7 s, 0.05 m | PASS |
| 2.1.0 #4 | 19.5 s, 0.06 m | 38.2 s, 0.07 m | **stopped 5.1 m short** at (16.08, -3.98) | FAIL |
| 1.5.0 #1 | 19.4 s, 0.06 m | 38.9 s, 0.07 m | **stopped 5.07 m short** at (16.04, -3.99) | FAIL |
| 1.5.0 #2 | 19.2 s, 0.05 m | 40.4 s, 0.07 m | **stopped 5.14 m short** at (16.11, -3.95) | FAIL |
| 1.5.0 #3 | 19.7 s, 0.10 m | 40.6 s, 0.10 m | 22.7 s, 0.09 m | PASS, 87 s |
| 1.5.0, that leg alone | | | 20.8 s, 0.04 m | PASS |

Distance driven per leg is the same to 0.1 m on both versions, and the speed
peaks at 1.47 to 1.48 m/s on every leg (the loop's 5 km/h lanes;
`planning_speed_limit` 2.0 in the arg file).

The 1.5.0 stalls: in autonomous, route SET, no velocity factor, and
`path_optimizer` had put a zero-velocity point at (16.1, -3.9) on the bottom
straight, right where the cart stood:

```
/planning/scenario_planning/lane_driving/behavior_planning/path         first zero-velocity point (10.98, -4.26)  [the goal]
/planning/scenario_planning/lane_driving/motion_planning/path_optimizer/trajectory   first zero-velocity point (16.36, -3.84)
/control/trajectory_follower/control_cmd   velocity 0.0, acceleration -3.4
```

That is the "stops the cart outside drivable area" behaviour the goal file
describes for the corner after the east side, which is tighter than the
vehicle model's turning radius. 2.1.0 stalled at the same spot, (16.08,
-3.98), once in four laps; 1.5.0 twice in four. It is a property of the
loop's south-east corner, not of either version.

### NTU r01, `@sim-ntu-r01`

One 263 m route through ten connected lanelets (all 20 km/h), from
(53017.248, 67902.080, -90.9°) to (52847.330, 67850.329, -179.5°). The poses
were picked from the lanelet graph by a scratch script. r01 has no saved
spots in `config/initial_poses/ntu-r01/`.

| preset | | 2.1.0 | 1.5.0 |
|---|---|---|---|
| stock (`@sim-ntu-r01`) | route, engage | accepted, engaged | accepted, engaged |
| | time to ARRIVED | 63.8 s | 63.9 s |
| | distance driven | 219.3 m | 219.3 m |
| | max speed | 4.30 m/s | 4.29 m/s |
| | arrival error | 0.03 m | 0.03 m |
| `planning_preset:=slow_indoor` | time to ARRIVED | 93.9 s | 93.8 s |
| | distance, max speed | 219.3 m, 2.62 m/s | 219.3 m, 2.62 m/s |
| | arrival error | 0.01 m | 0.01 m |

The max speeds are `max_vel` (4.17 stock, 2.5 `slow_indoor`) plus the
simulator's overshoot. The two versions are indistinguishable.

## 2. Deferred runtime checks (step 7)

### The planning preset takes effect

`ros2 param get --no-daemon` against the running planning simulator.
Upstream 2.1.0 values are from `autoware_planning_config`:

| node | parameter | upstream 2.1.0 | 2.1.0, `slow_indoor` | 1.5.0, `slow_indoor` |
|---|---|---|---|---|
| velocity_smoother | `max_vel` | 4.17 | **2.5** | 2.5 |
| behavior_path_planner | `max_vel` | 4.17 | **2.5** | 2.5 |
| motion_velocity_planner | `obstacle_stop.stop_planning.stop_margin` | 5.0 | **3.5** | 3.5 |
| | `...terminal_stop_margin` | 3.0 | **1.5** | 1.5 |
| | `...min_behavior_stop_margin` | 3.0 | **1.5** | 1.5 |
| | `road_user_stop.stop_planning.longitudinal_margin.default_margin` | 5.0 | **3.5** | 3.5 |
| behavior_path_planner | `goal_planner...enable_arc_backward_parking` | true | **false** | false |
| | `goal_planner...enable_freespace_parking` | true | **false** | false |
| | `start_planner.enable_back` | true | **false** | false |
| | `start_planner.freespace_planner.enable_freespace_planner` | true | **false** | false |
| | `dynamic_expansion.ego.extra_width` | 0.0 | **0.1** | 0.1 |

The same values come back for `@sim-ntu-r01 planning_preset:=slow_indoor`,
and the stock-preset NTU run reads 4.17 / 5.0 / 3.0 / 3.0 / 5.0 on both
versions. All six files reach their nodes through the thin wrapper, so
step 7's open question ("that play_launch lets our preset's configurations
shadow upstream preset defaults") is settled. The Rust parser was used.

### The `-no-perception` diagnostic graph

Probed 70 s into the Ming-Da replay (section 4), `launch_perception:=false`,
so the graph is `autoware-main-no-perception.yaml`:

| | 2.1.0 | 1.5.0 |
|---|---|---|
| aggregator | up for the whole run (it SIGSEGVed on 0.48.0 before the 2026-10-22 fix) | up |
| graph | 60 units, 40 leaves, 74 links | 62, 41, 75 |
| `/autoware/perception` | absent | absent |
| perception leaves | four parentless roots, ERROR, linked to nothing | the same |
| leaves gating `/autoware/modes/autonomous` | localization `sensor_fusion_status` and the planning, control and vehicle subtrees (the replay runs none of them) | the same set |
| `/api/fail_safe/mrm_state` | NORMAL, NONE | NORMAL, NONE |

No perception unit gates any mode, and nothing perception-related raises
an MRM. The workaround is still needed on 2.1.0. Without it,
`/autoware/perception` is in the graph and gates autonomous, as the
perception-on run shows:
`/autoware/perception/topic_rate_check/pointcloud ERROR` under autonomous
while CenterPoint was still loading.

Not covered: autonomous actually *available* with perception off on 2.1.0.
That needs planning, control and a vehicle in one run, and the planning
simulator uses autoware_launch's graph with dummy perception instead.
`just sim mrm-check` against the real graph is the check for step 11.

### cuda_ndt and `publish_loaded_map`

`golfcart_launch/config/localization/ndt_scan_matcher/ndt_scan_matcher.param.yaml`
now carries `dynamic_map_loading.publish_loaded_map: false`, and the
resolved launch passes the file to the cuda_ndt node. At runtime on 2.1.0
the node starts, logs no error, and tracks the whole bag (section 4).
cuda_ndt never declares the key (`io/params.rs` reads `update_distance`,
`map_radius` and `lidar_radius`), so the value is dropped silently, like
any undeclared parameter.

Side finding: `ros2 param get` returns `Parameter not set` for every
cuda_ndt parameter, including ones it reads (`dynamic_map_loading.map_radius`,
`score_estimation.converged_param_nearest_voxel_transformation_likelihood`).
play_launch's health log lists 35 of them as "never declared". The node
declares each parameter, reads it once and drops the handle. rclrs then
forgets the declaration. Nothing is wrong at runtime, but the running
values cannot be inspected. It is the same on 1.5.0, so it belongs to the
cuda_ndt_matcher repo and is not a 2.1.0 item.

## 3. Perception on, 2.1.0

Ming-Da replay, `launch_perception:=true use_traffic_light_recognition:=false`
(the indoor logging sim takes no perception preset, so these two mirror
`lidar_only`), **Python parser**. The Rust parser in play_launch 0.37.0
drops the three `<autoware_node>` entities (crop box, ground filter,
detection downsample: play_launch #0095). Bag at half rate.

87 entities (39 processes, 3 containers, 45 composables), all up after
3 min 38 s. Measured over 20 s of bag (half rate, so 5 Hz is the VLP-32C's
10 Hz):

| topic | rate | content |
|---|---|---|
| `/sensing/lidar/concatenated/pointcloud` | 5.0 Hz | |
| `/perception/obstacle_segmentation/pointcloud` | 5.0 Hz | |
| `/perception/occupancy_grid_map/map` | 5.0 Hz | |
| `.../detection/centerpoint/objects` | 5.0 Hz | 207 objects: 206 CAR (the basement's parked cars), 1 PEDESTRIAN |
| `.../detection/clustering/objects` | 5.0 Hz | 52 UNKNOWN (6013 before filtering) |
| `/perception/object_recognition/objects` | 5.0 Hz | 280 objects: 232 CAR, 48 UNKNOWN |

Both detectors publish, and the tracker merges them into
`/perception/object_recognition/objects`. The clustering detector is the
tracker's only source of unknown-class objects, as decided in step 7.

**Found and fixed (4cf62ee).** The first run built the *base* CenterPoint,
writing `lidar_centerpoint/base/pts_voxel_encoder.engine`, and then
started the traffic-light pipeline as well. `golfcart_autoware.launch.xml`
defaulted `lidar_detection_model` to a bare `centerpoint`. 1.5.0's
`lidar_dnn_detector` mapped that to `centerpoint_tiny`. 2.1.0's maps it to
`base` ("centerpoint -> base, centerpoint_<x> -> <x>"). The presets spell out
`centerpoint/centerpoint_tiny`, but the logging sims include
`golfcart_autoware.launch.xml` with no preset. The default now names the
tiny model. The traffic lights are not a regression:
`use_traffic_light_recognition` defaults to true in that file on `main` too,
so a logging sim with perception on starts them on both versions.

**Workstation only: the engines were rebuilt at launch.** The engines
step 9 built in `data/autoware_data-2.1.0/lidar_centerpoint/tiny/` were
rejected, and the 3.6 min startup is mostly the rebuild:

```
[W] [TRT] Plan was created with a different version of TensorRT! Current version: 10.8.0
[W] [TRT] Validation failed for the existing engine file. Rebuilding
```

This workstation has three TensorRT builds: `libnvinfer10` 10.15.1 from apt,
10.9.0 under `/usr/local/cuda`, and 10.8.0 as reported at runtime. The
engine key (`trt10.3.0.30` on the carts) and what `build-engines` linked
evidently differ from what the container loads. The Orins have one TensorRT
(10.3, JetPack 6.2), so this need not happen there. Step 11 should still
confirm that an installed or `build-engines`-built engine loads without
`Rebuilding` on the master.

## 4. NTU replay against 1.5.0, and the substitute

**Not possible on this machine.** `just ntu-test` reads
`/home/aeon/Downloads/2026-08-14_NTU-campus/merged/CSIE-1` (or
`GOLFCART_NTU_BAGS`), which does not exist here. No CSIE bag is anywhere on
the workstation or `/mnt/disk1`. CLAUDE.md's reference scores (cpu 0.038 m
scatter p95 / 0.179° yaw p95, cuda 0.035 / 0.167) stay unchecked against
2.1.0. That is a step 11 item on the master, which has the bags.

**Substitute**: the 2026-09-24 clockwise Ming-Da lap
(`rosbags/indoor-2026-09-24/clockwise-vlp32`, VLP-32C only, no IMU or
velocity), the Ming-Da map, board initialization, `cuda_ndt`, Rust parser,
the step 8 harness (bag paused, stack, resume, record the NDT outputs).

| run | rate | poses | NVTL median | p5 | p95 | min | min 10-scan median | scans < 2.1 gate | iterations, mean |
|---|---|---|---|---|---|---|---|---|---|
| 1.5.0 | 0.5 | 1276 | 2.453 | 2.309 | 2.518 | 1.823 | 2.265 | 1 | 1.92 |
| 2.1.0 | 0.5 | 1278 | 2.453 | 2.312 | 2.518 | 2.248 | 2.265 | 0 | 1.95 |
| step 8 reference (1.5.0, quiet host) | 1.0 | 1300 | 2.455 | 2.312 | 2.520 | 2.248 | 2.265 | – | 1.95 |

Pose difference on matching stamps:

| | common stamps | position p50 / p95 / max | yaw p95 / max |
|---|---|---|---|
| 1.5.0 vs 2.1.0 (0.5×) | 1276 | 0.01 / 0.09 / 0.88 cm | 0.003° / 0.161° |
| 1.5.0 (0.5×) vs step 8 reference | 1275 | 0.01 / 0.14 / 1.16 cm | 0.004° / 0.193° |

At full rate on the loaded host, the first runs did not compare: 1.5.0 locked
2.76 m off for the first 30 % of the bag (NVTL about 1.68, 342 to 347 scans
under the 2.1 gate) and then recovered. 2.1.0 jumped 1.1 m on its third
pose and then tracked, with 6 scans under the gate. Cause: the board align
took 7 s of wall time, against well under a second on a quiet host. The bag
kept playing while the cart rolled off the board, so NDT started from a
stale seed, and how it recovered depended on timing. `exe_time_ms` was
17 to 20 ms against the reference's 1.4 ms, with the GPU at 95 % for other
users. Halving the bag rate removed that, and the two versions then agree
to under a centimetre. The full-rate runs say nothing about either version.
They say the board handoff is sensitive to align latency, which the cart's
Orin under load could also show.

**1.5.0 only**: in every 1.5.0 replay (and in step 8's) two composables fail
to load:

```
[pointcloud_container]: Failed to load library: ... /opt/autoware/1.5.0/lib/libcuda_pointcloud_preprocessor.so: undefined symbol: _ZTVN18diagnostic_updater7UpdaterE
```

1.5.0's `libcuda_pointcloud_preprocessor.so` uses `diagnostic_updater` but
has no `NEEDED` entry for it. 2.1.0's has one. NDT is unaffected here,
because the indoor sim matches the raw `velodyne_points`. On the cart the
container loads other components first, which is presumably why it works
there. It is a 1.5.0 packaging bug that 2.1.0 does not have.

## 5. 1.5.0 before and after step 9

`play_launch resolve` (Rust) of `golfcart.launch.yaml` under 1.5.0 with
`main`'s `golfcart_launch`, `--host master`. Arguments expanded once by
origin/main's `scripts/launch/args.py` and once by this branch's, then
compared node by node: package, executable, every parameter, remaps,
container and arguments.

| arg file | nodes, main / branch | differences |
|---|---|---|
| `@mingda-loop` | 147 / 147 | 1: `/link_bridge`'s `--config` path (the worktree's checkout against this one) |
| `@ntu-r01` | 146 / 146 | the same one |

The branch's `args.py` adds
`data_path:=/home/aeon/repos/2026-golf-cart/data/autoware_data-1.5.0`, and
it appears only in launch-argument scopes (`./data/autoware_data` on main,
a symlink to the same directory). With perception off, no node takes a model
path, so step 9 changes nothing a 1.5.0 cart runs.

## What is left for step 11 (the hosts)

- Install 1.5.0-3 and 2.1.0-1 on both hosts (sudo; step 9's list), then the
  data, `just build` per version, and the CenterPoint-tiny engine. Confirm
  it loads without `Rebuilding`.
- NTU replay scores against CLAUDE.md's 0.035 m / 0.167° (cuda) on the
  master, which has the CSIE bags: `just ntu-test run CSIE-1 rviz=off` under
  each version.
- The real graph with perception off, end to end: `just sim mrm-check` under
  2.1.0, then autonomous available on the cart.
- `loop_goals_cw.yaml`: replace the south-east corner goal, which both
  versions refuse, with one the mission planner accepts.
- Board initialization with the cart's IMU and velocity, and the 2.1 NVTL
  gate on a cart session (`master_20261028_192241`), as step 8 left open.
- A supervised indoor drive on 2.1.0, with the same version on both hosts.

## Reproducing

The scratch scripts are not in the repository. Their recipe:

- 1.5.0 baseline overlay: `git worktree add --detach <wt> origin/main`, then
  colcon `golfcart_launch` from `<wt>/src/launcher/golfcart_launch` with a
  1.5.0 environment into a scratch install, and source its
  `local_setup.bash` after `scripts/env.sh`.
- Planning sim: `env -i ... GOLFCART_AUTOWARE_VERSION=<ver> ROS_DOMAIN_ID=87`,
  `source scripts/env.sh`, then `play_launch launch --disable-web-ui
  golfcart_launch planning_sim.launch.xml $(python3 scripts/launch/args.py
  --no-rviz @sim-mingda-loop)`, then `scripts/testing/sim_loop_drive.py --laps 1`.
- Replay: `scripts/rosbag/indoor_sim_{bag,up,conduct}.sh` under GNU parallel
  as `just indoor-test run` does, with `GOLFCART_INDOOR_BAG` set to the
  clockwise bag, `GOLFCART_INDOOR_BAG_RATE=0.5`, `map_path:=./data/mingda-basement`,
  and `ros2 bag record` of the `/localization/pose_estimator/*` outputs.
