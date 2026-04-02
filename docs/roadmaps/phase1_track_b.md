# Phase 1 Track B — Tooling & Infrastructure Status

Tracks progress on the five Track B tasks from [ROADMAP.md](../../ROADMAP.md#track-b--tooling--infrastructure).

Last updated: 2026-04-02

---

## 1. Clean up system-level AutoSDV remnants

**Status: Partial**

Directory rename done (commit `b073f4d`), but internal package names were not changed.

### Done
- [x] Renamed `src/system/autosdv_runtime` → `golfcart_runtime`
- [x] Renamed `src/system/autosdv_system_monitor` → `golfcart_system_monitor`
- [x] Updated 3 launch files to reference `golfcart_system_monitor` package name

### Not done
- [ ] Internal package name is still `autosdv_system_monitor` — `package.xml`, `CMakeLists.txt`, `setup.cfg`, Python module directory, launch YAML, resource file all use the old name
- [ ] Internal package name is still `autosdv_runtime` — `package.xml`, `CMakeLists.txt`, systemd service files (`autosdv.service`, `autosdv-healthcheck.service`, `autosdv-web-control.service`), CLI script (`scripts/autosdv`), Python module directory
- [ ] These are submodule repos — renaming requires changes pushed to `NEWSLabNTU/golfcart_runtime` and `NEWSLabNTU/golfcart_system_monitor`

---

## 2. Setup script overhaul

**Status: Partial**

### Done
- [x] `play_launch` — installed in `python-deps` recipe (`setup/justfile:206`)
- [x] Tamagawa IMU — placeholder recipe added (`setup/justfile:104-115`), defaults to skip
- [x] TIER IV camera — `tier4-camera` recipe installs `ros-humble-v4l2-camera`, `v4l-utils`, and udev rules template (core component, always runs)
- [x] u-blox udev rules — `ublox-udev` recipe (`setup/justfile:211-223`) installs `/dev/ublox-gps` symlink and `dialout` group
- [x] Stale ZED reference in TurboVNC prompt — fixed

### Not done
- [x] **Nebula LiDAR driver** — `nebula-driver` recipe installs Nebula 1.5.0 packages from apt
- [x] **u-blox GNSS ROS driver** — `ublox-driver` recipe installs `ros-humble-ublox-gps` and `ros-humble-ublox-msgs` from apt
- [ ] **Autoware Debian JetPack mismatch** — `install-autoware-debian.sh` downloads a JetPack 6.2 deb on aarch64 (line 22: `"Assuming JetPack 6.2 compatibility"`), but the target system runs JetPack 6.0. See [docs/roadblocks.md](../roadblocks.md).
- [ ] Remove stale AutoSDV-era optional components — not audited

---

## 3. Justfile recipes for outdoor ops

**Status: Mostly done**

### Done
- [x] `just check-sensors` recipe added (`justfile:150-151`)
- [x] `just bag-record` recipe added (`justfile:158-159`), wired to `scripts/rosbag/record_outdoor.sh`
- [x] `launch-zed` recipe removed (no longer in justfile)
- [x] `play_launch` is the default runtime (already was)

### Not done
- [ ] `scripts/rosbag/record_outdoor.sh` is a **stub** — exits with error on line 13; topic list on lines 20-47 is commented out and needs verification before activation
- [ ] `just check-sensors` fails before first build — `scripts/check/run.sh:6` unconditionally sources `install/setup.bash`. See [docs/roadblocks.md](../roadblocks.md).

---

## 4. Version control setup

**Status: Partial**

### Done
- [x] `CONTRIBUTING.md` added with `2026-golfcart` branching convention and submodule table

### Not done
- [ ] **No submodules have `branch = 2026-golfcart`** set in `.gitmodules`. All 10 submodules lack branch tracking:
  - `src/vehicle/external/autoware_manual_control`
  - `src/sensor_component/external/gnss_locator`
  - `src/sensor_component/external/ros-nmea-reader`
  - `src/param/autoware_individual_params`
  - `src/calibration/CalibrationTools`
  - `src/localization/cuda_ndt_matcher`
  - `src/sensor_kit/golfcart_sensor_kit_launch`
  - `src/vehicle/golfcart_vehicle_launch`
  - `src/system/golfcart_runtime`
  - `src/system/golfcart_system_monitor`
- [ ] No `2026-golfcart` branches created in the actual submodule repos (several already have `2026-golf` or `2025.02` branches but not the documented convention name)

---

## 5. Vehicle description update

**Status: Partial**

### Done
- [x] Golf cart dimensions measured and recorded in `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/config/vehicle_info.param.yaml`:
  - `wheel_base: 2.061`, `wheel_tread: 1.213`, `front_overhang: 0.406`, `rear_overhang: 0.821`, `vehicle_height: 2.005`, `max_steer_angle: 0.349 rad`

### Not done
- [ ] `wheel_radius` and `wheel_width` are empty (values TBD)
- [ ] Lexus mesh (`golfcart_vehicle_description/mesh/lexus.dae`) not replaced — no golf cart 3D model available yet

---

## Summary

| Task | Status | Blocking issues |
|------|--------|----------------|
| 1. AutoSDV cleanup | Partial | Internal package names still `autosdv_*` (submodule repos) |
| 2. Setup script overhaul | Partial | JetPack 6.0/6.2 mismatch; stale AutoSDV components not audited |
| 3. Justfile recipes | Mostly done | `record_outdoor.sh` stub |
| 4. Version control | Partial | No `.gitmodules` branch tracking; no branches created |
| 5. Vehicle description | Partial | `wheel_radius`/`wheel_width` TBD; Lexus mesh not replaced |

**Phase 1 exit criteria check:**
- [x] No Seyond/Robin-W/Cube1/ZED/MPU9250 code paths remain (Track A — done)
- [x] `just build` succeeds cleanly (fixed: `COLCON_IGNORE` on duplicate `individual_params`)
- [ ] LiDAR, GNSS, and IMU publish valid ROS topics (LiDAR & GNSS software ready; IMU blocked on Tamagawa driver)
- [ ] Submodule branches established (not done)
