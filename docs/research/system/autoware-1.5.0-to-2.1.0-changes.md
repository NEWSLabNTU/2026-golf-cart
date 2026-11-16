# Autoware 1.5.0 → 2.1.0: what changed, and what it changes here

Two halves: what changed in Autoware itself, then what that does to the golf
cart's own interfaces (launch arguments, files, commands). The work plan is
[roadmap 11](../../roadmaps/11-autoware-2.1.0-migration.md); this page is the
reference it draws on.

**State:** the version switch, the per-version workspaces and `just build`,
`test` and `clean` are on branch `autoware-2.1.0`. Everything marked
*pending* is not written yet.

**How it was measured (2026-11-16):** both releases installed side by side
from autoware-localrepo (1.5.0-3, 2.1.0-1) on the workstation, and compared
from `/opt/autoware/{1.5.0,2.1.0}/share`. Message diffs ignore comments and
whitespace. Where a line says *unverified*, nobody has run it yet.

## Part 1: Autoware itself

### Versions

| | 1.5.0 | 2.1.0 |
|---|---|---|
| autoware_universe | 0.48.0 | 0.53.0 (tag 0.53.2) |
| autoware_core | 1.5.0 | 1.10.0 |
| autoware_launch | 0.48.0 | 0.53.0 |
| autoware_msgs (`autoware_*_msgs`) | 1.11.0 | 1.13.0 |
| autoware_adapi_v1_msgs | 1.9.1 | 1.9.2 |
| cuda_blackboard | 0.1.0 | 0.5.0 |
| Nebula (LiDAR drivers) | 0.2.5, one `nebula_ros` | 1.2, split per vendor |
| ROS 2 | Humble | Humble (Jazzy also supported upstream) |
| Packages in `share/` | 455 | 499 (40 removed, 84 added) |

On JetPack 6.2 both run TensorRT 10.3 and CUDA 12.6. On x86 both localrepo
releases build against CUDA 12.8 and TensorRT 10.8.

### The launch tree was restructured

This is the change that costs the most.

- The six `tier4_*_launch` packages are gone:
  `tier4_{control,localization,map,perception,planning,sensing}_launch`.
  Each is replaced by a pair: `autoware_*_launch` (the launch files) and
  `autoware_*_config` (the parameter files), for control, localization, map,
  perception and planning; sensing has `autoware_sensing_launch` and
  `autoware_sensor_driver_launch`.
- `autoware_launch/config/{map,perception,planning,localization}` is gone; the
  files moved into the matching `autoware_*_config` package.
- `autoware_launch`'s `tier4_X_component.launch.xml` became
  `component_X.launch.xml`. A component no longer takes one `*_param_path`
  argument per file; it takes a `*_config_pkg` naming the package to read all
  of them from.
- `perception.launch.xml` and `detection.launch.xml` are gone. Perception is
  `component_perception.launch.xml` (LiDAR) plus
  `component_traffic_light.launch.xml`, with one
  `object_recognition_<mode>.launch.xml` per mode. The arguments
  `perception_mode`, `use_traffic_light_recognition`, `use_detection_by_tracker`,
  `use_image_segmentation_based_filter` and `use_lidar_rule_detector` no longer
  exist.
- Many launch files now use a new `<autoware_node>` action and include
  `agnocast_env.launch.xml`, which sets `LD_PRELOAD` for agnocast (zero-copy
  IPC; off unless `ENABLE_AGNOCAST=1`).

### Packages removed (40)

| Group | Packages |
|---|---|
| Launch (replaced, above) | `tier4_{control,localization,map,perception,planning,sensing}_launch`, `common_sensor_launch`, `common_awsim_labs_sensor_launch`, `single_lidar_common_launch` |
| Nebula 0.2 (replaced by per-vendor packages) | `nebula_ros`, `nebula_common`, `nebula_decoders`, `nebula_hw_interfaces`, `nebula_examples`, `nebula_sensor_driver`, `nebula_tests` |
| Localization | `autoware_automatic_pose_initializer` (now `autoware_pose_initialization_requester`), `autoware_pose2twist` |
| Planning | `autoware_mission_planner` (moved into core), `autoware_trajectory_optimizer`, `autoware_trajectory_safety_filter`, `autoware_trajectory_traffic_rule_filter` |
| Perception | `autoware_object_range_splitter`, `autoware_object_velocity_splitter`, `autoware_polar_grid`, `autoware_livox_tag_filter`, `autoware_image_diagnostics`, `trt_batched_nms` |
| Old external APIs | `autoware_external_api_msgs`, `autoware_iv_external_api_adaptor`, `autoware_iv_internal_api_adaptor`, `awapi_awiv_adapter`, `tier4_autoware_api_extension`, `tier4_deprecated_api_adapter` |
| System and tools | `autoware_bluetooth_monitor`, `autoware_component_monitor`, `autoware_component_interface_tools`, `autoware_auto_common`, `reaction_analyzer`, `tier4_datetime_rviz_plugin` |

