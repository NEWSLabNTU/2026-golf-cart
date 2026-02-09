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
make prepare

# Build the workspace
make build

# Launch the system
make launch

# Stop the system
make stop
```

### Launch with Specific Configuration

```bash
# Launch with u-blox GNSS and USB cameras
make launch ARGS="gnss_receiver:=ublox camera_model:=usb"

# Indoor testing without GNSS
make launch ARGS="use_gnss:=false"
```

## Development Status

This project is currently in development. See [MIGRATION.md](MIGRATION.md) for the detailed migration plan and progress tracking.

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
└── MIGRATION.md          # Migration plan from Golf Cart
```

## Documentation

- [MIGRATION.md](MIGRATION.md) - Migration plan from Golf Cart to golf cart

## License

This project is based on [Golf Cart](https://github.com/NEWSLabNTU/Golf Cart) and inherits its Apache 2.0 license. See [LICENSE.txt](LICENSE.txt) for details.

## Acknowledgments

This project is built upon:
- **Golf Cart**: Software-Defined Vehicle platform by NEWSLab, National Taiwan University
- **Autoware**: Open-source autonomous driving software by the Autoware Foundation
