# Contributing to 2026 Golf Cart

## Branching Convention

### Main Repository

- **`main`** — stable, integration-ready code. PRs go here.
- **`allen`**, **`darren`** — personal working branches for each team member.

### Submodule Repositories (NEWSLabNTU forks)

When making project-specific changes in a forked submodule, create a branch named **`2026-golfcart`** in that submodule's repository before committing. This keeps golf cart changes separate from the upstream fork's default branch and makes it easy to track what we've changed.

```bash
# Example: creating the project branch in a submodule
cd src/sensor_kit/golfcart_sensor_kit_launch
git checkout -b 2026-golfcart
git push -u origin 2026-golfcart
```

Once the branch exists, update the corresponding entry in `.gitmodules` to pin to it:

```ini
[submodule "src/sensor_kit/golfcart_sensor_kit_launch"]
    path = src/sensor_kit/golfcart_sensor_kit_launch
    url = https://github.com/NEWSLabNTU/golfcart_sensor_kit_launch.git
    branch = 2026-golfcart
```

Then run `git submodule sync && git submodule update --remote` to track the branch.

---

## Submodule Overview

| Submodule path | Repository | Fork? | Notes |
|---|---|---|---|
| `src/vehicle/external/autoware_manual_control` | `evshary/autoware_manual_control` | Upstream | Keyboard control |
| `src/sensor_component/external/gnss_locator` | `NEWSLabNTU/gnss_locator` | Fork | GNSS localization |
| `src/sensor_component/external/ros-nmea-reader` | `jerry73204/ros-nmea-reader` | Upstream | NMEA GPS parser |
| `src/param/autoware_individual_params` | `NEWSLabNTU/autoware_individual_params` | Fork | Sensor kit params |
| `src/system/golfcart_runtime` | `NEWSLabNTU/golfcart_runtime` | Fork | CLI + systemd runtime |
| `src/system/golfcart_system_monitor` | `NEWSLabNTU/golfcart_system_monitor` | Fork | Web system monitor |
| `src/calibration/CalibrationTools` | `NEWSLabNTU/CalibrationTools` | Fork | LiDAR-camera calib |
| `src/localization/cuda_ndt_matcher` | `NEWSLabNTU/cuda_ndt_matcher` | Fork | CUDA NDT localization |
| `src/sensor_kit/golfcart_sensor_kit_launch` | `NEWSLabNTU/golfcart_sensor_kit_launch` | Fork | Sensor launch files |
| `src/vehicle/golfcart_vehicle_launch` | `NEWSLabNTU/golfcart_vehicle_launch` | Fork | Vehicle launch files |

For NEWSLabNTU forks, always use the `2026-golfcart` branch for project-specific work.

---

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>: <short description>

[optional body]
```

Types: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `style`

Examples:
- `feat: add check-sensors justfile recipe`
- `chore: update .gitmodules to golfcart_runtime`
- `fix: correct imu topic name in record_outdoor.sh`

---

## Submodule Workflow

```bash
# Initialize all submodules (first time)
just checkout

# Update submodules to latest tracked commit
git submodule update --remote

# After changing a submodule, commit the parent repo pointer update
git add src/sensor_kit/golfcart_sensor_kit_launch
git commit -m "chore: update golfcart_sensor_kit_launch submodule"
```
