#!/usr/bin/env bash
# record_orin.sh — record the orin host's ZED topics to the orin's local disk.
#
# Launched as a `node:` entry from golfcart.launch.yaml when record:=true; see
# record_master.sh for why it is not an `executable:` entry, and for how the
# ROS arguments that replay appends are handled.
#
# Topic names verified against a running ZED X on 2026-08-07. They follow the
# zed-ros2-wrapper v5 scheme (rgb/color/rect/image), NOT the v4 scheme
# (rgb/image_rect_color) that the design document quotes.
#
# Depth is off: depth.depth_mode is NONE in golfcart_sensor_kit_launch's
# config/zed.param.yaml, so nothing publishes
# on the depth topics. Enable both deliberately if ever needed - depth data is
# very large.

set -euo pipefail

# Drop everything from `--ros-args` onwards; keep any leading arguments.
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--ros-args" ]]; then
        break
    fi
    ARGS+=("$arg")
done

OUTPUT_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
BAG_NAME="orin_$(date +%Y%m%d_%H%M%S)"

TOPICS=(
  # ZED X - compressed RGB only; the raw image would swamp the disk
  /sensing/camera/zed/rgb/color/rect/image/compressed
  /sensing/camera/zed/rgb/color/rect/camera_info

  /sensing/camera/zed/imu/data
  /sensing/camera/zed/status/health

  /tf_static
)

mkdir -p "${OUTPUT_DIR}"
echo "record_orin: writing to ${OUTPUT_DIR}/${BAG_NAME} (${#TOPICS[@]} topics)"

# exec so SIGTERM reaches ros2 bag directly and the bag finalizes cleanly.
exec ros2 bag record -o "${OUTPUT_DIR}/${BAG_NAME}" "${TOPICS[@]}"
