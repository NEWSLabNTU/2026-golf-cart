# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview
This is a golf cart autonomous driving system for 華夏科大 campus deployment, based on the AutoSDV platform. The system uses Autoware 2025.02 on AGX Orin (JetPack 6.0) with ROS 2 Humble.

**Key System Configuration:**
- **LiDAR**: Velodyne VLP-32C only
- **GNSS**: u-blox (F9R for practice, F9P for production)
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras (will upgrade to Tier IV cameras later)
- **Vehicle Interface**: Turing Drive packages (replaces AutoSDV custom PWM interface)
- **Map**: 華夏科大 campus HDMap (COSS map for practice)
- **Localization**: Autoware NDT scan matching (GNSS for initialization)
- **Planning**: Autoware built-in planner (enabled, not manual control)

**Migration Status**: See MIGRATION.md for detailed migration plan from AutoSDV to golf cart system.

## Essential Commands

### Build System (ROS 2 with colcon)
- `make prepare` - Install ROS dependencies using rosdep
- `make build` - Build all ROS packages with colcon (Release mode, symlink-install)
- `make launch` - Launch AutoSDV using systemd service (installs service if needed, then starts)
- `make stop` - Stop the running AutoSDV system
- `make restart` - Restart the AutoSDV system
- `make status` - Show AutoSDV system status and logs
- `make controller` - Run keyboard manual control
- `make clean` - Remove build, install, and log directories (with confirmation)
- `make checkout` - Initialize and update all git submodules
- `make setup` - Set up development environment using Ansible scripts

