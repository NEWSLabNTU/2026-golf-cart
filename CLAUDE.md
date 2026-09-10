# CLAUDE.md

Guidance for Claude Code when working with this repository.

## Project Overview
This is a golf cart autonomous driving system for 華夏科大 campus deployment, based on the Golf Cart platform. The system uses Autoware 2025.02 on AGX Orin (JetPack 6.2) with ROS 2 Humble.

**Key System Configuration:**
- **LiDAR**: Velodyne VLP-32C only
- **GNSS**: u-blox (F9R for practice, F9P for production)
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras (will upgrade to Tier IV cameras later)
- **Vehicle Interface**: Turing Drive packages (replaces Golf Cart custom PWM interface)
- **Map**: COSS practice map and the NTU campus map. A 華夏科大 campus HDMap is PLANNED and does not exist; `data/huaxia-campus/` is not present.
- **Localization**: Autoware NDT scan matching (GNSS for initialization)
- **Planning**: Autoware built-in planner (enabled, not manual control)

**Migration Status**: See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) for detailed migration plan from Golf Cart to golf cart system.

## Essential Commands

### Build & Run
```bash
./setup.sh              # Interactive setup (ROS 2, dependencies)
./setup.sh status       # Check installation status
just build              # Build all packages
just test               # Run tests
just launch             # Launch system (web UI: http://localhost:8081)
just launch "..."  # Launch with parameters
just launch tx=on       # ⚠️ CAN TX live: this can drive the cart
just clean              # Remove build artifacts
just checkout           # Update git submodules
just --list             # Show all available commands
```

### Command modules

Grouped families live in `just/*.just` and are reached as `just <module> <recipe>`
(or `just <module>::<recipe>`). A bare `just <module>` lists that module:

| module | covers |
|---|---|
| `ntu-test` | NTU campus NDT replay — run `just ntu-test` for the ordered sequence |
| `indoor-test` | indoor cold start from the reflective board, init-only replay of the basement bag — `just indoor-test` for the sequence |
| `bag` | rosbag record, play, merge, fetch |
| `record` | recording lifecycle, independent of the launch |
| `service` | multi-machine systemd units, `doctor`, `host-status` |
| `vehicle` | vehicle interface bring-up, manual control, control tests |
| `can` | CAN record, replay, decode |
| `tool` | RViz, PlotJuggler, TUI, keyboard controller |
| `diag` | diagnostic graph: QoS checks, leaf listing, fault injection |

`build`, `test`, `clean`, `launch*`, `stop-all` and `logs` stay at the root —
they are the daily verbs, and a module may not share a name with a recipe
(`mod launch` beside `launch:` is a hard error that breaks the whole justfile).

`just --list` expands modules because the default recipe passes
`--list-submodules`; without it each module collapses to one line.

### Tools
```bash
just tool rviz          # Launch RViz
just tool plotjuggler   # PlotJuggler visualization
just tool controller    # Keyboard manual control
just tool tui           # Drive monitor TUI (pose, speed, states)
just tool sphere        # Sensor transforms: cameras and LiDARs on one sphere
just tool sphere-demo   # Same display, synthetic sensors, no vehicle
```

### Vehicle Interface (standalone, no Autoware)
```bash
just vehicle interface                       # CAN RX only on can0 — cart cannot move
just vehicle interface can=vcan0             # bench, against mock_vcu
just vehicle interface converter=on          # + robot_state_publisher + velocity converter
just vehicle interface tx=on                 # ⚠️ CAN TX live: this can drive the cart
just vehicle manual-control                          # keyboard teleop — SECOND terminal
```
Options are `KEY=VALUE`, any order: `can=`, `tx=on|off`, `converter=on|off`.
`tx` defaults to `off` on every path. Keyboard control is a separate recipe
because it reads a raw tty: it must own a real terminal, so it cannot be a node
inside a launch file (play_launch does not support `launch-prefix` either).

### Control Testing
```bash
just vehicle control-straight   # Run 10m straight trajectory (needs: just vehicle interface converter=on)
just vehicle control-circle     # Run circular trajectory
```

### Rosbag
```bash
just bag record         # Record outdoor sensor topics
just bag play           # Play most recent recording
```

### Simulation
```bash
just launch-sim-planning  # Autoware planning simulator
just launch-sim-logging   # Logging simulation (rosbag replay)
just sim-coss-park        # Full COSS Park simulation scenario
```

### Manual Build
```bash
source install/setup.bash
colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

# Or use justfile
just build

# Build specific package (must include all standard flags)
colcon build --base-paths src --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release --packages-select <package_name>
```

**Important**: Always use `--base-paths src` and other standard flags from `just build` when running colcon commands manually.
**Important**: Push a submodule commit to its fork before committing the parent's pointer to it. See [Submodule Pointer Rule](#submodule-pointer-rule).
**Important**: Respect the .gitconfig in the repository when committing. Use Conventional Commits format (`feat`, `fix`, `chore`, `docs`, `refactor`, etc.) for commit messages.

## Architecture

