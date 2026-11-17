# Phase 11: Autoware 2.1.0 beside 1.5.0

Goal: run the stack on Autoware 2.1.0 (localrepo 2.1.0-1, universe 0.53.2,
core 1.10.0) while 1.5.0 stays installed and selectable, so either version can
be driven until 2.1.0 has earned the default. Branch: `autoware-2.1.0`.

This file is the change inventory, surveyed 2026-11-16 by diffing the 1.5.0
and 2.1.0 source workspaces (`autoware-localrepo/{1.5.0,2.1.0}/amd64/source`).
Nothing below has been built or launched yet; items marked *unverified* need a
real launch to settle.

What changed upstream, and what it changes in this repository's own
interfaces, measured from the two installed releases:
[autoware-1.5.0-to-2.1.0-changes.md](../research/system/autoware-1.5.0-to-2.1.0-changes.md).

## Summary

- **Messages and services: nothing breaks.** Every type our code uses is
  unchanged apart from comments; only additions upstream. Topic and service
  names we use (`/localization/initialize`, `/api/localization/initialize`,
  `/control/control_mode_request`, `/control/command/*`, the diag graph's
  `struct`/`status`) are the same. Rust message crates regenerate from
  whatever is on `AMENT_PREFIX_PATH`. One field changed in a type that crosses
  the link (`DiagNodeStatus` gains `is_overridden`), so **both hosts must run
  the same version**.
- **The launch layer is restructured, and that is the bulk of the work.**
  `tier4_{localization,perception,planning,map,sensing,control}_launch` are
  gone, replaced by `autoware_*_launch` plus `autoware_*_config` packages;
  `autoware_launch/config/{map,perception,planning,localization}` is gone;
  `tier4_X_component.launch.xml` became `component_X.launch.xml` with a
  `*_config_pkg` argument instead of per-file `*_param_path` arguments. About
  75 references in our launch files point at paths that no longer exist.
- **Several nodes abort at startup without new required parameters** (EKF,
  CUDA preprocessor, start/goal planner, obstacle stop, NDT).
- **Infrastructure needs one version switch.** About 60 places hardcode
  `/opt/autoware/1.5.0` or `-1-5-0`, and `build/`/`install/` cannot be shared
  between underlays.

## 0. Install prerequisites (per host)

1. The hosts run localrepo **1.5.0-1**, which installs the unversioned
   `/usr/bin/apply-autoware-theme`, `10-cyclone-max.conf` and
   `multicast-lo.service` and cannot coexist with another version. Move to
   **1.5.0-3** first (packages keep their version numbers, so `apt upgrade`
   does nothing: replace the localrepo deb, `uninstall-autoware.sh`, reinstall).
2. Then 2.1.0-1 (`jetpack62` on both Orins). The orin may have no internet:
   stage the debs and the `data-2.1.0-1` model debs on the master.
3. `setup/scripts/configure-multicast-lo.sh` writes the same
   `/etc/systemd/system/multicast-lo.service` that 1.5.0-1's
   `autoware-config-1-5-0` owns, so purging 1.5.0-1 deletes ours. Rename ours
   (`golfcart-multicast-lo.service`) or re-run the step after.
4. Never source `autoware-env.bash` after `scripts/env.sh`: it sets Autoware's
   lo-only `CYCLONEDDS_URI` and would undo the master/orin domain split.
5. **2.1.0 has not run on Orin hardware yet** (tested in an L4T container),
   and patches `cuda_blackboard` for CUDA 12.6. Our `cuda_pointcloud_filters`,
   `cuda_ndt_matcher` and `gmslcam` link it.

## 1. Version selection and workspaces

- Default in `config/runtime.conf`:
  `GOLFCART_AUTOWARE_VERSION="${GOLFCART_AUTOWARE_VERSION:-1.5.0}"`, with an
  optional gitignored per-host override like `config/host`. `versions.yaml`
  becomes the catalogue (supported versions, localrepo release, apt suffix,
  deb sha256); `scripts/version/export-versions.sh` reads keys that no longer
  exist and nothing calls it: rewrite or delete.
- `scripts/env.sh` must resolve the version **before** sourcing Autoware (it
  sources Autoware at l.490 but `runtime.conf` at l.690), source
  `/opt/autoware/$V/setup.bash`, fail loudly if missing, and export
  `GOLFCART_AUTOWARE_{VERSION,PREFIX,SUFFIX}`, `GOLFCART_{BUILD,INSTALL}_DIR`,
  `GOLFCART_DATA_PATH`. Keep `QT_QPA_PLATFORMTHEME=qt5ct` (moved out of
  `setup.bash` into `autoware-env.bash` in 1.5.0-3/2.1.0).
