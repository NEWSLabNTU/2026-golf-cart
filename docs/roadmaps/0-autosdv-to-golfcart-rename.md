# AutoSDV to Golf Cart Rename Roadmap

**Goal**: Rename all `autosdv` references to `golfcart` across the project.

**Status**: ✅ **All phases complete** (Phase 5 finished 2026-08-13)

**Summary**:
- ✅ Renamed `autosdv_launch` package → `golfcart_launch`
- ✅ Renamed launch files: `autosdv.launch.yaml` → `golfcart.launch.yaml`, `autosdv_autoware.launch.xml` → `golfcart_autoware.launch.xml`
- ✅ Renamed vehicle/sensor model: `autosdv_vehicle` → `golfcart_vehicle`, `autosdv_sensor_kit` → `golfcart_sensor_kit`
- ✅ Renamed ROS namespace: `autosdv` → `golfcart`
- ✅ Renamed Python classes: `AutoSdvActuator` → `GolfCartActuator`, `AutoSdvVelocityReportNode` → `GolfCartVelocityReportNode`
- ✅ Updated build/infra: justfile, Docker, CI, setup scripts, versions.yaml, env vars
- ✅ Updated scripts, hardcoded paths, documentation, logos
- ✅ Renamed `autosdv_runtime` → `golfcart_runtime` and `autosdv_system_monitor` → `golfcart_system_monitor` submodules

---

## Completed Phases

### Phase 1: Main Launch Package ✅

Renamed `autosdv_launch` → `golfcart_launch`:
- Directory: `src/launcher/autosdv_launch/` → `golfcart_launch/`
- Python module: `autosdv_launch/` → `golfcart_launch/`
- Launch files: `autosdv.launch.yaml` → `golfcart.launch.yaml`, `autosdv_autoware.launch.xml` → `golfcart_autoware.launch.xml`
- RViz config: `autosdv.rviz` → `golfcart.rviz`
- Resource marker, package.xml, CMakeLists.txt, all internal `find-pkg-share` references

### Phase 2: Vehicle Model and Sensor Kit Names ✅

- `autosdv_vehicle` → `golfcart_vehicle` in all launch arg defaults
- `autosdv_sensor_kit` → `golfcart_sensor_kit` in all launch arg defaults and config paths
- Renamed `individual_params/config/default/autosdv_sensor_kit/` → `golfcart_sensor_kit/` (in autoware_individual_params submodule)

### Phase 3: ROS Namespace ✅

- `<push-ros-namespace namespace="autosdv"/>` → `namespace="golfcart"` in vehicle_interface.launch.xml and basic_control.launch.xml

### Phase 4: Python Class and Node Names ✅

- `AutoSdvActuator` → `GolfCartActuator`, node name `golfcart_actuator_node`
- `AutoSdvVelocityReportNode` → `GolfCartVelocityReportNode`, node name `golfcart_velocity_report_node`

### Phase 6: Build & Infrastructure ✅

- `justfile`: launch commands updated to `golfcart_launch golfcart.launch.yaml`
- `versions.yaml`: `autosdv:` → `golfcart:` top-level key
- `scripts/version/*.sh`: `AUTOSDV_VERSION` → `GOLFCART_VERSION` etc.
- `docker/Makefile`, `Dockerfile`: image name, paths
- `.github/workflows/docker-build.yml`: `IMAGE_NAME: golfcart`
- `setup/setup.sh`, `setup/justfile`, `setup/scripts/*.sh`: UI strings, env vars
- `.envrc`: comment
- WiFi AP: `autosdv-ap` → `golfcart-ap`, AP name updated

### Phase 7: Scripts and Hardcoded Paths ✅

- Hardcoded paths: `/home/jetson/AutoSDV/` → `/home/jetson/golfcart/`
- Script comments and docstrings updated

### Phase 8: Documentation and Cosmetic ✅

- CLAUDE.md, README.md, MIGRATION.md, NOTICE updated
- All `docs/` markdown files (~25 files) updated
- Logo SVGs: "AutoSDV" text → "Golf Cart"
- Copyright headers in C++ source (localization submodule)
- Python docstrings in control_test package

---

## Phase 5: System Submodules ✅ COMPLETE

**Scope**: Rename the `autosdv_runtime` and `autosdv_system_monitor` submodules.
**Done 2026-08-13.** The stated blocker had already cleared: both GitHub
repositories were renamed to `golfcart_*` some time ago, and `.gitmodules`
pointed at the new URLs. Only the ROS package names inside them were left.