### Core Structure
- **src/launcher/golfcart_launch/** - Main launch configurations and system monitor
  - Provides web-based system monitor at http://localhost:8080/
  - Main launch file: `golfcart.launch.yaml`
- **src/param/autoware_individual_params/** - Parameter configurations for different sensor kits
- **src/sensor_kit/golfcart_sensor_kit_launch/** - Sensor integration and launch files
- **src/vehicle/golfcart_vehicle_launch/** - Vehicle interface and description
- **src/sensor_component/external/** - External sensor drivers (submodules)

### Key Submodules
**Golf Cart Migration Notes:**
- **Retained**: autoware_manual_control, gnss_locator, ros-nmea-reader
- **To Replace**: ros2_mpu9250_driver → Tamagawa IMU driver (pending)
- **Camera**: USB cameras (no ZED submodule needed initially)
- **Vehicle Interface**: Will use Turing Drive packages (to be added)

Submodules:
- autoware_manual_control - Keyboard control interface
- golfcart_sensor_kit_launch - Sensor kit configurations
- gnss_locator - GNSS positioning
- ros2_mpu9250_driver - IMU driver (to be replaced with Tamagawa)
- ros-nmea-reader - NMEA GPS data parser

### config/ is the single source of truth

Everything that varies by machine, deployment or session lives in `config/`, and
no script hardcodes any of it. See [config/README.md](config/README.md).

| File | Decides |
|---|---|
| `config/host` | which machine this checkout is (`master`/`orin`). **Gitignored** |
| `config/multi_machine.conf` | the other host's `user@addr`, repo path, ssh key, master IP |
| `config/sensors.conf` | `IMU_SOURCE`, `CAMERA_MODEL` — env vars, not launch args |
| `config/vehicle.conf` | `GOLFCART_TX_ENABLED` — CAN TX master enable, same reason |
| `config/recording/*_topics.txt` | what each host records |
| `config/cyclonedds/*.xml` | DDS profiles, one per role |

`scripts/env.sh` is the matching single source for the *environment* — Autoware
sourcing, `CYCLONEDDS_URI`, `RMW_IMPLEMENTATION`, PATH, `GOLFCART_BAG_DIR`.
`.envrc` sources it, and so do the systemd unit exec scripts. Do not re-derive any
of that in a new script; source `scripts/env.sh` and let it resolve.

Units state their role with `GOLFCART_ENV_ROLE`, which outranks `config/host`: a
unit must not depend on a file someone can edit underneath it.

### Recording: first-hand topics only

`config/recording/*_topics.txt` record **driver output**. Topics a node computed
from other topics — the concatenated cloud, the corrected IMU — are commented out,
because replay is a logging simulation: the single-machine stack runs with drivers
disabled against the merged bag and recomputes them with current parameters
instead of the ones frozen at record time.

A topic that is expected but dead stays listed and records zero messages. An empty
topic says "this device was expected and was silent"; an absent one says nothing.

NDT needs velocity, via `/vehicle/status/velocity_status` →
`vehicle_velocity_converter` → `gyro_odometer` → `ekf_localizer`, so the vehicle
interface must run while recording. The VCU does not need autonomous mode:
`VelocityReport` comes from the decoded MTR frame and is gated on neither
`tx_enabled` nor the control mode — but it *is* gated on frame freshness, so check
`ros2 topic hz` rather than assume.

### The vendor CAN DBC

`golfcart_vehicle_interface` generates CAN bindings from Turing Drive's
`CAX_ADS_CAN.dbc` at build time. The file is proprietary and gitignored, so only
the machine it was copied to has it. `just build` **skips the package** when
neither `CAX_ADS_DBC` nor a DBC in the crate root exists — the orin has no CAN bus
and needs neither. Do not "fix" that skip; without it the orin cannot build at all.

### Submodule Pointer Rule

**Never commit a submodule pointer to a commit that is not yet on GitHub, on a
long-lived branch of its NEWSLabNTU fork.**

A superproject commit records a submodule as a bare SHA and cannot describe what
that SHA should contain. If it is not reachable on the fork, a fresh clone fails
at `git submodule update` with `upload-pack: not our ref <sha>`, and the parent
commit is unusable — there is nothing in it to recover the intent from.

The second half is the one that gets missed: **a feature branch is not enough.**
A pointer whose only home is `feat/…` breaks the moment that branch is deleted
after merging — routine hygiene that silently invalidates history.

Order of operations:

1. Push the submodule commit to its fork, on a long-lived branch
   (`main`, `2026-golf`, `2026-golfcart`, … — whichever that repo actually uses).
2. Then commit and push the parent's pointer update.

Audit every pointer before pushing the parent:

```bash
git submodule foreach --quiet \
  'echo "$sm_path $(git branch -r --contains HEAD | tr -d " " | tr "\n" " ")"'
```

Any submodule printing no remote branch, or only a `feat/…` branch, is not ready
to be pointed at. Full workflow in [CONTRIBUTING.md](CONTRIBUTING.md#submodule-workflow).

### Data Structure
- **data/COSS-map-planning/** - Practice map (from Golf Cart)
- **data/huaxia-campus/** - planned production map. DOES NOT EXIST; nothing may depend on it.
- **data/models/** - ML models (YOLOX, CenterPoint, TensorRT)

### Build Artifacts
- **build/** - Compiled binaries (gitignored)
- **install/** - Installed packages and setup files
- **log/** - Build and runtime logs

## Development Workflow

### Sensor Configuration
**Golf Cart Configuration:**
- **LiDAR**: Velodyne VLP-32C only (no Robin-W or Cube1)
- **GNSS**: u-blox F9R (practice) → F9P (production)
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras → Tier IV GMSL cameras (future upgrade)

Sensor configurations are in `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/`

### Launch System
- Main launch uses Autoware's standard launch system
- Vehicle model: `golfcart_vehicle`
- Sensor model: `golfcart_sensor_kit`
- Default map: `./data/COSS-map-planning`. The production map is planned, not present.

### Writing launch XML

**Never put a double hyphen inside an XML comment.** `--` is illegal there per the
XML spec — it ends the comment early — so a file containing one is rejected
outright, by every parser, before any launch logic runs. The comments in this
repository carry a lot of reasoning, and the natural things to write in them are
exactly the things that break this: a command-line flag (`--parser python`,
`--symlink-install`, `--packages-select`), or an em dash typed as two hyphens.

The failure is loud but the message does not name the cause:

```
Error: Rust parser error while parsing golfcart_launch: XML parsing error: comment at 97:5 contains '--'
ParseError: not well-formed (invalid token): line 104, column 61
```

Write the flag in prose instead ("play_launch's Python parser", "colcon's
symlink install"), and use a real em dash or a single hyphen for punctuation.
Same rule for `.launch.xml`, `.urdf`, `.xacro` and `package.xml`. YAML launch
files are unaffected — `#` comments have no such restriction, which is why
`golfcart.launch.yaml` can say `--parser` freely.

### Launch Parameters for Golf Cart

#### LiDAR Configuration
```bash
# Velodyne VLP-32C (golf cart standard)
just launch "lidar_model:=vlp32c"
```

#### Camera Configuration
`camera.launch.xml` is the single entry point for every camera. The Autoware
sensing launch chain forwards only a fixed set of arguments, so through `just
launch` the selection is made by environment variable:

```bash
# Three GMSL cameras on the Advantech (default)
CAMERA_MODEL=gscam just launch

# ZED X — set automatically for the orin host; also selectable directly
ros2 launch golfcart_sensor_kit_launch camera.launch.xml camera_model:=zedx

# No camera
CAMERA_MODEL=none just launch
```

#### GNSS Configuration
```bash
# u-blox GNSS (golf cart standard)
just launch "gnss_receiver:=ublox"
```

**Usage:**
```bash
# Full visual localization (requires visual map)
just launch "pose_source:=visual visual_map_dir:=/path/to/visual_map"

# Visual odometry only (no global init, manual pose required)
just launch "pose_source:=isaac"
```

**Creating Visual Maps:**
```bash
# Golf cart standard configuration
just launch "lidar_model:=vlp32c camera_model:=usb gnss_receiver:=ublox"

# Indoor testing without GNSS
just launch "lidar_model:=vlp32c camera_model:=usb use_gnss:=false"
```

### Python Packages
Standard ROS 2 conventions: setup.py/setup.cfg, test files for copyright/flake8/pep257.

### Setup Script Architecture

`./setup.sh` is a launcher: it execs `setup/main.py`. Everything with logic in
it is Python, and all of it is standard library.

```bash
./setup.sh                       # pick a preset, then the steps
./setup.sh --status              # what is installed
./setup.sh --list                # every step, and whether it applies here
./setup.sh --run --profile vehicle -y   # unattended
./setup.sh --run --all --skip tensorrt-engines
./setup.sh --dry-run --json      # the resolved selection, machine-readable
./setup.sh --rerun opencv        # forget one step's state, run it again
./setup.sh --plain               # numbered menu, for a dumb terminal
```

**Every step is declared in `setup/golfcart_setup/registry.py` and nowhere
else.** Adding one means adding a `Step(...)` there; there is no wrapper recipe
to write and no menu array to update. This replaced a system in which the menu
offered 16 entries while `just setup` ran 25 steps -- the thirteen invisible
ones included two that wrote udev rules and three that installed sensor drivers.

`setup/justfile` is **gone**. Setup does not use `just`; `just` is instead an
ordinary setup step, since the rest of the repo needs it.

**State is `setup/.state.json`, not marker files.** It records status, timestamp
and a digest of what each step would run, so a step whose install script has
been edited shows as *stale* rather than done -- the case marker files could not
express. An existing `.markers/` directory is imported on first run.

**The menu is stdlib `curses`, and there is no venv.** It was Textual, which
cost 5.8 MB of widgets in a 15 MB venv and ~54 s on a cold first run while `uv`
fetched a Python, to draw 25 checkboxes; `curses` imports in 3 ms. The preset is
asked first, on its own screen, then the step list opens seeded from it (`p`
re-asks without leaving). Arrows move, space ticks, and enter opens a review
screen before anything installs. `--plain` is the numbered fallback, used
automatically when curses cannot drive the terminal.

**Five presets, and `vehicle` is `dev` plus one group.**

| profile | |
|---|---|
| `dev` | laptop, workstation, PC: dev tools, libraries, sysctl, loopback multicast |
| `vehicle` | `dev` plus the **System config** group: sensor udev, CAN, PTP, camera modules |
| `all` | every step, including the slow and opt-in ones |
| `none` | nothing preselected |
| `ci` | headless, build dependencies only |

`all` and `none` are computed in `Step.default_for`, so a new step joins them
without being listed. There is no per-board profile: a Jetson on a desk is a
development machine and a Jetson in the cart is the vehicle. `--profile laptop`
and `--profile orin` still work and print the new name.

**The OS is checked before anything runs.** Ubuntu 22.04 proceeds; another
Ubuntu or a Debian warns and proceeds; anything else stops and names
`--ignore-os-check`. Every install script writes 22.04 apt package names, so
this is not a style preference.

Dropped 2026-09-02, with reasons in the registry docstring: `pacmod`
(unreferenced, and added an apt source with `trusted=yes`), `gdown` (unused),
`isaac-ros` (out of the plan).

**Iceoryx was removed from the project entirely**, not just from setup: the
runtime, `config/iceoryx/`, `scripts/iceoryx/`, the `iox-roudi.service` unit, the
`<SharedMemory>` blocks in all three CycloneDDS profiles, and the guards in
`scripts/env.sh` and the justfile. It capped publisher ports at a compile-time
constant this stack exceeds and aborted at participant creation rather than
falling back. See `config/README.md`.

### Preset System

Golf Cart uses a **preset system** (following Autoware's pattern) to manage component-level configurations. Presets group related parameters for common use cases.

#### How Presets Work

**Preset files** are YAML launch files that define launch arguments:

```yaml
# config/perception/preset/lidar_only_preset.yaml
launch:
  - arg:
      name: perception_mode
      default: "lidar"
  - arg:
      name: use_traffic_light_recognition
      default: "false"
  # ... more args
```

**Main launch file** includes presets:

```yaml
# golfcart.launch.yaml
- arg:
    name: perception_preset
    default: "lidar_only"

- include:
    file: "$(find-pkg-share golfcart_launch)/config/perception/preset/$(var perception_preset)_preset.yaml"
```

**Benefits**:
- ✅ Select presets for convenience: `perception_preset:=camera_lidar_fusion`
- ✅ Override individual parameters for experimentation: `use_traffic_light_recognition:=true`
- ✅ Easy to extend: Add new preset file without modifying launch files

#### Creating Custom Presets

1. Copy existing preset: `cp lidar_only_preset.yaml custom_preset.yaml`
2. Modify parameter defaults in the new file
3. Use with: `just launch perception_preset:=custom`

**Note**: Preset files must use `<name>_preset.yaml` naming convention.

#### Available Presets

**Perception** (`config/perception/preset/`):
- `lidar_only` - LiDAR only, no camera features (default)
- `camera_lidar_fusion` - Camera + LiDAR with traffic light recognition
- `minimal` - Minimal features for development/debugging

**Localization** (`config/localization/preset/`):
- `default` - Gyro odometry twist estimation (default)
- `eagleye` - GNSS-based odometry (requires GNSS)

See `config/{perception,localization}/preset/README.md` for detailed documentation.

## Quick Reference

### Common Launch Parameters

#### Preset-Based Configuration (Recommended)
```bash
# Perception presets (controls perception mode and features)
perception_preset:=lidar_only           # Default: LiDAR only, no camera features
perception_preset:=camera_lidar_fusion  # Camera + LiDAR with traffic light recognition
perception_preset:=minimal              # Minimal features for development

# Localization presets (controls twist estimation)
localization_preset:=default            # Default: gyro_odom
localization_preset:=eagleye            # GNSS-based odometry (requires GNSS)

# Example: Use camera-lidar fusion
just launch perception_preset:=camera_lidar_fusion
```

#### Sensor Configuration
```bash
# Sensor suites (predefined combinations)
sensor_suite:=vlp32c             # Velodyne VLP-32C

# Individual sensor overrides
lidar_model:=vlp32c
camera_model:=gscam|zedx|none   # env ONLY - see below
imu_source:=xsens|zed           # env ONLY - see below
gnss_receiver:=ublox|septentrio|garmin|none
```

#### GPU acceleration: one coarse switch, two fine ones

**CUDA is the default.** All three are launch arguments; none is set from the
environment by a user.

```bash
just launch                          # CUDA preprocessing + concatenation (default)
just launch use_cuda:=false          # both back on CPU
just launch pointcloud_backend:=cpu  # same, spelled out
```

`use_cuda` sets the default for `pointcloud_backend` (`cpu|cuda`) and nothing
else. An explicit `pointcloud_backend:=` wins over it, because a launch argument
default is only consulted when the caller supplied nothing.

**`pose_source` is deliberately NOT governed by `use_cuda`.** It selects a
localization *method* (`ndt`, `cuda_ndt`, `aruco`, `yabloc`, `eagleye`), and only
two of those are the same algorithm on different hardware. Deriving it from a GPU
switch meant `use_cuda:=false` silently rewrote a deliberate `yabloc` or
`eagleye` choice to `ndt`. It now has its own default, `cuda_ndt`:

```bash
just launch pose_source:=ndt      # CPU NDT; the fallback if init hangs
just launch use_cuda:=false       # CPU preprocessing, still cuda_ndt
```

The same pair exists in `logging_simulation.launch.yaml` and
`ntu_logging_sim.launch.xml`, so a replay defaults to the stack the vehicle runs.

**The two stages have very different evidence behind them.**

`pointcloud_backend:=cuda` is measured: a full NDT replay of the NTU CSIE-1 bag
scored cpu at 0.038 m scatter p95 / 0.179 deg yaw p95 and cuda at 0.035 / 0.167
over ~600 m, so it does not regress localization.

`pose_source:=cuda_ndt` is the **default**, and is half done. Per-frame it is
the faster of the two: 40.5 ms mean on the Orin against Autoware's own 47.0 ms
on the same bag, at 3.0 cm RMSE, holding 10 Hz in real time.

**Its align service has been measured at ~23 s against the caller's deadline**,
so `/localization/initialize` times out and the scan matcher stays latched off.
If the stack comes up and never localizes, that is this, and the fallback is
`pose_source:=ndt`. Re-measure on the Orin before assuming the number holds: the
per-frame path improved 10x there and the align path may have moved with it. See
[docs/handover/2026-08-30-cuda-pipeline-to-orin.md](docs/handover/2026-08-30-cuda-pipeline-to-orin.md).

**`camera_model`, `imu_source` and `tx_enabled` do NOT work as launch arguments.** They reach
`golfcart_autoware.launch.xml`, but the path onwards runs through
`tier4_sensing_component.launch.xml` and `tier4_sensing_launch/sensing.launch.xml`
— installed Autoware files that forward a fixed set of arguments and drop the
rest. The sensor kit reads `$(env IMU_SOURCE xsens)` / `$(env CAMERA_MODEL gscam)`
instead, so `just launch "imu_source:=zed"` looks like it works and does nothing.
Set them in `config/sensors.conf`, which `scripts/env.sh` sources for both shells
and units.

**`use_cuda`, `pointcloud_backend` and `pose_source` ARE real launch arguments**,
and cross that same gap without becoming config knobs. `golfcart.launch.yaml`
declares them and `set_env`s `POINTCLOUD_BACKEND` immediately before the include,
so the value reaches the sensor kit through the environment while the interface
stays `key:=value`. Forwarding it as an argument would appear to work under
play_launch, whose parser does not scope includes the way `ros2 launch` does, and
would then silently stop working under stock `ros2 launch`; the environment
survives both. Nothing needs `POINTCLOUD_BACKEND` set in a shell.

`pointcloud_backend` picks where the **whole preprocessing and concatenation
stage** runs, not just the concatenator:

| | `cpu` (default) | `cuda` |
|---|---|---|
| per-LiDAR | crop box, distortion corrector, ring outlier filter (3 nodes) | `CudaPointcloudPreprocessorNode` (1 node) |
| concatenation | `PointCloudConcatenateDataSynchronizerComponent` | `CudaPointCloudConcatenateDataSynchronizerComponent` |

**The drivers stay on the CPU in both modes.** Nebula has no CUDA decoder for
Velodyne, only an unmerged Hesai-only PR, and the Seyond driver is a vendor CPU
binary. That costs little: the host-to-device upload happens at the
preprocessor's input, which is what Autoware's own `pipeline_mode:=cuda` does.

Halves cannot be mixed, and the launch refuses to try. The CUDA concatenator
subscribes over `cuda_blackboard` and needs the `pointcloud_before_sync/cuda`
negotiation topic that only the CUDA preprocessor publishes.

**Only the Velodyne is preprocessed.** The Seyond publishes `PointXYZIRC` with no
per-point time field, so as configured it cannot be deskewed by CPU or GPU; it
reaches the concatenator raw.

**Corrected 2026-08-30: the vendor driver already has the field.** It ships
`seyond::PointXYZIT` with a per-point `double timestamp`, selected by
`POINT_TYPE` in its CMakeLists and its own default. What is missing is the
conversion into Autoware's `PointXYZIRCAEDT`, whose `time_stamp` is an offset
from the scan start rather than an absolute double. That is a field mapping and
some arithmetic in this repo, not a vendor change. See
docs/research/localization/robinw-autoware-pipeline.md.

**And there is a second, separate gap found 2026-08-30.** `NEWSLabNTU/seyond_ros_driver`
already emits Autoware's `PointXYZIRC` (`8e99e38`), but registers the field
*names* as `I`, `R`, `C` where Autoware compares them literally against
`intensity`, `return_type`, `channel`
(`autoware_pointcloud_preprocessor/src/utility/memory.cpp`). So the cloud is
rejected by every preprocessing node today, independently of the timestamp
question. Three string literals. See docs/roadmaps/6-robinw-localization.md, R0-a.

Full reasoning and the measurements behind it:
[docs/research/sensing/autoware-cuda-pointcloud-chain.md](docs/research/sensing/autoware-cuda-pointcloud-chain.md)
and [docs/research/sensing/lidar-pipeline-starvation.md](docs/research/sensing/lidar-pipeline-starvation.md).

`tx_enabled` is the same story one branch over: `tier4_vehicle_launch/vehicle.launch.xml`
forwards only `vehicle_id`, `raw_vehicle_cmd_converter_param_path` and
`initial_engage_state`. `vehicle_interface.launch.xml` reads
`$(env GOLFCART_TX_ENABLED false)`; `config/vehicle.conf` holds the resting value,
and `just launch tx=on` / `just launch-up tx=on` / `just launch-all tx=on` set it
per invocation (`scripts/tx_switch.sh` strips the token). Not sticky on purpose:
an invocation without `tx=`, and `just launch-down`, both clear it.
`just vehicle interface tx=on` is a separate path that bypasses Autoware and
passes the launch argument for real.

`launch-all` applies TX to the **master only** — it does not forward the token to
the orin, which has no CAN bus. `just service host-status` / `just service status` print
the effective value and where it came from (`unit-env` or `config/vehicle.conf`).

#### Localization (pose_source)
```bash
# pose_source options:
pose_source:=ndt       # Default: LiDAR NDT scan matching (Autoware, requires point cloud map)
pose_source:=cuda_ndt  # CUDA-accelerated NDT (1.3-1.6x faster, 57% less CPU on Jetson)
pose_source:=isaac     # cuVSLAM visual odometry only (relative tracking, manual init)
pose_source:=visual    # cuVGL + cuVSLAM (camera-only, auto init from visual map)

# For visual localization, specify map directory:
visual_map_dir:=/path/to/visual_map  # Contains cuvgl_map/, cuvslam_map/
```

**Working in `cuda_ndt_matcher`? Euler angles are a trap there.** A pose vector
`[x, y, z, roll, pitch, yaw]` in that crate is Autoware's convention,
**R = Rx·Ry·Rz**. nalgebra's `euler_angles()` and `from_euler_angles()` compose
the **reverse**, R = Rz·Ry·Rx. The two agree only when at most one angle is
non-zero, and both are `(f64, f64, f64)`, so nothing catches a mix-up — it has
produced three separate bugs, each found by a number looking wrong rather than by
a test failing. Use `optimization::types::{isometry_to_pose_vector,
pose_vector_to_isometry, rotation_from_pose_angles, pose_angles_from_rotation}`,
or `isometry_to_transform_matrix` when a kernel wants a 4x4 and you already hold
an isometry. Any test for this needs roll, pitch **and** yaw all non-zero. Full
detail, including two ways such a test silently proves nothing, is in that
submodule's `CLAUDE.md` under *Coding Conventions*.

It is also why `converged_param_nearest_voxel_transformation_likelihood` has been
re-derived more than once: the 2026-08-03/04 occurrences moved the *scale* of
published NVTL, so scores recorded before them do not compare with scores after.
The 2026-08-30 occurrence did not — it reached only a dormant covariance mode and
the RViz score overlay, and per-scan NVTL measured 3.138 either side of the fix.
The comment at that parameter in
`cuda_ndt_matcher_launch/config/cuda_scan_matcher.param.yaml` carries the
history; re-derive the gate from a healthy run's score distribution, never
inherit it.

#### Pose initializer (what seeds `/localization/initialize`)
```bash
pose_initializer:=gnss             # Default: Autoware's GNSS-seeded initializer; unchanged behaviour
pose_initializer:=board            # reflective_pose_detector finds the retroreflective board and calls the service
pose_initializer:=none             # nothing seeds it: RViz 2D Pose Estimate or /initialpose3d
reflective_pose_scenario:=basement # scenarios/<name>/detector.yaml for board; basement | sim
```

Orthogonal to `pose_source`: it names what *seeds* localization, `pose_source`
names what *tracks* afterwards, so `board` composes with `ndt` and `cuda_ndt`
alike. Anything but `gnss` forces the pose initializer's `gnss_enabled` off
regardless of `use_gnss`, so Autoware's `pose_initializer` waits on the service
instead of on a fix; the default starts neither board node. The two nodes come
up as `/localization/board_detector` and `/localization/board_pose_initializer`,
included from `golfcart_autoware.launch.xml` directly so their config reaches
them as arguments. Config lives in
`golfcart_launch/config/localization/reflective_pose/`: `board_detector.param.yaml`
(vehicle wiring: frames, `accumulate_scans`, the motion-guard twist topic) and
`board_pose_initializer.param.yaml` (handoff policy) are per vehicle;
`scenarios/<name>/detector.yaml` (board, gates, covariance) is per site, and
`scenarios/basement/falcon_map.yaml` is the offline anchoring counterpart.
`board_input_pointcloud` is the cloud the detector reads, defaulting to the
VLP-32C's raw driver topic `/sensing/lidar/vlp32/velodyne_points` because that
is the one still in frame `velodyne` with intensity intact.

`just indoor-test` replays the basement bag against `data/basement-indoor/`
through `indoor_logging_sim.launch.xml` (`bag` paused, `up`, `rviz`, `resume`,
`down`; `fake-tf` only for the standalone detector). The bag has one topic and
no velocity, so the replay proves initialization only. Design and status:
[docs/roadmaps/7-reflective-board-cold-start.md](docs/roadmaps/7-reflective-board-cold-start.md).

#### System Features
```bash
# Localization
use_gnss:=false                  # Indoor operation (no GNSS)
use_ntrip:=true                  # RTK positioning (ublox only)
use_mapless_mode:=true           # Indoor operation without localization

# Perception
launch_perception:=false           # Disable entire perception module

# Advanced: Override preset-defined parameters
perception_mode:=lidar                      # Override preset perception mode
use_traffic_light_recognition:=true        # Override preset setting
use_detection_by_tracker:=false            # Override preset setting
use_image_segmentation_based_filter:=false # Override preset setting
use_pointcloud_map:=true                   # Override preset setting
twist_source:=gyro_odom|eagleye            # Override preset twist source
```

### Vehicle Interface (Quick Ref)

**Motor PWM** (PCA9685 I2C, channel 0):
- Range: 280-460, Init: 370 (neutral), Brake: 340
- Forward: 371-460, Reverse: 280-369
- Multi-mode controller: Emergency Brake, Full Stop, Deadband Hold, Active Control (PID)

**Steering PWM** (PCA9685 I2C, channel 1):
- Range: 350-450, Init: 400 (center)
- Max angle: 0.349 rad ≈ 20°
- Dual-mode controller: Fallback (v<0.3m/s), Normal (yaw rate feedback)

**Velocity Sensing**:
- Hall effect sensor (KY-003) on GPIO
- Parameters: `params/velocity_report.yaml`

**Actuator Parameters**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/params/actuator.yaml`

## Documentation

### Main Documentation Book (MkDocs)
- **Framework**: MkDocs with Material theme (following Autoware conventions)
- **Setup**: `cd book && just setup` (installs dependencies)
- **Build**: `cd book && just build` (builds to `site/`)
- **Serve**: `cd book && just serve` (http://localhost:3000)
- **Source**: `book/src/` (Markdown files)
- **Config**: `book/mkdocs.yml`

**Features**:
- ✅ Material Design theme
- ✅ Mermaid diagram support
- ✅ Multi-language (English + 繁體中文)
- ✅ Math rendering (MathJax)
- ✅ Search, dark mode, mobile responsive

**Key Guides** (in book):
- **Sensor Integration**: `book/src/guides/sensor-integration/`
  - Simple usage guide, sensor-specific details
- **Vehicle Control**: `book/src/guides/vehicle-control/`
  - Overview, hardware, control details, tuning & testing
  - Multi-mode controllers, PCA9685 I2C, hall effect sensor, PID tuning

### Legacy Guides (docs/)
| Guide | Description |
|-------|-------------|
| [docs/guides/sensor_configuration.md](docs/guides/sensor_configuration.md) | Sensor suites, NTRIP/RTK, localization |
| [docs/guides/vehicle_calibration.md](docs/guides/vehicle_calibration.md) | PWM control, PID tuning, testing tools |
| [docs/guides/lidar_integration.md](docs/guides/lidar_integration.md) | Velodyne VLP-32C, TensorRT |
| [docs/guides/control_testing.md](docs/guides/control_testing.md) | Control system testing procedures |
| [docs/guides/mrm_configuration.md](docs/guides/mrm_configuration.md) | MRM (emergency stop) configuration |
| [docs/multi-machine.md](docs/multi-machine.md) | Two-machine operation: `just launch-all`, per-host DDS profiles, orin lifecycle, recording |
| [docs/design/zed_camera_integration.md](docs/design/zed_camera_integration.md) | ZED X launch structure, published topics, TF ownership split between the ZED driver and Autoware, IMU source selection |
| [docs/roadmaps/2-zed-camera-integration.md](docs/roadmaps/2-zed-camera-integration.md) | ZED integration phase: work items, acceptance criteria, deferred field measurements |
| [docs/guides/isaac_vslam_testing.md](docs/guides/isaac_vslam_testing.md) | Isaac SLAM testing |
| [docs/design/isaac_vslam_integration.md](docs/design/isaac_vslam_integration.md) | Isaac SLAM architecture |
| [docs/research/localization/ndt_parameter_tuning_coss_map.md](docs/research/localization/ndt_parameter_tuning_coss_map.md) | NDT tuning research |
| [docs/research/localization/ndt_tuning_ntu_campus.md](docs/research/localization/ndt_tuning_ntu_campus.md) | NTU NDT tuning: crop range, voxel size, why the NVTL gate is not portable, and the traps |
| [docs/research/safety/assurance-2.0-for-autoware-llm.md](docs/research/safety/assurance-2.0-for-autoware-llm.md) | Assurance 2.0 survey: formal safety case for Autoware + LM integration tiers |
| [docs/design/lm_driving_tuning_workflow.md](docs/design/lm_driving_tuning_workflow.md) | LM driving integration: BEV-token input, zone-mask output, verifier-gated tuning workflow |
| [docs/superpowers/specs/2026-07-27-indoor-artag-localization-design.md](docs/superpowers/specs/2026-07-27-indoor-artag-localization-design.md) | Indoor AR-tag + NDT localization design: tags replace GNSS for init, EKF correction, and NDT regularization |
| [docs/roadmaps/3-indoor-localization.md](docs/roadmaps/3-indoor-localization.md) | Indoor localization phase master: sub-phases A (calibration) → B (mapping) → C (tag map) → D (runtime) |
| [docs/roadmaps/2-camera-image-pipeline.md](docs/roadmaps/2-camera-image-pipeline.md) | Camera image pipeline: why JPEG, the `CompressedImage.format` contract, zero-copy capture, and the rclrs image_transport crate |
| [docs/design/diagnostics-and-mrm-visualization.md](docs/design/diagnostics-and-mrm-visualization.md) | Diagnostics / MRM chain as it actually runs, why `/diagnostics_agg` is never published here, which ROS and Autoware viewers already exist, and the proposed views split across play_launch vs `golfcart_system_monitor` |
| [docs/roadmaps/4-diagnostics-observability.md](docs/roadmaps/4-diagnostics-observability.md) | Phase 4-O: why the AD API is the subscription surface, why `transient_local` on the struct topic blocks the design, and the O-A..O-F work items |
| [docs/roadmaps/5-sphere-sensor-view.md](docs/roadmaps/5-sphere-sensor-view.md) | Phase 5: RViz2 spherical sensor view — rendering-only extrinsic check, S1..S4, and why the sphere radius bounds what it can prove |
| [docs/guides/sphere_sensor_view.md](docs/guides/sphere_sensor_view.md) | Spherical sensor view: how to read a seam, what sweeping the radius proves, and what the tool cannot tell you |
| [docs/design/sphere_sensor_view.md](docs/design/sphere_sensor_view.md) | Spherical sensor view design: the display plugin, what is vendored from rviz_satellite, the two cloud modes |

## Known Issues

- **Steering reversed**: Left/right inverted in manual control
- **Network monitor errors**: AWS Greengrass socket errors (non-critical, ignore)
- **Isaac ROS GXF libraries**: If `pose_source:=visual` or `pose_source:=isaac` fails with "libgxf_*.so not found", the GXF library paths are not in `LD_LIBRARY_PATH`. Re-source the setup files:
  ```bash
  source /opt/ros/humble/setup.bash
  source /opt/autoware/1.5.0/setup.bash
  source install/setup.bash
  ```
  GXF libraries are located at `/opt/ros/humble/share/*/gxf/lib/` and should be added by Isaac ROS environment hooks.

## NDT Localization (Golf Cart)

### Overview
The golf cart uses Autoware's built-in NDT (Normal Distributions Transform) scan matching for localization:
- **Input Requirements**: LiDAR point cloud, IMU data, speedometer from vehicle interface, GNSS (initialization)
- **Map**: Point cloud map (PCD format) + Lanelet2 vector map
- **Practice**: F9R GNSS + COSS map
- **Production**: F9P GNSS + 華夏科大 map

### Configuration
NDT parameters may need tuning for golf cart:
- Located in: `src/param/autoware_individual_params/individual_params/config/default/`
- Key parameters: resolution, convergence tolerance, iteration limits
- Adjust based on testing results

### Localization Dependencies
1. **LiDAR**: Velodyne VLP-32C (Phase #3)
2. **IMU**: Tamagawa IMU (Phase #5)
3. **Speedometer**: From Turing Drive vehicle interface (Phase #7)
4. **GNSS**: u-blox for initialization (Phase #4)
5. **Map**: Point cloud + Lanelet2 map (Phase #8)

All dependencies must be ready before localization can work.

## Tooling Preferences
- Prefer `rg` (ripgrep) over `grep -r` / `find … -exec grep` for codebase searches — it's faster, respects `.gitignore`, and the flags compose more cleanly (e.g. `rg -nE 'pattern' path`, `rg -l 'pattern'`, `rg -tyaml 'pattern'`).
- Prefer `just <recipe>` over `cargo` or raw `sh` scripts.

## Important Notes
- **Target Platform**: Advantech Orin computer with JetPack 6.2
- **Autoware Version**: 2025.02 at `/home/aeon/repos/autoware/2025.02-ws`
- Always source ROS environment: `source /opt/ros/humble/setup.bash`
- Requires ROS 2 Humble distribution
- Built for Ubuntu 22.04 with NVIDIA GPU support
- Uses colcon build system (not catkin)
- Symlink installs enabled for faster development iteration
- System monitor available at http://localhost:8080/ when launched
- **Migration**: See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) for team assignments and phase details

## System Management

### Systemd Service Integration

Applies to the two-machine deployment. `just launch` (single machine) is
unaffected and still runs play_launch in the foreground.

Both hosts run the same units, installed per machine with a role:

| Unit | Hosts | Purpose |
|---|---|---|
| `golfcart-launch.service` | both | the stack, via play_launch |
| `golfcart-record.service` | both | rosbag only, independent lifecycle |
| `golfcart-watchdog.service` | orin | stops everything if the master vanishes |

```bash
just service install master            # this machine
just service install-orin              # the orin, over ssh
just launch-all                     # starts both; returns immediately
just stop-all                       # stops both; leaves recording alone
just logs
just record start / record-stop        # recording, independent of the launch
just service doctor                            # when topics do not show up
```

Units are installed but never enabled: they start on demand, not at boot.
Lingering is required and the installer enables it — without it the user manager
exits with the last session and takes the units with it.

See [docs/multi-machine.md](docs/multi-machine.md) for operation and
[docs/design/orin_provisioning_implementation_plan.md](docs/design/orin_provisioning_implementation_plan.md)
for why it is built this way.

**Note**: earlier revisions of this file described a `golfcart` CLI with
`golfcart status` / `golfcart enable`, and a service auto-installed on first
`just launch`. That was inherited from the AutoSDV system and never existed in
this repository.

### Process Management
- `just launch` (single machine): Ctrl-C stops it; a second Ctrl-C forces it
- `just launch-all` (two machines): nothing to Ctrl-C — it returns
  immediately, and `just stop-all` is the stop verb
- `KillMode=control-group` in the units is what keeps orphans from surviving
- play_launch ignores SIGTERM, so the units stop it with `KillSignal=SIGINT`

### Known Issues and Solutions

#### Journal Logging
`journalctl --user -u <unit>` works for the golfcart units. If a bare
`journalctl --user` shows nothing, use `systemctl --user status <unit>`, which
prints recent lines regardless.

#### Network Monitor Error
- Network monitor may show socket connection errors
- This is a known non-critical issue related to AWS Greengrass
- Can be safely ignored - doesn't affect system functionality

## Velodyne VLP-32C LiDAR Integration

### Golf Cart Configuration
The golf cart uses Velodyne VLP-32C as the sole LiDAR sensor:
- Driver: Nebula (Autoware's universal LiDAR driver)
- Launch file: `golfcart_sensor_kit_launch/launch/lidar.launch.xml`
- Config: `golfcart_sensor_kit_launch/config/VLP32.param.yaml`
- Network IP: 192.168.7.10 (default, configurable via `vlp32c_device_ip` arg)

### Coordinate System
- Velodyne follows ROS standard (REP-103): X:forward, Y:left, Z:up
- Transformation configured in: `sensor_kit_calibration.yaml`
- Adjust roll, pitch, yaw based on physical mounting position

## TensorRT Model Compilation

### First Run Behavior
On first launch, TensorRT will compile ONNX models to optimized CUDA engines:
- This process can take 10-30 minutes depending on hardware
- Compiled engines are cached in `./data/` directory
- Key models:
  - `lidar_centerpoint/pts_voxel_encoder_centerpoint_tiny.engine`
  - `lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.engine`
  - Traffic light classifiers (if enabled)

### Optimized Perception Configuration
For faster startup and LiDAR-only operation, configure in `golfcart.launch.yaml`:
```yaml
- name: perception_mode
  value: "lidar"
