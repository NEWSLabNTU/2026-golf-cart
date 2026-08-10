#!/usr/bin/env bash
# record_master.sh — record the master host's sensor topics to a local rosbag.
#
# Launched as a `node:` entry from golfcart.launch.yaml when record:=true, so
# play_launch supervises it and stops it with the rest of the stack. It is NOT an
# `executable:` entry: play_launch 0.5.1 runs those during its dump phase and
# waits for them to exit, then drops them from record.json entirely, so a
# recorder there would hang the launch and never be replayed. See the Amendments
# section of docs/design/multi_machine_deployment.md.
#
# Being a `node:` entry means replay appends ROS arguments (--ros-args -r
# __node:=... and friends). They are ignored rather than stripped: "$@" is never
# forwarded to ros2 bag, whose topic list is fixed below. Do not add "$@" to the
# exec line without filtering out everything from --ros-args onwards.
#
# The orin's ZED topics are deliberately absent: they are recorded on the orin by
# record_orin.sh, onto its own disk. Pulling full-rate images across the shared
# 100 Mb/s LAN would saturate it.

set -euo pipefail

OUTPUT_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
BAG_NAME="master_$(date +%Y%m%d_%H%M%S)"

TOPICS=(
  # LiDAR - Velodyne VLP-32C
  /sensing/lidar/top/pointcloud_raw
  /sensing/lidar/top/pointcloud_raw_ex
  /sensing/lidar/concatenated/pointcloud

  # LiDAR - Falcon (Seyond)
  /sensing/lidar/falcon/iv_points

  # GNSS (u-blox)
  /sensing/gnss/ublox/nav_sat_fix
  /sensing/gnss/pose
  /sensing/gnss/pose_with_covariance

  # IMU (Xsens)
  /sensing/imu/xsens/imu_raw
  /sensing/imu/imu_data

  # USB cameras - compressed only, the raw streams are far too large
  /sensing/camera/left/image_raw/compressed
  /sensing/camera/left/camera_info
  /sensing/camera/right/image_raw/compressed
  /sensing/camera/right/camera_info
  /sensing/camera/rear/image_raw/compressed
  /sensing/camera/rear/camera_info

  # Vehicle interface status
  /vehicle/status/velocity_status
  /vehicle/status/steering_status
  /vehicle/status/gear_status
  /vehicle/status/control_mode
  /vehicle/status/turn_indicators_status
  /vehicle/status/hazard_lights_status
  /vehicle/status/actuation_status

  /diagnostics
  /tf
  /tf_static
)

mkdir -p "${OUTPUT_DIR}"
echo "record_master: writing to ${OUTPUT_DIR}/${BAG_NAME} (${#TOPICS[@]} topics)"

# exec so SIGTERM from play_launch reaches ros2 bag directly and the bag closes
# cleanly; a wrapper shell in between would swallow it and truncate the metadata.
exec ros2 bag record -o "${OUTPUT_DIR}/${BAG_NAME}" "${TOPICS[@]}"
