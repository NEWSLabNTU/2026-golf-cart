# Contributing to 2026 Golf Cart

## Branching Convention

### Main Repository

- **`main`** — stable, integration-ready code. PRs go here.
- **`allen`**, **`darren`** — personal working branches for each team member.

### Submodule Repositories: one line per what the source follows

A submodule's branch is chosen by what its **source** has to follow, not by
what it links. Most Autoware message types are stable across releases, so a
package that only uses them shares one source and is rebuilt per Autoware
version (`config/autoware-version`).

| Class | Line | When |
|---|---|---|
| Golf cart | `2026-golf` | the content is this vehicle's: its launch, description, parameters |
| Autoware release | the upstream version, `1.5.0`, `2.1.0`; a golf cart patch on top is `2026-golf-<ver>` | the source itself differs between Autoware releases |
| ROS edition | `main` (or upstream's `ros2`); `humble`/`jazzy` only once the code splits | drivers and nodes with no Autoware dependency |
| Standalone | `main`, semver tags if a version is needed | libraries and tools shared with other projects |

`golfcart_launch` (in this repository, not a submodule) is the glue: anything
that names an Autoware launch file, config package or path lives there, on
the superproject's per-version branch (`main` is the default version,
`autoware-2.1.0` the next). A submodule that has to reach such a path takes it
as a launch argument with a default, so it keeps one source.

Superseded branch names are frozen, never deleted: no new commits, but
superproject history pins commits that may be reachable only from them.
Earlier names include `golfcart`, `golfcart-1.5.0`, `1.5.0` on seyond_ros_driver,
and `main` on the two repos that moved to `2026-golf`. This file used to
prescribe a `2026-golfcart` branch that no repository adopted.

Record the line in `.gitmodules`, then `git submodule sync`:

```ini
[submodule "src/sensor_kit/golfcart_sensor_kit_launch"]
    path = src/sensor_kit/golfcart_sensor_kit_launch
    url = https://github.com/NEWSLabNTU/golfcart_sensor_kit_launch.git
    branch = 2026-golf
```

---

## Submodule Overview

| Submodule path | Class | Line |
|---|---|---|
| `src/vehicle/golfcart_vehicle_launch` | golf cart | `2026-golf` |
| `src/system/golfcart_system_monitor` | golf cart | `2026-golf` |
| `src/param/autoware_individual_params` | golf cart | `2026-golf` |
| `src/sensor_kit/golfcart_sensor_kit_launch` | golf cart | `2026-golf` |
| `src/calibration/CalibrationTools` | Autoware release | `1.5.0` (then `2.1.0`) |
| `src/sensor_component/external/seyond_ros_driver` | ROS edition | `main` (vendor syncs merged in) |
| `src/sensor_component/external/ublox` | ROS edition | `ros2` |
| `src/sensor_component/external/xsens_mti_can_ros2_driver` | ROS edition | `main` |
| `src/sensor_component/external/gmslcam` | ROS edition | `main` |
| `src/sensor_component/external/zed-ros2-wrapper` | ROS edition | upstream tag `v5.4.1`, no branch |
| `src/localization/cuda_ndt_matcher` | standalone | `main` |
| `src/sensing/cuda_pointcloud_filters` | standalone | `main` |
| `src/localization/reflective_pose_detector` | standalone | `main` |
| `src/localization/rig_localization` | standalone | `main` |
| `src/vehicle/external/autoware_manual_control` | standalone | `main` |
| `src/sensor_component/external/gnss_locator` | standalone | `main` |

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

**Rule: push the submodule before you push the pointer.**

A superproject commit records a submodule as a bare SHA. If that SHA only exists
on someone's laptop, every fresh clone fails at `git submodule update` with

```
fatal: remote error: upload-pack: not our ref <sha>
```

and the superproject commit is unusable — the parent repo cannot tell you what
was supposed to be there. So, in order:

1. Push the submodule commit to its NEWSLabNTU fork on GitHub.
2. Push it to a **long-lived branch**, not just a feature branch. A pointer whose
   only home is `feat/…` breaks the moment that branch is deleted after merging —
   normal hygiene that silently invalidates history.
3. Only then commit and push the parent's pointer update.

Check before pushing the parent:

```bash
# every pointer, and which remote branches contain it
git submodule foreach --quiet \
  'echo "$sm_path $(git branch -r --contains HEAD | tr -d " " | tr "\n" " ")"'
```

Anything printing no remote branch, or only a feature branch, is not ready.

```bash
# Initialize all submodules (first time)
just checkout

# Update submodules to latest tracked commit
git submodule update --remote

# After changing a submodule: push it FIRST, then the parent pointer
git -C src/sensor_kit/golfcart_sensor_kit_launch push origin HEAD:main
git add src/sensor_kit/golfcart_sensor_kit_launch
git commit -m "chore: update golfcart_sensor_kit_launch submodule"
```