- name: use_traffic_light_recognition
  value: "false"
- name: use_detection_by_tracker
  value: "false"
- name: use_image_segmentation_based_filter
  value: "false"
```

## Vehicle Interface

### Turing Drive Integration (Golf Cart)
The golf cart uses Turing Drive vehicle interface packages (replacing Golf Cart custom PWM interface):
- **Status**: Pending - specifications and packages to be obtained from Turing Drive
- **Expected components**:
  - Vehicle interface node (control command → CAN/vehicle protocol)
  - Velocity/odometry reporting
  - Gear status management
  - Control mode management (manual/autonomous)
- **Integration files**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_launch/launch/vehicle_interface.launch.xml`

### Golf Cart PWM Interface (Reference Only)
The original Golf Cart system used custom PWM control:
- Motor PWM: 370 = stop, >370 = forward, <370 = reverse
- Steering PWM: 400 = center, 350 = left, 450 = right
- **Note**: This is for reference only. Golf cart will use Turing Drive interface.

## u-blox GNSS Integration

### Practice Setup (F9R RTK)
Learn with F9R from seniors Allan & David:
- **Device**: u-blox F9R RTK receiver
- **Purpose**: Practice setup, learn configuration
- **Map**: Use with COSS map for localization testing
- **Launch parameter**: `gnss_receiver:=ublox`

