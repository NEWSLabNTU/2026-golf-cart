# Development

For people changing the code. Users start at [README.md](README.md).

Also read:

- [CONTRIBUTING.md](CONTRIBUTING.md): branches, commit messages, and the
  submodule rule (push a submodule commit to its fork before the parent pointer)
- [CLAUDE.md](CLAUDE.md): the detailed project notes, including the traps
- [docs/README.md](docs/README.md): index of design notes, roadmaps and research
- [docs/multi-machine.md](docs/multi-machine.md): how the two machines are wired
  together (domains, link bridge, systemd units)

## Build and test

```bash
just build           # colcon build, Release, symlink install
just build --clean   # wipe build/ install/ log/ first
just test            # colcon test + results
just checkout        # update submodules
```

Building by hand needs the same flags:

```bash
colcon build --base-paths src --symlink-install \
  --cmake-args -DCMAKE_BUILD_TYPE=Release --packages-select <package>
```

With the symlink install, edits to existing YAML, XML and Python files apply
without a rebuild. A new file needs a rebuild.

`just build` skips packages a machine cannot build, instead of failing.
`scripts/colcon_ignore.sh` decides, and prints why:

| skipped | when | fix |
|---|---|---|
| ZED packages | no ZED SDK 5.x at `/usr/local/zed` | install the SDK (orin only) |
| `golfcart_vehicle_interface` | no `CAX_ADS_CAN.dbc` in the crate root and no `CAX_ADS_DBC` | copy the vendor DBC (orin only) |
| u-blox driver | `ros-humble-mavros-msgs` missing | `rosdep` / apt |
| `rig_localization` | cuVSLAM not fetched | `./setup.sh --only cuvslam` |

A skipped package is not an error, so read the build output: a missing DBC on the
orin means the cart cannot be driven.

### TensorRT engines

Perception nodes compile each ONNX model into a TensorRT engine on first use,
minutes per model on the Orin. Engines are cached in git, one pack per key:

```bash
just engines key       # aw1.5.0-trt10.3.0.30-agx-orin-64gb on both hosts today
just engines install   # data/engines/<key>/ -> data/autoware_data/, ONNX sha256 checked
just engines verify    # installed engines against the pack
just build-engines     # builds what is still missing; loads, not rebuilds, the rest
just engines save      # after a build that produced new or changed engines
```

The key is Autoware release + full TensorRT version + board (Jetson module
part number, or GPU name and compute capability elsewhere). L4T, CUDA and the
hostname are recorded in `manifest.yaml` but not keyed on. `install` copies an
engine only where the ONNX beside its target hashes to the one it was built
from, and keeps a differing local engine unless given `--force`; whatever it
skips is built on first launch as before. The `tensorrt-engines` setup step
runs install, then build-engines.

Engines are stored zstd-compressed (`<stem>.engine.zst`, `zstd -19`; needs the
`zstd` CLI, `sudo apt install zstd`) as plain git blobs, no LFS: about 9.2 MB
per key today, nearly all of it the CenterPoint-tiny backbone, which barely
compresses. Every save of a changed engine adds its packed size to history
for good, so save only when an engine really changed; `save` on unchanged
engines writes nothing. Design:
[docs/research/perception/tensorrt-engine-prebuild.md](docs/research/perception/tensorrt-engine-prebuild.md).

## Running on one machine

`just run` runs the stack on this machine only, in the foreground. No systemd, no
ssh. Ctrl-C stops it.

```bash
just run                            # web UI at http://localhost:8081
just run use_gnss:=false            # indoor, no GNSS
just run @basement use_gnss:=true   # an argument file, then an override
```

`host:=` comes from `config/host`. Without that file the machine uses
`host:=all` and the loopback network profile, and runs everything itself.

To run the master's systemd unit without the orin:

```bash
GOLFCART_USE_ORIN=0 just up
```

The vehicle interface runs on the orin, so this cannot drive the cart.

## Simulators

