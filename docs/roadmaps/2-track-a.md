# Phase 2 Track A — TIER IV Camera Setup

Tracks progress on the four Track A tasks from [ROADMAP.md](../../ROADMAP.md#track-a--tier-iv-camera-setup).

Last updated: 2026-04-29

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
- `sensor_kit.xacro` defines three camera frames (`camera_{left,right,rear}_optical_link`) via a small macro; transforms come from `sensor_kit_calibration.yaml` (currently all zeros)
- `sensor_kit_calibration.yaml` has placeholder (zeros) entries for the three USB cameras; ZED entry remains commented
- Camera launch file (`camera.launch.xml`) has been rewritten to drive USB cameras via `gscam` (left/right active, rear node currently commented out); ZED references removed
- `package.xml` lists `usb_cam` as dependency but no TIER IV driver dependency

### Can do before real machine
- [x] ZED camera references removed from `sensor_kit.xacro` (done in Phase 1)
- [x] **Add three camera frame definitions to `sensor_kit.xacro`** — `camera_{left,right,rear}_optical_link` links added via macro with placeholder (zero) transforms
- [x] **Add calibration entries to `sensor_kit_calibration.yaml`** — three camera entries with placeholder values
- [x] **TIER IV C1 ROS 2 driver package identified** — GMSL2-USB 3.0 Conversion Kit presents C1 as UVC device; driven via `gscam` (GStreamer + `nvvidconv` hardware acceleration on Jetson). Note: `ros-humble-usb-cam` and `ros-humble-v4l2-camera` were earlier candidates; `gscam` was chosen for the Jetson hardware pipeline (`v4l2src ! UYVY ! nvvidconv ! RGBA ! videoconvert ! RGB`).

### Requires real machine
- [ ] Fill in actual mount position values in `sensor_kit_calibration.yaml` after physical measurement

---

## 3. Camera launch file

**Status: Substantially done for `camera_model:=usb`; `tier4` option still pending**

### Current state
- `camera.launch.xml` has been rewritten to launch three `gscam_node` instances (one per camera) using the GMSL2-USB pipeline. Left and right are active; the rear node is currently commented out pending verification. ZED references removed — the roadblock in [docs/roadblocks.md](../roadblocks.md#cameralaunchxml-still-uses-zed-driver-not-usb-camera) is resolved.
- `camera_model` argument exists in `golfcart.launch.yaml` (line 19-22) with options: `usb`, `none`
- Three TIER IV camera config YAMLs exist: `camera_{left,rear,right}.yaml`, each pinned to a `/dev/v4l/by-path/...` symlink (left=`2.2`, rear=`2.3`, right=`2.4`). Pipeline + device-path rationale in [`config/gscam.md`](../../src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/gscam.md).
- Dummy `camera_{left,rear,right}_calibration.yaml` files exist as intrinsics placeholders

### Can do before real machine
- [x] **Rewrite `camera.launch.xml`** to support TIER IV camera launch (three nodes with device path arguments)
- [ ] **Add `camera_model:=tier4` option** to launch parameter and sensor suite
- [x] **Create config YAML templates** for each camera (device path, resolution, frame rate, intrinsics placeholder)
- [x] **TIER IV driver in `setup/justfile`** — `tier4-camera` recipe installs `ros-humble-usb-cam`, `v4l-utils`, and udev rules template (`setup/files/99-tier4-camera.rules`). `usb_cam` already installed on target (v0.8.1). **Note**: actual launch now uses `gscam`, not `usb_cam` — recipe needs updating.
- [ ] **Add camera driver dependency to `package.xml`** — add `gscam` as exec dependency (the existing `usb_cam` entry is no longer used)
- [ ] **Re-enable rear camera node** in `camera.launch.xml`

### Requires real machine
- [x] ~~Configure udev rules~~ — superseded by `/dev/v4l/by-path/...` pinning in the YAMLs
- [ ] Perform camera intrinsic calibration (camera matrix, distortion coefficients) — replace dummy `*_calibration.yaml` with real values

---

## 4. Verify image streaming

**Status: Not started — requires hardware**

### Not done
- [ ] Confirm all three cameras publish to expected topics:
  - `/sensing/camera/left/image_raw`
  - `/sensing/camera/right/image_raw`
  - `/sensing/camera/rear/image_raw`
- [ ] Verify image quality and frame rate in RViz
- [ ] Test with perception pipeline (if camera-lidar fusion preset is enabled)

> **Cannot be done before real machine** — requires cameras physically connected.

---

## Summary

| Task | Status | Can prepare before real machine? |
|------|--------|----------------------------------|
| 1. Mount cameras | Blocked | No — physical mounting |
| 2. Sensor kit description | Substantially done — placeholders in place, awaiting real measurements | **Yes** (done) |
| 3. Camera launch file | Substantially done (`usb`) | **Yes** — `tier4` option, rear node enable, recipe/package.xml cleanup |
| 4. Verify streaming | Not started | No — requires hardware |

### Blockers
- **TIER IV C1 camera hardware** not yet available
- ~~TIER IV camera ROS 2 driver package~~ — resolved: `gscam` via GMSL2-USB kit (Jetson `nvvidconv` pipeline; `usb_cam` and `v4l2_camera` were earlier candidates)
- Mount positions cannot be measured until cameras are on the golf cart

### Pre-move preparation checklist
These items can be completed on the dev machine before transferring to the real golf cart:
- [x] Camera frame definitions in `sensor_kit.xacro` (with placeholder transforms)
- [x] Calibration placeholder entries in `sensor_kit_calibration.yaml`
- [x] Rewritten `camera.launch.xml` supporting `usb` camera model via `gscam`
- [x] Config YAML templates for three cameras (with `/dev/v4l/by-path/...` pinning)
- [x] TIER IV driver package identified and added to setup recipe (recipe still installs `usb_cam`; actual driver is `gscam` — needs updating)
- [ ] `camera_model:=tier4` option documented and wired into launch system

### Phase 2 exit criteria (Track A portion)
- [ ] Three cameras stream images to `/sensing/camera/*/image_raw`
