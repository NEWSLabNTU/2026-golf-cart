# Phase 1 Track A — Sensor Kit Cleanup Checklist

Items to remove or update to strip AutoSDV-era sensor references (Seyond/Robin-W, Cube1, ZED, MPU9250).

---

## 1. Submodule Removal

- [x] **Remove `seyond_ros_driver` submodule** — `src/sensor_component/external/seyond_ros_driver`
  - Entry removed from `.gitmodules`, submodule deinitialized

---

## 2. Files to Delete Entirely

- [x] **`scripts/check/seyond.rviz`** — Seyond-specific RViz config, no longer needed
- [x] **`scripts/check/camera_c1.rviz`** — Old camera RViz config (referenced in roadmap cleanup table)

---

## 3. `scripts/check/sensors.launch.xml` — Remove Seyond + Old Camera

Current file launches Velodyne, Seyond, a gscam camera node, and three RViz instances.

- [x] Remove Seyond driver include (line 8-10):
  ```xml
  <include file="$(find-pkg-share seyond)/start.py">
    <arg name="lidar_ip" value="172.168.1.10"/>
  </include>
  ```
- [x] Remove old camera node (lines 12-15) — uses hardcoded `GMSL2-USB3.0` device path with `videoflip rotate-180`
  ```xml
  <node pkg="gscam" exec="gscam_node" name="v4l2_camera">
    <param name="gscam_config" value="v4l2src device=/dev/v4l/by-id/usb-Ability_GMSL2-USB3.0_Conversion_Kit_C1-Master-video-index0 ! videoconvert ! videoflip method=rotate-180 ! video/x-raw,format=RGB"/>
    <param name="frame_id" value="camera"/>
  </node>
  ```
- [x] Remove Seyond RViz node (line 18):
  ```xml
  <node pkg="rviz2" exec="rviz2" name="rviz2_seyond" args="-d seyond.rviz"/>
  ```
- [x] Remove camera RViz node (line 19):
  ```xml
  <node pkg="rviz2" exec="rviz2" name="rviz2_camera" args="-d camera_c1.rviz"/>
  ```

**Result**: Only Velodyne launch + velodyne.rviz remain.

---

## 4. `justfile` — Remove ZED Recipe

- [x] Remove `launch-zed` recipe (lines 94-98):
  ```just
  # Launch only ZED camera node for testing
  launch-zed:
      play_launch launch \
          --web-addr 0.0.0.0:8081 \
          zed_wrapper zed_camera.launch.py camera_model:=zedxm
  ```

---

## 5. Launch Files — Clean Sensor Suite / Arg Descriptions

These three launch files have identical sensor suite args referencing Robin-W, Cube1, ZED, MPU9250:

### `src/launcher/golfcart_launch/launch/golfcart.launch.yaml`
- [x] Line 10: Change default sensor suite from `vlp32c_zed_imu` to golf cart default (e.g., `vlp32c_usb`)
- [x] Line 11: Remove `robin_zed`, `robin_zed_mpu`, `vlp32c_zed`, `vlp32c_zed_mpu`, `vlp32c_zed_imu`, `cube1_usb` from description
- [x] Line 17: Remove `cube1` and `robin-w` from LiDAR model description, keep `vlp32c`
- [x] Line 22: Remove `zedxm` from camera model description
- [x] Line 27: Remove `mpu9250` and `zed` from IMU source description, replace with `tamagawa` (or leave as placeholder)
- [x] Lines 55-57: Remove `enable_zed_object_detection` argument

### `src/launcher/golfcart_launch/launch/sensor_only.launch.yaml`
- [x] Same changes as golfcart.launch.yaml (lines 10-11, 17, 22, 27, 55)

### `src/launcher/golfcart_launch/launch/logging_simulation.launch.yaml`
- [x] Same changes (lines 14-15, 21, 31, 59)

---

## 6. `src/launcher/golfcart_launch/launch/camera_calibration.launch.xml`