```bash
just sim planning @sim-ntu-r01                  # planning simulator; or map_path:=<dir>
just sim planning @sim-mingda-loop              # then: just sim loop-drive
just sim logging                                # stack with drivers off; play a bag into it
just sim aruco @sim-aruco                       # ArUco localization driving the planning sim
just sim coss-park                              # logging sim + COSS Park bag + recording
just sim mrm-check                              # MRM end-to-end check on the Ming-Da lane
```

The `@sim-*` argument files are listed in
[docs/operating.md](docs/operating.md#launch-arguments-and-argument-files).
`just --list sim` shows the rest, including synthetic GMSL cameras on
v4l2loopback (`just sim cameras`).

Replay tests with their own step-by-step sequences: `just ntu-test` (NTU NDT
replay) and `just indoor-test` (board cold start).

## Bench work on the vehicle interface

```bash
just vehicle interface                 # real bus, can0 (no Autoware)
just vehicle interface can=vcan0       # against a virtual bus
just vehicle manual-control            # keyboard, in a second terminal
just can vcu-status                    # receive-only VCU readout
just can record / just can decode      # raw CAN
```

## Project structure

```
.
├── src/
│   ├── launcher/golfcart_launch/   # main launch files (golfcart.launch.yaml), presets, RViz config
│   ├── sensor_kit/                 # sensor launch and config (golfcart_sensor_kit_launch)
│   ├── sensor_component/external/  # sensor drivers (submodules)
│   ├── vehicle/                    # vehicle description and CAN vehicle interface
│   ├── localization/               # cuda_ndt_matcher, board and ArUco localizers, rig_localization
│   ├── sensing/                    # CUDA point cloud filters
│   ├── param/                      # Autoware individual params per sensor kit
│   ├── system/                     # golfcart_domain_bridge, system monitor
│   ├── simulation/, tools/         # Isaac Sim twin, sphere sensor view
│   └── calibration/
├── config/          # everything that varies by machine or session (see below)
├── just/            # just modules: `just <module> <recipe>`
├── scripts/         # scripts behind the recipes; scripts/env.sh is the environment
├── setup/           # ./setup.sh: the installer and its step registry
├── data/            # maps and models (not in git)
├── docs/            # design notes, guides, roadmaps, research
└── ROADMAP.md
```

## config/ and scripts/env.sh

Everything that differs between machines or sessions lives in `config/`. No
script hardcodes it. See [config/README.md](config/README.md).

| file | decides |
|---|---|
| `config/host` | which machine this is: `master` or `orin` (gitignored) |
| `config/multi_machine.conf` | the orin's ssh address and repo path, the ssh key, the master's IP |
| `config/runtime.conf` | container mode, middleware, the ROS domain ids |
| `config/launch/*.args` | named launch argument sets (`@name`) |
| `config/link/topics.yaml` | which topics cross between the machines |
| `config/recording/*_topics.txt` | what each machine records |
| `config/cyclonedds/*.xml` | DDS profiles, one per role |

`scripts/env.sh` sets up the environment from these files: ROS and Autoware
sourcing, `ROS_DOMAIN_ID`, `CYCLONEDDS_URI`, `RMW_IMPLEMENTATION`,
`GOLFCART_BAG_DIR`. `.envrc` (direnv) and the systemd units both source it. New
scripts should source it too, not work these out again.

Sensor choices (`camera_model`, `imu_source`, `gnss_receiver`, `use_ntrip`,
`pointcloud_backend`) are ordinary launch arguments with defaults in
`golfcart.launch.yaml`.

## Deprecated recipes

The old launch recipes still work. Each prints a warning and forwards to the new
one. They will be removed.

| old | new |
|---|---|
| `just launch` | `just run` |
| `just launch-all` | `just up` |
| `just stop-all` | `just down` |
| `just launch-up` / `just launch-down` | `just up` / `just down` (both machines) |
| `just launch-drive-basement` | `just up @basement` |
| `just launch-drive-mingda` | `just up @mingda` |
| `just launch-drive-mingda-loop` | `just up @mingda-loop` |
| `just launch-sim-planning r01` | `just sim planning @sim-ntu-r01` |
| `just launch-sim-logging` | `just sim logging` |

`just --list` shows every recipe, modules expanded.
