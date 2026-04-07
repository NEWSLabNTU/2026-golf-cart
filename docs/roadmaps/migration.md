# Golf Cart Migration Plan (DEPRECATED)

> **DEPRECATED**: This document is superseded by [ROADMAP.md](../../ROADMAP.md) in the project root. Do not use this file for current planning. It is kept for historical reference only.

This document outlines the migration plan from the Golf Cart platform to a golf cart autonomous driving system for 華夏科大 campus deployment.

## System Overview

### Target System Configuration
- **Platform**: Golf cart with AGX Orin (JetPack 6.0)
- **LiDAR**: Velodyne VLP-32C
- **GNSS**: u-blox receiver
- **IMU**: Tamagawa IMU
- **Cameras**: Multiple USB cameras → Tier IV cameras (future)
- **Vehicle Interface**: Turing Drive packages
- **Localization**: Autoware NDT scan matching
- **Planning**: Autoware built-in planner
- **Map**: 華夏科大 campus HDMap

## Key Changes from Golf Cart
1. Replace `golfcart_vehicle_interface` with Turing Drive vehicle interface packages
2. Replace COSS campus map with 華夏科大 campus HDMap
3. Use Autoware built-in NDT localization (not GNSS-only)
4. Use Autoware built-in planning (enable launch_planning)
5. Simplified sensor suite (VLP-32C, u-blox, Tamagawa IMU, USB cameras)

| Component             | Golf Cart                      | Golf Cart            |
|-----------------------|------------------------------|----------------------|
| **Platform**          | Custom small vehicle         | Golf cart            |
| **Compute**           | AGX Orin (JP5.x)             | AGX Orin (JP6.0)     |
| **LiDAR**             | Robin-W / VLP-32C / Cube1    | VLP-32C only         |
| **GNSS**              | Garmin / Septentrio / u-blox | u-blox only          |
| **IMU**               | MPU9250                      | Tamagawa             |
| **Camera**            | ZED stereo                   | USB → Tier IV        |
| **Vehicle Interface** | Custom PWM                   | Turing Drive         |
| **Map**               | COSS campus                  | 華夏科大 campus      |
| **Localization**      | GNSS or NDT                  | NDT (GNSS for init)  |
| **Planning**          | Disabled (manual)            | Enabled (autonomous) |

## Team Assignment

### Hardware Availability
- **Available now**: Velodyne VLP-32C LiDAR, USB cameras, Orin box (for testing), u-blox F9R RTK (from Allan & David), COSS map (for practice)
- **Waiting for**: u-blox F9P GNSS (production), Tamagawa IMU, Turing Drive packages, 華夏科大 HDMap (production)

**Note**: Use F9R + COSS map for GNSS and localization practice. Production system will use F9P + 華夏科大 map. Teams must coordinate GNSS + Map work since localization requires both.

### Team A: Allan & Liao (Sensor Focus)

**Immediate (Orin box):** #3 LiDAR, #6 Cameras, #2 Sensor verification, #4 GNSS (find Allan & David, learn F9R, test with COSS map)
**When hardware arrives:** #4 GNSS (switch to F9P + 華夏科大 map), #5 IMU, migrate to Advantech
**Coordinate with Team B:** GNSS + Map localization testing
**Shared:** #9 NDT Localization, #11 Integration & Testing

### Team B: Vincent & Darren (System Focus)

**Immediate:** #1 Advantech setup, #8 Map (practice with COSS map), Study #7 TD interface
**When specs/map arrive:** #7 TD Vehicle Interface, #8 HDMap (華夏科大), #10 Planning & Control
**Coordinate with Team A:** GNSS + Map localization testing
**Shared:** #9 NDT Localization, #11 Integration & Testing

---

## Phase #1: Advantech Orin Computer Setup

**Objective**: Prepare Advantech Orin-based computer with correct firmware and development environment.

**Work Items:**
- [ ] Flash new firmware on Advantech Orin computer
- [ ] Confirm system is running JetPack 6.0 (NOT JP6.2 or newer)
  - Check with: `cat /etc/nv_tegra_release` or `dpkg -l | grep nvidia-jetpack`
- [ ] Set up testing desk in room B04
  - Power supply
  - Network connection
  - Monitor, keyboard, mouse
  - Development tools