- [x] Lines 5-12: Remove ZED camera launch/include block, replace with USB or Tier IV camera config

---

## 7. `src/launcher/golfcart_launch/rviz/golfcart.rviz` — Remove Stale Frames

- [x] Lines 96-99: Remove `cube1` frame entry
- [x] Lines 108-111: Remove `robin_w` frame entry
- [ ] Lines 156-180: Remove all `zedxm_*` frame entries — **partially done**: `zedxm_camera_*` frames removed but a `zedxm` topic reference remains at line 4202 (`/sensing/camera/zedxm/point_cloud/cloud_registered`)

---

## 8. Documentation Cleanup

### High priority (actively misleading)

- [x] **`docs/guides/lidar_integration.md`** — Remove Robin-W row from table (line 9), remove entire "Seyond Robin-W Integration" section (lines 15-47), remove Cube1 row (line 11)
- [x] **`src/launcher/golfcart_launch/config/perception/preset/README.md`** — Line 50: Update example from `robin_zed` to golf cart sensor suite
- [x] **`src/launcher/golfcart_launch/config/localization/preset/README.md`** — Line 19: Remove `MPU9250 or ZED IMU`, replace with Tamagawa

### Lower priority (research docs, historical context may be useful)

- [ ] **`docs/research/lidar_marker_localization.md`** — Multiple Robin-W references in examples (6 occurrences remain)
- [ ] **`docs/research/indoor_localization.md`** — Multiple Robin-W/ZED references in architecture options (12 occurrences remain)
- [ ] **`docs/research/nvidia_isaac_ros.md`** — Multiple Robin-W references in configuration examples (11 occurrences remain)

---

## 9. Setup / Build References

- [x] **`setup/README.md`** — Line 78, 100: Remove ZED SDK installation references
- [x] **`data/.gitignore`** — Line 1: Remove `/zed-sdk/` entry (no longer needed)

---

## 10. `CLAUDE.md` Updates

- [x] Line 296-298: Remove `robin_zed`, `vlp32c_zed`, `vlp32c_zed_imu` sensor suite references
- [x] Line 301: Change `lidar_model:=robin-w|vlp32c|cube1` to `lidar_model:=vlp32c`
- [x] Line 302: Change `camera_model:=zedxm|usb|none` to `camera_model:=usb|none`
- [x] Line 303: Change `imu_source:=mpu9250|zed` to `imu_source:=tamagawa`

---

## 11. Submodule Files (Require `just checkout` First)

These files are in uncloned submodules and cannot be edited until submodules are initialized:

### `golfcart_sensor_kit_launch` submodule
- [ ] **`lidar.launch.xml`** — Remove Cube1 and Robin-W code paths (lines 17-26), keep only `vlp32c`
- [ ] **`sensor_kit.xacro`** — Remove ZED camera references (lines 89-111, `zed_wrapper` include)
- [ ] **`imu.launch.xml`** — Replace MPU9250 driver references with Tamagawa IMU driver

### `autoware_individual_params` submodule
- [ ] **`sensor_kit_calibration.yaml`** — Update with measured VLP-32C mount position (currently all zeros)

---

## Summary

| Category                      | Items               | Status              |
|-------------------------------|---------------------|---------------------|
| Submodule removal             | 1                   | Done                |
| File deletions                | 2                   | Done                |
| sensors.launch.xml            | 4 edits             | Done                |
| justfile                      | 1 recipe            | Done                |
| Launch YAML files             | 3 files             | Done                |
| camera_calibration.launch.xml | 1 file              | Done                |
| RViz config                   | 1 file (3 sections) | Partial (1 zedxm topic ref remains at line 4202) |
| Documentation                 | 5+ files            | High-priority done; 3 research docs skipped (29 refs, low priority) |
| Setup/build refs              | 2 files             | Done                |
| CLAUDE.md                     | 4 lines             | Done                |
| Submodule files (blocked)     | 4 files             | Blocked on checkout |
