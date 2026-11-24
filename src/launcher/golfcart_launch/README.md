# Golf Cart Launch Package

This package provides the main launch system for Golf Cart, including launch files and Autoware configuration files with Golf Cart-specific customizations.

## Package Structure

```
golfcart_launch/
├── launch/             # Launch files for Golf Cart system
│   ├── golfcart.launch.yaml          # Main entry point
│   ├── sensing.launch.xml           # Sensor suite configuration
│   ├── localization.launch.xml      # Localization (NDT, EKF, Isaac SLAM)
│   ├── planning.launch.xml          # Path and motion planning
│   └── ...
├── config/             # Autoware configuration files
│   ├── localization/   # ArUco, reflective board, rigloc, presets
│   ├── system/         # Diagnostics, MRM configuration
│   ├── planning/       # Planning parameters
│   ├── perception/     # Perception parameters
│   └── ...
├── rviz/              # RViz configuration files
└── golfcart_launch/    # Python package (if needed)
```

## Configuration Files Source

Base configuration copied from: autoware_launch (version 0.40.0)
Original location: autoware/src/launcher/autoware_launch/autoware_launch/config/
Date copied: 2025-12-28

## Configuration Customizations

All configuration files are in the `config/` directory. Below are Golf Cart-specific modifications from the Autoware defaults.

### Localization

Autoware's localization parameters (EKF, NDT and its preprocessing, pose
initializer, yabloc, eagleye, ...) are not here: they are the
[golfcart_localization_config](../golfcart_localization_config/README.md)
package, a whole copy of Autoware 2.1.0's `autoware_localization_config` with
our changes marked, passed to upstream as `localization_config_pkg`.

`config/localization/` keeps only what is ours alone: the ArUco detector and
localizer, the reflective board (`reflective_pose/`), rig_localization
(`rigloc/`) and the localization presets (`preset/`).

### System Diagnostics & MRM (config/system/)

- **diagnostics/localization.yaml**: Disabled localization accuracy check
  - **CRITICAL CHANGE**: Commented out `/autoware/localization/accuracy` check to prevent false MRM triggers
  - **Reason**: Default error ellipse thresholds (1.5m position, 0.3m lateral) too strict for VLP-32C
  - **Impact**: MRM emergency stops no longer triggered by localization uncertainty alone
  - Localization quality still monitored via `scan_matching_status` (NDT score threshold)
  - **Alternative (not implemented)**: Override `localization_error_monitor.param.yaml` with higher thresholds:
    - `error_ellipse_size: 3.0` (from 1.5m)
    - `error_ellipse_size_lateral_direction: 0.6` (from 0.3m)
  - **Recommendation**: Monitor `/localization/localization_error_monitor/debug/ellipse_marker` during testing
  - Last modified: 2025-12-28

**MRM Background:**
- MRM triggers emergency stop when autonomous mode becomes unavailable
- Autonomous mode requires ALL of: localization, perception, planning, control, vehicle, map
- Default behavior: Emergency stop with -2.5 m/s² braking (aggressive)
- During outdoor testing, brief localization uncertainty can trigger false emergency stops
- This change allows controlled operation with acceptable localization uncertainty

**Monitoring MRM Status:**
```bash
# Check autonomous mode availability
ros2 topic echo /system/operation_mode/availability

# Check MRM state
ros2 topic echo /system/fail_safe/mrm_state

# View all diagnostics
ros2 run rqt_robot_monitor rqt_robot_monitor
```

## Choosing a pose source

`pose_source` selects how the vehicle knows where it is. The three options are
not variations on one pipeline — `aruco` replaces the pipeline.

| value | what runs | needs |
|---|---|---|
| `ndt` (default) | Autoware NDT scan matching | point cloud map |
| `cuda_ndt` | CUDA-accelerated NDT | point cloud map |
| `aruco` | indoor ArUco board localization | surveyed board map, **no** point cloud map |

```bash
just run                                    # ndt
just run "pose_source:=cuda_ndt"
just run "pose_source:=aruco aruco_tag_map_path:=./data/<site>/aruco_tag_map.yaml"

# or by preset, which sets pose_source for you
just run "localization_preset:=aruco aruco_tag_map_path:=/path/to/aruco_tag_map.yaml"
```

`aruco_tag_map_path` has no default and is required. A default would be worse
than nothing: it would point at some other site's board positions and the
vehicle would localize confidently into the wrong building.

Selecting `aruco` changes more than one node:

- no scan matcher, no point cloud map loader, no NDT pointcloud preprocessing —
  `golfcart_map_component.launch.xml` brings up lanelet2 and the projection only
- three per-camera ArUco detectors come up under `/sensing/camera/*`
- the **diagnostics graph is switched** to `autoware-main-aruco.yaml`, because
  upstream's requires an NDT scan-matcher diagnostic that can never publish on
  this path and would leave the whole localization subtree stale
- `pose_initializer` runs with NDT and GNSS initialization disabled; the ArUco
  localizer supplies the initial pose through `/localization/initialize`

Related: [`golfcart_aruco_localizer`](../../localization/golfcart_aruco_localizer/README.md),
[`golfcart_aruco_detector`](../../localization/golfcart_aruco_detector/README.md).

### Trying it without a vehicle

The whole localization stack runs against synthetic detections in seconds — no
map, no simulator, no hardware:

```bash
ros2 launch golfcart_launch sim_smoke.launch.xml pattern:=corridor
python3 scripts/check/aruco_smoke_test.py       # 6 graded scenarios, exits non-zero on failure
```

## Configuration Categories (config/ directory)

- **control/**: Vehicle control parameters (trajectory following, cmd gate, etc.)
- **localization/**: Localization parameters (NDT, EKF, pose initializer, etc.)
- **map/**: Map loading and projection parameters
- **perception/**: Object detection and tracking parameters
- **planning/**: Path and motion planning parameters
- **system/**: System monitoring and diagnostics
- **vehicle/**: Raw vehicle command converter parameters
- **simulator/**: Simulation-specific parameters

## Updating Configurations

When updating Autoware base version:
1. Review changes in upstream autoware_launch/config/
2. Merge relevant updates into this package's config/ directory
3. Preserve Golf Cart-specific customizations documented above
4. Test thoroughly with Golf Cart hardware
5. Document changes in this README

## Related Documentation

- **MRM Configuration Guide**: `docs/guides/mrm_configuration.md` - Detailed MRM system documentation
- **NDT Parameter Tuning**: `docs/research/localization/ndt_parameter_tuning_coss_map.md` - Empirical tuning results
- **Control Testing**: `docs/guides/control_testing.md` - Control system testing procedures
