# Golf Cart Autonomous Driving System

This project implements an autonomous driving system for a golf cart, based on the [Golf Cart](https://github.com/NEWSLabNTU/Golf Cart) platform and powered by [Autoware](https://github.com/autowarefoundation/autoware).

## Overview

This system provides a complete autonomous driving software stack for golf cart applications, supporting:

- **Navigation**: GPS-based waypoint following and localization
- **Perception**: LiDAR-based obstacle detection and camera-based vision
- **Control**: Drive-by-wire interface for steering, throttle, and braking
- **Mapping**: 3D map-based localization using NDT scan matching

## System Configuration

### Target Platform
- **Hardware**: two NVIDIA AGX Orin machines (master + orin) — see [The cart is two machines](#the-cart-is-two-machines)
- **OS**: JetPack 6.x (Ubuntu 22.04)
- **ROS**: ROS 2 Humble
- **Autoware**: 1.5.0, installed at `/opt/autoware/1.5.0/`

### Sensor Configuration
- **LiDAR**: Velodyne VLP-32C
- **GNSS**: u-blox receiver
- **IMU**: Tamagawa IMU (Autoware recommended)
- **Cameras**: Multiple USB cameras (future upgrade to Tier IV cameras)

## The cart is two machines

This is the part to get straight before anything else. The vehicle runs on **two**
computers, and the normal deployment uses both:

| | runs | records |
|---|---|---|
| **master** | the whole Autoware stack and the wired sensors (Velodyne, Falcon, GNSS, IMU, USB cameras) | its own bag, to the external SSD when mounted — [see below](#where-the-bag-lands) |
| **orin** | the ZED X camera only | its own bag, locally in `~/rosbags` |

They split because the shared LAN negotiates 100 Mb/s and a single LiDAR stream is
~30 MB/s. Neither machine records the other's topics.

Both carry the **same repository and the same recipes**. Recipes ending `-up` /
`-down` act on whichever machine runs them; `launch-all` / `stop-all` act on both,
by logging into the orin and running its copy of the same recipe. There is no
separate remote vocabulary to learn.

Running on one machine is also supported, and is covered under
[Single machine](#single-machine-development-and-bench-testing) below — but it is
the bench case, not the vehicle.

## Setup

Prerequisites on **both** machines: JetPack 6.x on an AGX Orin, and Autoware 1.5.0
at `/opt/autoware/1.5.0/`.

### 1. Prepare each machine

Do this on the master **and** on the orin, in each machine's own checkout:

```bash
git clone --recurse-submodules https://github.com/NEWSLabNTU/2026-golf-cart.git
cd 2026-golf-cart
./setup.sh                  # dependencies (interactive)
echo master > config/host   # on the orin: echo orin > config/host
just build
```

`config/host` is gitignored — it states which machine this checkout is on, and
selects the DDS profile. Without it a shell falls back to `loopback` and sees no
cross-machine topics.

### 2. Vendor CAN database — master only, by hand

`golfcart_vehicle_interface` generates its CAN bindings from Turing Drive's
`CAX_ADS_CAN.dbc` at build time. The file is proprietary, gitignored, and cannot
be fetched automatically — obtain it from Turing Drive and copy it into the crate
root **on the master**:

```bash
cp /path/to/CAX_ADS_CAN.dbc \
   src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/
```

`CAX_ADS_DBC=/absolute/path/to/file.dbc` works instead, if you would rather keep
it outside the tree.

**The orin does not need it.** Only the machine wired to the CAN bus runs the
vehicle interface. `just build` skips `golfcart_vehicle_interface` when no DBC is
present, rather than failing the whole build — so the orin builds cleanly without
the vendor file, and starts building the package the moment one appears.

### 3. ZED SDK — orin only, by hand

The orin needs the ZED SDK at `/usr/local/zed`, installed from the Stereolabs
`.run` installer. **This is not automated** — the installer does not script
cleanly, so it stays a manual step. Currently installed: SDK 5.2.3.

Two consequences that are easy to miss:

- `just build` **silently skips** the ZED packages when `/usr/local/zed` is
  absent. The build succeeds and the camera simply never appears.
- The SDK drops `/etc/sysctl.d/60-zed-buffers.conf`, which lowers
  `net.core.rmem_max` below the 10 MB our DDS profiles require. CycloneDDS then
  refuses to start on *every* profile, loopback included. Re-run
  `./setup/scripts/configure-cyclonedds-sysctl.sh` after installing or upgrading
  the SDK, then `just build` again to pick the ZED packages up.

### 4. Wire the two together, from the master

```bash
just service install master     # systemd units + lingering (sudo)
just service ssh-setup                  # dedicated key, copied to the orin
just service install-orin       # runs the orin's own installer over ssh
just service doctor && just service doctor-orin # confirm both sides
```

Time sync matters as much as the rest — two bags cannot be merged if the clocks
disagree. See *Time sync* in [docs/multi-machine.md](docs/multi-machine.md).

## Daily operation

From the master:

```bash
just launch-all    # both hosts; returns immediately
just logs          # follow this host's log
just stop-all      # stop both hosts
just service doctor        # when topics do not show up
```

There is no Ctrl-C to press. Both hosts run under systemd, so closing the terminal
or dropping the ssh session does not stop the cart — `just stop-all` is the stop
verb.

Full operational guide: [docs/multi-machine.md](docs/multi-machine.md).

## Recording

Independent of the launch — start it any time, stack up or down:

```bash
just record start      # both hosts record to their own disk
just record status
just record stop

just bag fetch-orin    # copy the orin's bags over
just bag merge "master_<ts> orin_<ts>"
just bag replay
```

Or record in the foreground, this host only, from a terminal — Ctrl-C stops it
and finalizes the bag:

```bash
just bag record                # $GOLFCART_BAG_DIR/master_<ts>
just bag record campus_loop    # $GOLFCART_BAG_DIR/master_<ts>_campus_loop
just bag record-indoor         # pre-drive checklist, then the same recording
just bag play                  # newest finalized bag in $GOLFCART_BAG_DIR
```

Topics recorded are plain lists, one per line — edit these, not any script:

```
config/recording/master_topics.txt
config/recording/orin_topics.txt
```

These are the only lists. `just record start`, `just bag record` and `just bag
record-indoor` all read them through `scripts/recording/topics.sh`; no recorder
carries its own copy. A host whose role is neither `master` nor `orin` (one
machine running everything) records both. `just bag record-aruco` is the
exception: it records a purpose-built set including the detector's output, for
one analysis script.

### Where the bag lands

Each host writes to its own disk, into `$GOLFCART_BAG_DIR`, one directory per
run named `<role>_<YYYYmmdd_HHMMSS>`:

| host | directory | example |
|---|---|---|
| master | external SSD if mounted, else `~/rosbags` | `/mnt/external/rosbags/master_20260814_152605` |
| orin | `~/rosbags` (it has no SSD) | `~/rosbags/orin_20260814_152603` |

`scripts/env.sh` resolves `GOLFCART_BAG_DIR`: `/mnt/external/rosbags` when
`/mnt/external` is mounted and writable, otherwise `~/rosbags`. An explicit
`GOLFCART_BAG_DIR` still wins.

**Check which one you got before a long run.** The root filesystem has a couple
of GB free and recording runs at roughly 15–30 MB/s, so a bag fills it in
minutes — and the fallback to `~/rosbags` is silent:

```bash
source scripts/env.sh; echo "$GOLFCART_BAG_DIR"   # what the next run will use
df -h "$GOLFCART_BAG_DIR"
```

The recorder also logs its exact output path on the line it starts with:

```bash
systemctl --user status golfcart-record.service | grep record_unit_exec:
# record_unit_exec: role=master writing /home/ubuntu/rosbags/master_20260814_152605 (27 topics)

just record status                       # active/inactive, both hosts
ls -dt "$GOLFCART_BAG_DIR"/*_*  | head    # most recent bags, newest first
```

Use `systemctl --user status`, not `journalctl --user -u golfcart-record.service`
— on this machine the latter prints `-- No entries --` for these units.

A finished bag is a directory holding `metadata.yaml` plus one or more
`<name>_N.db3` files (sqlite3, the ROS 2 Humble default). `ros2 bag info <dir>`
is the check that it finalized — see [docs/roadblocks.md](docs/roadblocks.md) if
`metadata.yaml` is 0 bytes.

### Getting both halves onto one machine

```bash
just bag fetch-orin        # rsync the orin's orin_* bags into this host's $GOLFCART_BAG_DIR
just bag merge "master_20260814_152605 orin_20260814_152603"
```

`bag-merge` writes `merged_<timestamp>` next to the first input unless you pass
`-o /path/to/output`. The merged bag is roughly the sum of its inputs, so point
`-o` at the SSD if the inputs are large.

`just stop-all` deliberately leaves a recording running; stopping the stack and
stopping a recording are separate decisions.

**The vehicle interface must be running while you record.** NDT needs a velocity
signal, which reaches it as
`/vehicle/status/velocity_status` → `vehicle_velocity_converter` →
`gyro_odometer` → `ekf_localizer`. Without that topic in the bag, a replay has no
twist and localization will not converge.

The VCU does **not** need to be in autonomous mode for this. `VelocityReport` is
published from the decoded MTR frame the VCU broadcasts anyway; it depends on
neither `tx_enabled` nor the control mode, so RX-only is enough:

```bash
just vehicle interface     # CAN RX only — the cart cannot be commanded to move
```

Confirm before a long run — the report is gated on frame freshness, so a silent
VCU yields a silent topic:

```bash
ros2 topic hz /vehicle/status/velocity_status
```

We record first-hand driver output only. Derived topics — the concatenated cloud,
the corrected IMU — are commented out of the lists, because replay is a logging
simulation: the single-machine stack runs with drivers disabled against the merged
bag and recomputes them with current parameters rather than the ones frozen at
record time.

## Single machine (development and bench testing)

For working at a desk, or driving the master alone with no orin attached. This
runs play_launch in the foreground with the `loopback` DDS profile and involves no
systemd and no ssh:

```bash
just launch                              # web UI at http://localhost:8081
just launch "use_gnss:=false"            # indoor, no GNSS
just launch "gnss_receiver:=ublox camera_model:=usb"
```

Launch arguments are one positional string, not `ARGS=...`.

To drive the master alone but still through its systemd unit:

```bash
GOLFCART_USE_ORIN=0 just launch-all
```

`just --list` shows every recipe.

## Development Status

This project is currently in development. See [ROADMAP.md](ROADMAP.md) for the active development plan and [docs/](docs/) for archived documentation.

## Project Structure

```
.
├── src/
│   ├── launcher/          # Main launch files
│   ├── sensor_kit/        # Sensor integration
│   ├── vehicle/           # Vehicle interface
│   ├── param/             # Configuration parameters
│   ├── sensor_component/  # External sensor drivers
│   └── system/            # System monitoring
├── data/                  # Maps and ML models
├── docs/                  # Documentation archive
├── ROADMAP.md             # Active development roadmap
└── CONTRIBUTING.md        # Branching convention and workflow
```

## Maps Download

Click the link to download NTU campus map to data/ntu-campus-planning: https://newslabn.csie.ntu.edu.tw/drive/d/s/17udXr7jE0y1uVZuITDKMHFdhprfnH8l/y7cT2BSRT_5RUSI5bp4blXm8MI8qlp-3-iLCA3n5hIg0
The expected structure will be
```
├── data/
│   └── ntu-campus-planning/             # For NTU campus map
│       └── r01/                         # Route 01
│           ├── lanelet2_map.osm         # Lanelet2 map
│           ├── map_projector_info.yaml  # Map projector information
│           └── pointcloud_map.pcd.pcd   # Point cloud
```


## Documentation

### Active
- [ROADMAP.md](ROADMAP.md) — Five-phase development plan with parallel tracks (cleanup, sensors, DBW, planning, integration)
- [CONTRIBUTING.md](CONTRIBUTING.md) — Branching convention (`2026-golfcart`), submodule table, and workflow
- [docs/multi-machine.md](docs/multi-machine.md) — Two-machine operation: provisioning, launch, recording, troubleshooting

### Roadblocks
- [docs/roadblocks.md](docs/roadblocks.md) — Open issues blocking setup, build, or test (JetPack mismatch, duplicate package, missing drivers)

### Guides
- [docs/guides/lidar_integration.md](docs/guides/lidar_integration.md) — Velodyne VLP-32C driver setup and network configuration
- [docs/guides/mrm_configuration.md](docs/guides/mrm_configuration.md) — Minimal Risk Maneuver (emergency stop) parameter configuration
- [docs/guides/mrm_troubleshooting.md](docs/guides/mrm_troubleshooting.md) — MRM diagnostics and troubleshooting procedures

### Research
- [docs/research/localization/ndt_parameter_tuning_coss_map.md](docs/research/localization/ndt_parameter_tuning_coss_map.md) — NDT scan matcher parameter tuning results for VLP-32C on COSS map
- [docs/research/indoor_localization.md](docs/research/indoor_localization.md) — Survey of ROS 2 indoor localization methods (historical, AutoSDV era)
- [docs/research/nvidia_isaac_ros.md](docs/research/nvidia_isaac_ros.md) — Isaac ROS Visual SLAM analysis and integration notes (historical, AutoSDV era)
- [docs/research/lidar_marker_localization.md](docs/research/lidar_marker_localization.md) — LiDAR-based landmark localization research (historical, AutoSDV era)

### Archived Roadmaps
- [docs/roadmaps/0-migration.md](docs/roadmaps/0-migration.md) — Original 11-phase migration plan from AutoSDV/Golf Cart to golf cart (superseded by ROADMAP.md)
- [docs/roadmaps/1-track-a.md](docs/roadmaps/1-track-a.md) — Sensor cleanup (done), VLP-32C & u-blox (software ready), Tamagawa IMU (blocked)
- [docs/roadmaps/1-track-b.md](docs/roadmaps/1-track-b.md) — Phase 1 Track B tooling & infrastructure progress (partial: setup gaps, no submodule branch tracking)
- [docs/roadmaps/0-autosdv-to-golfcart-rename.md](docs/roadmaps/0-autosdv-to-golfcart-rename.md) — AutoSDV→golfcart naming rename status (completed)
- [docs/roadmaps/2-vehicle-interface-hardening.md](docs/roadmaps/2-vehicle-interface-hardening.md) — golfcart_vehicle_interface fixes vs Autoware pacmod_interface reference
- [docs/roadmaps/2-vehicle-interface-fault-handling.md](docs/roadmaps/2-vehicle-interface-fault-handling.md) — ROS-sub / CAN-msg drop handling
- [docs/design/vehicle_interface_standalone.md](docs/design/vehicle_interface_standalone.md) — one `just vehicle interface` recipe for standalone bench testing, with `tx=` / `keyboard=` options
- [docs/roadmaps/2-xsens-driver-hardening.md](docs/roadmaps/2-xsens-driver-hardening.md) — Xsens MTi CAN driver hardening

## License

This project is based on [Golf Cart](https://github.com/NEWSLabNTU/Golf Cart) and inherits its Apache 2.0 license. See [LICENSE.txt](LICENSE.txt) for details.

## Acknowledgments

This project is built upon:
- **Golf Cart**: Software-Defined Vehicle platform by NEWSLab, National Taiwan University
- **Autoware**: Open-source autonomous driving software by the Autoware Foundation
