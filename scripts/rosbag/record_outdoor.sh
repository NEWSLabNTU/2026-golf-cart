#!/usr/bin/env bash
# record_outdoor.sh — Record outdoor sensor topics to a timestamped rosbag.
#
# Topic list curated for Golf Cart sensor stack:
#   * Velodyne VLP-32C
#   * u-blox ZED-F9P GNSS
#   * Tamagawa IMU (or interim ros2_mpu9250_driver)
#   * USB camera (or future Tier IV GMSL)
#   * golfcart_vehicle_interface status + diagnostics
#
# Update the TOPICS array as the sensor stack evolves.

set -euo pipefail

OUTPUT_DIR="$(cd "$(dirname "$0")/../.." && pwd)/rosbags"
BAG_NAME="outdoor_$(date +%Y%m%d_%H%M%S)"

TOPICS=(
  # LiDAR (Velodyne VLP-32C)
  /sensing/lidar/top/pointcloud_raw
  /sensing/lidar/top/pointcloud_raw_ex
  /sensing/lidar/concatenated/pointcloud
  /sensing/lidar/velodyne_packets

  # GNSS (u-blox)
  /sensing/gnss/ublox/nav_sat_fix
  /sensing/gnss/ublox/navpvt
  /sensing/gnss/pose
  /sensing/gnss/pose_with_covariance

  # IMU
  /sensing/imu/imu_data
  /sensing/imu/imu_raw
  /sensing/imu/tamagawa/imu_raw

  # Cameras (USB: left, right, rear).
  #
  # There is no `front` camera and no raw `image_raw` on any of them. The sensor
  # kit's camera.launch.xml brings up three gmslcam nodes with `codec: jpeg`,
  # and gmslcam publishes CompressedImage only, so the compressed topic is the
  # only one that exists. This list previously named
  # /sensing/camera/front/* and recorded three empty channels.
  /sensing/camera/left/image_raw/compressed
  /sensing/camera/left/camera_info
  /sensing/camera/right/image_raw/compressed
  /sensing/camera/right/camera_info
  /sensing/camera/rear/image_raw/compressed
  /sensing/camera/rear/camera_info

  # Vehicle interface status + diagnostics
  /vehicle/status/velocity_status
  /vehicle/status/steering_status
  /vehicle/status/gear_status
  /vehicle/status/control_mode
  /vehicle/status/turn_indicators_status
  /vehicle/status/hazard_lights_status
  /vehicle/status/actuation_status
  /diagnostics

  # TF
  /tf
  /tf_static
)

mkdir -p "$OUTPUT_DIR"
echo "Recording to: $OUTPUT_DIR/$BAG_NAME"
echo "Topics: ${#TOPICS[@]} entries"
printf '  %s\n' "${TOPICS[@]}"
echo
echo "Press Ctrl-C to stop recording."
echo

WORKSPACE_SETUP="$(cd "$(dirname "$0")/../.." && pwd)/install/setup.bash"
if [[ -f "$WORKSPACE_SETUP" ]]; then
    # shellcheck disable=SC1090
    source "$WORKSPACE_SETUP"
fi

ros2 bag record -o "$OUTPUT_DIR/$BAG_NAME" "${TOPICS[@]}"
