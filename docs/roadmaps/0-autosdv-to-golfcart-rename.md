# AutoSDV to Golf Cart Rename Roadmap

**Goal**: Rename all `autosdv` references to `golfcart` across the project.

**Status**: ✅ **Phases 1-4, 6-8 Complete** | ⏸️ **Phase 5 Deferred, and half-done
by accident** — the two submodule *directories* were renamed while their package
names were not, which has already broken two launch paths. See Phase 5.

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

The two submodules are in a **half-renamed state**, which is worse than either
end of the rename and is where the bugs come from. Their *directories* were
renamed; their *package names* were not:

| On disk | `package.xml` name |
|---------|--------------------|
| `src/system/golfcart_runtime/` | `autosdv_runtime` |
| `src/system/golfcart_system_monitor/` | `autosdv_system_monitor` |

`find-pkg-share` resolves the package name, not the directory, so anything that
followed the directory rename is broken. Two instances found and fixed on
2026-08-13:

- `logging_simulation.launch.yaml` and `sensor_only.launch.yaml` included
  `$(find-pkg-share golfcart_system_monitor)/launch/golfcart_system_monitor.launch.yaml`.
  Neither the package nor the file exists under that name, and neither include is
  guarded, so both launches died there. `logging_simulation` is what phase 3B
  needs for indoor NDT validation.
- `autosdv_runtime`'s launcher ran `ros2 launch autosdv_launch autosdv.launch.yaml`,
  from before phase 1 renamed that package and file. Now
  `golfcart_launch golfcart.launch.yaml`.

### Still stale in the runtime submodule

The systemd units hardcode the old workspace location and are not templated:

```
# systemd/autosdv.service
WorkingDirectory=%h/AutoSDV
ExecStart=%h/AutoSDV/install/autosdv_runtime/share/autosdv_runtime/scripts/autosdv-launch.sh
```

This repo lives at `~/repos/2026-golf-cart`, so the service path is wrong
independently of any naming question. Left alone deliberately: correcting it
means deciding the deployment layout, which is a different call from a rename.
`just launch` does not go through systemd — it runs
`ros2 launch golfcart_launch golfcart.launch.yaml` directly — so this affects the
`golfcart` CLI and service path only.

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
