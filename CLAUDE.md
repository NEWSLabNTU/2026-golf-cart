# CLAUDE.md

Guidance for Claude Code when working with this repository.

## Project Overview
This is a golf cart autonomous driving system for 華夏科大 campus deployment, based on the Golf Cart platform. The system uses the Autoware 1.5.0 apt distribution (`autoware-full-1-5-0`, universe 0.48.0) on AGX Orin (JetPack 6.2) with ROS 2 Humble.

**Key System Configuration:**
- **LiDAR**: Velodyne VLP-32C only
- **GNSS**: u-blox ZED-F9P on the Advantech, driver built from the NEWSLabNTU/ublox submodule (apt has no RTCM input), apt `ntrip_client`, RTK over NTRIP optional
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
just up                 # Start both hosts as systemd units; returns at once
just up @mingda a:=1    # ...with an arg file (config/launch/*.args) + overrides
just down               # Stop both hosts (recording left alone)
just run                # This host only, foreground (web UI: http://localhost:8081)
just run "..."          # ...with parameters
just logs               # Follow this host's unit
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
| `pose` | initial pose per map without an RViz click: `capture MAP SPOT` once, then `init MAP SPOT`; `list` |
| `bag` | rosbag record, play, merge, fetch |
| `record` | recording sessions on both hosts (ROS bags + CAN + pcapng, one ID): `start [SCOPE] [NAME]`, `status`, `stop`, `collect [ID]`, `list`, `scopes` (topic classes, counts per host), `nuke` (deletes all, asks); independent of the launch |
| `service` | multi-machine systemd units, `doctor`, `host-status` |
| `vehicle` | vehicle interface bring-up, manual control, control tests |
| `can` | CAN record, replay, decode; `vcu-status` is a receive-only live readout of the VCU and our commands |
| `tool` | RViz, PlotJuggler, TUI, keyboard controller |
| `diag` | diagnostic graph: QoS checks, leaf listing, fault injection |
| `gnss` | F9P / RTK: `check` the setup, `test` the receiver against the NTRIP caster, `launch` it standalone (`ntrip=off` for driver only) |
| `link` | the master/orin wire: what crosses it, `pressure`, the two-host `sim` |
| `sim` | simulators: `planning`, `logging`, `aruco`, `coss-park`, the `loop-drive` / `mrm-check` tests; synthetic `cameras` |

`build`, `test`, `clean`, `up`, `down`, `run` and `logs` stay at the root —
they are the daily verbs, and a module may not share a name with a recipe
(`mod sim` beside `sim:` is a hard error that breaks the whole justfile).

### Launching: `up`, `down`, `run`

| recipe | where | how |
|---|---|---|
| `just up [ARGS...]` | both hosts | `golfcart-launch.service` here and on the orin (over ssh); returns at once |
| `just down` | both hosts | stops the orin first, then this host; recording keeps running |
| `just run [ARGS...]` | this host | play_launch in the foreground; Ctrl-C stops it |

ARGS are launch arguments plus `@name`, which expands in place to
`config/launch/<name>.args` (`@basement`, `@mingda`, `@mingda-loop`,
`@sim-*`); later args win, so `just up @mingda-loop planning_speed_limit:=0.5`
overrides the file. `scripts/launch/args.py` does the expansion for every
launcher, adds `host:=`, `master_ip:=` and `link_topics:=` for the host's
role, and prints the final list before anything starts. The unit gets its args
from `.golfcart-launch.args` (gitignored), which `up` rewrites on every start,
so no flag outlives the start that asked for it. `_up-local` / `_down-local`
are the private per-host halves that `up` / `down` run on each machine.

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
just vehicle interface                       # real bus, can0
just vehicle interface can=vcan0             # bench, against mock_vcu
just vehicle interface converter=on          # + robot_state_publisher + velocity converter
just vehicle manual-control                          # keyboard teleop — SECOND terminal
```
Options are `KEY=VALUE`, any order: `can=`, `converter=on|off`.
The interface always transmits — see "No CAN TX switch" below. Keyboard control is a separate recipe
because it reads a raw tty: it must own a real terminal, so it cannot be a node
inside a launch file (play_launch does not support `launch-prefix` either).

### Control Testing
```bash
just vehicle control-straight   # Run 10m straight trajectory (needs: just vehicle interface converter=on)
just vehicle control-circle     # Run circular trajectory
```

### Rosbag
```bash
just bag record [NAME]  # Record this host's config/recording list, foreground
just bag play           # Play most recent recording in $GOLFCART_BAG_DIR
```

### Simulation
```bash
just sim planning @sim-ntu-r01      # Autoware planning simulator (map_path:= or an @sim-* file)
just sim planning @sim-mingda-loop  # ...on the Ming-Da loop, slow_indoor
just sim logging                    # Logging simulation (rosbag replay)
just sim aruco                      # ArUco localization driving the planning simulator
just sim coss-park                  # Full COSS Park simulation scenario
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
- **Retained**: autoware_manual_control, gnss_locator
- **To Replace**: ros2_mpu9250_driver → Tamagawa IMU driver (pending)
- **Camera**: USB cameras (no ZED submodule needed initially)
- **Vehicle Interface**: Will use Turing Drive packages (to be added)

Submodules:
- autoware_manual_control - Keyboard control interface
- golfcart_sensor_kit_launch - Sensor kit configurations
- gnss_locator - GNSS positioning
- ublox - u-blox ZED-F9P driver, NEWSLabNTU fork with RTCM input (NTRIP client is apt)
- rig_localization - camera + IMU + wheel twist estimator (`localization_preset:=rigloc`); runs on
  the orin under a two-machine profile; links cuVSLAM (`./setup.sh --only cuvslam`), and
  `just build` skips it without
- ros2_mpu9250_driver - IMU driver (to be replaced with Tamagawa)

### config/ is the single source of truth