### Production Setup (F9P)
Target configuration for golf cart:
- **Device**: u-blox F9P GNSS receiver (pending hardware)
- **Map**: Use with 華夏科大 campus map
- **Configuration files**:
  - `golfcart_sensor_kit_launch/launch/gnss.launch.xml`
  - `golfcart_sensor_kit_launch/config/ublox_gnss.param.yaml` (to be created)
- **Calibration**: Antenna position from base_link in `sensor_kit_calibration.yaml`

### Integration with Localization
- GNSS provides initial position for NDT localization
- Must work together with map for Autoware localization
- Coordinate with map preparation team

## IMU Integration

Two sources, selected by `imu_source` (env `IMU_SOURCE`). Both feed the same
Autoware chain — `imu_corrector` then `gyro_bias_estimator` — which always runs
on the Advantech regardless of source. Launch file:
`golfcart_sensor_kit_launch/launch/imu.launch.xml`.

**Currently `IMU_SOURCE=zed`** (`config/sensors.conf`): the Xsens MTi is broken
and publishes nothing. Its raw topic stays in the recorded topic list on purpose —
an empty topic in a bag records that the device was expected and silent, which an
absent topic does not.

### Xsens MTi over CAN (`imu_source:=xsens`, currently broken)
- **Driver**: `xsens_mti_can_ros_driver`, launched by `imu.launch.xml`
- **Raw topic**: `/sensing/imu/xsens/imu_raw`
- **Frame**: `imu_link`
- **Parameters**: `golfcart_sensor_kit_launch/config/xsens_mti_can.param.yaml`,
  **not** the driver submodule's own `param/xsens_mti_can_ros_node.yaml`. It is a
  full copy, not an override — the driver merges nothing, so a partial file would
  drop `can_interface`, `frame_id` and every `pub_*` flag. Two values differ from
  the driver's copy and both describe *this* MTi's MT Manager output
  configuration, which is why they live in the sensor kit:
  - `start_frame_id: 17` (0x11 StatusWord). The driver dispatches a sample group
    when it sees the start frame, and this MTi emits 0x11/0x32/0x34/0x51 — never
    the default 0x05 (SampleTime), so with the default it never dispatches and
    every topic advertises without publishing.
  - `time_option: "host"`. It emits neither 0x07 (UTCTime) nor 0x05, so both
    device-clock options fall back to the host clock anyway, once per sample,
    behind a 5 s throttled warning. Restore `mti_utc` once UTC Time is enabled in
    MT Manager and the MTi has GNSS reception.
