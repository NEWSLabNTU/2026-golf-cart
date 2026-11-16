# Perception Presets

Perception presets define the perception configuration for Golf Cart. They control which perception features are enabled and which perception mode is used.

## Autoware 2.1.0 (this branch)

2.1.0's perception component is lidar only; traffic lights are a component of
their own (`component_traffic_light`, included by `golfcart_autoware.launch.xml`
when `use_traffic_light_recognition` is true). So:

- `lidar_only` and `minimal` work as before.
- `camera_lidar_fusion` **stops the launch**: `perception_mode` other than
  `lidar`, `use_detection_by_tracker:=true` and
  `use_image_segmentation_based_filter:=true` each fail with an
  `Undefined variable: 'GOLFCART_UNSUPPORTED_..._on_autoware_2_1_0'` error, because
  2.1.0 has no such pipeline and the arguments would otherwise be dropped
  without a word. Camera fusion on 2.1.0 needs its own composition
  (`object_recognition_camera_lidar_radar.launch.xml`) and has not been built.
- `traffic_light_recognition/enable_fine_detection` is passed on as 2.1.0's
  `traffic_light_recognition/use_high_accuracy_detection`.
- **The clustering detector is on in `lidar_only` and `minimal`** (decided
  2026-11-17). In 1.5.0's lidar mode the tracker ignored it, so both presets
  turned it off to save its CPU. In 2.1.0 the tracker reads clustering as its
  own channel (`lidar_clustering`, objects of class unknown), so it is what
  detects anything CenterPoint has no class for. `use_lidar_rule_detector:=false`
  still drops it.

The two copies are `launch/components/tier4_perception_component.launch.xml`
(of `component_perception`) and `launch/components/perception/object_recognition_lidar.launch.xml`.
The rest of this file describes 1.5.0.

## Available Presets

### `lidar_only` (Default)
Default preset for Golf Cart. Uses only LiDAR for perception.

**Configuration**:
- `perception_mode`: `lidar`
- `use_traffic_light_recognition`: `false`
- `use_detection_by_tracker`: `false`
- `use_image_segmentation_based_filter`: `false`
- `use_pointcloud_map`: `true`
- `lidar_detection_model`: `centerpoint/centerpoint_tiny`
- `use_lidar_rule_detector`: `false` (1.5.0; `true` on 2.1.0, above)
- `use_perception_analytics_publisher`: `false`

**Detection is CenterPoint tiny and nothing else** (1.5.0). In lidar mode the tracker
(multi-channel merger) reads only CenterPoint's validated objects, so the
clustering detector Autoware also starts was computed and discarded. Upstream
has no switch for it; `use_lidar_rule_detector` exists only in our copies of the
perception launch (`launch/components/tier4_perception_component.launch.xml`,
`launch/components/perception/`), which `test_perception_copies.py` holds to
upstream. Consequence: only CenterPoint's classes (car, truck, bus, bicycle,
motorcycle, pedestrian) become objects. A box or a trolley in the aisle is not
one.

**Use cases**:
- Standard outdoor operation with LiDAR
- When camera is not available or not needed
- Faster perception processing

**Launch**:
```bash
just run "perception_preset:=lidar_only"
# Or omit (it's the default)
just run
```

### `camera_lidar_fusion`
Uses both camera and LiDAR for enhanced perception. Enables camera-based features.

**Configuration**:
- `perception_mode`: `camera_lidar_fusion`
- `use_traffic_light_recognition`: `true`
- `use_detection_by_tracker`: `true`
- `use_image_segmentation_based_filter`: `true`
- `use_pointcloud_map`: `true`
- `lidar_detection_model`, `use_lidar_rule_detector`,
  `use_perception_analytics_publisher`: Autoware's defaults

**Use cases**:
- Urban environments with traffic lights
- When enhanced object detection is needed
- Research on sensor fusion

**Requirements**:
- Camera sensor must be available
- Higher computational resources required

**Launch**:
```bash
just run perception_preset:=camera_lidar_fusion
```

### `minimal`
Minimal perception configuration for development and debugging.

**Configuration**:
- `perception_mode`: `lidar`
- `use_traffic_light_recognition`: `false`
- `use_detection_by_tracker`: `false`
- `use_image_segmentation_based_filter`: `false`
- `use_pointcloud_map`: `false`

**Use cases**:
- Development and debugging
- Faster startup times
- Testing without perception features

**Launch**:
```bash
just run "perception_preset:=minimal"
```

## Usage

Specify the preset when launching Golf Cart:

```bash
# Real hardware mode
just run "perception_preset:=<preset_name>"

# Logging simulation mode
ros2 launch golfcart_launch logging_simulation.launch.yaml perception_preset:=<preset_name>
```

## Creating Custom Presets

To create a custom preset:

1. Copy an existing preset file (e.g., `lidar_only.yaml`)
2. Rename it (e.g., `custom.yaml`)
3. Modify the parameters as needed
4. Add conditional logic in `golfcart.launch.yaml` to support the new preset
5. Update this README with the new preset documentation

## Parameter Reference

| Parameter | Type | Description |
|-----------|------|-------------|
| `perception_mode` | string | Perception mode: `lidar`, `camera_lidar_fusion`, `camera_lidar_radar_fusion`, `radar` |
| `use_traffic_light_recognition` | bool | Enable traffic light recognition using camera |
| `use_detection_by_tracker` | bool | Enable object detection by tracking |
| `use_image_segmentation_based_filter` | bool | Enable image-based segmentation filtering |
| `use_pointcloud_map` | bool | Use pointcloud map for localization and perception |

## Notes

- Perception presets are independent of sensor suite configuration
- Camera-based features require appropriate camera sensor (configured via `sensor_suite` or `camera_model`)
- Some features may require additional computational resources (GPU for ZED object detection, etc.)