Everything that varies by machine, deployment or session lives in `config/`, and
no script hardcodes any of it. See [config/README.md](config/README.md).

| File | Decides |
|---|---|
| `config/host` | which machine this checkout is (`master`/`orin`). **Gitignored** |
| `config/multi_machine.conf` | the other host's `user@addr`, repo path, ssh key, master IP |
| `config/recording/topics.yaml`, `scopes.yaml` | what is recorded: topic classes, and the scopes that pick them |
| `config/cyclonedds/*.xml` | DDS profiles, one per role |

`scripts/env.sh` is the matching single source for the *environment* — Autoware
sourcing, `CYCLONEDDS_URI`, `RMW_IMPLEMENTATION`, PATH, `GOLFCART_BAG_DIR`.
`.envrc` sources it, and so do the systemd unit exec scripts. Do not re-derive any
of that in a new script; source `scripts/env.sh` and let it resolve.

Units state their role with `GOLFCART_ENV_ROLE`, which outranks `config/host`: a
unit must not depend on a file someone can edit underneath it.

The hosts' own `/etc` configuration (NetworkManager cart profiles, CAN networkd,
udev rules, chrony, linuxptp, sysctl, the SSD's fstab line) lives in
`setup/host/{common,master,orin}/`, a tree mirroring target paths, with
`setup/host/manifest.yaml` as the allow-list. `just host diff` (`--orin` for the
orin, read only) shows drift, `just host capture` copies live into the tree with
secrets stripped, and the setup step `host-config` restores it. Edit a cart
system file there, never only in `/etc`.

### The master/orin link is a separate ROS domain

Under `host:=master` / `host:=orin`, `config/cyclonedds/{master,orin}.xml` bind
the stack's own domain (50 on the master, 60 on the orin, exported as
`ROS_DOMAIN_ID` by `scripts/env.sh`) to `lo` and only the link domain (10,
`GOLFCART_LINK_DOMAIN_ID`, all three in `config/runtime.conf`) to the LAN address. Nothing in the stack can reach the
other machine; `golfcart_domain_bridge` (one `link_bridge` node per host,
started by `golfcart.launch.yaml`) copies exactly the topics in
`config/link/topics.yaml` across, in the direction the file gives them. To add
a cross-host topic, add it there — with a `max_hz` if it is an image. Never
list a topic in both directions; the bridge refuses (echo loop).

The CAN vehicle interface runs on the **orin** (`vehicle_host:=orin`, the
default; `vehicle_host:=master` puts it back). Its six command topics cross
master → orin, its seven `/vehicle/status/*` reports cross back, and
`/control/control_mode_request` — a **service**, which Autoware's engage path
calls — crosses under `services:`. Services cannot be generic in Humble, so each
service type is compiled into the bridge (`service_types()` in
`golfcart_domain_bridge`); an unknown type is logged and skipped. A request
whose far end is down is left unanswered, so the caller times out rather than
reading a made-up reply. If the link drops, commands stop and the interface's
`control_timeout_ms` watchdog (500 ms) brakes.

