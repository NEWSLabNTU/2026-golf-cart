# Known Roadblocks

**Target machine**: NVIDIA Jetson AGX Orin Developer Kit, JetPack 6.2.1 (L4T R36.4, Ubuntu 22.04).
**Verified**: 2026-04-07 — no external sensors physically connected yet; software stack installed and workspace builds.

---

## Open Issues


### No sensors physically connected (verified 2026-04-07)

- **Status**: The target machine has all software dependencies installed but zero external sensors are attached.
- **Hardware available on the board**:
  - 4× Ethernet ports (1 active on LAN at 192.168.10.182; 3 spare for LiDAR)
  - 2× CAN bus interfaces (`can0`, `can1`) — available but DOWN (useful for Turing Drive DBW)
  - 9× I2C buses (`i2c-0` through `i2c-8`)
  - 3× Tegra UART ports (`ttyTHS1`–`ttyTHS3`)
  - GMSL camera connectors (ZED-X driver probes but no cameras present)
- **Missing connections**:
  - No Velodyne VLP-32C — no interface on 192.168.7.x subnet
  - No u-blox GNSS — no `/dev/ttyACM*` or `/dev/ublox-gps`
  - No Tamagawa IMU — no serial devices
  - No cameras — no `/dev/video*` devices
- **Impact**: All hardware verification tasks (LiDAR in RViz, GNSS fix, IMU data, camera streaming) remain blocked on physical sensor connection.
- **Action**: Connect sensors to the Orin DevKit and configure network/serial interfaces.


### Tamagawa IMU driver — Placeholder only

- **Package**: Unknown (driver source not confirmed)
- **Status**: `just tamagawa-imu` creates a marker file but installs nothing.
- **Impact**: IMU launch will fail until the driver is obtained and manually installed.
- **Action**: Request Turing Drive (the company) to provide the Tamagawa IMU driver package.


### Sensor mount calibration — values present but unverified on golf cart

- **Files**:
  - `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` (active, used at runtime)
  - `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_description/config/sensor_kit_calibration.yaml` (used by URDF/xacro)
- **Status**: Both files are synchronized and contain plausible meter values (verified 2026-04-07):
  ```yaml
  vlp32c:        x: 0.46,  y: 0.0,  z: 1.96   # LiDAR
  imu_link:      x: -0.67, y: 0.03, z: 1.81   # IMU
  gnss_base_link: x: 0.83, y: 0.0,  z: 1.69   # GNSS
  ```
  The `autoware_individual_params` version also has USB camera placeholder entries.
- **Impact**: These values may be carried over from the previous vehicle, not measured on the golf cart. Using incorrect calibration will degrade NDT localization and sensor fusion.
- **Action**: Physically measure all sensor mount positions on the golf cart relative to `base_link` and verify/update both files.


### ~~`wheel_radius: 0.53` may need verification~~ — Fixed

