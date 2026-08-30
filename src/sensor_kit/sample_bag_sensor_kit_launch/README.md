# sample_bag_sensor_kit_launch

Sensor kit for replaying the **Autoware sample rosbag** through this repo's
logging simulation:

```bash
just launch-sim-logging "vehicle_model:=sample_vehicle \
  sensor_model:=sample_bag_sensor_kit \
  map_path:=./src/localization/cuda_ndt_matcher/data/sample-map"
```

The vehicle side needs nothing new: Autoware's own `sample_vehicle` matches the
bag. Only the sensor kit had to be written, because `sample_sensor_kit` declares
four LiDARs and the bag carries three.

Adapted from `cuda_ndt_matcher/tests/rosbag_replay/rosbag_sensor_kit_launch`,
with its calibration moved into this repo's existing `individual_params` rather
than a second package of that name.

**Both pointcloud backends.** This kit owns its preprocessing stage and carries
the same `pointcloud_backend:=cpu|cuda` split as `golfcart_sensor_kit_launch`,
so the two modes can be compared against a bag anyone can obtain:

```bash
just launch-sim-logging "vehicle_model:=sample_vehicle \
  sensor_model:=sample_bag_sensor_kit \
  map_path:=./src/localization/cuda_ndt_matcher/data/sample-map \
  pointcloud_backend:=cuda"
```

Measured that way on an AGX Orin, at equal throughput, `cuda` moves about a
quarter of a core off `pointcloud_container` and puts about a third of the GPU
and half a watt on instead. Numbers and caveats in
[docs/handover/2026-08-30-cuda-ndt-on-orin.md](../../../docs/handover/2026-08-30-cuda-ndt-on-orin.md).

Note this kit preprocesses **three** Velodynes; the golf cart preprocesses one,
because the Seyond publishes `PointXYZIRC` with no per-point time and cannot be
deskewed by either backend. Expect a smaller saving there.


Custom sensor kit for the Autoware [rosbag replay simulation tutorial](https://autowarefoundation.github.io/autoware-documentation/main/demos/rosbag-replay-simulation/).

## Why This Exists

The sample rosbag from the tutorial contains only **3 LiDARs** (top, left, right), but `sample_sensor_kit` expects **4 LiDARs** (including rear). This package provides a sensor configuration matching the actual rosbag data.

## Differences from sample_sensor_kit

| Component | sample_sensor_kit          | sample_bag_sensor_kit                     |
|-----------|----------------------------|---------------------------------------|
| LiDARs    | 4 (top, left, right, rear) | 3 (top, left, right)                  |
| IMU       | tamagawa                   | Same (delegates to sample_sensor_kit) |
| GNSS      | ublox                      | Same (delegates to sample_sensor_kit) |

### Modified Files

Based on `sample_sensor_kit_launch` from Autoware 1.5.0 with these changes:

- `config/concatenate_and_time_sync_node.param.yaml`: 3 lidar topics instead of 4
- `launch/lidar.launch.xml`: Removed rear LiDAR definition
- `launch/pointcloud_preprocessor.launch.py`: Points to local config file
- `launch/sensing.launch.xml`: Includes IMU/GNSS from `sample_sensor_kit_launch`

## Usage

Set `sensor_model:=sample_bag_sensor_kit` when launching:

```bash
ros2 launch autoware_launch logging_simulator.launch.xml \
  sensor_model:=sample_bag_sensor_kit \
  ...
```

## Related Packages

- `sample_bag_sensor_kit_description`: URDF/calibration files for this sensor kit
- `individual_params/config/default/sample_bag_sensor_kit/`: Sensor calibration parameters
