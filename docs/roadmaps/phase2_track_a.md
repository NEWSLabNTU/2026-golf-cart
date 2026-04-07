# Phase 2 Track A — TIER IV Camera Setup

Tracks progress on the four Track A tasks from [ROADMAP.md](../../ROADMAP.md#track-a--tier-iv-camera-setup).

Last updated: 2026-04-07 (verified on target machine)

---

## 1. Mount three TIER IV cameras

**Status: Blocked — requires hardware + golf cart** (confirmed on target 2026-04-07)

**Target machine note**: No cameras connected. No `/dev/video*` devices. The board has GMSL camera connectors (ZED-X driver probes on I2C bus 8 but no cameras found).

### Not done
- [ ] Obtain TIER IV C1 camera hardware
- [ ] Mount two front-facing cameras (front-left, front-right)
- [ ] Mount one rear-facing camera
- [ ] Measure and record mount positions from `base_link` (x, y, z, roll, pitch, yaw for each)

> **Cannot be done before real machine** — physical mounting and measurement required.

---

## 2. Update sensor kit description

**Status: Not started — can be partially prepared**

### Current state
- `sensor_kit.xacro` has a TODO placeholder at line 88: `<!-- TODO: Add USB/Tier IV camera frames when camera integration is ready -->`
- `sensor_kit_calibration.yaml` has ZED entry commented out (lines 9-15); no TIER IV entries
- Camera launch file (`camera.launch.xml`) still references ZED `zed_wrapper` package
- `package.xml` lists `usb_cam` as dependency but no TIER IV driver dependency

### Can do before real machine
- [x] ZED camera references removed from `sensor_kit.xacro` (done in Phase 1)
- [ ] **Add three camera frame definitions to `sensor_kit.xacro`** — define `camera_front_left`, `camera_front_right`, `camera_rear` links with placeholder transforms (all zeros)
- [ ] **Add calibration entries to `sensor_kit_calibration.yaml`** — three camera entries with placeholder values
- [x] **TIER IV C1 ROS 2 driver package identified** — GMSL2-USB 3.0 Conversion Kit presents C1 as UVC device; uses `ros-humble-usb-cam` (already installed on target, v0.8.1). Note: `ros-humble-v4l2-camera` was originally planned but is unavailable in the Humble arm64 apt repo.

### Requires real machine
- [ ] Fill in actual mount position values in `sensor_kit_calibration.yaml` after physical measurement

---

## 3. Camera launch file

**Status: Not started — can be partially prepared**

### Current state
- `camera.launch.xml` launches a single ZED camera via `zed_wrapper` with `zed_camera.launch.py`
- `camera_model` argument exists in `golfcart.launch.yaml` (line 19-22) with options: `usb`, `none`
- No TIER IV camera config YAML files exist (no `tier4_camera_*.yaml`)
- No camera intrinsic calibration files exist

### Can do before real machine
- [ ] **Rewrite `camera.launch.xml`** to support TIER IV camera launch (three nodes with device path arguments)
- [ ] **Add `camera_model:=tier4` option** to launch parameter and sensor suite
- [ ] **Create config YAML templates** for each camera (device path, resolution, frame rate, intrinsics placeholder)
- [x] **TIER IV driver in `setup/justfile`** — `tier4-camera` recipe installs `ros-humble-usb-cam`, `v4l-utils`, and udev rules template (`setup/files/99-tier4-camera.rules`). `usb_cam` already installed on target (v0.8.1).
- [ ] **Add camera driver dependency to `package.xml`** — add `usb_cam` as exec dependency

### Requires real machine
- [ ] Configure udev rules — edit `/etc/udev/rules.d/99-tier4-camera.rules` with actual USB port paths (see `setup/files/99-tier4-camera.rules` for instructions)
- [ ] Perform camera intrinsic calibration (camera matrix, distortion coefficients)

---

## 4. Verify image streaming

**Status: Not started — requires hardware**

### Not done
- [ ] Confirm all three cameras publish to expected topics:
  - `/sensing/camera/camera_front_left/image_raw`
  - `/sensing/camera/camera_front_right/image_raw`
  - `/sensing/camera/camera_rear/image_raw`
- [ ] Verify image quality and frame rate in RViz
- [ ] Test with perception pipeline (if camera-lidar fusion preset is enabled)

> **Cannot be done before real machine** — requires cameras physically connected.

---

## Summary

| Task | Status | Can prepare before real machine? |
|------|--------|----------------------------------|
| 1. Mount cameras | Blocked | No — physical mounting |
| 2. Sensor kit description | Not started | **Yes** — frame definitions, calibration placeholders |
| 3. Camera launch file | Not started | **Yes** — launch rewrite, configs, driver recipe |
| 4. Verify streaming | Not started | No — requires hardware |

### Blockers
- **TIER IV C1 camera hardware** not yet available
- ~~TIER IV camera ROS 2 driver package~~ — resolved: `usb_cam` via GMSL2-USB kit (`v4l2_camera` unavailable in Humble arm64 repo)
- Mount positions cannot be measured until cameras are on the golf cart

### Pre-move preparation checklist
These items can be completed on the dev machine before transferring to the real golf cart:
- [ ] Camera frame definitions in `sensor_kit.xacro` (with placeholder transforms)
- [ ] Calibration placeholder entries in `sensor_kit_calibration.yaml`
- [ ] Rewritten `camera.launch.xml` supporting `tier4` camera model
- [ ] Config YAML templates for three cameras
- [x] TIER IV driver package identified and added to setup recipe
- [ ] `camera_model:=tier4` option documented and wired into launch system

### Phase 2 exit criteria (Track A portion)
- [ ] Three cameras stream images to `/sensing/camera/*/image_raw`
