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

## Order of work

1. Workstation: 1.5.0-1 → 1.5.0-3, then 2.1.0-1 beside it.
2. Smoke test play_launch on a stock 2.1.0 planning simulator launch.
3. Version switch, per-version workspaces and data dirs (section 1).
4. Required parameters and dead paths (section 2), then the planning wrapper,
   perception presets and diag graph.
5. `cuda_ndt_matcher` and `cuda_pointcloud_filters` (section 3).
6. Planning simulator on Ming-Da and NTU maps; NTU logging replay against the
   1.5.0 scores.
7. Hosts: master then orin, same version on both; engines rebuilt; a
   supervised indoor drive.