- **The top-level key is `/**`, and must stay that way.** The node's
  fully-qualified name is `/sensing/imu/xsens/xsens_mti_can_ros_node` —
  `imu.launch.xml` pushes the `imu` and `xsens` namespaces — so a bare
  `xsens_mti_can_ros_node:` key normalises to `/xsens_mti_can_ros_node` and
  matches nothing. Nothing warns: the parameters are dropped and the driver runs
  on its compiled-in defaults, which reproduces the "advertises but never
  publishes" symptom above by a completely separate route. Any future param file
  for a namespaced node in this repo has the same trap.
- **Known issue**: the driver has `pub_transform: true`, broadcasting
  `world -> imu_link` while the URDF publishes `sensor_kit_base_link -> imu_link`.
  That frame has two parents today.

### ZED X built-in (`imu_source:=zed`)
- **Driver**: none launched here — the ZED node on the orin already publishes it
- **Raw topic**: `/sensing/camera/zed/imu/data`
- **Frame**: `zed_imu_link`, parented to `zed_left_camera_frame` by the driver
- Uses `imu/data`, not `imu/data_raw`. "raw" in Autoware means "not yet corrected
  by Autoware", not "uncalibrated by the vendor"; `gyro_bias_estimator` can only
  remove a constant bias, so feeding it the SDK's uncalibrated fields would
  discard scale and misalignment corrections nothing can rebuild.
