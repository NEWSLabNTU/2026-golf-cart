# Phase 1 Track A — Sensor Kit Cleanup Checklist

Items to remove or update to strip AutoSDV-era sensor references (Seyond/Robin-W, Cube1, ZED, MPU9250).

---

## 1. Submodule Removal

- [x] **Remove `seyond_ros_driver` submodule** — `src/sensor_component/external/seyond_ros_driver`
  - Entry removed from `.gitmodules`, submodule deinitialized

---

## 2. Files to Delete Entirely

- [ ] **`scripts/check/seyond.rviz`** — Seyond-specific RViz config, no longer needed
- [ ] **`scripts/check/camera_c1.rviz`** — Old camera RViz config (referenced in roadmap cleanup table)

---

## 3. `scripts/check/sensors.launch.xml` — Remove Seyond + Old Camera

Current file launches Velodyne, Seyond, a gscam camera node, and three RViz instances.

- [ ] Remove Seyond driver include (line 8-10):
  ```xml
  <include file="$(find-pkg-share seyond)/start.py">
    <arg name="lidar_ip" value="172.168.1.10"/>
  </include>
  ```
- [ ] Remove old camera node (lines 12-15) — uses hardcoded `GMSL2-USB3.0` device path with `videoflip rotate-180`
  ```xml
  <node pkg="gscam" exec="gscam_node" name="v4l2_camera">
    <param name="gscam_config" value="v4l2src device=/dev/v4l/by-id/usb-Ability_GMSL2-USB3.0_Conversion_Kit_C1-Master-video-index0 ! videoconvert ! videoflip method=rotate-180 ! video/x-raw,format=RGB"/>
    <param name="frame_id" value="camera"/>
  </node>
  ```
- [ ] Remove Seyond RViz node (line 18):
  ```xml
  <node pkg="rviz2" exec="rviz2" name="rviz2_seyond" args="-d seyond.rviz"/>
  ```
- [ ] Remove camera RViz node (line 19):
  ```xml
  <node pkg="rviz2" exec="rviz2" name="rviz2_camera" args="-d camera_c1.rviz"/>
  ```

**Result**: Only Velodyne launch + velodyne.rviz remain.

---

## 4. `justfile` — Remove ZED Recipe

- [ ] Remove `launch-zed` recipe (lines 94-98):
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
- [ ] Line 10: Change default sensor suite from `vlp32c_zed_imu` to golf cart default (e.g., `vlp32c_usb`)
- [ ] Line 11: Remove `robin_zed`, `robin_zed_mpu`, `vlp32c_zed`, `vlp32c_zed_mpu`, `vlp32c_zed_imu`, `cube1_usb` from description
- [ ] Line 17: Remove `cube1` and `robin-w` from LiDAR model description, keep `vlp32c`
- [ ] Line 22: Remove `zedxm` from camera model description
- [ ] Line 27: Remove `mpu9250` and `zed` from IMU source description, replace with `tamagawa` (or leave as placeholder)
- [ ] Lines 55-57: Remove `enable_zed_object_detection` argument

### `src/launcher/golfcart_launch/launch/sensor_only.launch.yaml`
- [ ] Same changes as golfcart.launch.yaml (lines 10-11, 17, 22, 27, 55)

### `src/launcher/golfcart_launch/launch/logging_simulation.launch.yaml`
- [ ] Same changes (lines 14-15, 21, 31, 59)

---

## 6. `src/launcher/golfcart_launch/launch/camera_calibration.launch.xml`

- [ ] Lines 5-12: Remove ZED camera launch/include block, replace with USB or Tier IV camera config

---

## 7. `src/launcher/golfcart_launch/rviz/golfcart.rviz` — Remove Stale Frames

- [ ] Lines 96-99: Remove `cube1` frame entry
- [ ] Lines 108-111: Remove `robin_w` frame entry
- [ ] Lines 156-180: Remove all `zedxm_*` frame entries (`zedxm_camera_center`, `zedxm_camera_link`, `zedxm_left_camera_frame`, `zedxm_left_camera_optical_frame`, `zedxm_right_camera_frame`, `zedxm_right_camera_optical_frame`)

---

## 8. Documentation Cleanup

### High priority (actively misleading)

- [ ] **`docs/guides/lidar_integration.md`** — Remove Robin-W row from table (line 9), remove entire "Seyond Robin-W Integration" section (lines 15-47), remove Cube1 row (line 11)
- [ ] **`src/launcher/golfcart_launch/config/perception/preset/README.md`** — Line 50: Update example from `robin_zed` to golf cart sensor suite
- [ ] **`src/launcher/golfcart_launch/config/localization/preset/README.md`** — Line 19: Remove `MPU9250 or ZED IMU`, replace with Tamagawa

### Lower priority (research docs, historical context may be useful)

- [ ] **`docs/research/lidar_marker_localization.md`** — Multiple Robin-W references in examples
- [ ] **`docs/research/indoor_localization.md`** — Multiple Robin-W/ZED references in architecture options
- [ ] **`docs/research/nvidia_isaac_ros.md`** — Multiple Robin-W references in configuration examples

---

## 9. Setup / Build References

- [ ] **`setup/README.md`** — Line 78, 100: Remove ZED SDK installation references
- [ ] **`data/.gitignore`** — Line 1: Remove `/zed-sdk/` entry (no longer needed)

---

## 10. `CLAUDE.md` Updates

- [ ] Line 296-298: Remove `robin_zed`, `vlp32c_zed`, `vlp32c_zed_imu` sensor suite references
- [ ] Line 301: Change `lidar_model:=robin-w|vlp32c|cube1` to `lidar_model:=vlp32c`
- [ ] Line 302: Change `camera_model:=zedxm|usb|none` to `camera_model:=usb|none`
- [ ] Line 303: Change `imu_source:=mpu9250|zed` to `imu_source:=tamagawa`

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
| RViz config                   | 1 file (3 sections) | Done                |
| Documentation                 | 5+ files            | Done                |
| Setup/build refs              | 2 files             | Done                |
| CLAUDE.md                     | 4 lines             | Done                |
| Submodule files (blocked)     | 4 files             | Blocked on checkout |
