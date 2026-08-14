# CLAUDE.md

Guidance for Claude Code when working with this repository.

## Project Overview
This is a golf cart autonomous driving system for 華夏科大 campus deployment, based on the Golf Cart platform. The system uses Autoware 2025.02 on AGX Orin (JetPack 6.2) with ROS 2 Humble.

**Key System Configuration:**
- **LiDAR**: Velodyne VLP-32C only
- **GNSS**: u-blox (F9R for practice, F9P for production)
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras (will upgrade to Tier IV cameras later)
- **Vehicle Interface**: Turing Drive packages (replaces Golf Cart custom PWM interface)
- **Map**: 華夏科大 campus HDMap (COSS map for practice)
- **Localization**: Autoware NDT scan matching (GNSS for initialization)
- **Planning**: Autoware built-in planner (enabled, not manual control)

**Migration Status**: See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) for detailed migration plan from Golf Cart to golf cart system.

## Essential Commands

### Build & Run
```bash
./setup.sh              # Interactive setup (ROS 2, dependencies)
./setup.sh status       # Check installation status
just build              # Build all packages
just test               # Run tests
just launch             # Launch system (web UI: http://localhost:8081)
just launch "..."  # Launch with parameters
just clean              # Remove build artifacts
just checkout           # Update git submodules
just --list             # Show all available commands
```

### Tools
```bash
just tool-rviz          # Launch RViz
just tool-plotjuggler   # PlotJuggler visualization
just tool-controller    # Keyboard manual control
just tool-tui           # Drive monitor TUI (pose, speed, states)
```

### Vehicle Interface (standalone, no Autoware)
```bash
just vehicle-interface                       # CAN RX only on can0 — cart cannot move
just vehicle-interface can=vcan0             # bench, against mock_vcu
just vehicle-interface converter=on          # + robot_state_publisher + velocity converter
just vehicle-interface tx=on                 # ⚠️ CAN TX live: this can drive the cart
just manual-control                          # keyboard teleop — SECOND terminal
```
Options are `KEY=VALUE`, any order: `can=`, `tx=on|off`, `converter=on|off`.
`tx` defaults to `off` on every path. Keyboard control is a separate recipe
because it reads a raw tty: it must own a real terminal, so it cannot be a node
inside a launch file (play_launch does not support `launch-prefix` either).

### Control Testing
```bash
just control-straight   # Run 10m straight trajectory (needs: just vehicle-interface converter=on)
just control-circle     # Run circular trajectory
```

### Rosbag
```bash
just bag-record         # Record outdoor sensor topics
just bag-play           # Play most recent recording
```

### Simulation
```bash
just launch-sim-planning  # Autoware planning simulator
just launch-sim-logging   # Logging simulation (rosbag replay)
just sim-coss-park        # Full COSS Park simulation scenario
```

### Manual Build
```bash
source install/setup.bash
colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

# Or use justfile
just build

# Build specific package (must include all standard flags)
colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release --packages-select <package_name>
```

