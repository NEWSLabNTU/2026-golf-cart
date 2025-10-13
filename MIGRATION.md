# Golf Cart Migration Plan

This document outlines the migration plan from the AutoSDV platform to a golf cart autonomous driving system. The migration is organized into phases with specific work items and file references for educational purposes.

## System Overview

### Source System (AutoSDV)
- Small-scale autonomous vehicle platform
- Multiple sensor configurations (Robin-W, Velodyne 32C, Blickfeld Cube1)
- ZED stereo camera with object detection
- Garmin/Septentrio/u-blox GNSS support
- MPU9250 IMU
- Custom vehicle interface with PWM control

### Target System (Golf Cart)
- Golf cart platform running on AGX Orin with JetPack 6.0
- Single LiDAR: Velodyne VLP-32C
- GNSS: u-blox receiver
- IMU: Tamagawa IMU (Autoware recommended)
- Cameras: Multiple USB cameras → Tier IV cameras (future)
- Golf cart vehicle interface (to be developed)

## Migration Phases

---

## Phase 1: Core System Setup and Infrastructure

**Objective**: Set up the development environment and verify basic system functionality.

### Work Items

#### 1.1 Development Environment Setup
- [ ] Install JetPack 6.0 on AGX Orin
- [ ] Set up ROS 2 Humble
- [ ] Clone and build Autoware 2025.02 workspace
- [ ] Verify Autoware installation

**Files to check:**
- `Makefile` - Build and setup commands
- `.github/workflows/` - CI/CD configurations (if any)

#### 1.2 Project Structure Migration
- [ ] Review and update project documentation
- [ ] Clean up AutoSDV-specific references
- [ ] Update CLAUDE.md with golf cart specifics
- [ ] Set up version control for golf cart project

**Files to check:**
- `README.md` - Project overview
- `CLAUDE.md` - Technical documentation
- `LICENSE.txt` - License information

#### 1.3 Build System Verification
- [ ] Test `make prepare` command
- [ ] Test `make build` command
- [ ] Verify colcon build completes successfully
- [ ] Check for missing dependencies

**Files to check:**
- `Makefile` - Build targets
- `src/*/package.xml` - ROS package dependencies
- `src/*/CMakeLists.txt` - Build configurations

---

## Phase 2: Sensor Integration - LiDAR

**Objective**: Configure and test Velodyne VLP-32C LiDAR as the primary 3D sensor.

### Work Items

#### 2.1 LiDAR Driver Configuration
- [ ] Review Velodyne VLP-32C configuration in AutoSDV
- [ ] Update network configuration for VLP-32C
- [ ] Configure LiDAR IP address and port
- [ ] Test LiDAR driver standalone

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/lidar.launch.xml` (lines 28-34)
- `src/sensor_kit/autosdv_sensor_kit_launch/config/VLP32.param.yaml`
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (line 8-10, default lidar_model)

#### 2.2 LiDAR Calibration
- [ ] Mount VLP-32C on golf cart
- [ ] Measure sensor position relative to base_link
- [ ] Update sensor_kit_calibration.yaml
- [ ] Verify point cloud coordinate system

**Files to check:**
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/sensor_kit_calibration.yaml` (lines 9-15)
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_description/urdf/sensor_kit.xacro`

#### 2.3 Point Cloud Processing
- [ ] Test point cloud preprocessing pipeline
- [ ] Configure filtering parameters
- [ ] Verify pointcloud_container integration
- [ ] Test visualization in RViz

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/pointcloud_preprocessor.launch.py`
- `src/sensor_kit/autosdv_sensor_kit_launch/config/pointcloud_preprocessor.param.yaml`

#### 2.4 Remove Unused LiDAR Support
- [ ] Remove Robin-W specific code (optional cleanup)
- [ ] Remove Blickfeld Cube1 specific code (optional cleanup)
- [ ] Update launch files to default to VLP-32C

**Files to check:**
- `src/sensor_component/external/seyond_ros_driver/` - Robin-W driver
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/cube1.launch.py`
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/seyond_robin_w.launch.xml`

---

## Phase 3: Sensor Integration - GNSS