### Current State

Both submodules are now fully renamed, package names included.

| Submodule | Package name | Python module | Entry point |
|-----------|--------------|---------------|-------------|
| `src/system/golfcart_runtime` | `golfcart_runtime` | `golfcart_runtime/` | `golfcart` CLI |
| `src/system/golfcart_system_monitor` | `golfcart_system_monitor` | `golfcart_system_monitor/` | `golfcart_system_monitor_node.py` |

Also renamed in the runtime submodule: the systemd units
(`golfcart.service`, `golfcart-healthcheck.service`/`.timer`,
`golfcart-web-control.service`), the journald drop-in, and the launch wrapper.
`AUTOSDV_WORKSPACE` is still honoured alongside `GOLFCART_WORKSPACE` so an
existing deployment keeps working until its environment is updated.

### What the half-renamed state had already broken

The directories had been renamed to `golfcart_*` while the package names stayed
`autosdv_*`. `find-pkg-share` resolves the package name, so anything written to
match the directory failed:

- `logging_simulation.launch.yaml` and `sensor_only.launch.yaml` included
  `$(find-pkg-share golfcart_system_monitor)/...`, which did not resolve. Neither
  include is guarded, so both launches died there — including the one indoor NDT
  validation depends on.
- The runtime launcher ran `ros2 launch autosdv_launch autosdv.launch.yaml`, from
  before phase 1 renamed that package and file, so the systemd and CLI launch
  path could not have worked at all.

Both are fixed, and the references now match the packages that exist.

### Deliberately left alone

The systemd units still point at `%h/AutoSDV`, which is wrong for a workspace at
`~/repos/2026-golf-cart` regardless of naming, and the installer copies the units
without substitution. Correcting it means choosing a deployment layout, which is
a separate decision from a rename. `just launch` does not go through systemd — it
runs `ros2 launch golfcart_launch golfcart.launch.yaml` directly — so this
affects the `golfcart` CLI and service path only.

### Verification

- Both packages build under their new names and install correct
  `ament_index/resource_index/packages` entries.
- `golfcart --help` runs from the installed CLI.
- `ros2 launch golfcart_system_monitor golfcart_system_monitor.launch.yaml`
  starts, and its GNSS subscriptions follow `use_gnss`: three under `true`, none
  under `false`.

References TO these packages are preserved in the main repo:
- `find-pkg-share autosdv_system_monitor` in `golfcart.launch.yaml`, `sensor_only.launch.yaml`, `logging_simulation.launch.yaml`
- `.gitmodules` entries with original URLs

### Prerequisites

Before renaming:
1. Rename GitHub repos: `NEWSLabNTU/autosdv_runtime` → `NEWSLabNTU/golfcart_runtime`, `NEWSLabNTU/autosdv_system_monitor` → `NEWSLabNTU/golfcart_system_monitor`
2. Or fork under new names

### Work Items When Ready

#### autosdv_runtime → golfcart_runtime
- [ ] Rename GitHub repo (or fork)
- [ ] Update `.gitmodules` path and URL
- [ ] Rename directory, Python module, resource marker
- [ ] Update package.xml, CMakeLists.txt, setup.py
- [ ] Rename Python classes: `AutoSDV` → `GolfCart`, `AutoSDVManager` → `GolfCartManager`, etc.
- [ ] Rename CLI: `scripts/autosdv` → `scripts/golfcart`
- [ ] Rename systemd services: `autosdv.service` → `golfcart.service`, etc.
- [ ] Update config/launch.conf
- [ ] Update all Python source (~50 occurrences across 8 files)

#### autosdv_system_monitor → golfcart_system_monitor
- [ ] Rename GitHub repo (or fork)
- [ ] Update `.gitmodules` path and URL
- [ ] Rename directory, Python module, resource marker
- [ ] Update package.xml, CMakeLists.txt, setup.py
- [ ] Rename launch file and Python node file
- [ ] Update class name: `AutoSDVSystemMonitor` → `GolfCartSystemMonitor`
- [ ] Update HTML title, log messages, node name

#### Downstream references (in main repo)
- [ ] Update `find-pkg-share autosdv_system_monitor` → `golfcart_system_monitor` in 3 launch files
- [ ] Update `.gitmodules` paths and URLs
