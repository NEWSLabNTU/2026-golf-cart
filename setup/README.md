# Golf Cart Development Environment Setup

A lightweight setup system using [just](https://github.com/casey/just) with checkpoint-based resume capability.

## Prerequisites

Install `just` command runner:

```bash
# Ubuntu/Debian
curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin

# Or via cargo
cargo install just

# Or via apt (Ubuntu 22.04+)
sudo apt install just
```

## Quick Start

```bash
cd scripts/setup

# Run full setup (will prompt for sudo password once at the beginning)
./setup.sh

# If setup fails, simply re-run to resume from where it stopped
./setup.sh

# Run specific recipe
./setup.sh status
./setup.sh ros2
```

## Sudo Handling

The setup requires root privileges for many steps (apt, udev, etc.). The wrapper script `setup.sh` handles this:

1. **Password prompt once**: At the start, you'll be asked for your sudo password
2. **Keep-alive loop**: A background process refreshes sudo credentials every 50 seconds
3. **Auto-cleanup**: The keep-alive stops automatically when setup completes, fails, or is interrupted (Ctrl+C)

This means you can start `./setup.sh` and walk away - no need to babysit for password prompts.

**Note**: Always use `./setup.sh` instead of calling `just` directly to ensure proper sudo handling.

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | Run full setup (all steps) |
| `./setup.sh status` | Show which steps are completed |
| `./setup.sh <step>` | Run a specific step |
| `./setup.sh clean-markers` | Reset all checkpoints to force re-run |
| `./setup.sh clean-marker <name>` | Reset a specific step |

## Setup Steps

The setup runs these steps in order:

1. **ros2** - Install ROS 2 Humble
2. **ros2-dev-tools** - Install colcon, rosdep, pytest, flake8
2b. **colcon-cargo-ros2** - Install/upgrade the Rust colcon extension (>= 0.5.1)
3. **gdown** - Install Google Drive downloader
4. **geographiclib** - Install GeographicLib tools and geoid data
5. **pacmod** - Add AutonomouStuff apt repository
6. **dev-tools** - Install git-lfs, pre-commit, Go, PlotJuggler
7. **blickfeld** - Install Blickfeld LiDAR SDK
8. **autoware-debian** - Install Autoware Debian packages
9. **python-deps** - Install Golf Cart Python dependencies
10. **ublox-udev** - Install u-blox GPS udev rules

> The numbered list above is out of date: it still names `blickfeld` and omits
> `isaac-ros`, `otocam`, `opencv`, `linuxptp` and the network configuration.
> `./setup.sh status` and `cd setup && just --list` are authoritative; this list
> is not.

### Optional Steps

| Command | Description |
|---------|-------------|
| `./setup.sh download-artifacts` | Download ML model artifacts (~2GB) |
| `./setup.sh opencv` | Put OpenCV on one version: Ubuntu 4.5.4, with contrib |
| `./setup.sh opencv-check` | Report the OpenCV state, change nothing |
| `./setup.sh colcon-cargo-ros2` | Install/upgrade colcon-cargo-ros2 (>= 0.5.1) |

#### colcon-cargo-ros2

On by default in the interactive menu, because `golfcart_vehicle_interface` and
`cuda_ndt_matcher` build with `ament_cargo`. Without the extension colcon does
not process them at all -- it reports them as "not processed", and every
dependent then fails looking for a `package.sh` that was never generated.

The floor is **0.5.1**: earlier releases do not emit the `[patch.crates-io]`
entries those packages rely on, and a stale install still imports cleanly, so an
import check would never catch it. The step compares the installed version and
runs `pip3 install --user -U --no-deps 'colcon-cargo-ros2>=0.5.1'` when it is
missing or too old.

`--no-deps` is deliberate: the extension depends on `colcon-core` -> `empy`, and
letting pip resolve that installs empy 4.x into `~/.local`, shadowing the apt
`python3-empy` 3.x that `rosidl_adapter` needs
(`AttributeError: module 'em' has no attribute 'BUFFERED_OPT'`).

#### opencv

JetPack 6.2 leaves two OpenCVs installed. NVIDIA's repo ships
`libopencv`/`libopencv-dev` at 4.8.0 with apt priority 600; Ubuntu ships the
`libopencv-*4.5d` runtime at 4.5.4. Nothing on the system links 4.8.0 -- not
`cv_bridge`, not Autoware, not Isaac, not `python3-opencv` -- but
`libopencv-dev` owns `/usr/include/opencv4` and the `/usr/lib/libopencv_*.so`
symlinks, so every local build compiles against 4.8.0 headers and links a 4.5.4
runtime. Silent ABI mismatch.

It also costs the contrib modules: NVIDIA's build has no `aruco`, so
`find_package(OpenCV REQUIRED COMPONENTS aruco)` fails and
`golfcart_aruco_detector` and `golfcart_aruco_localizer` cannot be built at all
on a stock box.

The step installs `files/99-opencv-ubuntu.pref` (priority 1001, which is what
lets the resolver pick the older version at all, and holds it against the next
`apt upgrade`), removes the NVIDIA-only packages, repairs any interrupted
transaction, installs Ubuntu's `libopencv-dev` and `libopencv-contrib-dev` with
`--allow-downgrades`, and runs `ldconfig`.

That order is the whole script, and each step of it is there because leaving it
out fails in a way that names something else.

The NVIDIA-only packages come off **before** the install, and that order is the
whole trick. `opencv-licenses` owns `/usr/share/licenses/opencv4/*`, Ubuntu's
`libopencv-dev` ships the same paths, and NVIDIA's `libopencv-dev` declares no
`Replaces` for it. Install first and dpkg refuses to overwrite the file, the
`libopencv-dev` unpack fails, NVIDIA's 4.8.0 stays installed, and its
`Conflicts: libopencv-core-dev, libopencv-dnn-dev, …` — it is a monolithic dev
package that conflicts with every one of Ubuntu's split ones — then rejects the
other fifteen packages in the same run. One file conflict, fifteen failures, and
an apt that will not do anything else until it is repaired.

It is safe to re-run, it detects and repairs a system left half-unpacked by an
interrupted attempt, and it **refuses** to run if anything on the system is
actually linked against 4.8.0 rather than purging a library out from under it.
Run `opencv-check` first to see what it would do.

After it runs, anything already compiled against the 4.8.0 headers must be
rebuilt: `just clean && just build` from the repository root.

## How Resume Works

Each completed step creates a marker file in `.markers/`. When you re-run setup:
- Completed steps are skipped (marker exists)
- Failed/incomplete steps are re-run
- You can force re-run with `just clean-marker <step>`

## Directory Structure

```
scripts/setup/
├── setup.sh              # Entry point (handles sudo keep-alive)
├── justfile              # Recipe definitions
├── README.md             # This file
├── .gitignore            # Ignores .markers/
├── .markers/             # Checkpoint files (auto-created)
├── scripts/              # Complex setup scripts
│   ├── install-ros2.sh
│   ├── install-ros2-dev-tools.sh
│   ├── install-autoware-debian.sh
│   └── download-artifacts.sh
└── files/                # Static files
    ├── 99-ublox-gps.rules
    └── artifacts.yaml    # ML model download manifest

# Root-level version configuration
versions.yaml             # Single source of truth for all versions
scripts/version/          # Version helper scripts
├── get-version.sh        # Get individual version values
└── export-versions.sh    # Export all versions as env vars
```

## Compared to Ansible

| Feature | Ansible | justfile |
|---------|---------|----------|
| Install overhead | ~100MB (Python, collections) | ~2MB (single binary) |
| Startup time | ~10-15 seconds | Instant |
| Resume from failure | Re-run all (idempotent) | Marker-based skip |
| Learning curve | High (YAML DSL) | Low (shell-like) |
| Single machine setup | Overkill | Perfect fit |

## Troubleshooting

### Check what's completed
```bash
./setup.sh status
```

### Force re-run a specific step
```bash
./setup.sh clean-marker ros2
./setup.sh ros2
```

### Force re-run everything
```bash
./setup.sh clean-markers
./setup.sh
```

### View verbose output
The scripts output progress. For more detail, read the individual scripts in `scripts/`.
