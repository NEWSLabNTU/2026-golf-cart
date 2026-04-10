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
- **Hardware**: NVIDIA AGX Orin Developer Kit
- **OS**: JetPack 6.0 (Ubuntu 22.04)
- **ROS**: ROS 2 Humble
- **Autoware**: Version 2025.02

### Sensor Configuration
- **LiDAR**: Velodyne VLP-32C
- **GNSS**: u-blox receiver
- **IMU**: Tamagawa IMU (Autoware recommended)
- **Cameras**: Multiple USB cameras (future upgrade to Tier IV cameras)

## Quick Start

### Prerequisites
- JetPack 6.0 installed on AGX Orin
- Autoware 2025.02 workspace at `/home/aeon/repos/autoware/2025.02-ws`

### Build and Run

```bash
# Install dependencies
just setup

# Build the workspace
just build

# Launch the system
just launch
```

### Launch with Specific Configuration

```bash
# Launch with u-blox GNSS and USB cameras
make launch ARGS="gnss_receiver:=ublox camera_model:=usb"

# Indoor testing without GNSS
make launch ARGS="use_gnss:=false"
```

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

## Documentation

### Active
- [ROADMAP.md](ROADMAP.md) — Five-phase development plan with parallel tracks (cleanup, sensors, DBW, planning, integration)
- [CONTRIBUTING.md](CONTRIBUTING.md) — Branching convention (`2026-golfcart`), submodule table, and workflow

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
- [docs/roadmaps/migration.md](docs/roadmaps/migration.md) — Original 11-phase migration plan from AutoSDV/Golf Cart to golf cart (superseded by ROADMAP.md)
- [docs/roadmaps/phase1_track_a.md](docs/roadmaps/phase1_track_a.md) — Sensor cleanup (done), VLP-32C & u-blox (software ready), Tamagawa IMU (blocked)
- [docs/roadmaps/phase1_track_b.md](docs/roadmaps/phase1_track_b.md) — Phase 1 Track B tooling & infrastructure progress (partial: setup gaps, no submodule branch tracking)
- [docs/roadmaps/autosdv_to_golfcart_rename.md](docs/roadmaps/autosdv_to_golfcart_rename.md) — AutoSDV→golfcart naming rename status (completed)

## License

This project is based on [Golf Cart](https://github.com/NEWSLabNTU/Golf Cart) and inherits its Apache 2.0 license. See [LICENSE.txt](LICENSE.txt) for details.

## Acknowledgments

This project is built upon:
- **Golf Cart**: Software-Defined Vehicle platform by NEWSLab, National Taiwan University
- **Autoware**: Open-source autonomous driving software by the Autoware Foundation