`ros2 topic list` in a shell that sourced `scripts/env.sh` shows this host's stack domain; `just link topics` shows the wire, `just
link pressure` measures it. Before the split, one domain on the LAN put every
participant on the wire, and because the recorder is a second reader of every
raw cloud, CycloneDDS multicast the clouds out of the NIC: in simulation with
the real stack the 100 Mbit/s link sat at its ceiling with the orin subscribed
to none of it, and the master's own recorder lost 59 % of its scans to the
backpressure.
[docs/research/system/domain-split-link-pressure.md](docs/research/system/domain-split-link-pressure.md)
has the numbers and what in the simulation is synthetic (the driver bytes;
nothing downstream). `just link sim baseline|split` reproduces it after `just
build`, no root needed. Not yet measured on the vehicle. Lanes carry the
consumer's QoS, not the sensor's instinct: the IMU is `reliable` because
`imu_corrector` subscribes reliable, and the ZED's dynamic `/tf` is listed
because gyro_odometer needs it.

**The `ros2` CLI daemon keeps the environment it started with.** There is one
daemon per `ROS_DOMAIN_ID`. The first `ros2 topic|node|service` call on a domain
starts it, and it keeps that shell's `RMW_IMPLEMENTATION`, `CYCLONEDDS_URI` and
the rest from then on. Later calls on the same domain query it whatever their own
shell says. So a daemon started from a shell that never sourced `scripts/env.sh`,
or under the other host's profile, gives an empty or wrong graph to every shell
after it. Sometimes it fails outright with
`xmlrpc.client.Fault: <Fault 1: "<class 'RuntimeError'>:!rclpy.ok()">`, which
names no cause. A test on a scratch domain id leaves a daemon of its own behind.
When the CLI output does not match what the stack is doing, restart the daemon
from a shell that sourced `scripts/env.sh` (`ros2 daemon stop; ros2 daemon start`),
or pass `--no-daemon`. Scripts and one-off tests should use `--no-daemon`.

### Recording: first-hand topics only

A recording is a **session**: one ID (`YYYYmmdd_HHMMSS[_NAME]`, made once on the
master by `just record start` and passed to the orin), files in
`recordings/<id>/<role>/` inside the repo on each host (gitignored; not `log/`,
which `just clean` deletes): `bag/`, `<can>.log` (`candump -L`), `<nic>.pcapng`
(rootless `tshark`), `session.yaml` (commit, launch args, chrony offset, each
recorder's status/size/exit). `just record collect [ID]` rsyncs the orin's half
over `on_orin.sh`. What a session records is its **scope**,
`config/recording/scopes.yaml` (`drive` default, `autonomy`, `all`, `raw`, `can`,
`ros`; `localize` = `drive`);
`scripts/recording/session.py` is the one runner, under `golfcart-record.service`
(id and scope via `.golfcart-record.args`, rewritten on every start) and in the
foreground for `just bag record` / `just can record`. A missing or DOWN interface
is skipped and noted, never fatal. `GOLFCART_BAG_DIR` now only holds bags from
before sessions. User guide: [docs/recording.md](docs/recording.md).

**Topics are classes**, `config/recording/topics.yaml`, the one topic source
(`scripts/recording/topics.sh` / `session.py topics` print them). Each class has
per-host topics (`master:` / `orin:` / `both:`) and a kind: **first-hand** (driver
or vehicle output: `lidar`, `camera`, `imu`, `gnss`, `vehicle`, `tf`) or
**computed** (our stack's output: `sensing_derived`, `diagnostics`,
`vehicle_cmd`, `localization`, `planning`, `control`, `perception`). A scope's
`ros:` is `all`, `none` or a class list, where `first-hand` / `computed` stand
for every class of that kind. `drive` = first-hand + sensing_derived +
diagnostics + vehicle_cmd + localization (NDT pose and scores, EKF);
`ros` = first-hand only; `autonomy` adds planning, control, perception.
`session.yaml` lists the classes and topic count per class. To add a topic, put
it in its class; never in a script.

**Replay leaves computed topics out.** Replay is a logging simulation: the stack
runs with drivers disabled and recomputes those topics with current parameters,
so played as well they would have two publishers. Every path that plays into a
stack (`just bag play`, `play-ntu`, `ntu-test bag`, `indoor-test bag`,
`board_check.sh`) goes through `scripts/recording/play.py`: Humble's `ros2 bag
play` has no exclude, so it passes `--topics` = the bag's metadata minus computed
classes minus unclassified topics matching `replay.stack_patterns` (what an `all`
bag is mostly made of). `/tf` mixes the ZED's IMU frame (needed) with the stack's
`map -> base_link` / `map -> ndt_base_link`, so it is played remapped and
republished without `replay.tf_computed`. `computed=on` / `--computed` /
`GOLFCART_REPLAY_COMPUTED=on` plays everything; `just bag replay` (RViz only, no
stack) always does. The concatenated cloud and corrected IMU stay unrecorded.

A topic that is expected but dead stays listed and records zero messages. An empty
topic says "this device was expected and was silent"; an absent one says nothing.

NDT needs velocity, via `/vehicle/status/velocity_status` →
`vehicle_velocity_converter` → `gyro_odometer` → `ekf_localizer`, so the vehicle
interface must run while recording. The VCU does not need autonomous mode:
`VelocityReport` comes from the decoded MTR frame and is not gated on the control
mode — but the VCU sends that frame only while it hears our rolling counter, and
the report is gated on frame freshness, so check `ros2 topic hz` rather than
assume.

### The vendor CAN DBC

`golfcart_vehicle_interface` generates CAN bindings from Turing Drive's
`CAX_ADS_CAN.dbc` at build time. The file is proprietary and gitignored, so only
the machine it was copied to has it. `just build` **skips the package** when
neither `CAX_ADS_DBC` nor a DBC in the crate root exists.

**The DBC belongs on the orin now.** The bus moved to the orin's header pins
(setup step `orin-can0`) and `golfcart.launch.yaml`'s `vehicle_host` defaults to
`orin`, so the orin is the machine that must build the interface. A master
without the DBC skips the package and loses nothing; an orin without it skips
it too, and then the launch includes a node whose executable does not exist —
the cart has no velocity and cannot be engaged. Copy the file to the orin's
crate root. Keep the skip itself: it is what lets either machine build without
the file.

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
Point cloud maps are committed as `pointcloud_map.pcd.zst` (zstd -19) and
unpacked beside themselves by `just data unpack` (setup step `map-data`); the
`.pcd` files are gitignored (`*.pcd` in `data/.gitignore`), so a shallow clone carries only
the compressed copies. After editing a map in git, `just data pack <file.pcd>`
and commit the `.zst`, never the `.pcd`. See docs/maps.md.

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
- **GNSS**: u-blox ZED-F9P only. There is no F9R; anything that says F9R is from an older project
- **IMU**: Tamagawa IMU (replaces MPU9250)
- **Cameras**: USB cameras → Tier IV GMSL cameras (future upgrade)

Sensor configurations are in `src/param/autoware_individual_params/individual_params/config/default/golfcart_sensor_kit/`

### Launch System
- Main launch uses Autoware's standard launch system
- Vehicle model: `golfcart_vehicle`
- Sensor model: `golfcart_sensor_kit`
- Default map: `./data/COSS-map-planning`, changed with `map_path:=` (for example
  `map_path:=./data/basement-indoor`). Until 2026-09-29 that override silently did
  nothing: `map_path` was a fixed include value, so the loaders always got COSS.
  The production map is planned, not present.

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
just run "lidar_model:=vlp32c"
```

#### Camera Configuration
`camera.launch.xml` is the single entry point for every camera. Through the
stack the selection is the `camera_model` launch argument (and `capture_profile`
for the GMSL capture path), passed down by name:

```bash
# Three GMSL cameras on the Advantech (default)
just run

# ZED X — set automatically for the orin host; also selectable directly
ros2 launch golfcart_sensor_kit_launch camera.launch.xml camera_model:=zedx

# No camera
just run "camera_model:=none"

# Another GMSL capture profile (a directory in the sensor kit's config/camera_capture/)
just run "capture_profile:=v4l2-mmap"
```

#### GNSS Configuration
```bash
# u-blox GNSS (golf cart standard)
just run "gnss_receiver:=ublox"
```

**Usage:**
```bash
# Full visual localization (requires visual map)
just run "pose_source:=visual visual_map_dir:=/path/to/visual_map"

# Visual odometry only (no global init, manual pose required)
just run "pose_source:=isaac"
```

