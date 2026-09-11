#!/usr/bin/env bash
# indoor_sim_rviz.sh - RViz for the indoor replay, on bag time, with a visible map.
#
#   just indoor-test rviz
#
# Same reasoning as ntu_sim_rviz.sh, which this mirrors:
#
# 1. Config. golfcart_ntu.rviz draws /map/pointcloud_map at a size and alpha
#    that survive being looked at from a distance; the stock autoware.rviz
#    renders a 4M-point basement as nearly nothing and reads as "map failed
#    to load". The board polygon arrives on /map/vector_map from the
#    lanelet2_map.osm that is the polygon and nothing else.
#
# 2. Timing. RViz must be born on bag time, so `just indoor-test bag` runs
#    the player paused first and this starts with a correct clock.
#
# The vehicle parameters are required: autoware.rviz carries a VehicleModel
# display backed by statically typed parameters, and without them RViz aborts
# loading the WHOLE config and comes up empty. They match
# golfcart_vehicle_description.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${REPO_ROOT}/src/launcher/golfcart_launch/rviz/golfcart_ntu.rviz"

# 3. Waiting. Started against an empty graph, RViz comes up with every display
# in error and stays that way, so it waits for the stack rather than trusting
# the operator's typing order. Already-up is the common case and costs one
# service listing.
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/rosbag/indoor_sim_lib.sh"
sim_source_env "${REPO_ROOT}"
if ! has_service /localization/initialize; then
    wait_for 120 "the stack (just indoor-test up)" has_service /localization/initialize \
        || die "no stack to draw; start it first"
fi

[ -f "${CONFIG}" ] || { echo "missing rviz config: ${CONFIG}" >&2; exit 1; }

exec rviz2 -d "${CONFIG}" --ros-args \
    -p use_sim_time:=true \
    -p wheel_radius:=0.265 \
    -p wheel_width:=0.14 \
    -p wheel_base:=2.061 \
    -p wheel_tread:=1.213 \
    -p front_overhang:=0.406 \
    -p rear_overhang:=0.821 \
    -p left_overhang:=0.001 \
    -p right_overhang:=0.001 \
    -p vehicle_height:=2.005 \
    -p max_steer_angle:=0.349