**Objective**: Configure u-blox GNSS receiver for outdoor positioning.

### Work Items

#### 3.1 u-blox Driver Configuration
- [ ] Review existing u-blox support in AutoSDV
- [ ] Install u-blox ROS 2 driver dependencies
- [ ] Configure serial port and baud rate
- [ ] Test GNSS data reception

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/gnss.launch.xml` (lines 14-20)
- u-blox configuration file: `$(find-pkg-share ublox_gps)/c94_f9p_rover.yaml` (external to project)

#### 3.2 GNSS Calibration
- [ ] Mount u-blox antenna on golf cart
- [ ] Measure antenna position relative to base_link
- [ ] Update sensor_kit_calibration.yaml
- [ ] Configure GNSS-to-MGRS conversion

**Files to check:**
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/sensor_kit_calibration.yaml` (lines 41-47)
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/gnss.launch.xml` (lines 40-50)

#### 3.3 GNSS Testing
- [ ] Test static position accuracy
- [ ] Verify GNSS pose topic publishing
- [ ] Test GNSS/IMU fusion
- [ ] Validate coordinate transformations

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 22-25, gnss_receiver parameter)

#### 3.4 Remove Unused GNSS Support
- [ ] Remove Garmin GNSS code (optional cleanup)
- [ ] Remove Septentrio GNSS code (optional cleanup)
- [ ] Update default gnss_receiver parameter to "ublox"

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/gnss.launch.xml` (lines 22-38)

---

## Phase 4: Sensor Integration - IMU

**Objective**: Replace MPU9250 IMU with Tamagawa IMU (Autoware recommended).

### Work Items

#### 4.1 Tamagawa IMU Driver Integration
- [ ] Research Tamagawa IMU ROS 2 driver
- [ ] Add Tamagawa driver as dependency
- [ ] Create launch file for Tamagawa IMU
- [ ] Configure IMU serial communication

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/imu.launch.xml` (entire file - needs major changes)
- `src/sensor_kit/autosdv_sensor_kit_launch/package.xml` - Add Tamagawa driver dependency

#### 4.2 Remove MPU9250 Support
- [ ] Remove MPU9250 driver references
- [ ] Remove MPU9250 launch configurations
- [ ] Update imu.launch.xml for Tamagawa
- [ ] Remove MPU9250 parameter files

**Files to check:**
- `src/sensor_component/external/ros2_mpu9250_driver/` - MPU9250 driver (submodule to remove)
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/imu.launch.xml` (lines 9-18)

#### 4.3 IMU Calibration
- [ ] Mount Tamagawa IMU on golf cart
- [ ] Measure IMU position relative to base_link
- [ ] Update sensor_kit_calibration.yaml
- [ ] Configure IMU corrector parameters

**Files to check:**
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/sensor_kit_calibration.yaml` (lines 34-40)
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/imu_corrector.param.yaml`

#### 4.4 IMU Testing
- [ ] Test IMU data publishing
- [ ] Verify IMU orientation
- [ ] Test gyro bias estimation
- [ ] Validate IMU/GNSS fusion for localization

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/imu.launch.xml` (lines 20-30)

---

## Phase 5: Sensor Integration - Cameras

**Objective**: Configure USB cameras for perception (with future upgrade path to Tier IV cameras).

### Work Items

#### 5.1 USB Camera Setup (Initial Phase)
- [ ] Review existing USB camera configuration
- [ ] Test USB camera detection on AGX Orin
- [ ] Configure camera device paths
- [ ] Set up 4-camera configuration (front, rear, left, right)

**Files to check:**
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/camera.launch.xml` (lines 35-72)
- `src/sensor_kit/autosdv_sensor_kit_launch/config/usb_camera_*.yaml`

#### 5.2 Camera Calibration
- [ ] Mount cameras on golf cart
- [ ] Measure camera positions relative to base_link
- [ ] Update sensor_kit_calibration.yaml
- [ ] Perform intrinsic calibration for each camera
- [ ] Perform extrinsic calibration