- Crosses the DDS link at 100 Hz. `gyro_odometer` time-syncs it against vehicle
  twist, so link jitter shows up as twist noise — prefer a wired link.

### Corrected output
`/sensing/imu/imu_data`, consumed by `autoware_gyro_odometer`. Corrector
parameters are per-device and do not transfer between sources:
`individual_params/.../imu_corrector_{xsens,zed}.param.yaml`.

## Camera Configuration

Two camera sets on two machines, both behind `camera.launch.xml`. Design:
[docs/design/zed_camera_integration.md](docs/design/zed_camera_integration.md).

### GMSL cameras — Advantech (`camera_model:=gscam`)
Three TIER IV GMSL cameras (left, right, rear) via `gscam`:
- **Config**: `golfcart_sensor_kit_launch/config/camera_{left,right,rear}.yaml`
- **Topics**: `/sensing/camera/{left,right,rear}/image_raw/compressed`
- **Frames**: `camera_left`, `camera_right`, `camera_rear`

### ZED X — orin (`camera_model:=zedx`)
One ZED X stereo camera, driven as a composable node:
- **Launch**: `golfcart_sensor_kit_launch/launch/zed.launch.xml`
- **Config**: `golfcart_sensor_kit_launch/config/zed.param.yaml`, layered over
  `zed_wrapper`'s `common_stereo.yaml` and `zedx.yaml`
