#!/usr/bin/env bash
# creep_record.sh - record what localization sees while the driver creeps the cart.
#
#   just tool creep-record [NAME]        # Ctrl-C to stop
#   just tool creep-report BAG           # then summarize it, on the same machine
#
# Handover 2026-10-22, open item 2: NDT jumps 14-25 m whenever the cart moves,
# while the board detector still has it right. The suspect is the VCU speed
# report. Run on the MASTER with `just launch-drive-mingda` up and the cart
# localized, start this, have the driver creep about 1 m forward along the
# lane in manual, stop, wait 5 s, Ctrl-C.
#
# Records, from the master's stack domain:
#   - everything under /localization except point clouds and markers: EKF,
#     NDT pose and scores, twist estimator, initialization state, board pose
#   - /vehicle/status/* and the velocity converter's twist: the speed chain
#   - the corrected IMU, /tf_static, and the VLP-32C's RAW cloud, so NDT can be
#     replayed offline on the workstation if the summary does not settle it
#     (about 1.5 MB per scan: a one-minute creep is under 1 GB)
set -euo pipefail

NAME=${1:-creep-$(date +%Y%m%d-%H%M%S)}
OUT="${GOLFCART_BAG_DIR:?scripts/env.sh sets GOLFCART_BAG_DIR}/$NAME"

INCLUDE='^/localization/.*|^/vehicle/status/.*|^/sensing/vehicle_velocity_converter/.*|^/sensing/imu/imu_data$|^/sensing/lidar/vlp32/velodyne_points$|^/tf_static$|^/api/localization/.*|^/initialpose3d$'
# Debug clouds and markers under /localization are large and recomputable.
# Anchored to /localization so the raw VLP-32C cloud above is kept.
EXCLUDE='^/localization/.*(points|pointcloud|cloud|marker|_image).*'

echo "recording to $OUT"
echo "now: driver creeps ~1 m forward in manual, stops, waits 5 s; then Ctrl-C here"
exec ros2 bag record -o "$OUT" -e "$INCLUDE" -x "$EXCLUDE"