**Files to check:**
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/sensor_kit_calibration.yaml` (lines 48-75)
- `src/launcher/autosdv_launch/launch/camera_calibration.launch.xml`

#### 5.3 USB Camera Testing
- [ ] Test camera image streaming
- [ ] Verify camera topics
- [ ] Test camera visualization in RViz
- [ ] Validate camera synchronization

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 12-15, camera_model parameter)

#### 5.4 Remove ZED Camera Support
- [ ] Remove ZED camera dependencies
- [ ] Remove ZED object detection converter
- [ ] Update default camera_model to "usb"
- [ ] Clean up ZED-specific configurations

**Files to check:**
- `src/sensor_component/external/zed-ros2-wrapper/` - ZED driver (submodule to remove)
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/zed_with_object_detection.launch.xml`
- `src/sensor_kit/autosdv_sensor_kit_launch/autosdv_sensor_kit_launch/launch/camera.launch.xml` (lines 20-33)
- `src/sensor_kit/autosdv_sensor_kit_launch/config/zed_object_detection.yaml`
- `src/sensor_kit/autosdv_sensor_kit_launch/scripts/zed_to_autoware_converter.py`

#### 5.5 Tier IV Camera Upgrade (Future)
- [ ] Research Tier IV C1 camera specifications
- [ ] Plan camera mounting positions
- [ ] Create Tier IV camera launch configuration
- [ ] Add Tier IV camera support alongside USB cameras

**Files to prepare:**
- New launch file: `tier4_camera.launch.xml`
- New config files for Tier IV cameras
- Update `camera.launch.xml` to support "tier4" camera_model

---

## Phase 6: Vehicle Interface Development

**Objective**: Develop golf cart-specific vehicle interface to replace AutoSDV interface.

### Work Items

#### 6.1 Golf Cart Hardware Analysis
- [ ] Document golf cart drive-by-wire system
- [ ] Identify control interfaces (CAN, PWM, etc.)
- [ ] Determine steering, throttle, brake control methods
- [ ] Map Autoware control commands to golf cart actuation

**Reference files (AutoSDV interface):**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_launch/launch/vehicle_interface.launch.xml`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/actuator.py`

#### 6.2 Actuator Node Development
- [ ] Create golf cart actuator node
- [ ] Implement steering control
- [ ] Implement throttle control
- [ ] Implement brake control
- [ ] Add safety limits and emergency stop

**Files to create/modify:**
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/actuator.py` (new)
- `src/vehicle/golfcart_vehicle_interface/params/actuator.yaml` (new)

**Reference files:**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/actuator.py`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/params/actuator.yaml`

#### 6.3 Velocity Report Node
- [ ] Create velocity report node for golf cart
- [ ] Implement wheel speed sensor reading
- [ ] Implement velocity calculation
- [ ] Publish velocity status to Autoware

**Files to create/modify:**
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/velocity_report.py` (new)

**Reference files:**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/velocity_report.py`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/params/velocity_report.yaml`

#### 6.4 Vehicle Status Nodes
- [ ] Implement gear manager for golf cart
- [ ] Implement control mode manager
- [ ] Implement steering status reporter
- [ ] Implement signal manager (turn signals, hazards)