**Important**: Always use `--base-paths src` and other standard flags from `just build` when running colcon commands manually.
**Important**: Never commit a submodule pointer to a commit that is not yet on GitHub, on a long-lived branch of its NEWSLabNTU fork. Push the submodule first, then the parent pointer — otherwise a fresh clone fails at `git submodule update` and the parent commit cannot say what was meant to be there. See [CONTRIBUTING.md](CONTRIBUTING.md#submodule-workflow).
**Important**: Respect the .gitconfig in the repository when committing. Use Conventional Commits format (`feat`, `fix`, `chore`, `docs`, `refactor`, etc.) for commit messages.

## Architecture

### Core Structure
- **src/launcher/golfcart_launch/** - Main launch configurations and system monitor
  - Provides web-based system monitor at http://localhost:8080/
  - Main launch file: `golfcart.launch.yaml`
- **src/param/autoware_individual_params/** - Parameter configurations for different sensor kits
- **src/sensor_kit/golfcart_sensor_kit_launch/** - Sensor integration and launch files
- **src/vehicle/golfcart_vehicle_launch/** - Vehicle interface and description
- **src/sensor_component/external/** - External sensor drivers (submodules)
- **src/localization/golfcart_board_initializer/** - Indoor cold-start pose from a retroreflective board; ROS-free detector plus a VLP-32C simulator, so `python3 -m pytest test` runs with no ROS or hardware

### Key Submodules
**Golf Cart Migration Notes:**
- **Retained**: autoware_manual_control, gnss_locator, ros-nmea-reader
- **To Replace**: ros2_mpu9250_driver → Tamagawa IMU driver (pending)
- **Camera**: USB cameras (no ZED submodule needed initially)
- **Vehicle Interface**: Will use Turing Drive packages (to be added)

Submodules:
- autoware_manual_control - Keyboard control interface
- golfcart_sensor_kit_launch - Sensor kit configurations
- gnss_locator - GNSS positioning
- ros2_mpu9250_driver - IMU driver (to be replaced with Tamagawa)
- ros-nmea-reader - NMEA GPS data parser

### Data Structure
- **data/COSS-map-planning/** - Practice map (from Golf Cart)
- **data/huaxia-campus/** - Production map for 華夏科大 campus (to be added)
- **data/models/** - ML models (YOLOX, CenterPoint, TensorRT)

### Build Artifacts
- **build/** - Compiled binaries (gitignored)
- **install/** - Installed packages and setup files
- **log/** - Build and runtime logs

## Development Workflow

### Sensor Configuration
**Golf Cart Configuration:**
- **LiDAR**: Velodyne VLP-32C only (no Robin-W or Cube1)
- **GNSS**: u-blox F9R (practice) → F9P (production)
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras → Tier IV GMSL cameras (future upgrade)

Sensor configurations are in `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/`

### Launch System
- Main launch uses Autoware's standard launch system
- Vehicle model: `golfcart_vehicle`
- Sensor model: `golfcart_sensor_kit`
- Default map: `./data/COSS-map-planning` (practice) → `./data/huaxia-campus/` (production)

### Launch Parameters for Golf Cart

#### LiDAR Configuration
```bash
# Velodyne VLP-32C (golf cart standard)
just launch "lidar_model:=vlp32c"
```

#### Camera Configuration
`camera.launch.xml` is the single entry point for every camera. The Autoware
sensing launch chain forwards only a fixed set of arguments, so through `just
launch` the selection is made by environment variable:

```bash
# Three GMSL cameras on the Advantech (default)
CAMERA_MODEL=gscam just launch

# ZED X — set automatically for the orin host; also selectable directly
ros2 launch golfcart_sensor_kit_launch camera.launch.xml camera_model:=zedx

# No camera
CAMERA_MODEL=none just launch
```

#### GNSS Configuration
```bash
# u-blox GNSS (golf cart standard)
just launch "gnss_receiver:=ublox"
```

**Usage:**
```bash
# Full visual localization (requires visual map)
just launch "pose_source:=visual visual_map_dir:=/path/to/visual_map"

# Visual odometry only (no global init, manual pose required)
just launch "pose_source:=isaac"
```

**Creating Visual Maps:**
```bash
# Golf cart standard configuration
just launch "lidar_model:=vlp32c camera_model:=usb gnss_receiver:=ublox"

# Indoor testing without GNSS
just launch "lidar_model:=vlp32c camera_model:=usb use_gnss:=false"
```

### Python Packages
Standard ROS 2 conventions: setup.py/setup.cfg, test files for copyright/flake8/pep257.

### Setup Script Architecture

The setup system (`setup/`) uses a two-layer design:

1. **`setup.sh`** - Interactive wrapper that asks all questions upfront before any installation begins
2. **`justfile`** - Recipe definitions that perform actual installations

**Adding new optional components:**

1. Add installation script to `setup/scripts/install-<name>.sh`
2. Add recipe to `setup/justfile`:
   ```just
   # Direct recipe (for manual invocation)
   my-component: _init
       @just _run my-component "{{scripts_dir}}/install-my-component.sh"

   # Conditional recipe (for interactive setup)
   _setup-my-component:
       #!/usr/bin/env bash
       if [[ "${INSTALL_MY_COMPONENT}" == "y" ]]; then
           just my-component
       else
           printf "{{yellow}}⊘{{nc}} my-component skipped (user choice)\n"
       fi
   ```
3. Add `_setup-my-component` to the `setup:` recipe chain
4. Add question in `setup.sh` `interactive_setup()` function:
   ```bash
   INSTALL_MY_COMPONENT="n"
   printf "${YELLOW}Optional:${NC} My Component description\n"
   if ask_yes_no "Install My Component?" "n"; then
       INSTALL_MY_COMPONENT="y"
   fi
   export INSTALL_MY_COMPONENT="$INSTALL_MY_COMPONENT"
   ```
5. Update summary output and status display

**Key pattern:** Questions are asked at the start, choices exported as env vars, justfile conditionals execute based on those vars.

### Preset System

Golf Cart uses a **preset system** (following Autoware's pattern) to manage component-level configurations. Presets group related parameters for common use cases.

#### How Presets Work

**Preset files** are YAML launch files that define launch arguments:

```yaml
# config/perception/preset/lidar_only_preset.yaml
launch:
  - arg:
      name: perception_mode
      default: "lidar"
  - arg:
      name: use_traffic_light_recognition
      default: "false"
  # ... more args
```

**Main launch file** includes presets:

```yaml
# golfcart.launch.yaml
- arg:
    name: perception_preset
    default: "lidar_only"

- include:
    file: "$(find-pkg-share golfcart_launch)/config/perception/preset/$(var perception_preset)_preset.yaml"
```

**Benefits**:
- ✅ Select presets for convenience: `perception_preset:=camera_lidar_fusion`
- ✅ Override individual parameters for experimentation: `use_traffic_light_recognition:=true`
- ✅ Easy to extend: Add new preset file without modifying launch files

#### Creating Custom Presets

1. Copy existing preset: `cp lidar_only_preset.yaml custom_preset.yaml`
2. Modify parameter defaults in the new file
3. Use with: `just launch perception_preset:=custom`

**Note**: Preset files must use `<name>_preset.yaml` naming convention.

#### Available Presets

**Perception** (`config/perception/preset/`):
- `lidar_only` - LiDAR only, no camera features (default)
- `camera_lidar_fusion` - Camera + LiDAR with traffic light recognition
- `minimal` - Minimal features for development/debugging

**Localization** (`config/localization/preset/`):
- `default` - Gyro odometry twist estimation (default)
- `eagleye` - GNSS-based odometry (requires GNSS)

See `config/{perception,localization}/preset/README.md` for detailed documentation.

## Quick Reference

### Common Launch Parameters

#### Preset-Based Configuration (Recommended)
```bash
# Perception presets (controls perception mode and features)
perception_preset:=lidar_only           # Default: LiDAR only, no camera features
perception_preset:=camera_lidar_fusion  # Camera + LiDAR with traffic light recognition
perception_preset:=minimal              # Minimal features for development

# Localization presets (controls twist estimation)
localization_preset:=default            # Default: gyro_odom
localization_preset:=eagleye            # GNSS-based odometry (requires GNSS)

# Example: Use camera-lidar fusion
just launch perception_preset:=camera_lidar_fusion
```

#### Sensor Configuration
```bash
# Sensor suites (predefined combinations)
sensor_suite:=vlp32c             # Velodyne VLP-32C

# Individual sensor overrides
lidar_model:=vlp32c
camera_model:=gscam|zedx|none   # env: CAMERA_MODEL
imu_source:=xsens|zed           # env: IMU_SOURCE
gnss_receiver:=ublox|septentrio
```

#### Localization (pose_source)
```bash
# pose_source options:
pose_source:=ndt       # Default: LiDAR NDT scan matching (Autoware, requires point cloud map)
pose_source:=cuda_ndt  # CUDA-accelerated NDT (1.3-1.6x faster, 57% less CPU on Jetson)
pose_source:=isaac     # cuVSLAM visual odometry only (relative tracking, manual init)
pose_source:=visual    # cuVGL + cuVSLAM (camera-only, auto init from visual map)

# For visual localization, specify map directory:
visual_map_dir:=/path/to/visual_map  # Contains cuvgl_map/, cuvslam_map/
```

#### System Features
```bash
# Localization
use_gnss:=false                  # Indoor operation (no GNSS)
use_ntrip:=true                  # RTK positioning (ublox only)
use_mapless_mode:=true           # Indoor operation without localization

# Perception
launch_perception:=false           # Disable entire perception module

# Advanced: Override preset-defined parameters
perception_mode:=lidar                      # Override preset perception mode
use_traffic_light_recognition:=true        # Override preset setting
use_detection_by_tracker:=false            # Override preset setting
use_image_segmentation_based_filter:=false # Override preset setting
use_pointcloud_map:=true                   # Override preset setting
twist_source:=gyro_odom|eagleye            # Override preset twist source
```

### Vehicle Interface (Quick Ref)

**Motor PWM** (PCA9685 I2C, channel 0):
- Range: 280-460, Init: 370 (neutral), Brake: 340
- Forward: 371-460, Reverse: 280-369
- Multi-mode controller: Emergency Brake, Full Stop, Deadband Hold, Active Control (PID)

**Steering PWM** (PCA9685 I2C, channel 1):
- Range: 350-450, Init: 400 (center)
- Max angle: 0.349 rad ≈ 20°
- Dual-mode controller: Fallback (v<0.3m/s), Normal (yaw rate feedback)

**Velocity Sensing**:
- Hall effect sensor (KY-003) on GPIO
- Parameters: `params/velocity_report.yaml`

**Actuator Parameters**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/params/actuator.yaml`

## Documentation

### Main Documentation Book (MkDocs)
- **Framework**: MkDocs with Material theme (following Autoware conventions)
- **Setup**: `cd book && just setup` (installs dependencies)
- **Build**: `cd book && just build` (builds to `site/`)
- **Serve**: `cd book && just serve` (http://localhost:3000)
- **Source**: `book/src/` (Markdown files)
- **Config**: `book/mkdocs.yml`

**Features**:
- ✅ Material Design theme
- ✅ Mermaid diagram support
- ✅ Multi-language (English + 繁體中文)
- ✅ Math rendering (MathJax)
- ✅ Search, dark mode, mobile responsive

**Key Guides** (in book):
- **Sensor Integration**: `book/src/guides/sensor-integration/`
  - Simple usage guide, sensor-specific details
- **Vehicle Control**: `book/src/guides/vehicle-control/`
  - Overview, hardware, control details, tuning & testing
  - Multi-mode controllers, PCA9685 I2C, hall effect sensor, PID tuning

### Legacy Guides (docs/)
| Guide | Description |
|-------|-------------|
| [docs/guides/sensor_configuration.md](docs/guides/sensor_configuration.md) | Sensor suites, NTRIP/RTK, localization |
| [docs/guides/vehicle_calibration.md](docs/guides/vehicle_calibration.md) | PWM control, PID tuning, testing tools |
| [docs/guides/lidar_integration.md](docs/guides/lidar_integration.md) | Velodyne VLP-32C, TensorRT |
| [docs/guides/control_testing.md](docs/guides/control_testing.md) | Control system testing procedures |
| [docs/guides/mrm_configuration.md](docs/guides/mrm_configuration.md) | MRM (emergency stop) configuration |
| [docs/multi-machine.md](docs/multi-machine.md) | Two-machine operation: `just launch-master`, per-host DDS profiles, orin lifecycle, recording |
| [docs/design/zed_camera_integration.md](docs/design/zed_camera_integration.md) | ZED X launch structure, published topics, TF ownership split between the ZED driver and Autoware, IMU source selection |
| [docs/roadmaps/2-zed-camera-integration.md](docs/roadmaps/2-zed-camera-integration.md) | ZED integration phase: work items, acceptance criteria, deferred field measurements |
| [docs/guides/isaac_vslam_testing.md](docs/guides/isaac_vslam_testing.md) | Isaac SLAM testing |
| [docs/design/isaac_vslam_integration.md](docs/design/isaac_vslam_integration.md) | Isaac SLAM architecture |
| [docs/research/localization/ndt_parameter_tuning_coss_map.md](docs/research/localization/ndt_parameter_tuning_coss_map.md) | NDT tuning research |
| [docs/research/safety/assurance-2.0-for-autoware-llm.md](docs/research/safety/assurance-2.0-for-autoware-llm.md) | Assurance 2.0 survey: formal safety case for Autoware + LM integration tiers |
| [docs/design/lm_driving_tuning_workflow.md](docs/design/lm_driving_tuning_workflow.md) | LM driving integration: BEV-token input, zone-mask output, verifier-gated tuning workflow |
| [docs/superpowers/specs/2026-07-27-indoor-artag-localization-design.md](docs/superpowers/specs/2026-07-27-indoor-artag-localization-design.md) | Indoor AR-tag + NDT localization design: tags replace GNSS for init, EKF correction, and NDT regularization |
| [docs/roadmaps/3-indoor-localization.md](docs/roadmaps/3-indoor-localization.md) | Indoor localization phase master: sub-phases A (calibration) → B (mapping) → C (tag map) → D (runtime) |
| [docs/design/indoor_pcd_mapping_reflector_anchor.md](docs/design/indoor_pcd_mapping_reflector_anchor.md) | Indoor PCD map creation with no GNSS: retroreflective board defines map origin and cold-start pose |
| [docs/design/board_pose_initializer.md](docs/design/board_pose_initializer.md) | Board pose initializer node: detection algorithm, pose extraction, VLP-32C simulator, test matrix |
| [docs/roadmaps/3-indoor-e-board-initializer.md](docs/roadmaps/3-indoor-e-board-initializer.md) | Phase 3E work items, acceptance criteria, and simulation results for the board initializer |

## Known Issues

- **Steering reversed**: Left/right inverted in manual control
- **Network monitor errors**: AWS Greengrass socket errors (non-critical, ignore)
- **Isaac ROS GXF libraries**: If `pose_source:=visual` or `pose_source:=isaac` fails with "libgxf_*.so not found", the GXF library paths are not in `LD_LIBRARY_PATH`. Re-source the setup files:
  ```bash
  source /opt/ros/humble/setup.bash
  source /opt/autoware/1.5.0/setup.bash
  source install/setup.bash
  ```
  GXF libraries are located at `/opt/ros/humble/share/*/gxf/lib/` and should be added by Isaac ROS environment hooks.

## NDT Localization (Golf Cart)

### Overview
The golf cart uses Autoware's built-in NDT (Normal Distributions Transform) scan matching for localization:
- **Input Requirements**: LiDAR point cloud, IMU data, speedometer from vehicle interface, GNSS (initialization)
- **Map**: Point cloud map (PCD format) + Lanelet2 vector map
- **Practice**: F9R GNSS + COSS map
- **Production**: F9P GNSS + 華夏科大 map

### Configuration
NDT parameters may need tuning for golf cart:
- Located in: `src/param/autoware_individual_params/individual_params/config/default/`
- Key parameters: resolution, convergence tolerance, iteration limits
- Adjust based on testing results

### Localization Dependencies
1. **LiDAR**: Velodyne VLP-32C (Phase #3)
2. **IMU**: Tamagawa IMU (Phase #5)
3. **Speedometer**: From Turing Drive vehicle interface (Phase #7)
4. **GNSS**: u-blox for initialization (Phase #4)
5. **Map**: Point cloud + Lanelet2 map (Phase #8)

All dependencies must be ready before localization can work.

## Tooling Preferences
- Prefer `rg` (ripgrep) over `grep -r` / `find … -exec grep` for codebase searches — it's faster, respects `.gitignore`, and the flags compose more cleanly (e.g. `rg -nE 'pattern' path`, `rg -l 'pattern'`, `rg -tyaml 'pattern'`).
- Prefer `just <recipe>` over `cargo` or raw `sh` scripts.

## Important Notes
- **Target Platform**: Advantech Orin computer with JetPack 6.2
- **Autoware Version**: 2025.02 at `/home/aeon/repos/autoware/2025.02-ws`
- Always source ROS environment: `source /opt/ros/humble/setup.bash`
- Requires ROS 2 Humble distribution
- Built for Ubuntu 22.04 with NVIDIA GPU support
- Uses colcon build system (not catkin)
- Symlink installs enabled for faster development iteration
- System monitor available at http://localhost:8080/ when launched
- **Migration**: See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) for team assignments and phase details

## System Management

### Systemd Service Integration

Applies to the two-machine deployment. `just launch` (single machine) is
unaffected and still runs play_launch in the foreground.

Both hosts run the same units, installed per machine with a role:

| Unit | Hosts | Purpose |
|---|---|---|
| `golfcart-launch.service` | both | the stack, via play_launch |
| `golfcart-record.service` | both | rosbag only, independent lifecycle |
| `golfcart-watchdog.service` | orin | stops everything if the master vanishes |

```bash
just service-install master            # this machine
just service-install-orin              # the orin, over ssh
just launch-master                     # starts both; returns immediately
just stop-master                       # stops both; leaves recording alone
just logs-master
just record-start / record-stop        # recording, independent of the launch
just doctor                            # when topics do not show up
```

Units are installed but never enabled: they start on demand, not at boot.
Lingering is required and the installer enables it — without it the user manager
exits with the last session and takes the units with it.

See [docs/multi-machine.md](docs/multi-machine.md) for operation and
[docs/design/orin_provisioning_implementation_plan.md](docs/design/orin_provisioning_implementation_plan.md)
for why it is built this way.

**Note**: earlier revisions of this file described a `golfcart` CLI with
`golfcart status` / `golfcart enable`, and a service auto-installed on first
`just launch`. That was inherited from the AutoSDV system and never existed in
this repository.

### Process Management
- `just launch` (single machine): Ctrl-C stops it; a second Ctrl-C forces it
- `just launch-master` (two machines): nothing to Ctrl-C — it returns
  immediately, and `just stop-master` is the stop verb
- `KillMode=control-group` in the units is what keeps orphans from surviving
- play_launch ignores SIGTERM, so the units stop it with `KillSignal=SIGINT`

### Known Issues and Solutions

#### Journal Logging
`journalctl --user -u <unit>` works for the golfcart units. If a bare
`journalctl --user` shows nothing, use `systemctl --user status <unit>`, which
prints recent lines regardless.

#### Network Monitor Error
- Network monitor may show socket connection errors
- This is a known non-critical issue related to AWS Greengrass
- Can be safely ignored - doesn't affect system functionality

## Velodyne VLP-32C LiDAR Integration

### Golf Cart Configuration
The golf cart uses Velodyne VLP-32C as the sole LiDAR sensor:
- Driver: Nebula (Autoware's universal LiDAR driver)
- Launch file: `golfcart_sensor_kit_launch/launch/lidar.launch.xml`
- Config: `golfcart_sensor_kit_launch/config/VLP32.param.yaml`
- Network IP: 192.168.7.10 (default, configurable via `vlp32c_device_ip` arg)

### Coordinate System
- Velodyne follows ROS standard (REP-103): X:forward, Y:left, Z:up
- Transformation configured in: `sensor_kit_calibration.yaml`
- Adjust roll, pitch, yaw based on physical mounting position

## TensorRT Model Compilation

### First Run Behavior
On first launch, TensorRT will compile ONNX models to optimized CUDA engines:
- This process can take 10-30 minutes depending on hardware
- Compiled engines are cached in `./data/` directory
- Key models:
  - `lidar_centerpoint/pts_voxel_encoder_centerpoint_tiny.engine`
  - `lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.engine`
  - Traffic light classifiers (if enabled)

### Optimized Perception Configuration
For faster startup and LiDAR-only operation, configure in `golfcart.launch.yaml`:
```yaml
- name: perception_mode
  value: "lidar"
- name: use_traffic_light_recognition
  value: "false"
- name: use_detection_by_tracker
  value: "false"
- name: use_image_segmentation_based_filter
  value: "false"
```

## Vehicle Interface

### Turing Drive Integration (Golf Cart)
The golf cart uses Turing Drive vehicle interface packages (replacing Golf Cart custom PWM interface):
- **Status**: Pending - specifications and packages to be obtained from Turing Drive
- **Expected components**:
  - Vehicle interface node (control command → CAN/vehicle protocol)
  - Velocity/odometry reporting
  - Gear status management
  - Control mode management (manual/autonomous)
- **Integration files**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_launch/launch/vehicle_interface.launch.xml`

### Golf Cart PWM Interface (Reference Only)
The original Golf Cart system used custom PWM control:
- Motor PWM: 370 = stop, >370 = forward, <370 = reverse
- Steering PWM: 400 = center, 350 = left, 450 = right
- **Note**: This is for reference only. Golf cart will use Turing Drive interface.

## u-blox GNSS Integration

### Practice Setup (F9R RTK)
Learn with F9R from seniors Allan & David:
- **Device**: u-blox F9R RTK receiver
- **Purpose**: Practice setup, learn configuration
- **Map**: Use with COSS map for localization testing
- **Launch parameter**: `gnss_receiver:=ublox`

### Production Setup (F9P)
Target configuration for golf cart:
- **Device**: u-blox F9P GNSS receiver (pending hardware)
- **Map**: Use with 華夏科大 campus map
- **Configuration files**:
  - `golfcart_sensor_kit_launch/launch/gnss.launch.xml`
  - `golfcart_sensor_kit_launch/config/ublox_gnss.param.yaml` (to be created)
- **Calibration**: Antenna position from base_link in `sensor_kit_calibration.yaml`

### Integration with Localization
- GNSS provides initial position for NDT localization
- Must work together with map for Autoware localization
- Coordinate with map preparation team

## IMU Integration

Two sources, selected by `imu_source` (env `IMU_SOURCE`). Both feed the same
Autoware chain — `imu_corrector` then `gyro_bias_estimator` — which always runs
on the Advantech regardless of source. Launch file:
`golfcart_sensor_kit_launch/launch/imu.launch.xml`.

### Xsens MTi over CAN (`imu_source:=xsens`, default)
- **Driver**: `xsens_mti_can_ros_driver`, launched by `imu.launch.xml`
- **Raw topic**: `/sensing/imu/xsens/imu_raw`
- **Frame**: `imu_link`
- **Known issue**: the driver has `pub_transform: true`, broadcasting
  `world -> imu_link` while the URDF publishes `sensor_kit_base_link -> imu_link`.
  That frame has two parents today.

### ZED X built-in (`imu_source:=zed`)
- **Driver**: none launched here — the ZED node on the orin already publishes it
- **Raw topic**: `/sensing/camera/zed/imu/data`
- **Frame**: `zed_imu_link`, parented to `zed_left_camera_frame` by the driver
- Uses `imu/data`, not `imu/data_raw`. "raw" in Autoware means "not yet corrected
  by Autoware", not "uncalibrated by the vendor"; `gyro_bias_estimator` can only
  remove a constant bias, so feeding it the SDK's uncalibrated fields would
  discard scale and misalignment corrections nothing can rebuild.
- Crosses the DDS link at 100 Hz. `gyro_odometer` time-syncs it against vehicle
  twist, so link jitter shows up as twist noise — prefer a wired link.

### Corrected output
`/sensing/imu/imu_data`, consumed by `autoware_gyro_odometer`. Corrector
parameters are per-device and do not transfer between sources:
`individual_params/.../imu_corrector_{xsens,zed}.param.yaml`.

## Camera Configuration

Two camera sets on two machines, both behind `camera.launch.xml`. Design:
[docs/design/zed_camera_integration.md](docs/design/zed_camera_integration.md).

### GMSL cameras — Advantech (`camera_model:=gscam`)
Three TIER IV GMSL cameras (left, right, rear) via `gscam`:
- **Config**: `golfcart_sensor_kit_launch/config/camera_{left,right,rear}.yaml`
- **Topics**: `/sensing/camera/{left,right,rear}/image_raw/compressed`
- **Frames**: `camera_left`, `camera_right`, `camera_rear`

### ZED X — orin (`camera_model:=zedx`)
One ZED X stereo camera, driven as a composable node:
- **Launch**: `golfcart_sensor_kit_launch/launch/zed.launch.xml`
- **Config**: `golfcart_sensor_kit_launch/config/zed.param.yaml`, layered over
  `zed_wrapper`'s `common_stereo.yaml` and `zedx.yaml`
- **Topics**: `/sensing/camera/zed/rgb/color/rect/{image,camera_info}` and
  `/sensing/camera/zed/imu/data`
- **The RGB channel is the left camera.** Images are stamped
  `zed_left_camera_frame_optical` (Z forward, X right, Y down), so any pose
  computed from them is in that frame — transform with tf2, never by hand.
- Left/right stereo, depth, and point cloud are all disabled. Positional
  tracking is off, because Autoware owns `map -> odom` and `odom -> base_link`.
- Only `zed_camera_link` (the screw hole in the camera's bottom) is calibrated
  in `sensor_kit_calibration.yaml`. Everything below it comes from the vendor
  URDF via a `robot_state_publisher` inside `zed.launch.xml`.
- Needs OpenGL hardware acceleration — plain VNC breaks it. If the GMSL link
  wedges (`ZEDX#0#0#FROZEN`), run `sudo service zed_x_daemon restart; sleep 25`.

## Golf Cart Migration Plan

**See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md)** for comprehensive migration plan with 11 phases and team assignments.

### Key Migration Tasks
1. **Phase #1**: Advantech Orin computer setup (JP6.2, firmware, dependencies)
2. **Phase #3**: Velodyne VLP-32C LiDAR integration
3. **Phase #4**: u-blox GNSS (F9R practice → F9P production)
4. **Phase #5**: Tamagawa IMU integration
5. **Phase #6**: USB cameras (upgrade to Tier IV later)
6. **Phase #7**: Turing Drive vehicle interface integration
7. **Phase #8**: 華夏科大 campus HDMap (COSS map for practice)
8. **Phase #9**: NDT localization tuning
9. **Phase #10**: Planning and control configuration
10. **Phase #11**: Integration testing and validation

### Team Assignments
- **Team A (Allan & Liao)**: Sensors (LiDAR, cameras, GNSS focus)
- **Team B (Vincent & Darren)**: System setup, map preparation, vehicle interface
- **Coordination**: Both teams work together on GNSS + Map for localization testing
- **Practice Equipment**: F9R GNSS + COSS map (from seniors Allan & David)
- **Production Equipment**: F9P GNSS + 華夏科大 map

### Hardware Status
**Available Now:**
- Velodyne VLP-32C LiDAR
- USB cameras
- u-blox F9R (practice, from Allan & David)
- COSS map (practice)
- Orin box (interim testing)

**Pending:**
- Advantech Orin computer
- u-blox F9P GNSS (production)
- Tamagawa IMU
- 華夏科大 campus map
- Turing Drive vehicle interface packages

## Recent Updates (Golf Cart Legacy)
- With --symlink-install flag in colcon build, edits on yaml, xml, py source files immediately apply if the file was installed earlier. There is no need to rebuild. In case you create a new file, you need to run colcon build again to create the symlink in the install/ dir.
- Original Golf Cart system had PWM interface calibration, Robin-W LiDAR, ZED cameras - see sections above for reference