- **File**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/config/vehicle_info.param.yaml`
- **Was**: `wheel_radius: 0.53` — this was the **diameter**, not the radius.
- **Fix**: Changed to `wheel_radius: 0.265` (0.53 / 2). Fixed 2026-04-07.

### GNSS antenna calibration — unverified on golf cart

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 16-22
- **Status**: Values present (x=0.83, y=0.0, z=1.69) but not confirmed as measured on the golf cart. Verified 2026-04-07.
- **Impact**: GNSS initial pose will be offset if values are wrong.
- **Action**: Verify or re-measure antenna position on the golf cart.

### IMU mount calibration — unverified on golf cart

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 9-15
- **Status**: Values present (x=-0.67, y=0.03, z=1.81) but not confirmed as measured on the golf cart. Verified 2026-04-07.
- **Impact**: IMU data will be misaligned if values are wrong. Also blocked by Tamagawa driver availability.
- **Action**: Verify or re-measure once IMU hardware is installed on the golf cart.

---

## Resolved

### `just build` / `just test` / `just setup` (ros-deps) — Duplicate `individual_params` package

- **Error**: `Duplicate package names not supported: individual_params` (colcon) / `Multiple packages found with the same name "individual_params"` (rosdep)
- **Cause**: `src/` contained two packages with the same name:
  - `src/param/autoware_individual_params/individual_params/` (ours)
  - `src/localization/cuda_ndt_matcher/src/autoware_rosbag_replay/individual_params/` (internal tool inside submodule)
- **Fix**: Added `COLCON_IGNORE` marker file to `src/localization/cuda_ndt_matcher/src/autoware_rosbag_replay/`. Verified: `just build`, `just test`, and `rosdep check` all pass.

### `just check-sensors` — Missing `install/setup.bash`

- **Error**: `scripts/check/run.sh: line 6: .../install/setup.bash: No such file or directory`
- **Cause**: `scripts/check/run.sh` unconditionally sourced `install/setup.bash`, which only exists after `just build`.
- **Fix**: Added guard in `run.sh` that prints `"Error: install/setup.bash not found. Run 'just build' first."` and exits.

### Nebula & u-blox drivers — No standalone install step

- **Nebula apt packages**: `ros-humble-nebula-ros-1-5-0`, `ros-humble-nebula-decoders-1-5-0`, etc.
- **u-blox apt packages**: `ros-humble-ublox-gps`, `ros-humble-ublox-msgs`, `ros-humble-ublox-serialization`
- **Fix**: Added dedicated `nebula-driver` and `ublox-driver` recipes to `setup/justfile`. Both run as core (non-optional) steps so drivers are available even if the user skips Autoware Debian.

### TIER IV camera driver — Was placeholder only

- **Status**: `just tier4-camera` was a stub that created a marker but installed nothing.
- **Fix**: Replaced with real install script (`setup/scripts/install-tier4-camera.sh`) that installs `ros-humble-usb-cam` and `v4l-utils`. The GMSL2-USB 3.0 Conversion Kit presents the TIER IV C1 as a standard UVC device. Udev rules template installed at `/etc/udev/rules.d/99-tier4-camera.rules` (requires port path configuration when hardware is connected). Note: `ros-humble-v4l2-camera` was originally planned but is unavailable in the Humble arm64 apt repo (404); `usb_cam` is the replacement.

### GNSS default receiver was `garmin`, not `ublox`

- **File**: `src/sensor_kit/golfcart_sensor_kit_launch/.../launch/gnss.launch.xml` line 3
- **Fix**: Changed default `gnss_receiver` from `garmin` to `ublox`.

---

### ~~TIER IV camera driver — `v4l2-camera` not installed on target~~ — Resolved

- **Was**: `ros-humble-v4l2-camera` planned but unavailable in Humble arm64 apt repo (404 Not Found).
- **Fix**: Switched to `ros-humble-usb-cam` (already installed on target, v0.8.1). Both are V4L2-based UVC drivers; `usb_cam` covers the same use case. Updated `setup/scripts/install-tier4-camera.sh` to use `usb_cam`. Resolved 2026-04-07.

---

## Reference: `just setup` on Fresh JetPack 6.2

The setup chain is:
```
ros2 → ros2-dev-tools → gdown → geographiclib → pacmod → dev-tools
→ autoware-debian → isaac-ros → python-deps → nebula-driver
→ ublox-driver → ublox-udev → tier4-camera → cyclonedds-sysctl
→ turbovnc-virtualgl → tamagawa-imu → ros-deps
```

| Step | Will it work? | Notes |
|------|--------------|-------|
| `ros2` | Yes | Installs `ros-humble-desktop` from packages.ros.org |
| `ros2-dev-tools` | Yes | Standard apt packages + `rosdep init` |
| `gdown` | Yes | `pip3 install --user gdown` (no PEP 668 on Ubuntu 22.04) |
| `geographiclib` | Yes | apt + `geographiclib-get-geoids` |
| `pacmod` | Yes | Adds AutonomouStuff apt repo |
| `dev-tools` | Yes | git-lfs, golang, pre-commit, plotjuggler |
| `autoware-debian` | Yes | Downloads JP6.2 deb — matches the target machine |
| `isaac-ros` | Yes (if selected) | Adds NVIDIA Isaac ROS apt repo, installs cuVSLAM/cuVGL |
| `python-deps` | Yes | `play_launch>=0.5.0,<0.6.0` available on PyPI |
| `nebula-driver` | Yes | Installs Nebula LiDAR 1.5.0 packages from apt |
| `ublox-driver` | Yes | Installs `ros-humble-ublox-gps`, `ublox-msgs`, `ublox-serialization` |
| `ublox-udev` | Yes | Copies udev rules, adds `dialout` group |
| ~~`usb-cam`~~ | Merged | Merged into `tier4-camera` recipe |
| `cyclonedds-sysctl` | Yes (if selected) | sysctl configuration |
| `turbovnc-virtualgl` | Yes (if selected) | Adds repos, installs, configures VirtualGL |
| `tamagawa-imu` | Stub | Prints warning, creates marker — does not install anything |
| `tier4-camera` | Yes | Installs `ros-humble-usb-cam`, `v4l-utils`, udev rules template |
| `ros-deps` | Yes | Fixed by `COLCON_IGNORE` (see Resolved section) |

All steps pass on JetPack 6.2. The Autoware Debian step installs `autoware-full-1-5-0`, which includes Nebula and u-blox drivers as transitive dependencies.

### Verified on target (2026-04-07)

| Component | Package | Installed? |
|-----------|---------|------------|
| ROS 2 Humble | `ros-humble-desktop` | Yes (0.10.0) |
| Autoware 1.5.0 | `autoware-full-1-5-0` | Yes (at `/opt/autoware/1.5.0/`) |
| Nebula LiDAR | `ros-humble-nebula-ros-1-5-0` | Yes (0.2.5) |
| u-blox GNSS | `ros-humble-ublox-gps` | Yes (2.3.0) |
| Camera (USB + TIER IV C1) | `ros-humble-usb-cam` | Yes (0.8.1) — single driver for USB and TIER IV C1 via UVC |
| CycloneDDS | `ros-humble-cyclonedds` | Yes (0.10.5) |
| GeographicLib | `geographiclib-tools` | Yes (1.52) |
| Tamagawa IMU | — | **No** (stub only) |
| PACMod | — | No (not needed) |
| Workspace build | `just build` | Yes (17 packages) |
| Disk space | — | 16 GB free of 54 GB (70% used) |
