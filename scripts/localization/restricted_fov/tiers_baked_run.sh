#!/usr/bin/env bash
# Replay one pre-baked restricted-FOV bag from the TIERS OS0-128 data.
#
#   scripts/tiers_baked_run.sh <baked_bag_name> <label>
#   scripts/tiers_baked_run.sh robinw robinw
#
# Bags are produced by scripts/localization/fov_bake_bag.py into
# data/tiers/baked/<name>. This is the measurement path; tiers_fov_study.sh,
# which filters live, is not.
#
# The live filter is a Python node that cannot pass a 2048x128 cloud at 10 Hz,
# so the runs keeping the most points ran at half rate and lost localization
# while the narrow ones held 10 Hz and tracked. That ordering came from the
# harness. With the field of view baked in, every run plays the same way and
# only the thing under study differs.

set -eo pipefail

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This campaign lives in the superproject but drives the cuda_ndt_matcher
# submodule's replay harness, so both roots are resolved rather than assumed.
ROOT="$(git -C "$CAMPAIGN_DIR" rev-parse --show-toplevel)"
PROJECT_DIR="$ROOT/src/localization/cuda_ndt_matcher"
SCRIPT_DIR="$PROJECT_DIR/scripts"
AUTOWARE_ACTIVATE="$SCRIPT_DIR/activate_autoware.sh"

BAKED="${1:?baked bag name}"
LABEL="${2:?run label}"
shift 2 || true
# Anything left is forwarded to the launch file, so a sweep can vary
# ndt_param_file without a copy of this script per configuration.
EXTRA_ARGS=("$@")
# Which set of baked bags. baked_odo carries the IMU and the synthesised vehicle
# twist that gyro_odometer and the EKF need; without them NDT runs on a
# constant-position prior and the same configuration diverges on some runs and
# not others. See scripts/localization/tiers_add_odometry.py.
BAKED_DIR="${BAKED_DIR:-baked_odo}"

BAG="$ROOT/data/tiers/$BAKED_DIR/$BAKED"
MAP="$ROOT/data/tiers/road01_map"

for required in "$BAG" "$MAP/pointcloud_map.pcd"; do
    [[ -e "$required" ]] || { echo "missing: $required" >&2; exit 1; }
done

OUT_DIR="$ROOT/data/fov_study/$LABEL"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export NDT_DEBUG_FILE="$OUT_DIR/ndt_debug.jsonl"
export NDT_READY_FILE="/tmp/ndt_ready_tiers_$LABEL"
rm -f "$NDT_READY_FILE"

# A frequency is required, not optional: bare `--clock` consumes the next
# argument as its value and swallows the bag path.
export BAG_PLAY_ARGS="--clock 200"

echo "=== TIERS baked run '$LABEL' from $BAKED ==="

# No live filter, so localization consumes the bag's cloud topic directly.
# KISS-ICP's first pose is the identity and the map was built in that frame, so
# the vehicle starts at the origin. No spaces in the list: run_demo.sh passes
# these through a `parallel` job as one string and the receiving shell re-splits
# on whitespace.
"$SCRIPT_DIR/run_demo.sh" --cuda "$MAP" "$BAG" "$OUT_DIR" \
    "sensor_model:=tiers_sensor_kit" \
    "vehicle_model:=sample_vehicle" \
    "input_pointcloud:=/sensing/lidar/os0/pointcloud_raw" \
    "user_defined_initial_pose:=[0.0,0.0,0.0,0.0,0.0,0.0,1.0]" \
    ${EXTRA_ARGS[*]} \
    2>&1 | tee "$OUT_DIR/run.log"

echo "=== '$LABEL' done, output in $OUT_DIR ==="