### Packages added (84), by theme

| Theme | Packages |
|---|---|
| Launch and config split | `autoware_{control,localization,map,perception,planning}_{launch,config}`, `autoware_sensing_launch`, `autoware_sensor_driver_launch` |
| Nebula 1.2 | `nebula`, `nebula_core_*`, and per vendor `nebula_{velodyne,hesai,robosense,continental,sample}{,_common,_decoders,_hw_interfaces}` |
| Agnocast | `agnocast`, `agnocast_components`, `agnocast_cie_*`, `ros2agnocast_discovery_*` |
| Redundancy and driving modes | `autoware_command_gate`, `autoware_driving_mode_manager`, `autoware_redundancy_{adapi_switcher,command_selector,switcher_interface,switcher_interface_plugins}`, `autoware_mrm_{in_lane_stop_operator,reset_manager,steering_hold_stop_operator}`, `autoware_in_lane_mrm_planner` |
| Planning | `autoware_trajectory_{gate,selector,validator}`, `autoware_minimum_rule_based_planner`, `autoware_behavior_path_direction_change_module`, `autoware_obstacle_proximity_checker`, `autoware_spheric_collision_detector` |
| Perception | `autoware_ground_segmentation_cuda`, `autoware_tensorrt_vad`, `autoware_traffic_light_pipeline`, `autoware_traffic_light_compliance_checker` |
| System design | `autoware_system_designer`, `autoware_system_design_examples`, `autoware_diagnostic_graph_merger`, `autoware_interface_spec_lint`, `autoware_component_interface_admission` |
| Simulation, sample vehicle, tools | `autoware_simulation_msgs`, `autoware_dummy_traffic_light_publisher`, `autoware_{sample,awsim}_sensor_kit_description`, `autoware_sample_vehicle_description`, `autoware_sample_designs`, `autoware_maps`, `autoware_evaluation_adapter`, `autoware_generic_service_divider`, `autoware_pose_initialization_requester`, two RViz plugins |

### Messages, services, actions

Nothing was renamed or had a field removed except the old external API.

**Removed (2):** `autoware_external_api_msgs/msg/ResponseStatus`,
`autoware_external_api_msgs/srv/GetVersion`, with their package.

**Changed (7):**

| Type | Change | Wire-compatible? |
|---|---|---|
| `tier4_system_msgs/DiagNodeStatus` | `+ bool is_overridden` | **No**: field added |
| `tier4_system_msgs/CommandSourceStatus` | `source` `uint16` → `uint32` | **No**: type widened |
| `autoware_internal_planning_msgs/CandidateTrajectory` | `+ TurnIndicatorsCommand turn_indicators_command` | No: field added |
| `autoware_control_validator/ControlValidatorStatus` | `+ over_velocity_target_vel`, `+ over_velocity_vehicle_vel` | No: fields added |
| `autoware_internal_planning_msgs/VelocityLimit` | `+ SENDER_API = "api"` constant | Yes (constant only) |
| `tier4_external_api_msgs/LocalizationScore` | two name constants | Yes |
| `autoware_adapi_v1_msgs/ObjectClassification` | whitespace only | Yes |

**Added (52).** They come with the new packages. Ones worth knowing:
`autoware_vehicle_msgs/Actuation{Command,Report}{,Stamped}` (actuation-level
vehicle interface), `tier4_vehicle_msgs/WheelLinearSpeedReport`, the
`tier4_system_msgs` driving-mode, command-source, trajectory-source and
redundancy types, `tier4_system_msgs/srv/SetDiagGraphOverride`, and
`tier4_planning_msgs/srv/SetLateralOffset`.

A field added in a message type changes its DDS type hash. A 1.5.0 node and a
2.1.0 node on the same topic of such a type do not match. That is why both cart
hosts must run the same version.

### Parameters that became required

These nodes abort at startup in 2.1.0 when a parameter file copied from 1.5.0
lacks the key:

| Node | Keys to add |
|---|---|
| `ekf_localizer` | `pose_measurement.max_pose_queue_size`, `twist_measurement.max_twist_queue_size`, `diagnostics.diagnostics_publish_frequency` |
| `ndt_scan_matcher` | `dynamic_map_loading.publish_loaded_map` |
| `CudaPointcloudPreprocessorNode` | `max_input_point_count`, `max_twist_frequency_hz`, `max_imu_frequency_hz` |
| `goal_planner` | `pull_over.bezier_parking.lateral_acceleration_threshold`, `...lateral_acceleration_filtering_duration` |
| `obstacle_stop` | `obstacle_filtering.min_object_length`, `detection_height.{bottom_limit,top_limit.default,top_limit.unknown}` |
| `start_planner` | `minimum_shift_length`, `turn_signal_on_centerline_start` |
| `lidar_marker_localizer` | 10 keys |

Changed without breaking: `imu_corrector` splits `correct_for_bias`,
`vehicle_velocity_converter` drops `frame_id`, `pose_initializer` gains
`stop_check_twist_topic`.

### Topics, nodes, graph

- The relay from `/planning/trajectory` to
  `/planning/scenario_planning/trajectory` is gone; control reads
  `/planning/trajectory`.
- `/autoware/system/service_log_checker` was deleted, so a diagnostic graph
  that links it fails to load.
- The graph aggregator now drops the diagnostics of nodes that are not
  launched, and gains `use_driving_mode_mappings`.
- `cuda_blackboard` 0.5 takes a CUDA stream in its subscriber; the stream-less
  constructor is deprecated.
- RViz's `PolarGridDisplay` plugin is gone.
- Upstream fixed the sign of the pitch² term in NDT's Hessian (#1217).

### Smoke test (2026-11-16)

Stock 2.1.0 `planning_simulator.launch.xml` on the sample map, under
play_launch 0.20.0, headless, four minutes:

- **play_launch's default Rust parser fails** on 2.1.0:
  `'launch.substitutions.EnvironmentVariable' object has no attribute 'perform'`.
  The trigger is the agnocast env files, which call
  `context.perform_substitution(EnvironmentVariable(...))`.
- With `--parser python`, all 97 entities started (48 nodes, 8 containers,
  41 composable nodes) and stayed up. The only error was the parking costmap
  finding no `map → base_link`, expected with no initial pose.
- play_launch flagged 12 nodes whose parameter files carry keys the node no
  longer declares. That is upstream's own files, not ours.
- Run it with this repository's `config/cyclonedds/loopback.xml`. Plain
  `ROS_LOCALHOST_ONLY=1` with no profile caps Cyclone's unicast discovery, and
  about 30 nodes then look missing.

## Part 2: what changes for the golf cart

### For whoever runs the cart

| | With 1.5.0 | With 2.1.0 |
|---|---|---|
| Commands | `just build`, `just up @…`, `just run`, … | **unchanged**. *Pending:* `just up` passing the version to both hosts' units. |
| Choosing the version | none (1.5.0 only) | `config/autoware-version` on each host, one line (`2.1.0`); gitignored, like `config/host`. One-off: `GOLFCART_AUTOWARE_VERSION=2.1.0 just …`. Default stays 1.5.0. |
| Both hosts | same commit | same commit **and** same Autoware version (`DiagNodeStatus` crosses the link) |
| Workspace | `build/`, `install/` | `build-<ver>/`, `install-<ver>/`; each version builds once. 1.5.0 keeps using an existing `build/` and `install/` until its first new-layout build. |
| Models | `data/autoware_data/` | `data/autoware_data-<ver>/` (1.5.0 falls back to the old directory) |
| `just clean` | removes everything | removes the selected version's workspace; `--all` removes every version's |
| `just build FLAGS` | only `--clean` | `--clean`, plus any colcon flag (`--parallel-workers 4`, `--packages-select …`) |
| TensorRT engines | built per version | rebuilt for 2.1.0. Engine keys already include the version (`aw2.1.0-trt10.3.0.30-agx-orin-64gb`). |
| Hosts | localrepo 1.5.0-1 | localrepo 1.5.0-3 (coexists), plus 2.1.0-1 |

### Launch arguments of `golfcart.launch.yaml`

The argument names stay. What some of them do changes underneath:

| Argument | Effect under 2.1.0 |
|---|---|
| `perception_preset` (`lidar_only`, `camera_lidar_fusion`, `minimal`) | **Needs a redesign.** The presets set `perception_mode`, `use_traffic_light_recognition`, `use_detection_by_tracker` and `use_image_segmentation_based_filter`, which upstream dropped silently: they would do nothing. |
| `perception_mode`, `use_traffic_light_recognition`, `use_detection_by_tracker`, `use_image_segmentation_based_filter` | Same: no longer reach Autoware. To remove, or map onto the new per-mode launch files. |
| `planning_preset` (`default`, `slow_indoor`) | Kept. `slow_indoor` gains the required goal_planner, obstacle_stop and start_planner keys, and our planning component copy becomes a thin wrapper over `autoware_planning_launch`. |
| `launch_perception:=false` | Kept. The perception stubs stay, because the planners still wait on the grid and the obstacle cloud. Whether the `-no-perception` graph overlay is still needed gets re-tested. |
| `pose_source` (`cuda_ndt`, `ndt`, …) | Kept. `ndt` needs the new NDT key; `cuda_ndt` gets the upstream Hessian fix ported. |
| `pose_initializer` (`gnss`, `board`, `none`) | Kept. Upstream's automatic initializer is now `autoware_pose_initialization_requester`. |
| `pointcloud_backend`, `use_cuda` | Kept. The CUDA preprocessor needs three new keys; `cuda_pointcloud_filters` moves to cuda_blackboard 0.5. |
| `lidar_model`, `camera_model`, `capture_profile`, `imu_source`, `gnss_receiver`, `use_ntrip` | Kept. Our sensing component copy still forwards them. The Velodyne include moves from `nebula_ros` to `nebula_velodyne`. |
| `map_path`, `@<site>` arg files | Kept. The map component is called with explicit file names and `map_config_pkg`. |
| `data_path` | New default per version (`data/autoware_data-<ver>`), resolved by `scripts/env.sh` as `GOLFCART_DATA_PATH`. *Pending:* `scripts/launch/args.py` passing it to the launch. |

### Our files that point at what moved

About 75 references in our launch files name paths that 2.1.0 removed. They
are listed per file in roadmap 11 §2. In short:

- `golfcart_autoware.launch.xml`: the map and control component includes.
- `components/tier4_{planning,localization}_component.launch.xml`: the
  `tier4_*_launch` targets.
- `cuda_ndt_matcher_launch`: gyro_odometer, the fusion filter, the error
  monitor and the pose initializer.
- The sensor kit: the Nebula launch and calibration paths.
- `config/system/diagnostics/autoware-main{,-aruco}.yaml`: the
  `service_log_checker` link.
- RViz configs, `config/recording/topics.yaml` and a recording test: the old
  `/planning/scenario_planning/trajectory` name.

### Messages our code uses

- **Unchanged:** every type our Rust and Python packages use, and every
  topic and service name we use (`/localization/initialize`,
  `/api/localization/initialize`, `/control/control_mode_request`,
  `/control/command/*`, the diagnostic graph's `struct` and `status`).
  Nothing in our source needs a message edit; the Rust crates regenerate
  from the underlay at build time.
- **Changed and crossing the link:** `DiagNodeStatus`, through the diagnostic
  graph topics. Same version on both hosts, or the bridge's two ends do not
  match.
- **Code changes:** `cuda_ndt_matcher` (launch paths, the Hessian fix, its
  comparison copy of core bumped to 1.10.0); `cuda_pointcloud_filters` (pass
  the stream). Everything else rebuilds unchanged.

### Tooling

- **play_launch:** use `--parser python` for 2.1.0 until the Rust parser
  handles `EnvironmentVariable` substitutions performed in a context.
  play_launch links no Autoware, so one install serves both versions.
- **Setup** *(pending)*: the `autoware-debian`, `autoware-data`,
  `tensorrt-engines` and `rviz-theme` steps are to follow the selected
  version, and `install-autoware-debian.sh` to install that version's
  localrepo release (1.5.0-3 for 1.5.0, 2.1.0-1 for 2.1.0). Today it still
  installs 1.5.0-1.
- **Environment:** `scripts/env.sh` sources `/opt/autoware/<ver>/setup.bash`,
  warns when the shell already holds another Autoware, and sets
  `QT_QPA_PLATFORMTHEME` itself. 1.5.0-3 and 2.1.0 moved that line into
  `autoware-env.bash`, which must not be sourced here, because it would undo
  the master/orin DDS split.
