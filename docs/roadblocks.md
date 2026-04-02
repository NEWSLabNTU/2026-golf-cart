# Known Roadblocks

**Target machine**: Fresh JetPack 6.2 (L4T R36.4, Ubuntu 22.04) with sensors connected.

---

## Open Issues


### Tamagawa IMU driver — Placeholder only

- **Package**: Unknown (driver source not confirmed)
- **Status**: `just tamagawa-imu` creates a marker file but installs nothing.
- **Impact**: IMU launch will fail until the driver is obtained and manually installed.
- **Action**: Request Turing Drive (the company) to provide the Tamagawa IMU driver package.


### VLP-32C mount calibration not measured

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 2-8
- **Status**: All transform values (x, y, z, roll, pitch, yaw) are zeros — placeholder, not measured.
- **Impact**: LiDAR point cloud will be misaligned with the vehicle frame. NDT localization accuracy will be degraded.
- **Action**: Physically measure VLP-32C mount position relative to `base_link` and update the calibration file.

### GNSS antenna calibration not measured

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 16-22
- **Status**: z value is `0.055` with comment "random value"; x and y are zero.
- **Impact**: GNSS initial pose will be offset from the true position.
- **Action**: Measure antenna position relative to `base_link` and update the calibration file.

### IMU mount calibration not measured

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 9-15
- **Status**: Mostly zeros except `z: -0.055` (likely placeholder).
- **Impact**: IMU data will be misaligned. Blocked by Tamagawa driver availability.
- **Action**: Measure once hardware is installed.

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
- **Fix**: Replaced with real install script (`setup/scripts/install-tier4-camera.sh`) that installs `ros-humble-v4l2-camera` and `v4l-utils`. The GMSL2-USB 3.0 Conversion Kit presents the TIER IV C1 as a standard UVC device. Udev rules template installed at `/etc/udev/rules.d/99-tier4-camera.rules` (requires port path configuration when hardware is connected).

### GNSS default receiver was `garmin`, not `ublox`

- **File**: `src/sensor_kit/golfcart_sensor_kit_launch/.../launch/gnss.launch.xml` line 3
- **Fix**: Changed default `gnss_receiver` from `garmin` to `ublox`.

---

## Reference: `just setup` on Fresh JetPack 6.2

The setup chain is:
```
ros2 → ros2-dev-tools → gdown → geographiclib → pacmod → dev-tools
→ autoware-debian → isaac-ros → python-deps → nebula-driver
→ ublox-driver → ublox-udev → usb-cam → cyclonedds-sysctl
→ turbovnc-virtualgl → tamagawa-imu → tier4-camera → ros-deps
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
| `usb-cam` | Yes | Installs `ros-humble-usb-cam` |
| `cyclonedds-sysctl` | Yes (if selected) | sysctl configuration |
| `turbovnc-virtualgl` | Yes (if selected) | Adds repos, installs, configures VirtualGL |
| `tamagawa-imu` | Stub | Prints warning, creates marker — does not install anything |
| `tier4-camera` | Yes | Installs `ros-humble-v4l2-camera`, `v4l-utils`, udev rules template |
| `ros-deps` | Yes | Fixed by `COLCON_IGNORE` (see Resolved section) |

All steps pass on JetPack 6.2. The Autoware Debian step installs `autoware-full-1-5-0`, which includes Nebula and u-blox drivers as transitive dependencies.