- Workspaces `build-<ver>/`, `install-<ver>/` via colcon `--build-base`/
  `--install-base` (and `--test-result-base`); update `justfile`
  build/test/clean, `.envrc`, `.gitignore`, and every script that sources
  `install/setup.bash` (most should source `scripts/env.sh` instead).
- `just up`: the version must reach the units before env.sh runs
  (`scripts/multi_machine/launch_unit_exec.sh`), e.g. a `.golfcart-launch.env`
  or an `autoware=` token stripped by `scripts/launch/args.py`; same on the
  orin. `up` refuses if the two hosts differ; `just service host-status` and
  `scripts/doctor.sh` print the version. `scripts/rmw/ensure.sh` should also
  catch a ros2 daemon started under the other version.
- play_launch links no Autoware: one install serves both.

### Hardcoded 1.5.0 to replace with the selected version

`scripts/env.sh`, `scripts/_env_guard.sh`, `justfile` (`build-engines`),
`setup/golfcart_setup/registry.py` (`_REQUIRE_AUTOWARE`, `autoware-debian`,
`autoware-data`, `tensorrt-engines`, `rviz-theme`),
`setup/scripts/install-autoware-debian.sh` (release URL, deb names, the
prerequisites script moved to `/usr/share/autoware/<ver>/`, the
`newslab-ros-config` overwrite hack is only for 1.5.0-1, the skip check cannot
see -1 → -3), `scripts/setup_autoware_data.sh` (takes the *last*
`/opt/autoware/*` downloader, i.e. 2.1.0's), `scripts/engines/engines.py`
(`autoware_release()` regex-parses env.sh), `scripts/rviz/{rviz,install_theme}.sh`,
`scripts/check/{run.sh,diag_graph_qos.sh,mode_strip_test.sh,rosbridge_graph_feed.sh,audit_launch.py}`,
`scripts/analysis/rank_play_launch.py`, `scripts/twin/*`, `config/twin.env.example`,
`golfcart_twin/{isaac/make_lidars.py,body/check_lidar_clearance.py}` (resolve
via ament index), tests `golfcart_launch/test/test_duplicated_node_checker.py`,
`rig_localization/.../test_launch.py`, `test_replay_launch.py`, and the
`cuda_ndt_matcher` submodule (`justfile`, `.envrc`, `scripts/activate_autoware.sh`).

### Models and engines

- Data dir per version: `data/autoware_data-<ver>/` (`mv data/autoware_data
  data/autoware_data-1.5.0`); `args.py` injects `data_path:=$GOLFCART_DATA_PATH`;
  launch defaults (`golfcart.launch.yaml:382`, the logging sims,
  `sensor_only.launch.yaml`, `twin_autoware.launch.xml`) follow.
- 2.1.0 changed the model layout: CenterPoint tiny is
  `lidar_centerpoint/tiny/pts_backbone_neck_head.onnx` (same sha256 as 1.5.0's
  `pts_backbone_neck_head_centerpoint_tiny.onnx`). Re-derive `build-engines`.
- Engine keys already separate versions (`aw2.1.0-trt10.3.0.30-agx-orin-64gb`);
  JetPack 6.2 is TensorRT 10.3 under both. Rebuild once rather than seed from
  the 1.5.0 pack.

## 2. Launch layer (golfcart_launch)

### Includes whose target is gone

| Our file | Old target | 2.1.0 |
|---|---|---|
| `golfcart_autoware.launch.xml` map include (~l.157) | `tier4_map_component` | `component_map.launch.xml`; pass `map_path`, `lanelet2_map_file`, `pointcloud_map_file`, `map_config_pkg` explicitly |
| `golfcart_autoware.launch.xml` control include (~l.337) | `tier4_control_component` | `component_control.launch.xml` (`module_preset`, `vehicle_model`, `vehicle_id`, `control_config_pkg`; `*_param_path` gone) |
| `components/tier4_planning_component.launch.xml` | `tier4_planning_launch/planning.launch.xml` | `autoware_planning_launch/launch/planning.launch.xml` |
| `components/tier4_localization_component.launch.xml` (other pose sources) | `tier4_localization_launch/localization.launch.xml` | `component_localization.launch.xml` (`localization_config_pkg`) |
| `cuda_ndt_matcher_launch/launch/{cuda_localization,autoware_localization}.launch.xml` | `tier4_localization_launch/...` gyro_odometer, fusion filter, error monitor | same paths under `autoware_localization_launch` |
| same | `autoware_automatic_pose_initializer` | removed; `autoware_pose_initialization_requester` |
| `components/golfcart_map_component.launch.xml` | `autoware_launch/config/map/*` | `autoware_map_config/config/*` |
| `golfcart_sensor_kit_launch/launch/lidar.launch.xml`, `board_detector_live.launch.xml`, `scripts/check/sensors.launch.xml` | `nebula_ros/launch/velodyne_launch_all_hw.xml` | `nebula_velodyne/...` (Nebula 1.2 split per vendor) |
| `golfcart_sensor_kit_launch/config/VLP32.param.yaml` | `nebula_decoders/calibration/velodyne/VLP32.yaml` | `nebula_velodyne_decoders/calibration/VLP32.yaml` |
| `aruco_planning_sim.launch.xml` | `tier4_simulator_component` | now requires `launch_fault_injection`; dummy perception moved to `planning_simulator/perception_simulation.launch.xml` |

### Planning (`slow_indoor`)

- Our copy of `tier4_planning_component` is obsolete: 2.1.0's
  `component_planning` is thin and every param path is an `<arg default=…>` in
  `autoware_planning_launch/planning.launch.xml` (`common_param_path`,
  `behavior_path_planner_{drivable_area_expansion,goal_planner_module,start_planner_module}_param_path`,
  `motion_velocity_planner_{obstacle_stop_module,road_user_stop_module}_param_path`).
  Replace the copy with a thin wrapper passing those six. *Unverified:* that
  play_launch lets our preset's configurations shadow upstream preset defaults.
- `config/planning/preset/default_preset.yaml` includes a path that is gone
  (now `autoware_planning_config/config/preset/default_preset.yaml`, which adds
  `launch_direction_change_module`). `test_planning_preset.py`'s `UPSTREAM_*`
  and the `golfcart_*_param_path` defaults move to `autoware_planning_config`.
- `slow_indoor` copies must add (no default in 2.1.0, node aborts):
  - `goal_planner`: `pull_over.bezier_parking.lateral_acceleration_threshold: 1.0`, `...lateral_acceleration_filtering_duration: 0.5`
  - `obstacle_stop`: `obstacle_filtering.min_object_length: 0.1`, `detection_height.bottom_limit: -50.0`, `detection_height.top_limit.default: 50.0`, `detection_height.top_limit.unknown: 1.0`
  - `start_planner`: `minimum_shift_length: 0.5`, `turn_signal_on_centerline_start: RIGHT`
  - `common`, `drivable_area_expansion`, `road_user_stop`: unchanged.

### Perception

- `tier4_perception_component` → `component_perception.launch.xml` (lidar
  only) plus `component_traffic_light.launch.xml`; `perception.launch.xml` and
  `detection.launch.xml` are gone, replaced by per-mode
  `object_recognition/object_recognition_{lidar,camera,...}.launch.xml`.
- `perception_mode`, `use_traffic_light_recognition`, `use_detection_by_tracker`,
  `use_image_segmentation_based_filter`, `use_lidar_rule_detector` are dropped
  silently: our three perception presets need a redesign.
  `object_recognition_lidar.launch.xml` includes `lidar_rule_detector`
  unconditionally, so turning it off still needs a copy.
- `test_perception_copies.py` would skip silently: re-pin.
- `perception_stubs.py` stays (planners still wait on the grid and the
  obstacle cloud).

### Diagnostic graph

- `config/system/diagnostics/autoware-main.yaml` (~l.96-99) and
  `autoware-main-aruco.yaml` (~l.84-87) link `/autoware/system/service_log_checker`,
  which 2.1.0 deleted: remove or the aggregator fails on an unknown link.
- Upstream localization/planning/perception/control/map/vehicle graphs are
  unchanged; `edits: remove /autoware/perception` is still valid.
- Re-test whether the `-no-perception` workaround is still needed: 2.1.0's
  loader now removes the diags of removed nodes. The aggregator's new
  `use_driving_mode_mappings` needs checking against our graphs.

### Parameter files

- `golfcart_launch/config/localization/ekf_localizer.param.yaml`: add
  `pose_measurement.max_pose_queue_size: 5`,
  `twist_measurement.max_twist_queue_size: 2`,
  `diagnostics.diagnostics_publish_frequency: 10.0`. Without them the EKF
  dies on every localization path, `cuda_ndt` included.
- `.../ndt_scan_matcher/ndt_scan_matcher.param.yaml`: add
  `dynamic_map_loading.publish_loaded_map: false` (schema-required; breaks
  `pose_source:=ndt`). *Unverified:* whether cuda_ndt's parser tolerates it.
- `golfcart_sensor_kit_launch/launch/pointcloud_preprocessor.launch.py` (CUDA
  path, inline params): `CudaPointcloudPreprocessorNode` requires
  `max_input_point_count` (upstream 691200 for an OT128; size for the VLP-32C,
  excess points are dropped), `max_twist_frequency_hz: 200.0`,
  `max_imu_frequency_hz: 200.0`.
- `lidar_marker_localizer.param.yaml`: 10 required keys missing; re-copy or delete.
- Review only: `imu_corrector` splits `correct_for_bias` (defaults reproduce
  1.5.0), `vehicle_velocity_converter` drops `frame_id`, `pose_initializer`
  gains `stop_check_twist_topic` (default matches our velocity topic),
  `mem_monitor` gains keys (we take upstream's file).

### Review, no change expected

- `tier4_sensing_component` copy: still needed for our six sensor args;
  header comment only.
- `tier4_system_component`: upstream adds `planning_setting`, and its default
  graph path is wrong upstream (we override it).
- The `/planning/trajectory` → `/planning/scenario_planning/trajectory` relay
  was dropped upstream; control reads `/planning/trajectory`. Our relays are
  redundant; `golfcart{,_drive}.rviz`, `config/recording/topics.yaml:223` and
  `scripts/recording/test_session.py:268` still use the old name.
- RViz: `rviz_plugins/PolarGridDisplay` is gone (load warning).
- **play_launch** *(unverified, highest risk)*: 2.1.0 launch files use a new
  `<autoware_node>` action (`autoware_agnocast_wrapper/actions/autoware_node.py`)
  and include `agnocast_env.launch.xml` with `LD_PRELOAD` almost everywhere.
  Check play_launch's parser on a 2.1.0 launch before porting anything else.

## 3. Code

| Package | Effort | Change |
|---|---|---|
| golfcart_vehicle_interface, golfcart_domain_bridge, autoware_manual_control, control_test, golfcart_system_monitor, golfcart_twin, gnss_locator, rig_localization, reflective_pose_detector, CalibrationTools, seyond_ros_driver, zed wrapper, gmslcam, ublox, xsens | none | rebuild |
| cuda_ndt_matcher | medium | launch paths above; port upstream's pitch² Hessian sign fix (#1217) to `src/ndt_cuda/src/derivatives/angular.rs:140` (`h_ang[(6, 2)] = sy` → `-sy`) and re-baseline the comparison tests; bump `tests/comparison/autoware_core` to 1.10.0 |
| cuda_pointcloud_filters | small | cuda_blackboard 0.1 → 0.5: pass the stream to the subscriber (`cuda_crop_box_filter_node.cpp:77` and the random-downsample twin); the stream-less constructor is deprecated |
| seyond_ros_driver | none | branch name `1.5.0` is convention only |

## 4. Submodule versioning

Decided 2026-11-17. A submodule is versioned by what its **source** has to
follow, not by what it links. Most Autoware message types did not change
between 1.5.0 and 2.1.0 (Part 1 of the
[change reference](../research/system/autoware-1.5.0-to-2.1.0-changes.md)),
so a package that only uses those shares one source and is rebuilt per
underlay.

| Class | Line | Members |
|---|---|---|
| Golf cart | `2026-golf`, one line for every Autoware version | golfcart_vehicle_launch, golfcart_system_monitor, autoware_individual_params, golfcart_sensor_kit_launch |
| Autoware release | upstream version name: `1.5.0`, `2.1.0`; a golf cart patch on top is `2026-golf-<ver>` | CalibrationTools; the superproject (`main` = default version, `autoware-2.1.0`) |
| ROS edition | `main` (or upstream's `ros2`) while one source builds on every edition in use; `humble`/`jazzy` only when code splits | seyond_ros_driver, ublox, xsens_mti_can_ros2_driver, gmslcam, zed-ros2-wrapper (upstream tag) |
| Standalone | `main`, semver tags when a version is needed | cuda_ndt_matcher, cuda_pointcloud_filters, reflective_pose_detector, rig_localization, autoware_manual_control, gnss_locator |

**`golfcart_launch` is the glue.** Everything that names an Autoware launch
file, config package or path lives there, on the superproject's per-version
branch. Submodules take such paths as launch arguments with 1.5.0's defaults.
That is how the sensor kit and cuda_ndt_matcher keep one source.

Old branch names stay and freeze: no new commits, never deleted.
Superproject history pins commits reachable only from them, and the
[submodule pointer rule](../../CLAUDE.md#submodule-pointer-rule) depends on
that. Cleaning up stale `feat/…` and `dependabot/…` branches is a separate
job, done only after checking that no pinned commit is reachable from them
alone.

### Renaming items

Pins as of 2026-11-17. "ff" means the target branch is an ancestor of the
pin, so it moves without rewriting anything.

| # | Submodule | Pin | Tracked now | Target | Action |
|---|---|---|---|---|---|
| R1 | golfcart_vehicle_launch | `b0b9191` | `2026-golf` | `2026-golf` | none, already there |
| R2 | golfcart_system_monitor | `aea966c` | `2026-golf` | `2026-golf` | none |
| R3 | autoware_individual_params | `68f230e` | `main` | `2026-golf` | ff `2026-golf` by 7; `.gitmodules` branch → `2026-golf`; freeze `main`, `golfcart-1.5.0` |
| R4 | golfcart_sensor_kit_launch | `3cf866f` | `main` | `2026-golf` | ff `2026-golf` by 39; `.gitmodules` → `2026-golf`; freeze `main` |
| R5 | CalibrationTools | `35859ed` | `golfcart` | `1.5.0`, then `2.1.0` | pin is `1.5.0` + 1 commit ("Set LiDAR range in lidar-to-lidar calibrator") − 1 (`bc36609`, the `.repos` pointer). Turn the range into a launch parameter on `1.5.0`, so `golfcart` freezes; otherwise `2026-golf-1.5.0`. `2.1.0`: from `1.5.0` if it builds on 2.1.0, else from upstream `tier4/universe` (upstream has no per-release branches) |
| R6 | seyond_ros_driver | `36cade3` | `1.5.0` | `main` | `main` is the vendor's line (3 vendor syncs, `18c5c93`); ours is `1.5.0`, 12 ahead. Merge vendor `main` into ours (a merge, no rewrite), build, then ff `main` to it; freeze `1.5.0`. Vendor syncs come in by merge from then on |
| R7 | cuda_ndt_matcher | `7a7fb8c` | `main` | `main` | none; `main` is 3 ahead of the pin (normal lag) |
| R8 | rig_localization | `4bd4a31` | `main` | `main` | none; `main` 2 ahead |
| R9 | cuda_pointcloud_filters, reflective_pose_detector, autoware_manual_control, gmslcam, xsens | — | `main` | `main` | none |
| R10 | gnss_locator | `3c46523` | none in `.gitmodules` | `main` | add `branch = main` |
| R11 | ublox | `c56b851` | `ros2` | `ros2` | none |
| R12 | zed-ros2-wrapper | `86171bc` | none | tag `v5.4.1` | none; note in `.gitmodules` that it is pinned to an upstream tag |
| R13 | superproject | — | `main`, `autoware-2.1.0` | same | `.gitmodules` changes R3, R4, R10, R12 land on `main` too, since they change no content |
| R14 | docs | — | — | — | the pointer rule in `CLAUDE.md` and `CONTRIBUTING.md` names these four classes and their lines |

## Order of work

Done (2026-11-16/17):
1. Workstation: 1.5.0-1 → 1.5.0-3, then 2.1.0-1 beside it.
2. Smoke test: stock 2.1.0 planning simulator, 97 entities under
   `--parser python`. The Rust parser fails: play_launch #0086, sent to play 118.
3. Version switch, per-version workspaces and data paths, about 20 scripts
   (section 1); the workspace builds against 2.1.0.
4. The change reference, including the sensor kit and vehicle comparison.

Next:
5. **Branches** (section 4, R1-R14): done 2026-11-17. `2026-golf`
   fast-forwarded in individual_params and the sensor kit. CalibrationTools
   is on `1.5.0` at bc36609; its `golfcart` commit only exposed four
   arguments at their defaults. seyond's vendor `main` is merged into ours
   (1d21e50, builds). The branch fields are on `main` too (0ae3bc0), and the
   rule is in CONTRIBUTING.md. Still to do: the master's `/mnt/external`
   bare repos need these branches before the orin can pull them.
6. **Glue into `golfcart_launch`, behaviour-neutral on 1.5.0**: done
   2026-11-17 on `autoware-2.1.0`. Resolved under 1.5.0 before and after
   (`@mingda-loop`, `@ntu-r01`, `@ntu-r01 pose_source:=ndt`): same node
   sets. The only parameter changes are the three new CUDA keys; the
   Velodyne calibration path is the same. The matcher's own copies of the two
   stack files stay, for its replay harness (`run_ndt_simulation.sh`), and
   rig_localization keeps its `autoware_localization.launch.xml` example;
   golfcart uses neither. Landing on `main` waits for a cart check. What was
   planned:
   - `cuda_ndt_matcher_launch` stops including Autoware's gyro_odometer,
     fusion filter, error monitor and pose initializer; `golfcart_launch`
     includes them. The matcher repo then only starts its own node, and
     loses its golf cart references.
   - The sensor kit takes the Nebula launch file and calibration file as
     arguments, with 1.5.0's paths as defaults.
   - The sensor kit gets the three new CUDA preprocessor keys (1.5.0 ignores
     keys it does not declare).
   - Our `vehicle.xacro` loses the `: ` in a comment, which breaks
     `robot_description` under real `ros2 launch` and the Python parser.
   - Proof: `play_launch resolve` of `@mingda-loop`, `@ntu-r01` and the sims
     under 1.5.0, before and after, with identical node, parameter and remap
     sets.
7. **2.1.0 launch layer**, on `autoware-2.1.0` (section 2): done
   2026-11-17 (16d8485, 5044b65). Every entry point resolves under both
   play_launch parsers (0.36.0 at 89b70f92, #0086 fixed) with the same node
   sets: `@ntu-r01` 127, `@mingda-loop` 128, `pose_source:=ndt` 127,
   `pose_source:=yabloc` 136, planning sim 98, aruco sim 103, NTU and indoor
   logging sims 74, `sensor_only` 42, perception on (`lidar_only`,
   `minimal`) 130. What changed:
   - map and control through `component_map` / `component_control`; the
     aruco path uses `use_pointcloud_map:=false`, so `golfcart_map_component`
     is gone;
   - localization: `autoware_localization_launch` paths and
     `pose_initialization_requester`;
   - planning: our component is a thin wrapper handing six `golfcart_` paths
     to `autoware_planning_launch`; the six `slow_indoor` copies are rebased on
     `autoware_planning_config` 2.1.0, which carries the newly required keys;
   - perception: two 2.1.0 copies (`component_perception`,
     `object_recognition_lidar`) carrying `use_lidar_rule_detector`; traffic
     lights through `component_traffic_light`; `camera_lidar_fusion`,
     `use_detection_by_tracker` and the image segmentation filter stop the
     launch with a named error (no 2.1.0 pipeline);
   - Nebula 1.2 paths passed from our sensing component; EKF and NDT keys;
     the diag graph's `/autoware/debug/tools` removed; aruco sim
     `launch_fault_injection` and `perception_simulation.launch.xml`.

   Left open:
   - `use_lidar_rule_detector`: decided 2026-11-17, on in `lidar_only` and
     `minimal`. On 2.1.0 the tracker reads the clustering detector as its own
     channel, the only source of unknown-class objects (a box, a trolley).
   - The yabloc/eagleye fallback runs on `autoware_localization_config`'s
     parameters: `component_localization` takes no paths. A golfcart
     localization config package would restore ours.
   - `data_path` still defaults to 1.5.0's `./data/autoware_data`; under the
     Python parser a perception launch stops on the missing 2.1.0 model files
     (step 9). The Rust parser only warns and resolves on: play_launch #0089.
   - `camera_calibration.launch.xml` needs CalibrationTools built for 2.1.0.
   - **Before landing step 6 on `main`**: `board_detector_live.launch.xml`
     needs `vlp32_calibration_file` set (1.5.0 path), because
     `VLP32.param.yaml` now reads it; on this branch it carries 2.1.0's.
   - Not run yet: anything at runtime. cuda_ndt reading the new
     `publish_loaded_map` key, the `-no-perception` graph workaround, and
     the planning preset shadowing upstream's are step 10 checks.
8. **Code** (section 3):
   - `cuda_pointcloud_filters` builds on both cuda_blackboard versions.
   - `cuda_ndt_matcher` gets upstream's Hessian sign fix on `main`: done
     2026-11-17 (b0bc3c6). Upstream's change (autoware_core #1217, in core
     1.10.0) is `h_ang_.row(6)` = d1, ∂²(R·x)/∂pitch² for x, z coefficient
     `sy` → `-sy`; our `h_ang` has the same row layout. Only the CPU copy
     (`derivatives/angular.rs`) had the bug. The CUDA kernels
     (`persistent_ndt_device.cuh`) already had `-sp`, so the default GPU
     path, the one the cart runs, does not change. The CPU path does
     (`NDT_USE_GPU=0`, GNSS regularization, the batch-align fallback).
     Two new tests fail before the fix and pass after it, at
     (0.05, -0.04, 3.06): a finite-difference check of every `h_ang` row,
     and CPU against GPU Hessian (1.35e-4 relative before, 3e-7 after).
     No other unit-test number moved. The comparison fork
     (`tests/comparison/autoware_core`) is on 1.10.0, branch
     `cuda_ndt-1.10.0`, which builds only against 2.1.0.
     **Gate check** under 1.5.0 (`main`'s launch layer), on the 2026-09-24
     clockwise Ming-Da bag. It is the only Ming-Da lap on the workstation
     and has only the VLP-32C, with no IMU or velocity, so the EKF has no
     twist. Board init, dense map. GPU path, before → after: about 1300
     poses each, NVTL median 2.456 → 2.455, p5 2.312 → 2.312, p95
     2.521 → 2.520, minimum 2.251 → 2.248, minimum 10-scan median 2.265 →
     2.265. Pose difference: 0.14 cm p95, 1.2 cm max, the same as between
     two runs of the fixed build. Offline (`offline_bench`, the same 1303
     scans and priors for each build): the GPU arm is identical, and on the
     CPU arm 6 frames moved by more than 1 mm (5.0 cm max) with an unchanged
     NVTL distribution. Pitch stays near zero indoors, so the term barely
     matters here. The 2.1 gate stays: a healthy lock never drops below a
     2.265 window median, and the CPU live runs, which started from a wrong
     board alignment, sat at 1.42 to 1.76, the "wrong pose" band the gate
     was set for. Not yet done: re-check the gate on a cart session with
     IMU and velocity (`master_20261028_192241`, whose healthy median was
     2.53), and regenerate the comparison ground truth under 2.1.0.
9. **Setup and units**: done 2026-11-17 on `autoware-2.1.0`.
   - `versions.yaml` is the catalogue (release, suffix, deb and GitHub
     sha256 for ubuntu2204 and jetpack62): 1.5.0 → 1.5.0-3, 2.1.0 → 2.1.0-1.
     `setup/golfcart_setup/autoware.py` reads it with a stdlib parser.
     `export-versions.sh` is gone.
   - `install-autoware-debian.sh [VER] [--dry-run] [--force] [--reinstall]`
     installs that release, compares the installed localrepo on its
     revision (1.5.0-1 is "older": it needs `--reinstall`, which runs the
     version's own `uninstall-autoware.sh -y` after the new localrepo deb),
     runs `/usr/share/autoware/<ver>/setup-prerequisites.sh
     --non-interactive`, and refuses an apt plan that removes another
     version's packages. The newslab-ros-config overwrite is dropped.
   - The `autoware-debian`, `autoware-data`, `tensorrt-engines` and
     `rviz-theme` steps carry the version in their argv (digests follow it);
     `GOLFCART_AUTOWARE_VERSION=2.1.0 ./setup.sh ...` selects it.
   - Data: `data/autoware_data-<ver>`, filled by that version's downloader.
     The old `data/autoware_data` is renamed to `-1.5.0` and left as a
     relative symlink (done on the workstation). `args.py` prepends
     `data_path:=` unless given one; the launch defaults read
     `GOLFCART_DATA_PATH`. 2.1.0's 2.4 GB of models are on the workstation.
   - Engines: `engines.py` keys on the selected version; `build-engines`
     uses `lidar_centerpoint/tiny/` under 2.1.0 (CenterPoint tiny built on
     the workstation in 46 s; traffic-light models not built).
   - `just up` checks both hosts with `version_check.sh` and refuses before
     starting anything; the version reaches each unit in
     `.golfcart-launch.env`. `host-status` and `doctor` print it;
     `ensure.sh` stops a ros2 daemon from another version. RViz theme: one
     stylesheet per version.
   - Resolve, play_launch 0.37.0, 2.1.0, both parsers: perception on now
     resolves (`lidar_only` and `minimal`), and so does
     `logging_simulation.launch.yaml`. Rust drops three nodes there: it does
     not know 2.1.0's `<autoware_node>` action (`Unsupported action type`),
     so the crop box, ground filter and detection downsample filter are
     missing (Rust 133 / Python 136, `minimal` 133 / 135, logging sim
     122 / 125). That is a play_launch issue to file.

   Left: `cuda_ndt_matcher` (`justfile`, `.envrc`, `activate_autoware.sh`)
   and `rig_localization` (`test_launch.py`, `test_replay_launch.py`) still
   name 1.5.0; they are submodules and change on their own branches. The
   launch paths that bypass `args.py` (`indoor_sim_up.sh`,
   `ntu_sim_run.sh`, `ntu-test up`, `link_sim`, `board_check.sh`,
   `bag_replay`, `tool board`) get `data_path` from `GOLFCART_DATA_PATH`
   via the launch defaults. Hosts: 1.5.0-1 → 1.5.0-3 needs
   `install-autoware-debian.sh 1.5.0 --reinstall` (sudo) on both, then
   2.1.0, then `setup_autoware_data.sh` and `just build` per version.
10. **Validation**: done 2026-11-17 on the workstation, 2.1.0 against 1.5.0
    (`main`'s launch layer). Numbers and logs:
    [autoware-2.1.0-validation.md](../research/system/autoware-2.1.0-validation.md).
    - Planning simulator: on NTU r01 (263 m route) the two versions are
      identical to 0.1 s, under the stock preset and `slow_indoor`. On the
      Ming-Da loop the same legs arrive in the same times. The loop goal
      file's south-east corner goal is refused by both ("Goal's footprint
      exceeds lane!"). The east-to-start leg sometimes stalls on
      `path_optimizer` at the same spot on both (1.5.0 2 of 4, 2.1.0 1 of 4).
    - Step 7's runtime checks: `slow_indoor`'s values are the running ones
      on 2.1.0 (`max_vel` 2.5, stop margins 3.5/1.5/1.5, the backward and
      freespace modules off), identical to 1.5.0. The `-no-perception`
      graph works on 2.1.0 and is still needed. cuda_ndt runs with
      `publish_loaded_map` in its file and ignores it (it never declares
      the key).
    - Perception on (Python parser): CenterPoint tiny and the clustering
      detector both publish, and the tracker merges them. Fixed: the logging
      sims ran the base CenterPoint on 2.1.0 (4cf62ee).
    - NTU replay: the bags are not on the workstation, so not run. The
      Ming-Da VLP-32C replay substitutes: pose difference 1.5.0 against
      2.1.0 0.09 cm p95, the same NVTL distribution (bag at half rate; the
      shared host was too loaded for full rate).
    - 1.5.0 before and after step 9: node, parameter and remap sets
      identical for `@mingda-loop` and `@ntu-r01`; `data_path` reaches no
      node with perception off.

    Left for step 11: the NTU scores on the master; engines that load
    without a rebuild (this workstation's mixed TensorRT forced one);
    `just sim mrm-check` on 2.1.0; replace the refused Ming-Da loop goal;
    the upstream aggregator mapping `/autoware/modes/autonomous/available`,
    which no graph has (harmless today).
11. **Hosts**: master then orin, same version on both; engines rebuilt; a
    supervised indoor drive.

Outside this repo: play_launch 0.37.0 (PyPI, installed on the workstation
2026-11-17; setup's floor is now 0.37.0) fixes #0085-#0089. Re-checked with
it under 2.1.0, both parsers, same node sets: `@ntu-r01` 127,
`@mingda-loop` 128, `pose_source:=ndt` 127, `pose_source:=yabloc` 136,
planning sim 98 (NTU and Ming-Da), aruco sim 103, NTU and indoor logging sims
73, `sensor_only` 41, `board_detector_live` 3, `bag_replay` 2, `sim_smoke` 8
(the counts one below step 7's are RViz, off here). `GOLFCART_PLAY_LAUNCH_PARSER`
is not needed. Perception on, and `logging_simulation.launch.yaml`, now stop
under both parsers on `./data/autoware_data/lidar_centerpoint/tiny/ml_package.param.yaml`:
a composable node's missing parameter file is an error, as in `ros2 launch`
(#0089). That is the step 9 `data_path` item, no longer hidden by a warning.
`camera_lidar_fusion` stops on its named refusal, as intended.