- [ ] Run `make setup` to install system dependencies via Ansible
  - Installs ROS 2 Humble
  - Installs Autoware dependencies
  - Configures system settings
- [ ] Verify Autoware 2025.02 at `/home/aeon/repos/autoware/2025.02-ws`
- [ ] Clone golf cart project and build: `make prepare && make build`

**Key Files:**
- `Makefile` - Build and setup commands
- `ansible/` - Ansible playbooks for system setup (if available)
- `src/*/package.xml` - ROS package dependencies

**Expected Result:**
- JetPack 6.0 confirmed
- Testing environment ready in room B04
- Clean build with no errors
- All system dependencies installed

**Note:** JetPack version is critical - Autoware 2025.02 compatibility must be verified with JP6.0.

---

## Phase #2: Sensor Verification

**Objective**: Verify all sensors are recognized and accessible by the system.

**Work Items:**
- [ ] Connect and test Velodyne VLP-32C network connectivity
- [ ] Connect and test u-blox GNSS serial port
- [ ] Connect and test Tamagawa IMU (check driver compatibility)
- [ ] Connect and test USB cameras (check device detection)
- [ ] Document sensor connection details (ports, IPs, device paths)

**Expected Result:** All sensors detected and accessible (may not have drivers configured yet).

---

## Phase #3: Velodyne VLP-32C LiDAR

**Objective**: Configure VLP-32C and verify point cloud output.

**Work Items:**
- [ ] Configure LiDAR network (check device IP)
- [ ] Mount LiDAR and measure position from base_link
- [ ] Update calibration parameters
- [ ] Test point cloud in RViz

**Key Files:**
- `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/lidar.launch.xml` - VLP-32C launch (lines 28-34)
- `src/sensor_kit/golfcart_sensor_kit_launch/config/VLP32.param.yaml` - LiDAR parameters
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/sensor_kit_calibration.yaml` - Calibration (lines 9-15)
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Set default `lidar_model:=vlp32c` (line 9)

**Expected Result:** Point cloud visible in RViz with correct orientation and position.

---

## Phase #4: u-blox GNSS

**Objective**: Configure u-blox GNSS for initial position and GNSS pose publishing.

**Practice Setup (F9R RTK with COSS map):**
- [ ] Find seniors Allan & David to learn u-blox F9R RTK usage
- [ ] Configure u-blox serial port and baud rate for F9R
- [ ] Test GNSS driver with F9R
- [ ] Learn u-blox driver configuration and Autoware integration
- [ ] Use COSS map for localization testing (coordinate with Team B on #8)
- [ ] Test GNSS + Map localization together

**Production Setup (F9P with 華夏科大 map):**
- [ ] Switch to u-blox F9P GNSS receiver
- [ ] Mount F9P antenna and measure position from base_link
- [ ] Update calibration parameters for F9P
- [ ] Test with 華夏科大 map (coordinate with Team B on #8)
- [ ] Verify GNSS fix and pose topics on production system

**Key Files:**
- `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/gnss.launch.xml` - u-blox configuration (lines 14-20)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/sensor_kit_calibration.yaml` - GNSS position (lines 41-47)
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Set default `gnss_receiver:=ublox` (line 19)
- External: `$(find-pkg-share ublox_gps)/c94_f9p_rover.yaml` - u-blox driver params

**Expected Result:** `/sensing/gnss/pose` and `/sensing/gnss/pose_with_covariance` topics publishing with valid fix. Localization works with map.

**Note**: GNSS and Map must work together for localization. Coordinate with Team B. Practice with F9R + COSS map, production with F9P + 華夏科大 map.

---

## Phase #5: Tamagawa IMU

**Objective**: Integrate Tamagawa IMU to replace MPU9250.

**Work Items:**
- [ ] Obtain Tamagawa IMU ROS 2 driver package/spec
- [ ] Replace MPU9250 with Tamagawa in imu.launch.xml
- [ ] Mount IMU and measure position from base_link
- [ ] Update calibration and corrector parameters
- [ ] Test IMU data publishing and gyro bias estimation

**Key Files:**
- `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/imu.launch.xml` - Replace MPU9250 driver (lines 9-18)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/sensor_kit_calibration.yaml` - IMU position (lines 34-40)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/imu_corrector.param.yaml` - IMU correction params
- `src/sensor_kit/golfcart_sensor_kit_launch/package.xml` - Add Tamagawa driver dependency
- Remove: `src/sensor_component/external/ros2_mpu9250_driver/` submodule

