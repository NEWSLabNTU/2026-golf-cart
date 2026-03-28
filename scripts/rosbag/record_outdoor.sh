#!/usr/bin/env bash
# record_outdoor.sh — Record outdoor sensor topics to a timestamped rosbag.
#
# WARNING: This script is a stub. The topic list below is a best-guess based
# on the planned sensor configuration. You MUST verify that all topics are
# actually being published before using this script in the field.
#
# Steps to activate:
#   1. Run `just launch` and confirm each topic with `ros2 topic list`
#   2. Adjust the TOPICS array below to match your confirmed topic names
#   3. Remove the "exit 1" line at the bottom of this warning block

echo "ERROR: record_outdoor.sh is not yet configured for this vehicle."
echo ""
echo "Edit $0 to verify and enable the topic list."
echo "See the TOPICS array in this script for the intended topics to record."
exit 1

# ---------------------------------------------------------------------------
# Intended topic list (uncomment and adjust after verifying sensor topics):
# ---------------------------------------------------------------------------
# set -e
#
# OUTPUT_DIR="$(cd "$(dirname "$0")/../.." && pwd)/rosbags"
# BAG_NAME="outdoor_$(date +%Y%m%d_%H%M%S)"
#
# TOPICS=(
#   /sensing/lidar/top/pointcloud_raw
#   /sensing/lidar/top/pointcloud_raw_ex
#   /sensing/gnss/ublox/nav_sat_fix
#   /sensing/gnss/ublox/navpvt
#   /sensing/imu/imu_data
#   /sensing/camera/front/image_raw
#   /vehicle/status/velocity_status
#   /vehicle/status/steering_status
#   /vehicle/status/control_mode
#   /tf
#   /tf_static
# )
#
# mkdir -p "$OUTPUT_DIR"
# echo "Recording to: $OUTPUT_DIR/$BAG_NAME"
# echo "Topics: ${TOPICS[*]}"
# echo "Press Ctrl-C to stop recording."
# echo ""
# source "$(cd "$(dirname "$0")/../.." && pwd)/install/setup.bash"
# ros2 bag record -o "$OUTPUT_DIR/$BAG_NAME" "${TOPICS[@]}"
