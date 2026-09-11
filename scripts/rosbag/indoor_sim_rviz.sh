#!/usr/bin/env bash
# indoor_sim_rviz.sh - RViz for the indoor replay, on bag time, with a visible map.
#
#   just indoor-test rviz
#
# Same reasoning as ntu_sim_rviz.sh, which this mirrors:
#
# 1. Config. golfcart_indoor.rviz, not golfcart_ntu.rviz: the outdoor config
#    draws the map as flat white 3 px points seen from straight above, and in
#    a basement that is a solid white sheet. 85% of this map's points lie
#    between 1.3 m and 3.1 m, which is the CEILING, so a top-down view shows
#    the ceiling and nothing else. The indoor config colours by height over a
#    fixed 0 to 3.2 m range, drops the points to 1 px at alpha 0.3, and puts
#    the camera behind and below the ceiling (ThirdPersonFollower, pitch 0.35)
#    so walls and columns read as structure. The board polygon arrives on
#    /map/vector_map from the lanelet2_map.osm that is the polygon and nothing
#    else.
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
CONFIG="${REPO_ROOT}/src/launcher/golfcart_launch/rviz/golfcart_indoor.rviz"

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