**Files to create/modify:**
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/gear_manager.py` (new)
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/control_mode_manager.py` (new)
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/steering_status.py` (new)
- `src/vehicle/golfcart_vehicle_interface/golfcart_vehicle_interface/signal_manager.py` (new)

**Reference files:**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/gear_manager.py`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/control_mode_manager.py`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/steering_status.py`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_interface/autosdv_vehicle_interface/signal_manager.py`

#### 6.5 Vehicle Description
- [ ] Create golf cart URDF model
- [ ] Define vehicle dimensions
- [ ] Define sensor mounting points
- [ ] Create vehicle visualization meshes (optional)

**Files to create/modify:**
- `src/vehicle/golfcart_vehicle_description/urdf/golfcart.xacro` (new)
- `src/vehicle/golfcart_vehicle_description/config/vehicle_info.param.yaml` (new)

**Reference files:**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_description/urdf/vehicle.xacro`
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_description/config/vehicle_info.param.yaml`

#### 6.6 Vehicle Interface Testing
- [ ] Test vehicle interface in simulation mode (dry_run)
- [ ] Test on stationary golf cart
- [ ] Test low-speed manual control
- [ ] Test emergency stop functionality
- [ ] Validate Autoware control integration

**Files to check:**
- `src/vehicle/autosdv_vehicle_launch/autosdv_vehicle_launch/launch/vehicle_interface.launch.xml` (line 5, is_simulation parameter)
- `src/vehicle/autosdv_vehicle_launch/scripts/*.py` - Testing scripts

---

## Phase 7: System Integration and Configuration

**Objective**: Integrate all components and configure the complete system.

### Work Items

#### 7.1 Launch System Configuration
- [ ] Update main launch file for golf cart
- [ ] Set default sensor parameters
- [ ] Configure perception pipeline
- [ ] Configure localization parameters
- [ ] Configure planning parameters

**Files to modify:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` - Main launch file (entire file)
- Rename to `golfcart.launch.yaml` (optional)

#### 7.2 Parameter Tuning
- [ ] Create golf cart parameter directory
- [ ] Copy and adapt AutoSDV parameters
- [ ] Tune localization parameters (NDT, EKF)
- [ ] Tune control parameters (MPC, pure pursuit)
- [ ] Tune perception parameters

**Files to create/modify:**
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/` (new directory)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_vehicle/` (new directory)

**Reference files:**
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_sensor_kit/*`
- `src/param/autoware_individual_params/individual_params/config/default/autosdv_vehicle/*`

#### 7.3 System Monitor Configuration
- [ ] Update system monitor for golf cart
- [ ] Configure topic monitoring
- [ ] Set up health checks
- [ ] Configure web dashboard

**Files to check:**
- `src/system/autosdv_system_monitor/` - System monitoring package
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 123-126)

#### 7.4 RViz Configuration
- [ ] Create golf cart RViz configuration
- [ ] Add sensor visualizations
- [ ] Add planning visualization
- [ ] Add diagnostic panels

**Files to create/modify:**
- `src/launcher/autosdv_launch/rviz/golfcart.rviz` (new, or modify autosdv.rviz)

**Reference files:**
- `src/launcher/autosdv_launch/rviz/autosdv.rviz`

---

## Phase 8: Mapping and Localization

**Objective**: Create maps and configure localization for the golf cart operating environment.

### Work Items

#### 8.1 Mapping
- [ ] Set up mapping mode
- [ ] Create vector map (Lanelet2) for operating area
- [ ] Create point cloud map for localization
- [ ] Validate map quality

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (line 50-51, map_path parameter)
- `data/COSS-map-planning/` - Example map structure

#### 8.2 Localization Configuration
- [ ] Configure NDT scan matching parameters
- [ ] Configure EKF fusion parameters
- [ ] Tune pose initialization
- [ ] Test localization accuracy

**Files to check:**
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/ndt_scan_matcher.param.yaml` (new)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/ekf_localizer.param.yaml` (new)
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 107-111, pose_source and twist_source)

#### 8.3 Indoor Operation Support
- [ ] Test mapless mode for indoor operation
- [ ] Configure manual pose initialization
- [ ] Test operation without GNSS

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 28-30, use_mapless_mode)
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 133-140, static TF publisher)

---

## Phase 9: Perception Configuration

**Objective**: Configure perception pipeline for golf cart environment.

### Work Items

#### 9.1 Object Detection Configuration
- [ ] Configure LiDAR-based object detection
- [ ] Test object detection in parking lot environment
- [ ] Tune detection parameters
- [ ] Validate detection performance

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 83-96, perception parameters)
- `data/models/lidar_centerpoint/` - ML models

#### 9.2 Camera-Based Perception (Future)
- [ ] Plan camera-based object detection
- [ ] Integrate camera detection with LiDAR
- [ ] Configure sensor fusion
- [ ] Test multi-sensor perception

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 33-35, enable_zed_object_detection)

---

## Phase 10: Control and Planning

**Objective**: Configure control and planning modules for golf cart characteristics.

### Work Items

#### 10.1 Vehicle Model Calibration
- [ ] Measure golf cart dimensions
- [ ] Measure wheelbase and track width
- [ ] Determine steering ratio
- [ ] Measure weight and center of gravity

**Files to create/modify:**
- `src/vehicle/golfcart_vehicle_description/config/vehicle_info.param.yaml` (new)

#### 10.2 Control Parameter Tuning
- [ ] Tune MPC controller parameters
- [ ] Tune pure pursuit parameters
- [ ] Tune velocity controller
- [ ] Test control stability

**Files to create/modify:**
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_vehicle/mpc.param.yaml` (new)
- `src/param/autoware_individual_params/individual_params/config/default/golfcart_vehicle/pure_pursuit.param.yaml` (new)

#### 10.3 Planning Configuration
- [ ] Enable planning module
- [ ] Configure route planning
- [ ] Configure behavior planning
- [ ] Configure obstacle avoidance

**Files to check:**
- `src/launcher/autosdv_launch/launch/autosdv.launch.yaml` (lines 77-78, launch_planning currently false)

#### 10.4 Safety Configuration
- [ ] Configure emergency stop conditions
- [ ] Configure collision detection
- [ ] Configure safety speed limits
- [ ] Test safety behaviors

---

## Phase 11: Testing and Validation

**Objective**: Comprehensive testing and validation of the complete system.

### Work Items

#### 11.1 Unit Testing
- [ ] Test individual sensor drivers
- [ ] Test vehicle interface nodes
- [ ] Test localization accuracy
- [ ] Test perception accuracy

#### 11.2 Integration Testing
- [ ] Test sensor fusion
- [ ] Test end-to-end pipeline
- [ ] Test in various lighting conditions
- [ ] Test in various weather conditions

#### 11.3 Field Testing
- [ ] Test in parking lot (low speed)
- [ ] Test in controlled outdoor environment
- [ ] Test waypoint following
- [ ] Test obstacle avoidance
- [ ] Test emergency stop procedures

#### 11.4 Performance Optimization
- [ ] Profile system resource usage
- [ ] Optimize compute-intensive nodes
- [ ] Reduce latency
- [ ] Improve real-time performance

---

## Phase 12: Documentation and Deployment

**Objective**: Finalize documentation and prepare for deployment.

### Work Items

#### 12.1 Documentation
- [ ] Complete technical documentation
- [ ] Create operator manual
- [ ] Document calibration procedures
- [ ] Document troubleshooting guide

#### 12.2 Deployment Preparation
- [ ] Create installation guide
- [ ] Set up systemd service for autostart
- [ ] Configure logging and diagnostics
- [ ] Prepare backup and recovery procedures

#### 12.3 Training
- [ ] Train operators on system usage
- [ ] Train on emergency procedures
- [ ] Train on basic troubleshooting
- [ ] Document training materials

---

## Key Differences: AutoSDV vs Golf Cart

| Component | AutoSDV | Golf Cart |
|-----------|---------|-----------|
| **Platform** | Custom small vehicle | Golf cart |
| **Compute** | AGX Orin (JP5.x) | AGX Orin (JP6.0) |
| **LiDAR** | Robin-W / VLP-32C / Cube1 | VLP-32C only |
| **GNSS** | Garmin / Septentrio / u-blox | u-blox only |
| **IMU** | MPU9250 | Tamagawa |
| **Camera** | ZED stereo | USB cameras → Tier IV |
| **Vehicle Interface** | Custom PWM (370=stop) | TBD (golf cart specific) |
| **Autoware Version** | 2025.02 | 2025.02 |

## Critical Dependencies

### External ROS 2 Packages Required
- `velodyne_driver` / `nebula_ros` - VLP-32C driver
- `ublox_gps` - u-blox GNSS driver
- Tamagawa IMU driver (to be determined)
- `usb_cam` or `gscam` - USB camera driver
- `autoware` - Autoware.universe packages

### Hardware Dependencies
- Golf cart with drive-by-wire capability
- CAN bus or PWM interface for vehicle control
- Velodyne VLP-32C LiDAR
- u-blox GNSS receiver with antenna
- Tamagawa IMU
- USB cameras (4x)
- AGX Orin with adequate power supply

## Risk Assessment

### High Risk Items
1. **Vehicle interface compatibility** - Golf cart control system may differ significantly from AutoSDV
2. **IMU driver availability** - Tamagawa IMU ROS 2 driver may not be readily available
3. **Real-time performance on JP6.0** - Newer JetPack version may have different performance characteristics

### Medium Risk Items
1. **Camera calibration quality** - USB cameras may have lower quality than ZED
2. **GNSS accuracy** - u-blox receiver quality depends on model and antenna placement
3. **Parameter tuning** - Golf cart dynamics may require extensive tuning

### Mitigation Strategies
- Start with simulation mode for vehicle interface testing
- Have fallback IMU options (MPU9250, other supported IMUs)
- Plan for iterative parameter tuning with extensive field testing
- Use AutoSDV codebase as reference for all developments

## Success Criteria

### Phase Completion Criteria
- Each sensor publishes data at expected rate
- All coordinate transformations are correct
- Localization achieves < 10cm accuracy (with good GNSS)
- Object detection identifies obstacles reliably
- Vehicle responds correctly to control commands
- System runs reliably for 30+ minutes continuously
- Emergency stop functions correctly in all scenarios

### System-Level Criteria
- Complete autonomous waypoint following in test environment
- Safe obstacle avoidance behavior
- Graceful degradation when sensors fail
- System monitoring and logging functional
- Documentation complete and validated

## Timeline Estimate

| Phase | Estimated Duration | Dependencies |
|-------|-------------------|--------------|
| Phase 1: Setup | 1 week | Hardware availability |
| Phase 2: LiDAR | 1 week | Phase 1 |
| Phase 3: GNSS | 1 week | Phase 1 |
| Phase 4: IMU | 1-2 weeks | Phase 1, driver availability |
| Phase 5: Cameras | 2 weeks | Phase 1 |
| Phase 6: Vehicle Interface | 3-4 weeks | Golf cart availability |
| Phase 7: Integration | 2 weeks | Phases 2-6 |
| Phase 8: Mapping | 1 week | Phase 7 |
| Phase 9: Perception | 1 week | Phase 7 |
| Phase 10: Control | 2 weeks | Phase 8 |
| Phase 11: Testing | 3-4 weeks | Phase 10 |
| Phase 12: Documentation | 1 week | Phase 11 |

**Total Estimated Duration: 18-22 weeks**

Note: This timeline assumes part-time development (20 hours/week). Full-time development could reduce duration by 50%.

## References

### AutoSDV Resources
- AutoSDV GitHub: https://github.com/NEWSLabNTU/AutoSDV
- AutoSDV Book: https://newslabntu.github.io/autosdv-book/

### Autoware Resources
- Autoware Documentation: https://autowarefoundation.github.io/autoware-documentation/
- Autoware Universe: https://github.com/autowarefoundation/autoware.universe
- Autoware Core: https://github.com/autowarefoundation/autoware.core

### Sensor Resources
- Velodyne VLP-32C: https://velodynelidar.com/products/puck-hi-res/
- u-blox GNSS: https://www.u-blox.com/
- ROS 2 Humble: https://docs.ros.org/en/humble/

## Notes for Educational Use

This migration plan is designed to be educational. Each phase includes:
- Clear objectives
- Specific work items with checkboxes for tracking
- File references with line numbers where applicable
- Comparison between source (AutoSDV) and target (Golf Cart) systems

Students and developers can use this document to:
1. Understand the structure of an Autoware-based autonomous system
2. Learn how to adapt a reference platform to new hardware
3. Identify which files control which system behaviors
4. Understand dependencies between different system components
5. Learn proper testing and validation procedures

The file references are provided so that you can:
- Study how AutoSDV implemented each feature
- Use AutoSDV code as a reference for your implementation
- Understand parameter configurations
- Learn ROS 2 launch file structure
- See working examples of sensor integration

Remember: Always test in simulation mode first, then on a stationary vehicle, before attempting movement.
