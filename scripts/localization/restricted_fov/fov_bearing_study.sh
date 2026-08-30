#!/usr/bin/env bash
# Restricted-FOV study, wedge specified in VEHICLE BEARING rather than sensor
# azimuth. This is the one to use.
#
#   scripts/fov_bearing_study.sh <min_bearing> <max_bearing> <max_range> <label>
#   scripts/fov_bearing_study.sh -60 60 70 robinw_fwd_120
#
# Bearings are degrees in base_link: 0 straight ahead, positive to the left.
#
# The companion fov_study.sh crops at the decoder, which is cheaper and more
# faithful, but on this bag it can only produce a cloud for azimuth windows
# containing 0 or 300, and every such window contains bearing +85 or +145. A
# forward wedge excludes both, so it cannot be cut there at any width. This path
# filters the concatenated cloud instead, which can point anywhere.
#
# It also clips the rig's two VLP16s to the same wedge, which fov_study.sh could
# not do. That is the right behaviour for emulating a single narrow forward
# sensor, so results here are NOT directly comparable with that script's: they
# are strictly stricter.
#
# Read docs/research/localization/restricted-fov-ndt.md before quoting anything
# from this.

set -eo pipefail

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This campaign lives in the superproject but drives the cuda_ndt_matcher
# submodule's replay harness, so both roots are resolved rather than assumed.
ROOT="$(git -C "$CAMPAIGN_DIR" rev-parse --show-toplevel)"
PROJECT_DIR="$ROOT/src/localization/cuda_ndt_matcher"
SCRIPT_DIR="$PROJECT_DIR/scripts"
AUTOWARE_ACTIVATE="$SCRIPT_DIR/activate_autoware.sh"

MIN_BEARING="${1:?min bearing in degrees, 0 = ahead}"
MAX_BEARING="${2:?max bearing in degrees}"
MAX_RANGE="${3:?max range in metres}"
LABEL="${4:?run label}"

# The filter lives in the superproject, because the question it answers is about
# the golf cart's sensor choice rather than about this matcher. Resolve it rather
# than hardcoding a ../../.. that breaks if either checkout moves.
FILTER="$CAMPAIGN_DIR/tools/fov_restrict_node.py"

FILTERED_TOPIC="/sensing/lidar/fov_restricted/pointcloud"

OUT_DIR="$ROOT/data/fov_study/$LABEL"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

export NDT_DEBUG_FILE="$OUT_DIR/ndt_debug.jsonl"
export NDT_READY_FILE="/tmp/ndt_sim_ready_fov_$LABEL"
rm -f "$NDT_READY_FILE"

# The decoder stays at its stock full-circle settings. Restricting in both places
# at once would leave the wedge that survives being the intersection of two
# separately-specified windows, which is not what the label would say.
unset NDT_FOV_MIN_ANGLE NDT_FOV_MAX_ANGLE NDT_FOV_MAX_RANGE NDT_FOV_SCAN_PHASE

echo "=== FOV run '$LABEL': bearing ${MIN_BEARING}..${MAX_BEARING} deg, range ${MAX_RANGE} m ==="

# The filter must outlive nothing: run_demo's `parallel --halt now,done=1` tears
# down its own jobs when the bag ends, but this process is not one of them.
source "$AUTOWARE_ACTIVATE"
source "$PROJECT_DIR/install/setup.bash"
python3 "$FILTER" \
    --min-bearing "$MIN_BEARING" --max-bearing "$MAX_BEARING" \
    --max-range "$MAX_RANGE" --output "$FILTERED_TOPIC" \
    >"$OUT_DIR/filter.log" 2>&1 &
FILTER_PID=$!
trap 'kill "$FILTER_PID" 2>/dev/null || true' EXIT

"$SCRIPT_DIR/run_demo.sh" --cuda \
    "$PROJECT_DIR/data/sample-map" \
    "$PROJECT_DIR/data/sample-rosbag-fixed" \
    "$OUT_DIR" \
    "input_pointcloud:=$FILTERED_TOPIC" 2>&1 | tee "$OUT_DIR/run.log"

echo "=== '$LABEL' done, output in $OUT_DIR ==="
grep -c . "$OUT_DIR/filter.log" >/dev/null 2>&1 && tail -2 "$OUT_DIR/filter.log" || true
