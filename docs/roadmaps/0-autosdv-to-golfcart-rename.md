# AutoSDV to Golf Cart Rename Roadmap

**Goal**: Rename all `autosdv` references to `golfcart` across the project.

**Status**: ✅ **Phases 1-4, 6-8 Complete** | ⏸️ **Phase 5 Deferred**

**Summary**:
- ✅ Renamed `autosdv_launch` package → `golfcart_launch`
- ✅ Renamed launch files: `autosdv.launch.yaml` → `golfcart.launch.yaml`, `autosdv_autoware.launch.xml` → `golfcart_autoware.launch.xml`
- ✅ Renamed vehicle/sensor model: `autosdv_vehicle` → `golfcart_vehicle`, `autosdv_sensor_kit` → `golfcart_sensor_kit`
- ✅ Renamed ROS namespace: `autosdv` → `golfcart`
- ✅ Renamed Python classes: `AutoSdvActuator` → `GolfCartActuator`, `AutoSdvVelocityReportNode` → `GolfCartVelocityReportNode`
- ✅ Updated build/infra: justfile, Docker, CI, setup scripts, versions.yaml, env vars
- ✅ Updated scripts, hardcoded paths, documentation, logos
- ⏸️ Deferred: `autosdv_runtime` and `autosdv_system_monitor` submodules (require GitHub repo renames)

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

## Phase 5: System Submodules ⏸️ DEFERRED

**Scope**: Rename `autosdv_runtime` and `autosdv_system_monitor` submodules. Deferred because these require GitHub repository renames.

### Current State

The two submodules are **untouched** and still use the `autosdv` naming:
- `src/system/autosdv_runtime/` — CLI tool, systemd services, launch management
- `src/system/autosdv_system_monitor/` — Web-based system monitor

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