### AutoSDV Service Management (autosdv command)
After building (`make build`), the `autosdv` command is available:
- `autosdv install` - Install systemd user service (done automatically by `make launch`)
- `autosdv start` - Start the AutoSDV system
- `autosdv stop` - Stop the AutoSDV system
- `autosdv restart` - Restart the system
- `autosdv status` - Show system status and recent logs
- `autosdv enable` - Enable automatic startup at login
- `autosdv disable` - Disable automatic startup
- `autosdv monitor` - Open web monitor in browser (http://localhost:8080/)
- `autosdv uninstall` - Remove the systemd service

### Manual Commands
- `source install/setup.bash` - Source the ROS workspace (required before running nodes)
- `colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release` - Manual build
- `rosdep install -y --from-paths src --ignore-src -r` - Install dependencies

## Architecture Overview

### Core Structure
- **src/launcher/autosdv_launch/** - Main launch configurations and system monitor
  - Provides web-based system monitor at http://localhost:8080/
  - Main launch file: `autosdv.launch.yaml`
- **src/param/autoware_individual_params/** - Parameter configurations for different sensor kits
- **src/sensor_kit/autosdv_sensor_kit_launch/** - Sensor integration and launch files
- **src/vehicle/autosdv_vehicle_launch/** - Vehicle interface and description
- **src/sensor_component/external/** - External sensor drivers (submodules)

### Key Submodules
**Golf Cart Migration Notes:**
- **Retained**: autoware_manual_control, gnss_locator, ros-nmea-reader
- **To Replace**: ros2_mpu9250_driver → Tamagawa IMU driver (pending)
- **Camera**: USB cameras (no ZED submodule needed initially)
- **Vehicle Interface**: Will use Turing Drive packages (to be added)

Submodules:
- autoware_manual_control - Keyboard control interface
- autosdv_sensor_kit_launch - Sensor kit configurations
- gnss_locator - GNSS positioning
- ros2_mpu9250_driver - IMU driver (to be replaced with Tamagawa)
- ros-nmea-reader - NMEA GPS data parser

### Data Structure
- **data/COSS-map-planning/** - Practice map (from AutoSDV)
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

Sensor configurations are in `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/`

### Launch System
- Main launch uses Autoware's standard launch system
- Vehicle model: `autosdv_vehicle`
- Sensor model: `autosdv_sensor_kit`
- Default map: `./data/COSS-map-planning` (practice) → `./data/huaxia-campus/` (production)

### Launch Parameters for Golf Cart

#### LiDAR Configuration
```bash
# Velodyne VLP-32C (golf cart standard)
make launch ARGS="lidar_model:=vlp32c"
```

#### Camera Configuration
```bash
# USB cameras (current)
make launch ARGS="camera_model:=usb"

# Tier IV GMSL cameras (future)
make launch ARGS="camera_model:=tier4"

# No camera
make launch ARGS="camera_model:=none"
```

#### GNSS Configuration
```bash
# u-blox GNSS (golf cart standard)
make launch ARGS="gnss_receiver:=ublox"
```

#### Indoor Operation (No GPS)
For indoor testing without GNSS, use manual pose initialization via RViz:
```bash
# Disable GNSS for indoor operation
make launch ARGS="use_gnss:=false"
```

When running indoors:
1. The system uses NDT localization instead of GNSS
2. Use RViz's "2D Pose Estimate" tool to set initial vehicle position
3. Click and drag on the map to set pose and orientation
4. The `/initialpose` topic receives the manual pose input

#### Combined Configuration Example
```bash
# Golf cart standard configuration
make launch ARGS="lidar_model:=vlp32c camera_model:=usb gnss_receiver:=ublox"

# Indoor testing without GNSS
make launch ARGS="lidar_model:=vlp32c camera_model:=usb use_gnss:=false"
```

### Python Packages
Python packages follow ROS 2 conventions with:
- Standard setup.py/setup.cfg structure
- Test files for copyright, flake8, pep257
- Resource directories for ROS package discovery

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

## Important Notes
- **Target Platform**: Advantech Orin computer with JetPack 6.0 (NOT JP6.2 or newer)
- **Autoware Version**: 2025.02 at `/home/aeon/repos/autoware/2025.02-ws`
- Always source ROS environment: `source /opt/ros/humble/setup.bash`
- Requires ROS 2 Humble distribution
- Built for Ubuntu 22.04 with NVIDIA GPU support
- Uses colcon build system (not catkin)
- Symlink installs enabled for faster development iteration
- System monitor available at http://localhost:8080/ when launched
- **Migration**: See MIGRATION.md for team assignments and phase details

## System Management

### Systemd Service Integration
- AutoSDV now runs as a systemd user service for better process management
- Service is automatically installed on first `make launch`
- Provides clean shutdown with no orphan processes
- Logs accessible via `autosdv status` or `systemctl --user status autosdv`
- Service is NOT enabled for automatic startup by default (use `autosdv enable` if needed)

### Process Management
- The system handles multiple Ctrl-C presses gracefully
- First Ctrl-C: Graceful shutdown attempt
- Second Ctrl-C: Force shutdown all processes
- No orphan processes left after shutdown

### Known Issues and Solutions

#### Journal Logging
If `journalctl --user` doesn't show logs:
1. Run `sudo ./enable_journal.sh` to enable persistent journal storage
2. Log out and back in for group changes to take effect
3. Alternatively, use `systemctl --user status autosdv` to view logs

#### Network Monitor Error
- Network monitor may show socket connection errors
- This is a known non-critical issue related to AWS Greengrass
- Can be safely ignored - doesn't affect system functionality

## Velodyne VLP-32C LiDAR Integration

### Golf Cart Configuration
The golf cart uses Velodyne VLP-32C as the sole LiDAR sensor:
- Driver: Nebula (Autoware's universal LiDAR driver)
- Launch file: `autosdv_sensor_kit_launch/launch/lidar.launch.xml`
- Config: `autosdv_sensor_kit_launch/config/VLP32.param.yaml`
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
For faster startup and LiDAR-only operation, configure in `autosdv.launch.yaml`:
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
The golf cart uses Turing Drive vehicle interface packages (replacing AutoSDV custom PWM interface):
- **Status**: Pending - specifications and packages to be obtained from Turing Drive
- **Expected components**:
  - Vehicle interface node (control command → CAN/vehicle protocol)
  - Velocity/odometry reporting
  - Gear status management
  - Control mode management (manual/autonomous)
- **Integration files**: `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_launch/launch/vehicle_interface.launch.xml`

### AutoSDV PWM Interface (Reference Only)
The original AutoSDV system used custom PWM control:
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
  - `autosdv_sensor_kit_launch/launch/gnss.launch.xml`
  - `autosdv_sensor_kit_launch/config/ublox_gnss.param.yaml` (to be created)
- **Calibration**: Antenna position from base_link in `sensor_kit_calibration.yaml`

### Integration with Localization
- GNSS provides initial position for NDT localization
- Must work together with map for Autoware localization
- Coordinate with map preparation team

## Tamagawa IMU Integration

### Golf Cart Configuration
Replace MPU9250 with Tamagawa IMU (Autoware recommended):
- **Status**: Pending hardware and driver integration
- **Driver**: Tamagawa IMU ROS 2 driver (to be obtained)
- **Launch file**: `autosdv_sensor_kit_launch/launch/imu.launch.xml` (to be updated)
- **Calibration**: IMU corrector parameters in `sensor_kit_calibration.yaml`

### AutoSDV MPU9250 (Reference Only)
Original system used MPU9250:
- Driver: `ros2_mpu9250_driver` submodule
- Launch file includes imu_corrector and gyro_bias_estimator
- **Note**: Golf cart will replace with Tamagawa IMU

## Camera Configuration

### USB Cameras (Current)
The golf cart currently uses USB cameras:
- **Launch file**: `autosdv_sensor_kit_launch/launch/camera.launch.xml`
- **Camera model parameter**: `camera_model:=usb`
- USB cameras provide basic vision input for perception

### Tier IV GMSL Cameras (Future Upgrade)
Plan to upgrade to Tier IV GMSL cameras:
- Higher quality and reliability
- Better integration with Autoware
- **Camera model parameter**: `camera_model:=tier4` (when available)

### AutoSDV ZED Camera (Reference Only)
Original AutoSDV used ZED stereo cameras with object detection:
- ZED object detection integration available in codebase
- Launch file: `autosdv_sensor_kit_launch/launch/zed_with_object_detection.launch.xml`
- **Note**: Not used in golf cart configuration

## Golf Cart Migration Plan

**See MIGRATION.md** for comprehensive migration plan with 11 phases and team assignments.

### Key Migration Tasks
1. **Phase #1**: Advantech Orin computer setup (JP6.0, firmware, dependencies)
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

## Recent Updates (AutoSDV Legacy)
- With --symlink-install flag in colcon build, edits on yaml, xml, py source files immediately apply if the file was installed earlier. There is no need to rebuild. In case you create a new file, you need to run colcon build again to create the symlink in the install/ dir.
- Original AutoSDV system had PWM interface calibration, Robin-W LiDAR, ZED cameras - see sections above for reference