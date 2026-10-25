# Localization Presets

Localization presets define the localization configuration for Golf Cart. They control which twist estimation method is used.

## Available Presets

### `default` (Default)
Default localization preset using gyro odometry for twist estimation.

**Configuration**:
- `twist_source`: `gyro_odom`

**Use cases**:
- Standard operation with IMU
- Most outdoor and indoor scenarios
- When Eagleye is not needed

**Requirements**:
- IMU sensor (Tamagawa IMU)

**Launch**:
```bash
just launch "localization_preset:=default"
# Or omit (it's the default)
just launch
```

### `eagleye`
Uses Eagleye for twist estimation. Eagleye provides GNSS-based odometry.

**Configuration**:
- `twist_source`: `eagleye`

**Use cases**:
- When high-accuracy GNSS-based odometry is needed
- Outdoor environments with good GNSS reception
- Research on GNSS-IMU fusion

**Requirements**:
- GNSS receiver (u-blox or Septentrio)
- IMU sensor
- Good GNSS satellite visibility
- `use_gnss:=true` must be set

**Launch**:
```bash
just launch "localization_preset:=eagleye use_gnss:=true gnss_receiver:=ublox"
```

### `rigloc`
NDT stays the pose source (`pose_source`, `cuda_ndt` by default); the EKF's twist comes from
[rig_localization](https://github.com/NEWSLabNTU/rig_localization) (submodule
`src/localization/rig_localization`) instead of `gyro_odometer`: the ZED X's left image tracked by
cuVSLAM, the ZED's IMU and the vehicle's wheel speed (`/vehicle/status/velocity_status`), fused in
a smoother.

**Configuration**:
- `twist_source`: `rigloc`
- the localizer's parameters: `config/localization/rigloc/rigloc.param.yaml` (an overlay on
  rig_localization's documented `rigloc_launch/config/rigloc.param.yaml`)

**Where it runs**: `launch/components/rigloc_twist.launch.xml`. Under `host:=all` with the
localization component; under `host:=master` / `host:=orin` on the **orin**, beside the ZED, its
IMU and the vehicle interface, so no image crosses the link. Only its twist does
(`config/link/topics.yaml`). The orin also republishes the vehicle description on the orin-local
`/rigloc/tf_static_vehicle`, because `base_link -> zed_camera_link` is the master's.

**Requirements**:
- cuVSLAM on the host that runs it: `./setup.sh --only cuvslam`, then `just build`. Without it
  `just build` skips the rigloc packages.
- ZED X, its IMU, the vehicle interface's velocity report
- No twist for the first ~10-25 s while the localizer initialises: the EKF reports ERROR until
  the first one.

**EKF tuning**: the preset loads `config/localization/rigloc/ekf_localizer.param.yaml`, upstream's
values with lower process noise (`proc_stddev_wz_c` 0.5, `proc_stddev_vx_c` 5.0; the file's
header has the sweep). With upstream's, the 10 Hz twist 0.27 s late left the EKF's yaw-rate
variance high and the lateral-ellipse diagnostic reached ERROR within 1-4 s of losing NDT.

**Measured** (rig-odom-sim results 014, the clockwise recording replayed into the live NDT + EKF,
n=3, wheel stand-in, the tuned EKF): EKF xy RMS 0.037 m against `gyro_odom`'s 0.041 m; over three
10-20 s NDT outages the drift ties `gyro_odom`'s and the first lateral-ellipse ERROR comes at 75 s,
where `gyro_odom` has it (76-77 s). Not yet run on the vehicle.

**Launch**:
```bash
just launch "localization_preset:=rigloc"
```

## Usage

Specify the preset when launching Golf Cart:

```bash
# Real hardware mode
just launch "localization_preset:=<preset_name>"

# Logging simulation mode
ros2 launch golfcart_launch logging_simulation.launch.yaml localization_preset:=<preset_name>
```

## Twist Source Comparison

| Twist Source | Input Sensors | Accuracy | Latency | Use Case |
|--------------|---------------|----------|---------|----------|
| `gyro_odom` | IMU | Medium | Low | Standard operation |
| `eagleye` | GNSS + IMU | High (outdoor) | Medium | GNSS-based odometry |
| `rigloc` | ZED camera + IMU + wheel speed | High (measured offline) | ~0.27 s, 10 Hz | Camera-aided odometry |

## Creating Custom Presets

To create a custom preset:

1. Copy an existing preset file (e.g., `default.yaml`)
2. Rename it (e.g., `custom.yaml`)
3. Modify the `twist_source` parameter
4. Add conditional logic in `golfcart.launch.yaml` to support the new preset
5. Update this README with the new preset documentation

## Parameter Reference

| Parameter | Type | Options | Description |
|-----------|------|---------|-------------|
| `twist_source` | string | `gyro_odom`, `eagleye`, `rigloc` | Twist (velocity + angular rate) estimation source |

## Relationship with Other Parameters

Localization presets work together with other localization parameters:

- **`pose_source`**: Selects pose estimation method (`ndt`, `isaac`)
  - `ndt`: LiDAR-based NDT scan matching
  - `isaac`: Visual SLAM using Isaac ROS

- **`use_gnss`**: Enables GNSS subsystem
  - Required for `eagleye` twist source
  - Optional for `gyro_odom`

- **`use_ntrip`**: Enables RTK corrections for GNSS
  - Improves GNSS accuracy
  - Only works with u-blox receivers

- **`use_mapless_mode`**: Disables localization for indoor operation
  - Overrides pose/twist estimation
  - Uses odometry only

## Example Configurations

### Outdoor with RTK
```bash
just launch "localization_preset:=default pose_source:=ndt use_gnss:=true use_ntrip:=true"
```

### Indoor without GNSS
```bash
just launch "localization_preset:=default pose_source:=ndt use_gnss:=false use_mapless_mode:=true"
```

### Visual SLAM
```bash
just launch "localization_preset:=default pose_source:=isaac use_gnss:=false"
```

### Eagleye with GNSS
```bash
just launch "localization_preset:=eagleye pose_source:=ndt use_gnss:=true use_ntrip:=true"
```

## Notes

- Localization presets are independent of sensor suite configuration
- The `twist_source` parameter is passed to the localization component
- Eagleye requires proper GNSS configuration (see `docs/guides/sensor-integration/gnss.md`)
- For mapless operation, consider using `use_mapless_mode:=true` instead of changing localization preset
