#!/usr/bin/env bash
# Restricted-FOV study on the TIERS Ouster OS0-128, which unlike the Autoware
# sample bag is wider than a Seyond Robin-W in BOTH axes and can therefore
# emulate its vertical field of view as well as its horizontal one.
#
#   scripts/tiers_fov_study.sh <min_bearing> <max_bearing> <min_el> <max_el> <max_range> <label>
#   scripts/tiers_fov_study.sh -60 60 -35 35 70 robinw_full      # Robin-W spec
#   scripts/tiers_fov_study.sh -180 180 -90 90 100 tiers_full    # baseline
#
# Bearings and elevations are degrees in base_link, which for this rig IS the
# sensor frame -- see the note in the kit's sensor_kit_calibration.yaml.
#
# Prerequisites, produced by the pipeline documented in
# docs/research/localization/restricted-fov-ndt.md:
#   data/tiers/road01_os0/            rosbag2, OS0 points + IMU
#   data/tiers/road01_map/            pointcloud_map.pcd built from the full FOV
#
# The clouds are re-encoded to Autoware's PointXYZIRC on the way through. The
# Ouster layout is 48 bytes of x/y/z/intensity/t/reflectivity/ring/ambient/range,
# which Autoware's crop box refuses outright -- and it reports that as its own
# fault, "The pointcloud layout is not compatible", while NDT simply never
# receives a scan and says nothing at all.
#
# The map was built from the FULL field of view and the restricted runs localize
# against it. That is the arrangement a deployment has: the map is surveyed once
# with whatever sensor is convenient, and the vehicle localizes with the sensor
# it carries.

set -eo pipefail

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This campaign lives in the superproject but drives the cuda_ndt_matcher
# submodule's replay harness, so both roots are resolved rather than assumed.
ROOT="$(git -C "$CAMPAIGN_DIR" rev-parse --show-toplevel)"
PROJECT_DIR="$ROOT/src/localization/cuda_ndt_matcher"
SCRIPT_DIR="$PROJECT_DIR/scripts"
AUTOWARE_ACTIVATE="$SCRIPT_DIR/activate_autoware.sh"

MIN_BEARING="${1:?min bearing deg}"
MAX_BEARING="${2:?max bearing deg}"
MIN_EL="${3:?min elevation deg}"
MAX_EL="${4:?max elevation deg}"
MAX_RANGE="${5:?max range m}"
LABEL="${6:?run label}"

FILTER="$CAMPAIGN_DIR/tools/fov_restrict_node.py"
BAG="$ROOT/data/tiers/road01_os0"
MAP="$ROOT/data/tiers/road01_map"

for required in "$FILTER" "$BAG" "$MAP/pointcloud_map.pcd"; do
    [[ -e "$required" ]] || { echo "missing: $required" >&2; exit 1; }
done

RAW_TOPIC="/sensing/lidar/os0/pointcloud_raw"
FILTERED_TOPIC="/sensing/lidar/fov_restricted/pointcloud"

OUT_DIR="$ROOT/data/fov_study/$LABEL"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export NDT_DEBUG_FILE="$OUT_DIR/ndt_debug.jsonl"
export NDT_READY_FILE="/tmp/ndt_ready_tiers_$LABEL"
rm -f "$NDT_READY_FILE"

# The extracted bag carries no /clock, unlike the Autoware sample bag, because
# it was cut from a ROS 1 recording that had none either. Without --clock every
# node with use_sim_time waits forever on a clock that never ticks.
# A frequency is required, not optional: bare `--clock` consumes the next
# argument as its value and swallows the bag path.
export BAG_PLAY_ARGS="--clock 200"

echo "=== TIERS run '$LABEL': bearing ${MIN_BEARING}..${MAX_BEARING}, elevation ${MIN_EL}..${MAX_EL}, range ${MAX_RANGE} m ==="

source "$AUTOWARE_ACTIVATE"
source "$PROJECT_DIR/install/setup.bash"
python3 "$FILTER" \
    --min-bearing "$MIN_BEARING" --max-bearing "$MAX_BEARING" \
    --min-elevation "$MIN_EL" --max-elevation "$MAX_EL" \
    --max-range "$MAX_RANGE" \
    --origin 0 0 0 \
    --emit-xyzirc \
    --input "$RAW_TOPIC" --output "$FILTERED_TOPIC" \
    >"$OUT_DIR/filter.log" 2>&1 &
FILTER_PID=$!
trap 'kill "$FILTER_PID" 2>/dev/null || true' EXIT

# KISS-ICP's first pose is the identity by construction, and the map was built
# in that frame, so the vehicle starts at the origin facing along +x. No pose
# needs looking up.
#
# NO SPACES in the list. These arguments reach the launch through run_demo.sh,
# which passes them into a `parallel` job as one string, so the receiving shell
# re-splits them on whitespace. A spaced list silently becomes seven arguments
# and every launch argument after it takes the wrong value -- the first attempt
# ended up with `map_path` set to `1.0]`, and reported itself as a missing map
# projector file rather than as a quoting fault.
"$SCRIPT_DIR/run_demo.sh" --cuda "$MAP" "$BAG" "$OUT_DIR" \
    "sensor_model:=tiers_sensor_kit" \
    "vehicle_model:=sample_vehicle" \
    "input_pointcloud:=$FILTERED_TOPIC" \
    "user_defined_initial_pose:=[0.0,0.0,0.0,0.0,0.0,0.0,1.0]" \
    2>&1 | tee "$OUT_DIR/run.log"

echo "=== '$LABEL' done, output in $OUT_DIR ==="
tail -2 "$OUT_DIR/filter.log" 2>/dev/null || true
