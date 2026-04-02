# Golf Cart Autonomous Driving Roadmap

**Teams:**
- **Group X**: Liao & Allen
- **Group Y**: Darren & James

**Goal**: Full autonomous driving on the golf cart at NTU campus.

**Origin**: This project was forked from the [AutoSDV](https://github.com/NEWSLabNTU/autosdv) small-vehicle project. We reuse the infrastructure but must clean up components that don't apply to the golf cart.

---

## Phase 1: Cleanup & Foundation

Strip out AutoSDV leftovers and establish the golf cart baseline. Both groups work in parallel.

### Track A — Sensor Kit Cleanup & LiDAR
1. **Remove unused sensor submodules & launch paths** — The sensor kit carries AutoSDV baggage:
   - Remove `seyond_ros_driver` submodule (Robin-W/Seyond LiDAR, not used on golf cart)
   - Remove Cube1 and Robin-W code paths from `lidar.launch.xml` (lines 17-26), keep only `vlp32c`
   - Remove ZED camera references from `sensor_kit.xacro` (lines 89-111, `zed_wrapper` include)
   - Clean up `scripts/check/sensors.launch.xml` — it still launches Seyond driver and old camera config
   - Remove stale rviz configs (`scripts/check/seyond.rviz`)
2. **Velodyne VLP-32C bring-up** — Verify network config (192.168.7.10), confirm point cloud in RViz, measure mount position and update `sensor_kit_calibration.yaml` (currently all zeros).
3. **u-blox GNSS bring-up** — Configure serial port, test fix, verify `/sensing/gnss/pose` topic. Install udev rules.
4. **IMU bring-up** — Integrate Tamagawa IMU driver, replace MPU9250 references in `imu.launch.xml`, verify `/sensing/imu/imu_data`.

### Track B — Tooling & Infrastructure
1. **Clean up system-level AutoSDV remnants** — Review and decide on:
   - `src/system/autosdv_runtime` submodule — rename or replace for golf cart?
   - `src/system/autosdv_system_monitor` submodule — same
   - Any AutoSDV-specific configs in `src/launcher/golfcart_launch/`
2. **Setup script overhaul** — Update `setup.sh` / `setup/` to install golf cart dependencies (play_launch, Nebula driver, u-blox driver, Tamagawa driver, TIER IV camera driver). Remove stale optional components from AutoSDV era.
3. **Justfile recipes for outdoor ops** — Ensure `play_launch` is the default runtime (already is). Add recipes: `just check-sensors` (health check), verify `just bag-record` covers all needed topics. Clean up `launch-zed` recipe (ZED not used).
4. **Version control setup** — Create project branches in all forked submodule repos. Currently several submodules point to `NEWSLabNTU` forks — establish a consistent branching convention (e.g., `2026-golfcart` branches). Document in README or CONTRIBUTING.
5. **Vehicle description update** — Measure golf cart dimensions (wheelbase, width, overhang, tire radius) and update `vehicle_info.param.yaml`. Replace the Lexus mesh (`golfcart_vehicle_description/mesh/lexus.dae`) if a golf cart model is available.

**Phase 1 exit criteria**: No Seyond/Robin-W/Cube1/ZED/MPU9250 code paths remain. LiDAR, GNSS, and IMU publish valid ROS topics. `just build` succeeds cleanly. Submodule branches established.

---

## Phase 2: DBW Interface, Maps & Cameras

### Track A — TIER IV Camera Setup
1. **Mount three TIER IV cameras** — Two front-facing, one rear-facing. Measure and record mount positions from `base_link`.
2. **Update sensor kit description** — Replace ZED xacro entries in `sensor_kit.xacro` with three TIER IV C1 camera frames (`camera_front_left`, `camera_front_right`, `camera_rear`). Update `sensor_kit_calibration.yaml`.
3. **Camera launch file** — Rewrite `camera.launch.xml` to launch three TIER IV camera nodes with correct device paths and intrinsic calibration.
4. **Verify image streaming** — Confirm all three cameras publish to `/sensing/camera/*/image_raw`.

### Track B — Turing Drive DBW & Map Acquisition
1. **Request Turing Drive DBW package** — Contact Turing Drive to deliver the drive-by-wire interface package. This package provides wheel velocity and steering angle feedback, which are **required** for NDT localization (twist estimation). Block on this.
2. **Integrate DBW interface** — Replace `golfcart_vehicle_interface` (AutoSDV custom PWM actuator/velocity_report) with Turing Drive package. Update `vehicle_interface.launch.xml`. Verify Autoware-expected topics: `/vehicle/status/velocity_status`, `/vehicle/status/steering_status`, `/vehicle/status/control_mode`.
3. **Obtain NTU campus maps from Turing Drive** — Request Lanelet2 vector map (`.osm`) and point cloud map (`.pcd`). Place in `data/ntu-campus/`.
4. **Map audit** — Verify coordinate system, check lanelet connectivity, inspect PCD density and coverage. Run `just launch-sim-planning` with NTU map to verify Autoware plans a valid route.

**Phase 2 exit criteria**: Three cameras stream images. DBW interface publishes velocity and steering feedback. NTU map loads and passes planning simulation smoke test.

---

## Phase 3: Localization & Calibration

### Track A — LiDAR-Camera Calibration
1. **Set up LCTK** — Clone and build [NEWSLabNTU/LCTK](https://github.com/NEWSLabNTU/LCTK). Prepare calibration targets (checkerboard or ArUco).
2. **Perform LiDAR-to-camera extrinsic calibration** — Calibrate VLP-32C against each of the three TIER IV cameras.
3. **Write calibration results** — Update `sensor_kit_calibration.yaml` with calibrated extrinsics. Verify point cloud to image projection overlay in RViz.

### Track B — NDT Localization Tuning
1. **Verify NDT input pipeline** — Confirm `ndt_scan_matcher` receives all required inputs:
   - VLP-32C point cloud
   - IMU data (Tamagawa)
   - **Vehicle velocity from Turing Drive DBW** (wheel odometry)
   - **Steering angle from Turing Drive DBW** (for twist estimation)
   - GNSS initial pose
2. **Baseline NDT test** — Drive a loop on NTU campus, record rosbag, replay in logging simulation. Evaluate localization drift.
3. **Parameter tuning** — Adjust NDT resolution, convergence criteria, and EKF fusion weights in `ndt_scan_matcher.param.yaml` / `ekf_localizer.param.yaml`. Target <10cm accuracy.
4. **Document tuning results** — Record parameter sets and performance metrics.

**Phase 3 exit criteria**: Calibration extrinsics verified with projection overlay. NDT localization tracks within 10cm on NTU campus with DBW velocity/steering feedback.

---

## Phase 4: Planning, Control & Safety

### Track A — MRM & Safety Review
1. **Review AutoSDV planning/MRM patches** — The AutoSDV project carried patches on planning and MRM modules. Audit which patches were applied in this fork (check `src/launcher/golfcart_launch/config/control/` and planning configs). Determine which are still relevant for the golf cart and which should be reverted or adapted.
2. **Configure MRM** — Tune emergency stop parameters, collision detector thresholds, and AEB settings for golf cart dynamics (slower, heavier than AutoSDV small vehicle).
3. **Sensor failure handling** — Test system behavior when individual sensors drop out. Ensure MRM activates correctly.

### Track B — Planning Module Configuration
1. **Review AutoSDV planning patches** — Cross-check with Group X. Identify planning behavior changes from AutoSDV (e.g., speed limits, obstacle margins, intersection handling) and adapt for campus golf cart operation.
2. **Planning module bring-up** — Enable `launch_planning:=true`, verify route planning on NTU map end-to-end.
3. **Control parameter tuning** — Tune MPC lateral controller and PID longitudinal controller for smooth golf cart driving at low speeds (<15 km/h). The golf cart has different steering geometry than the AutoSDV small vehicle — expect re-tuning.
4. **Waypoint route creation** — Define standard test routes on NTU campus.

**Phase 4 exit criteria**: Planning patches reviewed and adapted. Autoware plans and follows a route on NTU map in simulation. MRM triggers correctly on simulated sensor failure.

---

## Phase 5: Integration & Field Testing

Both groups work together.

### Track A — Perception & Data Collection
1. **Perception validation** — Verify LiDAR-based CenterPoint detects pedestrians and obstacles on campus.
2. **Camera data collection pipeline** — Verify rosbag recording captures all three TIER IV camera streams alongside LiDAR and pose data. This pipeline is needed for future data collection tasks.
3. **Occupancy grid tuning** — Adjust ground segmentation and obstacle filtering for campus terrain.

### Track B — Full System Integration
1. **End-to-end pipeline test** — Sensors -> Localization -> Planning -> Control -> DBW -> Vehicle. Stationary first, then low-speed (<5 km/h) in parking lot.
2. **System performance profiling** — Monitor CPU/GPU/memory on AGX Orin during full-stack operation. Pre-compile TensorRT models to avoid 30-min first-run delay.
3. **Operational procedures** — Startup/shutdown checklists, pre-drive safety checks, emergency procedures.

### Joint Tasks
- **Campus road test** — Drive standard routes at increasing speeds. Both groups monitor different subsystems.
- **Reliability run** — 30+ minute continuous autonomous operation target.
- **Bug triage & fixes**.

**Phase 5 exit criteria**: Golf cart completes a full autonomous loop on NTU campus at target speed, stable for 30+ minutes.

---

## AutoSDV Cleanup Items

| Item                               | Location                                          | Action                                    |
|------------------------------------|---------------------------------------------------|-------------------------------------------|
| Seyond (Robin-W) LiDAR driver      | `src/sensor_component/external/seyond_ros_driver` | Remove submodule                          |
| Cube1/Robin-W launch paths         | `lidar.launch.xml` lines 17-26                    | Delete                                    |
| ZED camera xacro/calibration       | `sensor_kit.xacro`, `sensor_kit_calibration.yaml` | Replace with TIER IV cameras              |
| Sensor check script                | `scripts/check/sensors.launch.xml`                | Remove Seyond + old camera, keep Velodyne |
| Seyond/camera rviz configs         | `scripts/check/seyond.rviz`, `camera_c1.rviz`     | Remove or replace                         |
| `autosdv_runtime` submodule        | `src/system/autosdv_runtime`                      | Review — rename or keep                   |
| `autosdv_system_monitor` submodule | `src/system/autosdv_system_monitor`               | Review — rename or keep                   |
| Custom PWM vehicle interface       | `golfcart_vehicle_interface/`                     | Replace with Turing Drive DBW             |
| Lexus mesh                         | `golfcart_vehicle_description/mesh/lexus.dae`     | Replace if golf cart model available      |
| `vehicle_info.param.yaml`          | `golfcart_vehicle_description/config/`            | TODO: measure golf cart dimensions (wheelbase, tread width, overhang, tire radius) before updating |
| `launch-zed` justfile recipe       | `justfile` line 95-98                             | Remove                                    |
| Planning/MRM patches               | `config/control/`, `config/planning/`             | Audit — adapt or revert for golf cart     |

---

## Key Dependencies & Blockers

| Dependency                        | Blocks                                                | Owner                      |
|-----------------------------------|-------------------------------------------------------|----------------------------|
| Turing Drive DBW package delivery | Phase 2 (DBW integration), Phase 3 (NDT localization) | Track B group to request   |
| NTU campus maps from Turing Drive | Phase 2 (map audit), Phase 3 (NDT tuning)             | Track B group to request   |
| Tamagawa IMU driver availability  | Phase 1 (IMU bring-up)                                | Request from Turing Drive  |
| TIER IV camera hardware           | Phase 2 (camera setup)                                | Track A group              |
| LCTK build & calibration targets  | Phase 3 (LiDAR-camera calibration)                    | Track A group              |

---

## Notes

- Phases are sequential but tasks within each phase are parallelized across groups.
- Each phase has two tracks (A and B). Each group picks one track per phase — assignment is decided by the members themselves, not fixed.
- The Turing Drive DBW package is the critical-path blocker: without wheel velocity and steering feedback, NDT localization cannot function. The group taking Track B in Phase 2 should request this ASAP.
- AutoSDV planning/MRM patches should be reviewed jointly by both groups in Phase 4, since those patches may affect safety behavior.