- **Topics**: `/sensing/camera/zed/rgb/color/rect/{image,camera_info}` and
  `/sensing/camera/zed/imu/data`
- **The RGB channel is the left camera.** Images are stamped
  `zed_left_camera_frame_optical` (Z forward, X right, Y down), so any pose
  computed from them is in that frame — transform with tf2, never by hand.
- Left/right stereo, depth, and point cloud are all disabled. Positional
  tracking is off, because Autoware owns `map -> odom` and `odom -> base_link`.
- Only `zed_camera_link` (the screw hole in the camera's bottom) is calibrated
  in `sensor_kit_calibration.yaml`. Everything below it comes from the vendor
  URDF via a `robot_state_publisher` inside `zed.launch.xml`.
- Needs OpenGL hardware acceleration — plain VNC breaks it. If the GMSL link
  wedges (`ZEDX#0#0#FROZEN`), run `sudo service zed_x_daemon restart; sleep 25`.

## Golf Cart Migration Plan

**See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md)** for comprehensive migration plan with 11 phases and team assignments.

### Key Migration Tasks
1. **Phase #1**: Advantech Orin computer setup (JP6.2, firmware, dependencies)
2. **Phase #3**: Velodyne VLP-32C LiDAR integration
3. **Phase #4**: u-blox GNSS (F9R practice → F9P production)
4. **Phase #5**: Tamagawa IMU integration
5. **Phase #6**: USB cameras (upgrade to Tier IV later)
6. **Phase #7**: Turing Drive vehicle interface integration
7. **Phase #8**: 華夏科大 campus HDMap (COSS map for practice)
8. **Phase #9**: NDT localization tuning
9. **Phase #10**: Planning and control configuration
10. **Phase #11**: Integration testing and validation

### Team Assignments
- **Team A (Allan & Liao)**: Sensors (LiDAR, cameras, GNSS focus)
- **Team B (Vincent & Darren)**: System setup, map preparation, vehicle interface
- **Coordination**: Both teams work together on GNSS + Map for localization testing
- **Practice Equipment**: F9R GNSS + COSS map (from seniors Allan & David)
- **Production Equipment**: F9P GNSS + 華夏科大 map

### Hardware Status
**Available Now:**
- Velodyne VLP-32C LiDAR
- USB cameras
- u-blox F9R (practice, from Allan & David)
- COSS map (practice)
- Orin box (interim testing)

**Pending:**
- Advantech Orin computer
- u-blox F9P GNSS (production)
- Tamagawa IMU
- 華夏科大 campus map
- Turing Drive vehicle interface packages

## Recent Updates (Golf Cart Legacy)
- With --symlink-install flag in colcon build, edits on yaml, xml, py source files immediately apply if the file was installed earlier. There is no need to rebuild. In case you create a new file, you need to run colcon build again to create the symlink in the install/ dir.
- Original Golf Cart system had PWM interface calibration, Robin-W LiDAR, ZED cameras - see sections above for reference
