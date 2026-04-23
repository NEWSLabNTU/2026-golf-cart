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


### `camera.launch.xml` still uses ZED driver, not USB camera

- **File**: `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/camera.launch.xml`
- **Status**: The launch file still includes `zed_wrapper/launch/zed_camera.launch.py` with `camera_model` defaulting to `zedxm`, left over from the previous Golf Cart system. Per the migration plan, the golf cart uses USB cameras (`camera_model:=usb`) and will later upgrade to TIER IV GMSL.
- **Impact**: Launching camera with `camera_model:=usb` does nothing useful — it just passes `usb` to the ZED wrapper. USB cameras (via `ros-humble-usb-cam`, already installed on target) are never started.
- **Action**: Rewrite `camera.launch.xml` to launch `usb_cam` for `camera_model:=usb` (and `none` for no camera). Keep a path for `camera_model:=tier4` when GMSL hardware arrives. Remove the ZED wrapper include.


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

### Nebula decoder silent — "Missed pointcloud output deadline" (LiDAR broadcasting)

- **Symptom**: `ros2 launch sensors.launch.xml launch_lidar:=true ...` produced no point clouds. `velodyne_ros_wrapper_node` logged `Missed pointcloud output deadline` every 5 s. Ping to `192.168.7.10` succeeded and `tcpdump -i enP5p4s0 udp port 2368` showed ~1400 pkt/s from the LiDAR.
- **Cause**: The VLP-32C's "Host (Destination) IP" was set to `255.255.255.255` (broadcast). Nebula binds its UDP socket to the unicast `host_ip` (`192.168.7.1:2368`, confirmed via `ss -nlup`), so the kernel dropped the broadcast packets before they reached the driver — tcpdump (link layer) still saw them.
- **Fix**:
  1. In the LiDAR web UI at `http://192.168.7.10` → *Network*, set destination IP to `192.168.7.1` (the host's iface IP), click **Set** and **Save Configuration**, then power-cycle the sensor. Verified 2026-04-23: packets now `192.168.7.10:2368 → 192.168.7.1:2368`, decoder deadline warnings dropped to zero.
  2. Added a destination-IP sanity check to `scripts/check/run.sh` (tcpdump-based) that warns when the LiDAR is broadcasting instead of unicasting to the host's iface IP. Requires `tcpdump` (install via `sudo apt install tcpdump`; optional `sudo setcap cap_net_raw,cap_net_admin=eip $(which tcpdump)` to avoid the `sudo` prompt).

### `scripts/check/sensors.launch.xml` — RViz config not loading from non-`scripts/check/` CWD

- **Symptom**: Launching from any CWD other than `scripts/check/` caused RViz to start with an empty config. A PointCloud2 display added by hand then subscribed to `/velodyne_points` with default **RELIABLE** QoS, while Nebula publishes **BEST_EFFORT**, producing: `New subscription discovered on topic '/velodyne_points', requesting incompatible QoS ... RELIABILITY_QOS_POLICY`.
- **Cause**: The launch used `args="-d sensors.rviz"` (relative path). Fix attempt 1 (`-d $(dirname)/sensors.rviz` inline on the node) also failed: `$(dirname)` is evaluated lazily and, after the `<include>` of `velodyne_launch_all_hw.xml`, resolved to `/opt/autoware/.../nebula_ros/launch/` rather than the top-level file's directory.
- **Fix**: Capture `$(dirname)` into an `<arg>` declared **before** any `<include>`, then reference via `$(var ...)` on the node:
  ```xml
  <arg name="rviz_config" default="$(dirname)/sensors.rviz"/>
  ...
  <node pkg="rviz2" exec="rviz2" name="rviz2_sensors" args="-d $(var rviz_config)"/>
  ```
  With the saved config loading correctly, the RViz subscription uses BEST_EFFORT and the QoS warning only appears once during RViz startup as a transient probe (benign, does not recur).

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
