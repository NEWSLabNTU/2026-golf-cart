# Phase 1 Track A — Sensor Kit Cleanup & LiDAR

Tracks progress on the four Track A tasks from [ROADMAP.md](../../ROADMAP.md#track-a--sensor-kit-cleanup--lidar).

Last updated: 2026-04-23 (verified on target machine)

---

## 1. Remove unused sensor submodules & launch paths

**Status: Done** (commits `3cb1ddc`, `799d799`)

All AutoSDV-era sensor references (Seyond/Robin-W, Cube1, ZED, MPU9250) have been stripped.

### Submodule & file deletions
- [x] Remove `seyond_ros_driver` submodule
- [x] Delete `scripts/check/seyond.rviz`, `scripts/check/camera_c1.rviz`

### `scripts/check/sensors.launch.xml`
- [x] Remove Seyond driver include, old camera node, Seyond RViz, camera RViz
- Result: only Velodyne launch + `velodyne.rviz` remain

### `justfile`
- [x] Remove `launch-zed` recipe

### Launch YAML files (`golfcart.launch.yaml`, `sensor_only.launch.yaml`, `logging_simulation.launch.yaml`)
- [x] Remove Robin-W, Cube1, ZED, MPU9250 from sensor suite defaults and descriptions
- [x] Remove `enable_zed_object_detection` argument

### `camera_calibration.launch.xml`
- [x] Remove ZED camera launch block

### `golfcart.rviz`
- [x] Remove `cube1`, `robin_w`, `zedxm_*` frame entries

### Documentation
- [x] `docs/guides/lidar_integration.md` — Remove Robin-W, Cube1 rows and sections
- [x] Perception/localization preset READMEs — Remove stale sensor suite examples
- [x] Research docs — Added historical notices on Robin-W/ZED references
- [x] `setup/README.md` — Remove ZED SDK references
- [x] `data/.gitignore` — Remove `/zed-sdk/` entry
- [x] `CLAUDE.md` — Clean sensor suite, lidar_model, camera_model, imu_source references

### Submodule files
- [x] `lidar.launch.xml` — Keep only `vlp32c` path
- [x] `sensor_kit.xacro` — Remove ZED camera references
- [x] `imu.launch.xml` — Replace MPU9250 with Tamagawa placeholder (driver commented out)
- [x] `sensor_kit_calibration.yaml` — Remove `cube1`, `robin_w`, `zedxm_camera_link` entries

### Monitor topics
- [x] `golfcart_system_monitor/config/monitor_topics.yaml` — Removed Blickfeld, Robin-W, ZED, MPU9250, Garmin, Septentrio entries

---

## 2. Velodyne VLP-32C bring-up

**Status: Hardware connected and streaming** (verified on target 2026-04-23)

### Done
- [x] Launch file correctly invokes Nebula with VLP-32C (`lidar.launch.xml:16-21`)
- [x] Config file `VLP32.param.yaml` exists with valid parameters:
  - `sensor_ip: 192.168.7.10`, `data_port: 2368`, `rotation_speed: 600`, `return_mode: Dual`
  - Calibration file: `$(find-pkg-share nebula_decoders)/calibration/velodyne/VLP32.yaml`
- [x] Nebula driver installed via apt (verified on target):
  - `ros-humble-nebula-ros-1-5-0` (v0.2.5)
  - `ros-humble-nebula-decoders-1-5-0` (v0.2.5)
  - `ros-humble-nebula-common-1-5-0` (v0.2.5)
  - Plus: `nebula-hw-interfaces`, `nebula-msgs`, `nebula-sensor-driver`, `nebula-tests`, `nebula-examples`
- [x] **VLP-32C physically connected** to target machine — iface `enP5p4s0` configured with `192.168.7.1/24`; LiDAR reachable at `192.168.7.10`
- [x] **LiDAR streaming to host** — UDP packets verified `192.168.7.10:2368 → 192.168.7.1:2368` via tcpdump (2026-04-23)
- [x] **Nebula decoder producing point clouds** — "Missed pointcloud output deadline" warnings resolved after fixing the LiDAR's destination-IP from broadcast (255.255.255.255) to the host unicast IP in the web UI. See [docs/roadblocks.md](../roadblocks.md#nebula-decoder-silent--missed-pointcloud-output-deadline-lidar-broadcasting).
- [x] **UDP-stream sanity check added** to `scripts/check/run.sh` — uses tcpdump to detect when the LiDAR is broadcasting instead of unicasting to the host's iface IP (requires `tcpdump`, optionally `cap_net_raw` to skip sudo)
- [x] **RViz config path fix** in `scripts/check/sensors.launch.xml` — `$(dirname)` now captured into `rviz_config` arg before any `<include>` so RViz loads `sensors.rviz` regardless of CWD (prevents the BEST_EFFORT QoS mismatch). See [docs/roadblocks.md](../roadblocks.md#scriptschecksensorslaunchxml--rviz-config-not-loading-from-non-scriptscheck-cwd).

### Not done
- [ ] **Verify VLP-32C mount position** in `sensor_kit_calibration.yaml` — values present (x=0.46, y=0.0, z=1.96) but may be from the previous vehicle, not measured on the golf cart:
  ```yaml
  # src/param/autoware_individual_params/.../sensor_kit_calibration.yaml lines 2-8
  vlp32c:
    x: 0.46
    y: 0.0
    z: 1.96
    roll: 0.0
    pitch: 0.0
    yaw: 0.0
  ```
- [ ] Confirm point cloud quality/coverage in RViz with the LiDAR mounted on the golf cart (current verification was on the benchtop)

---

## 3. u-blox GNSS bring-up

**Status: Software ready, hardware not connected** (verified on target 2026-04-07)

### Done
- [x] Launch file supports u-blox (`gnss.launch.xml:14-20`): launches `ublox_gps_node` with `c94_f9p_rover.yaml`
- [x] u-blox driver installed via apt (verified on target):
  - `ros-humble-ublox-gps` (v2.3.0)
  - `ros-humble-ublox-msgs` (v2.3.0)
  - `ros-humble-ublox-serialization` (v2.3.0)
- [x] udev rules file installed at `/etc/udev/rules.d/99-ublox-gps.rules` — creates `/dev/ublox-gps` symlink (verified on target)
- [x] `ublox-udev` setup recipe installs rules and adds user to `dialout` group
- [x] User `ubuntu` is in `dialout` group (verified on target)
- [x] Default GNSS receiver changed from `garmin` to `ublox` in `gnss.launch.xml:3`

### Not done
- [ ] **Connect u-blox GNSS to target machine** — no `/dev/ttyACM*` or serial devices detected; UART ports `ttyTHS1`–`ttyTHS3` available
- [ ] **Verify GNSS antenna position** in `sensor_kit_calibration.yaml` — values present (x=0.83, y=0.0, z=1.69) but may be from the previous vehicle:
  ```yaml
  # sensor_kit_calibration.yaml lines 16-22
  gnss_base_link:
    x: 0.83
    y: 0.0
    z: 1.69
  ```
- [ ] Test fix quality and verify `/sensing/gnss/pose` topic with live hardware

---

## 4. IMU bring-up

**Status: Blocked — Tamagawa driver not available** (confirmed on target 2026-04-07)

### Done
- [x] `imu.launch.xml` updated: default topic set to `tamagawa/imu_raw` (line 9-10)
- [x] IMU corrector and gyro bias estimator are active and reference the Tamagawa topic
- [x] `imu_corrector.param.yaml` has real calibration values (non-zero gyro offsets):
  ```yaml
  angular_velocity_stddev_xx: 0.00339
  angular_velocity_offset_x: -0.005799
  angular_velocity_offset_y: -0.007148
  angular_velocity_offset_z: -0.001499
  ```
- [x] MPU9250 driver submodule removed from `.gitmodules` (commit `3cb1ddc`)

### Not done
- [ ] **Tamagawa driver not installed** — no apt package, no submodule, no source code in project. `dpkg -l | grep tamagawa` returns nothing (verified on target 2026-04-07).
- [ ] **Driver launch is commented out** in `imu.launch.xml:14-20` — placeholder references `tamagawa_imu_driver` package
- [ ] **Verify IMU mount position** in `sensor_kit_calibration.yaml` — values present (x=-0.67, y=0.03, z=1.81) but may be from the previous vehicle
- [ ] Verify `/sensing/imu/imu_data` topic with live hardware
- **Note**: UART ports `ttyTHS1`–`ttyTHS3` are available on the target for serial IMU connection.

### Blocker
Tamagawa IMU driver package source is not confirmed. **Action: request Turing Drive (the company) to provide the Tamagawa IMU driver package.** Listed in [ROADMAP.md Key Dependencies](../../ROADMAP.md#key-dependencies--blockers) as Track A responsibility to source.

---

## Summary

| Task | Status | Remaining work |
|------|--------|----------------|
| 1. Sensor cleanup | Done | — |
| 2. VLP-32C bring-up | Connected and streaming | Verify mount on golf cart, inspect point cloud coverage |
| 3. u-blox GNSS bring-up | Software ready, no hardware | Connect GNSS, measure antenna position, test fix |
| 4. Tamagawa IMU bring-up | Blocked | Source and install driver, uncomment launch, measure mount |

### Phase 1 exit criteria (Track A portion)
- [x] No Seyond/Robin-W/Cube1/ZED/MPU9250 code paths remain
- [x] LiDAR publishes valid point cloud (verified 2026-04-23; mount verification on golf cart still pending)
- [ ] GNSS publishes valid fix (software ready, needs hardware verification)
- [ ] IMU publishes valid data (blocked on Tamagawa driver)