**Creating Visual Maps:**
```bash
# Golf cart standard configuration
just run "lidar_model:=vlp32c camera_model:=usb gnss_receiver:=ublox"

# Indoor testing without GNSS
just run "lidar_model:=vlp32c camera_model:=usb use_gnss:=false"
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
./setup.sh --role master         # two-host install: one command per machine
./setup.sh --run --role orin -y  # the same, unattended, on the orin
./setup.sh --checklist [--json]  # only the still-to-do-by-hand list; exit 1 if any
```

**Two-host install is three commands plus two vendor files**: `./setup.sh
--role master` on the master, `./setup.sh --role orin` on the orin, then `just
service pair` on the master. `--role` writes `config/host` (refusing to replace
a different value without `--force-role`, which also forgets the role steps'
state), implies `--profile vehicle` unless one is given, and adds that role's
steps: `chrony-master` + `host-services` on the master, `chrony-orin` +
`orin-can0` + `host-services` on the orin. Steps tagged for the other role
(`hardware-config` is the master's LiDAR NICs) drop out. `Step.roles` says which
roles select a step, `Requires.role` where it applies; `--list` shows the reason
("orin host only, this host is master"). Without `--role`, `config/host` is the
role when it says master/orin, so a later plain `./setup.sh` keeps the role steps.
`host-services` runs `setup/scripts/install-host-service.sh` with no argument; it
reads the role from `config/host`.

**What setup cannot do is a checklist**, `setup/golfcart_setup/checklist.py`
(stdlib, read-only), printed after every run, by `--status`, by `--checklist`,
in `scripts/doctor.sh`, and on both hosts by `just service pair`. Each line has
its fix: `config/host` unset; on the orin the Turing Drive DBC and the ZED SDK
(whose installer lowers `net.core.rmem_max`, so `--rerun cyclonedds-sysctl`
after it); `rmem_max` below the profiles' `SocketReceiveBufferSize min`, read
from `config/cyclonedds/*.xml`; units missing, for another role or checkout, or
lingering off. Tests: `python3 -m unittest discover -s setup/tests`.

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

In the list, `[x]` is what the run will install and the right-hand column is
what the machine already has (*installed*, *script changed*, *failed*) -- an
unticked box beside *installed* is the normal case, because a preset leaves
finished steps alone.

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
3. Use with: `just run perception_preset:=custom`

**Note**: Preset files must use `<name>_preset.yaml` naming convention.

#### Available Presets

**Perception** (`config/perception/preset/`):
- `lidar_only` - LiDAR only, no camera features (default)
- `camera_lidar_fusion` - Camera + LiDAR with traffic light recognition
- `minimal` - Minimal features for development/debugging

**Localization** (`config/localization/preset/`):
- `default` - Gyro odometry twist estimation (default)
- `eagleye` - GNSS-based odometry (requires GNSS)

**Planning** (`config/planning/preset/`, `planning_preset:=`):
- `default` - stock autoware_launch (default)
- `slow_indoor` - the 1 m/s cart on indoor lanelets: no avoidance, lane change,
  crosswalk, traffic-light or intersection modules; no reversing manoeuvres
  (start/goal planner back-out and freespace off); 3.5 m stop margins;
  `max_vel` 2.5. The drive arg files and `just sim planning @sim-basement` use it. Unlike
  upstream's planning presets it can change parameter files, through our copy
  of `tier4_planning_component.launch.xml`; `test_planning_preset.py` pins both.

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
localization_preset:=rigloc             # NDT pose + rig_localization twist (ZED + IMU + wheel)

# Example: Use camera-lidar fusion
just run perception_preset:=camera_lidar_fusion
```

#### Sensor Configuration
```bash
# Sensor suites (predefined combinations)
sensor_suite:=vlp32c             # Velodyne VLP-32C

# Individual sensor overrides
lidar_model:=vlp32c
camera_model:=gmslcam|zedx|none # default gmslcam
capture_profile:=nvv4l2camerasrc # GMSL capture path
imu_source:=zed|xsens           # default zed (the Xsens is broken)
gnss_receiver:=ublox|septentrio|none
use_ntrip:=false|true
```

#### GPU acceleration: one coarse switch, two fine ones

**CUDA is the default.** All three are launch arguments; none is set from the
environment by a user.

```bash
just run                          # CUDA preprocessing + concatenation (default)
just run use_cuda:=false          # both back on CPU
just run pointcloud_backend:=cpu  # same, spelled out
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
just run pose_source:=ndt      # CPU NDT; the fallback if init hangs
just run use_cuda:=false       # CPU preprocessing, still cuda_ndt
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

**Its align service used to miss the caller's deadline at ~23 s**, so
`/localization/initialize` timed out and the scan matcher stayed latched off.
**That no longer reproduces on the workstation.** 2026-09-11, indoor replay,
board initializer seeding cuda_ndt against the basement Falcon map: the align
returned, and the matcher tracked the whole bag at 9.84 Hz with `exe_time_ms`
of 2.06. Both logging sims now default to `pose_source:=cuda_ndt` on the
strength of it.

It has NOT been re-measured on the Orin, which is the machine that matters, and
the old number came from there. If a stack comes up and never localizes, this
is still the first thing to suspect and `pose_source:=ndt` is still the control
run that isolates it. See
[docs/handover/2026-08-30-cuda-pipeline-to-orin.md](docs/handover/2026-08-30-cuda-pipeline-to-orin.md).

**Sensor choices are launch arguments, never environment variables.**
`camera_model`, `capture_profile`, `imu_source`, `gnss_receiver`, `use_ntrip`
and `pointcloud_backend` are declared in `golfcart.launch.yaml` with real
defaults and passed by name all the way to the sensor kit, through our own copy
`golfcart_launch/launch/components/tier4_sensing_component.launch.xml`. The
installed Autoware pair (`tier4_sensing_component.launch.xml` and
`tier4_sensing_launch/sensing.launch.xml`) forwards four arguments and drops the
rest; until 2026-11 that forced these through the environment (`CAMERA_MODEL`,
`IMU_SOURCE`, `GNSS_RECEIVER`, `USE_NTRIP`, `POINTCLOUD_BACKEND`, and
`config/sensors.conf`), so a forgotten export silently picked a different
sensor. All of that is gone, and the sensor kit reads no `$(env ...)` but
`VEHICLE_ID`. Do not reintroduce an env side channel: if a new argument has to
reach the sensor kit, add it to the component copy. Example:
`just run "imu_source:=xsens camera_model:=none"`.

`master_ip` and `link_topics` are likewise plain arguments with no default.
Under `host:=master` / `host:=orin` an empty one stops the launch with
`Undefined variable: 'MISSING_ARG_master_ip_required_under_host_master_or_orin'`
(or the `link_topics` twin, checked only when the link bridge starts);
`scripts/launch/args.py` passes both for the recipes and the units.

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

#### No CAN TX switch

There used to be one — `tx=on|off`, `GOLFCART_TX_ENABLED`, `config/vehicle.conf`,
the node's `tx_enabled` — and it is gone. With TX off the interface sent no
frames, and this VCU reports velocity and steering only while it hears the
rolling counter in our frames, so "listen only" left `/vehicle/status/*` empty
and the stack blind rather than the cart safe. The vehicle interface always
transmits; **the cart's power switch is the master enable**, and the
`control_timeout_ms` watchdog brakes on command silence.

A stale `tx_enabled:=false` somewhere is now **silently ignored** — ROS 2 launch
drops undeclared arguments — so it does not keep anything off. Use `vcan0`
(`just vehicle interface can=vcan0`) to exercise the node away from the cart.

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

**In board mode the RViz panel's "Initialize with GNSS" button re-runs the
board.** The button calls the AD API `/api/localization/initialize` with an
empty pose (default_adapi's `LocalizationNode` would forward that to
`/localization/initialize`, which has no GNSS here). Under
`pose_initializer:=board` a scoped `set_remap` in the API group of
`golfcart_autoware.launch.xml` moves default_adapi's server to
`/api/localization/initialize_default`, and `board_pose_initializer` serves the
public name (`adapi_initialize_service` in both policy files): an empty request
re-arms it like `just pose board` and answers when the pose initializer took a
board pose, or with an error after `adapi_board_timeout` (30 s: no board in
view, cart moving). A request carrying a pose (`scripts/testing/*`) is
forwarded unchanged to `_default`. RViz *2D Pose Estimate* is untouched:
`initial_pose_adaptor` is in the same remapped group and calls `_default`
directly. In `gnss` mode the resolved launch is identical to before. The
Trigger `/localization/board_pose_initializer/reinitialize` still works.

`just indoor-test` replays the basement bag against `data/basement-indoor/`
through `indoor_logging_sim.launch.xml` (`bag` paused, `up`, `rviz`, `resume`,
`down`; `fake-tf` only for the standalone detector). The bag has one topic and
no velocity, so the replay proves initialization only. Design and status:
[docs/roadmaps/7-reflective-board-cold-start.md](docs/roadmaps/7-reflective-board-cold-start.md).

#### Driving autonomously (Phase 8)

```bash
just up @basement      # both hosts, basement map, board init, no GNSS, 1.0 m/s planning default
just up @mingda        # same, on the re-anchored Ming-Da map (data/mingda-basement), 2.0 m/s
just up @mingda-loop   # @mingda on the clockwise loop lane
```

`planning_speed_limit:=<m/s>` is the startup planning speed default (empty keeps
Autoware's 4.17 m/s). It is a default, not a ceiling; the ceiling is the vehicle
interface's `max_speed_mps`. **`launch_perception` is the one switch for
perception, diagnostic graph included.** With it false the graph is the base graph
(upstream's, or the ArUco one) with the perception subtree removed through the
aggregator's own `edits: [{type: remove}]`
(`config/system/diagnostics/*-no-perception.yaml`, four-line overlays, not
copies). There is then no obstacle detection at all, and autonomy is for a
supervised run only. The planners still wait on the perception outputs, so in
that case `scripts/perception_stubs.py` publishes an all-free
`/perception/occupancy_grid_map/map` and an empty
`/perception/obstacle_segmentation/pointcloud`; without them behavior_path_planner
logs `waiting for occupancy_grid` and no trajectory ever flows (seen 2026-10-28).
Do not reach for `perception_preset:=minimal` instead: CenterPoint's TensorRT
engine build blocks its composable container for 10 to 30 minutes, and the
ground filter behind it, so the real grid never appears either. With it true,
upstream's graph stands unchanged. **The driver puts the cart in
AUTO on the dashboard, brake pedal held + AUTO button, before Autoware engages,
and leaves it the same way.** Nothing over CAN changes the VCU's mode; Autoware
reads the mode the VCU reports, and the interface's control-mode service only
acknowledges it, both ways (golfcart_vehicle_launch 960a2be). `just can
vcu-status` shows, receive only, what the VCU reports and what we send. Work items,
exit criteria and the engage order:
[docs/roadmaps/8-autonomous-driving.md](docs/roadmaps/8-autonomous-driving.md);
procedure: [docs/guides/control_testing.md](docs/guides/control_testing.md).

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
twist_source:=gyro_odom|eagleye|rigloc     # Override preset twist source
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

### Where documentation lives
README.md is for people operating the cart; keep internals out of it.

| file | audience | covers |
|---|---|---|
| [README.md](README.md) | users | what the cart is, hardware at a glance, the daily routine |
| [docs/hardware.md](docs/hardware.md) | users | both machines, every peripheral and link (Mermaid diagram), IPs, the VCU's known limits |
| [docs/setup.md](docs/setup.md) | installers | `./setup.sh --role master\|orin`, `just build`, `just service pair`, the DBC and ZED SDK by hand |
| [docs/operating.md](docs/operating.md) | users | `just up`/`down`, `@name` arg files, map and initial pose, RViz, logs, troubleshooting |
| [docs/recording.md](docs/recording.md) | users | record, fetch, merge, replay; where bags land |
| [docs/maps.md](docs/maps.md) | users | map download, layout, checking a new map |
| [DEVELOPMENT.md](DEVELOPMENT.md) | developers | `just run`, build skips, simulators, project layout, deprecated aliases |
| [docs/README.md](docs/README.md) | developers | index of roadmaps, research, guides, archive |
| [docs/multi-machine.md](docs/multi-machine.md) | developers | the two-host internals: domains, link bridge, units |

There is no MkDocs book in this repository; earlier revisions of this file
described one under `book/`.

### Legacy Guides (docs/)
| Guide | Description |
|-------|-------------|
| [docs/guides/sensor_configuration.md](docs/guides/sensor_configuration.md) | Sensor suites, NTRIP/RTK, localization |
| [docs/guides/vehicle_calibration.md](docs/guides/vehicle_calibration.md) | PWM control, PID tuning, testing tools |
| [docs/guides/lidar_integration.md](docs/guides/lidar_integration.md) | Velodyne VLP-32C, TensorRT |
| [docs/guides/control_testing.md](docs/guides/control_testing.md) | First supervised autonomous drive: roles, pre-drive checks, engage order, stopping |
| [docs/guides/mrm_configuration.md](docs/guides/mrm_configuration.md) | MRM (emergency stop) configuration |
| [docs/multi-machine.md](docs/multi-machine.md) | Two-machine operation: `just up` / `just down`, per-host DDS profiles, orin lifecycle, recording |
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

- **The VCU speed signals are m/s since the vendor's November 2026 update** (were whole km/h).
  `Vcu_Ads_Vehicle_Speed` (the report) now reads m/s in fine steps, unsigned: on 2026-11-09 our km/h
  reading came out 3.5-3.8x low against NDT (session `20261109_220723_vcu-right-turn`, 0.45 m
  reported vs 1.83 m travelled). `Ads_Vcu_Target_Speed` (the setpoint) is **assumed** m/s with it,
  not yet observed in AUTO; if wrong, the cart runs 3.6x slower than asked, never faster. One factor
  in the interface, `dbc::VCU_SPEED_UNIT_TO_MPS` (golfcart_vehicle_launch f0abd26), for both; the
  report is still signed by gear. Before the update both were km/h whatever the DBC said; the
  history is in [docs/research/system/vcu-speed-report.md](docs/research/system/vcu-speed-report.md).
- **`min_speed_mps: 0.8` in `vehicle_interface.param.yaml`** raises any nonzero speed setpoint to 2.9 km/h.
  It was 1.5 (5.4 km/h) until 2026-11-10, chosen when the cart stalled on a bump at a crawl with the
  setpoint still read as km/h; lowered so the Ming-Da loop's 3 km/h north lane is sent as asked, and not
  yet driven. If the cart stalls there, raise it back. The ceiling is `max_speed_mps` (2.5 since
  2026-11-02). The Ming-Da loop is 5 km/h, 3 km/h through the narrow north lane, and tags its four
  corners `turn_direction: right` so the indicator blinks before each (`turn:` in the route YAML).

- **Steering sign verified on the cart 2026-10-22** (Phase 8 V2): `invert_steering` (vehicle interface, 2026-08-12) is right; keyboard left (+5 deg) went out as -4.98 deg and turned the wheels left. The VCU's steering *report* is not usable yet: `0x102 Vcu_Ads_Tire_Angle` never goes negative, so every left angle reads 0.000 (raw bytes `00 00`, the VCU's doing, not our DBC decode), and `Vcu_Ads_Tire_Angular_Speed` is always 0. On 2026-11-06 the right side was live **in Manual** too (to +18.05 deg, `rosbags/can/can_can0_20261106_161744.log` on the master), so the earlier "live only in AUTO, frozen in Manual" (2026-10-22) no longer holds; reported to the vendor. Record with `just can record` **on the orin**, where the bus is. See [Phase 9](docs/roadmaps/9-mingda-autonomous-driving.md).
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
- **Practice**: ZED-F9P GNSS + COSS map
- **Production**: ZED-F9P GNSS + 華夏科大 map

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
- **Autoware Version**: 1.5.0, installed from apt under `/opt/autoware/1.5.0` (source workspace `/home/aeon/repos/autoware/1.5.0-ws`). Earlier revisions of this file said 2025.02; nothing by that name is installed.
- Always source ROS environment: `source /opt/ros/humble/setup.bash`
- Requires ROS 2 Humble distribution
- Built for Ubuntu 22.04 with NVIDIA GPU support
- Uses colcon build system (not catkin)
- Symlink installs enabled for faster development iteration
- System monitor available at http://localhost:8080/ when launched
- **Migration**: See [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) for team assignments and phase details

## System Management

### Systemd Service Integration

Applies to the two-machine deployment. `just run` (this host only) is
unaffected and runs play_launch in the foreground.

Both hosts run the same units, installed per machine with a role:

| Unit | Hosts | Purpose |
|---|---|---|
| `golfcart-launch.service` | both | the stack, via play_launch |
| `golfcart-record.service` | both | rosbag only, independent lifecycle |
| `golfcart-watchdog.service` | orin | stops everything if the master vanishes |

```bash
./setup.sh --role master               # on the master: steps + units (host-services)
./setup.sh --role orin                 # on the orin: the same for the orin
just service pair                      # on the master, once: ssh key, orin checks, checklists, doctor
just service pair --check              # the same checks, read-only, no prompts
just service install master            # units alone, this machine (what host-services runs)
just service install-orin              # units alone, the orin, over ssh
just up [ARGS...]                   # starts both; returns immediately
just down                           # stops both; leaves recording alone
just logs
just record start / record stop        # recording, independent of the launch; stop fetches + merges the orin bag
just service doctor                            # when topics do not show up
```

Units are installed but never enabled: they start on demand, not at boot.
Lingering is required and the installer enables it — without it the user manager
exits with the last session and takes the units with it.

`just service pair` (`scripts/multi_machine/pair.sh`) refuses unless this
checkout is the master, installs the ssh key through `setup_ssh.sh` when
BatchMode ssh fails, then checks the orin's checkout at `ORIN_WORKSPACE`, its
`config/host` and its units (from the orin's own `--checklist --json`), printing
what to run on the orin for each miss. On a terminal it offers to run
`./setup.sh --run --role orin -y` there with `on_orin.sh --tty`, behind a y/N.
A different commit on the two checkouts is a warning. Exit 0 means paired.

See [docs/multi-machine.md](docs/multi-machine.md) for operation and
[docs/design/orin_provisioning_implementation_plan.md](docs/design/orin_provisioning_implementation_plan.md)
for why it is built this way.

**Note**: earlier revisions of this file described a `golfcart` CLI with
`golfcart status` / `golfcart enable`, and a service auto-installed on first
`just launch`. It lived in the `golfcart_runtime` submodule, inherited from the
AutoSDV system and never wired in; the submodule was removed 2026-11-09.

### Process Management
- `just run` (this host only): Ctrl-C stops it; a second Ctrl-C forces it
- `just up` (two machines): nothing to Ctrl-C — it returns
  immediately, and `just down` is the stop verb
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
- Compiled engines are written beside the ONNX in `data/autoware_data/` (gitignored)
- Key models:
  - `lidar_centerpoint/pts_voxel_encoder_centerpoint_tiny.engine`
  - `lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.engine`
  - Traffic light classifiers (if enabled)

### Engine packs in git (`just engines`)
Built engines are cached in the repo as `data/engines/<key>/` (engines as
`<stem>.engine.zst`, Autoware `.json` sidecars, `manifest.yaml`), key = Autoware release + full
TensorRT version + board, e.g. `aw1.5.0-trt10.3.0.30-agx-orin-64gb` (both
hosts today). L4T, CUDA, hostname are recorded, not keyed.
- `just engines key | list | install | verify | save`; all take `--data-dir`.
- `install` decompresses to a temp file beside the target, checks the
  uncompressed `engine_sha256`, renames into place (a real file, never a
  symlink: Autoware writes through the path on a rebuild), and only where the target ONNX sha256 matches the manifest; mismatch,
  missing ONNX or no pack is skipped with a reason, exit 0, built on first
  launch as before. A differing local engine is kept unless `--force`.
- The `tensorrt-engines` setup step runs `engines install`, then
  `build-engines`, which loads (does not rebuild) a valid engine: measured
  5 s for CenterPoint tiny from an installed pack.
- **zstd -19 (CLI, `apt install zstd`), plain git blobs, no LFS**: ~9.2 MB
  per key today, nearly all the CenterPoint-tiny backbone, which barely
  compresses. Each save of a changed engine adds its packed size to history
  permanently: `just engines
  save` only after a build that really changed an engine (it writes nothing
  for byte-identical ones).
- Design: [docs/research/perception/tensorrt-engine-prebuild.md](docs/research/perception/tensorrt-engine-prebuild.md).

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

One receiver, a **u-blox ZED-F9P** (HPG 1.12, PROTVER 27.11 as read on
2026-09-17). Earlier revisions of this file described an F9R "practice" unit
inherited from an older project; there is none on this vehicle, and the
bring-up log records the day spent launching an F9R
sensor-fusion profile at an F9P before the receiver identified itself.

### Driver: the NEWSLabNTU/ublox submodule; NTRIP client from apt
- `src/sensor_component/external/ublox` (NEWSLabNTU/ublox, branch `ros2`), a
  fork of KumarRobotics/ublox 2.3.0 (`ublox`, `ublox_gps`, `ublox_msgs`,
  `ublox_serialization`). Three commits over upstream: a `/rtcm` subscription
  taking `mavros_msgs/RTCM`, a product-category fix for HPS devices, and a
  `zed_f9r.yaml` we do not use. **The apt `ros-humble-ublox-gps` 2.3.0 has no
  RTCM input at all** (checked 2026-10-21), so with it RTK corrections reach
  nothing; that is why the driver is source-built.
- `ntrip_client` is apt, `ros-humble-ntrip-client` (1.4.1), a rosdep key in
  the sensor kit's `package.xml`. It publishes on `rtcm` and uplinks
  `nmea_msgs/Sentence` from `nmea`; `rtcm_message_package: mavros_msgs` in its
  param file is what matches the fork.

Until 2026-10-21 both came from a `ublox_f9p_ws` workspace submodule (driver
nested, client vendored). It was dropped; its private repo keeps the bring-up
log, `SETUP_LOG.md`, which records the day spent launching an F9R profile at
an F9P, and a caster account in plain text in its `gps_launch`.

**Do not install ros-humble-ublox-gps**; the workspace build shadows it anyway,
but remove it if an older setup left it. `rosdep --ignore-src` installs the
fork's dependencies instead.

### Launch and configuration
- `golfcart_sensor_kit_launch/launch/gnss.launch.xml`: `gnss_receiver`
  (`ublox` | `septentrio` | `none`), `use_ntrip`, `ntrip_param_file`, all launch
  arguments of `golfcart.launch.yaml` passed down by name
- `golfcart_sensor_kit_launch/config/ublox_f9p.yaml`: the receiver, as a rover
  (`tmode3: 0`, `/dev/ublox-gps`, `frame_id: gps`, 1 Hz). The driver's own
  `zed_f9p.yaml` is a base-station survey-in profile; do not copy it.
- `golfcart_sensor_kit_launch/config/ntrip_client.param.yaml`: caster (e-GNSS
  `GNSS_Taiwan`, RTCM 3.2 MSM) **and account**. **Gitignored by the sensor
  kit, which is a public repo**; made from `ntrip_client.param.yaml.example`
  beside it, then `just build` once so the symlink install picks it up. Never
  put the account in the `.example`.
- `config/ntrip_credentials.txt` (gitignored): the account, kept on the
  vehicle to paste from. Nothing reads it.
- **Calibration**: antenna position from base_link in `sensor_kit_calibration.yaml`

Topics under `/sensing/gnss`: `ublox/nav_sat_fix` (what `gnss_poser` reads),
`ublox/nmea_sentence`, `ntrip/rtcm`, `ublox/rxmrtcm` (the receiver's account of
which corrections it accepted; `flags: 0` is a CRC pass). These are the names
`golfcart_system_monitor/config/monitor_topics.yaml` lists, though it still
types the RTCM topic as `rtcm_msgs/Message`, which this driver does not use.

### RTK over NTRIP
```bash
just run use_ntrip:=true           # needs the sensor kit's config/ntrip_client.param.yaml
scripts/testing/ntrip/check_ntrip_setup.sh   # everything the line above needs
```
`use_ntrip` is a plain launch argument, passed by name to the sensor kit like
`pointcloud_backend`. It defaults to **false**: it did nothing until 2026-09-19, and live
without an account the client exits on start and respawns every 5 s.

Known from the bring-up log, not yet fixed in the fork: the driver's NMEA
reassembly drops sentences split across a serial read, and GGA leads each
epoch so ~95% of GGAs are lost. The VRS still streams on the survivors, but a
moving rover wants ~1 Hz GGA. See `SETUP_LOG.md` section 9 in the retired
NEWSLabNTU/ublox_f9p_ws.

### Integration with Localization
- GNSS provides initial position for NDT localization
- Must work together with map for Autoware localization
- Coordinate with map preparation team

## IMU Integration

Two sources, selected by the `imu_source` launch argument. Both feed the same
Autoware chain — `imu_corrector` then `gyro_bias_estimator` — which always runs
on the Advantech regardless of source. Launch file:
`golfcart_sensor_kit_launch/launch/imu.launch.xml`.

**The default is `imu_source:=zed`** (`golfcart.launch.yaml`): the Xsens MTi is
broken and publishes nothing; `just run "imu_source:=xsens"` once it is repaired. Its raw topic stays in the recorded topic list on purpose —
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

### GMSL cameras — Advantech (`camera_model:=gmslcam`)
Three TIER IV GMSL cameras (left, right, rear) via `gmslcam`, the Rust (rclrs)
GStreamer node at `src/sensor_component/external/gmslcam` (submodule, `ament_cargo`):
- **Config**: `golfcart_sensor_kit_launch/config/camera_{left,right,rear}.yaml`
  (device, geometry, `codec: jpeg`, frame, topic names) plus one capture profile,
  `config/camera_capture/<profile>/{left,right,rear}.yaml`, holding the `pipeline`
  string; `capture_profile` defaults to `nvv4l2camerasrc` in `camera.launch.xml`
- **Topics**: `/sensing/camera/{left,right,rear}/image_raw/compressed` and
  `/sensing/camera/{left,right,rear}/camera_info`, both at the frame rate,
  `CompressedImage.format` the bare `jpeg`
- **Frames**: `camera_left_optical_link`, `camera_right_optical_link`,
  `camera_rear_optical_link`
- **Calibration**: `camera_{left,right,rear}_calibration.yaml`, wired through
  `camera_info_url` as a `file://` URL set in `camera.launch.xml`; gmslcam does
  not resolve `package://`
- **Parameter files must be keyed `/**` or by the node's full name.** rclrs does
  not expand `/**/camera_left`; that is why a capture profile is a directory of
  three files rather than one file keyed per node. Nothing warns when the key
  misses, the node just runs its built-in pipeline.
- **No hardware**: `capture_profile:=videotestsrc` needs no devices and no sudo;
  `sim` runs against `just sim cameras` (v4l2loopback), `sim-nvjpeg` the same
  through NVJPG on a Jetson
- Read `golfcart_sensor_kit_launch/config/gmslcam.md` before changing any of it

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
- Stereo video, **on by default since 2026-11-10** (`zed_stereo_video:=false`
  turns it off): the rectified left and right, H.264 on the orin's NVENC (Isaac
  ROS), into the orin's bag as
  `/sensing/camera/zed/{left,right}/color/rect/image/h264`. Needs the
  `isaac-h264-encoder` setup step there (installed on the orin 2026-11-10).
  Cost: ~33 Mbit/s per side, and with the RGB JPEG also subscribed every ZED
  stream drops to 15 Hz; the ZED IMU stays at 100 Hz.
  See docs/design/zed_camera_integration.md.
- Left/right raw images, depth, and point cloud are otherwise disabled. Positional
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
3. **Phase #4**: u-blox ZED-F9P GNSS
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
- **Practice Equipment**: ZED-F9P GNSS + COSS map
- **Production Equipment**: ZED-F9P GNSS + 華夏科大 map

### Hardware Status
**Available Now:**
- Velodyne VLP-32C LiDAR
- USB cameras
- u-blox ZED-F9P (on the vehicle; brought up 2026-09-17)
- COSS map (practice)
- Orin box (interim testing)

**Pending:**
- Advantech Orin computer
- Tamagawa IMU
- 華夏科大 campus map
- Turing Drive vehicle interface packages

## Recent Updates (Golf Cart Legacy)
- With --symlink-install flag in colcon build, edits on yaml, xml, py source files immediately apply if the file was installed earlier. There is no need to rebuild. In case you create a new file, you need to run colcon build again to create the symlink in the install/ dir.
- Original Golf Cart system had PWM interface calibration, Robin-W LiDAR, ZED cameras - see sections above for reference