**Expected Result:** `/sensing/imu/imu_data` topic publishing with correct orientation.

---

## Phase #6: USB Cameras

**Objective**: Configure USB cameras for initial testing (upgrade to Tier IV later).

**Work Items:**
- [ ] Test USB camera detection on AGX Orin
- [ ] Configure device paths for 4 cameras (front/rear/left/right)
- [ ] Mount cameras and measure positions from base_link
- [ ] Update calibration parameters
- [ ] Perform camera calibration (intrinsic & extrinsic)
- [ ] Test image streaming

**Key Files:**
- `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/camera.launch.xml` - USB camera setup (lines 35-72)
- `src/sensor_kit/golfcart_sensor_kit_launch/config/usb_camera_*.yaml` - Individual camera configs
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/sensor_kit_calibration.yaml` - Camera positions (lines 48-75)
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Set default `camera_model:=usb` (line 14)
- Remove: `src/sensor_component/external/zed-ros2-wrapper/` submodule and ZED-related files

**Expected Result:** Camera images publishing to `/sensing/camera/{front,rear,left,right}/image_raw`.

**Future:** Add Tier IV C1 camera support by creating new launch configuration.

---

## Phase #7: Turing Drive Vehicle Interface

**Objective**: Replace Golf Cart vehicle interface with Turing Drive packages.

**Work Items:**
- [ ] Obtain Turing Drive vehicle interface packages and specifications
- [ ] Review Turing Drive package structure and topic interfaces
- [ ] Add Turing Drive packages to `src/vehicle/` directory
- [ ] Create launch file to integrate Turing Drive interface with Autoware
- [ ] Verify required topics: `/vehicle/status/velocity_status`, `/vehicle/status/control_mode`, etc.
- [ ] Test in simulation mode first (if available)
- [ ] Test on stationary vehicle
- [ ] Validate control command flow from Autoware to vehicle

**Key Files:**
- New: `src/vehicle/turing_drive_*` packages (to be added)
- Modify: `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Update `launch_vehicle` section
- Modify: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_launch/launch/vehicle_interface.launch.xml` - Replace with Turing Drive launch
- Update: `src/vehicle/golfcart_vehicle_description/config/vehicle_info.param.yaml` - Golf cart dimensions
- Reference: `src/vehicle/golfcart_vehicle_interface/*` - Golf Cart interface for comparison

**Expected Result:**
- Vehicle control commands accepted from `/control/command/control_cmd`
- Vehicle status published to `/vehicle/status/*` topics
- Speedometer data available for NDT localization

**Note:** Actual integration details depend on Turing Drive package specifications.

---

## Phase #8: 華夏科大 Campus HDMap

**Objective**: Integrate HDMap to enable NDT localization and planning.

**Practice Setup (COSS map):**
- [ ] Use existing COSS map in `data/COSS-map-planning/` for learning
- [ ] Study map structure: Lanelet2 vector map + PCD point cloud map
- [ ] Learn map loading in Autoware
- [ ] Test map loading in RViz
- [ ] Coordinate with Team A on #4 for GNSS + Map localization testing
- [ ] Practice localization with F9R GNSS + COSS map

**Production Setup (華夏科大 map):**
- [ ] Obtain 華夏科大 campus HDMap (Lanelet2 format) from Turing Drive
- [ ] Obtain or create point cloud map for NDT localization
- [ ] Validate map structure and coordinate system
- [ ] Place in `data/huaxia-campus/` directory
- [ ] Update default map path in launch configuration
- [ ] Test with F9P GNSS (coordinate with Team A on #4)
- [ ] Verify localization works on production map

**Key Files:**
- `data/COSS-map-planning/` - Practice map (already available)
- `data/huaxia-campus/` (new directory) - Production map
  - `lanelet2_map.osm` - Vector map for planning
  - `pointcloud_map.pcd` - Point cloud map for NDT localization
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Update `map_path` parameter (line 51)

**Expected Result:** Map loads successfully, visible in RViz with correct coordinate frame. GNSS + Map localization works.

**Note**: Map and GNSS must work together for localization. Coordinate with Team A. Practice with COSS map, production with 華夏科大 map.

---

## Phase #9: NDT Localization

**Objective**: Configure Autoware's built-in NDT localization with speedometer, IMU, and GNSS initialization.

**Work Items:**
- [ ] Verify speedometer data from Turing Drive vehicle interface
- [ ] Configure NDT scan matcher parameters for VLP-32C
- [ ] Configure EKF localizer to fuse NDT + IMU + speedometer
- [ ] Set GNSS for initial pose estimate only
- [ ] Tune NDT parameters (resolution, iterations, transformation_epsilon)
- [ ] Test localization accuracy with stationary vehicle
- [ ] Test localization while driving

**Key Files:**
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Set `pose_source:=ndt`, `twist_source:=gyro_odom` (lines 108-111)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/ndt_scan_matcher.param.yaml` - NDT tuning
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/ekf_localizer.param.yaml` - EKF fusion parameters
- Autoware reference: `$(find-pkg-share autoware_launch)/config/localization/` - Default NDT parameters

**Expected Result:**
- Stable localization on HDMap with < 10cm accuracy
- `/localization/kinematic_state` publishing at stable rate
- Pose drift < 1m over 100m drive

**Note:** NDT parameters must be tuned based on point cloud density and map quality. Start with conservative values.

---

## Phase #10: Planning and Control

**Objective**: Enable Autoware's built-in planning component for autonomous navigation.

**Work Items:**
- [ ] Enable planning module in launch configuration
- [ ] Measure golf cart dimensions (wheelbase, width, overhang)
- [ ] Update vehicle_info.param.yaml with accurate dimensions
- [ ] Configure MPC controller parameters
- [ ] Test route planning on HDMap
- [ ] Test obstacle avoidance with LiDAR perception
- [ ] Tune control gains for smooth driving

**Key Files:**
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Set `launch_planning:=true` (line 78)
- `src/vehicle/golfcart_vehicle_description/config/vehicle_info.param.yaml` - Golf cart dimensions
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_vehicle/mpc.param.yaml` - MPC tuning
- Autoware reference: `$(find-pkg-share autoware_launch)/config/planning/` - Default planning parameters

**Expected Result:**
- Successful route planning from point A to B
- Smooth trajectory following
- Obstacle detection and avoidance
- Emergency stop when obstacles too close

---

## Phase #11: System Integration and Testing

**Objective**: Integrate all components and validate complete system.

**Work Items:**
- [ ] Test complete pipeline: sensors → localization → planning → control → vehicle
- [ ] Configure perception for campus environment
- [ ] Set safety parameters (max speed, emergency stop distance)
- [ ] Test in parking lot at low speed (<5 km/h)
- [ ] Test waypoint following on campus roads
- [ ] Validate emergency stop behavior
- [ ] Monitor system performance and resource usage

**Key Files:**
- `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` - Final system configuration
- `src/launcher/golfcart_launch/rviz/golfcart.rviz` - Visualization configuration
- `src/system/autosdv_system_monitor/` - System monitoring

**Expected Result:**
- Complete autonomous driving capability on 華夏科大 campus
- Safe operation with proper emergency handling
- System runs reliably for 30+ minutes

---

## Important Notes

### File Modification Strategy
- Files in `src/param/autoware_individual_params/` contain most tunable parameters
- Launch files in `src/sensor_kit/` and `src/vehicle/` handle hardware integration
- Main launch file `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` orchestrates everything
- With `--symlink-install`, editing `.yaml`, `.xml`, and `.py` files takes effect immediately (no rebuild needed for existing files)

### Key Topics to Monitor
- `/sensing/lidar/*/pointcloud` - LiDAR data
- `/sensing/gnss/pose` - GNSS position
- `/sensing/imu/imu_data` - IMU data
- `/localization/kinematic_state` - Vehicle pose from NDT
- `/planning/scenario_planning/trajectory` - Planned path
- `/control/command/control_cmd` - Control commands to vehicle
- `/vehicle/status/velocity_status` - Vehicle speed feedback

## References

- **Golf Cart**: https://github.com/NEWSLabNTU/Golf Cart
- **Autoware Documentation**: https://autowarefoundation.github.io/autoware-documentation/
- **ROS 2 Humble**: https://docs.ros.org/en/humble/
