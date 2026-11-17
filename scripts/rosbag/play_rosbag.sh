#!/bin/bash
# Play rosbag for logging simulation testing
# Usage: ./scripts/rosbag/play_rosbag.sh [rosbag_path]

set -e

ROSBAG_PATH="${1:-rosbags/outdoor_20251226_153115/}"

source /opt/ros/humble/setup.bash
. scripts/autoware_version.sh
source "${GOLFCART_INSTALL_DIR}/local_setup.bash"
ros2 bag play "$ROSBAG_PATH" --clock -l -r 1.5
