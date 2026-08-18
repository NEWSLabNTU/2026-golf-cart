#!/usr/bin/env bash
# ntu_sim_rviz.sh - RViz for the NTU replay, on bag time, with a visible map.
#
#   just ntu-sim-rviz
#
# Started separately from the stack rather than with rviz:=true, for two reasons.
#
# 1. Config. The stock autoware.rviz draws /map/pointcloud_map at Alpha 0.2 and
#    Size 0.02 m -- sensible for a dense urban map seen close up, invisible on
#    the NTU campus map seen from altitude. That reads as "the map failed to
#    load" while the topic is sitting there with 6.6M points. golfcart_ntu.rviz
#    is the same config with those two values raised.
#
# 2. Timing. RViz must be born on bag time. Start it before /clock exists and it
#    latches the maps at t=0, then the clock jumps ~4 days when playback starts
#    and the displays are dropped. `just ntu-sim-bag` runs the player paused
#    first precisely so this can start with a correct clock.
#
# The vehicle parameters below are NOT optional and their absence is silent-ish:
# autoware.rviz carries a VehicleModel display backed by statically typed
# parameters, and without them RViz aborts loading the WHOLE config with
#
#   Could not load display config: Statically typed parameter 'wheel_radius'
#   must be initialized.
#
# then comes up with an empty default config. Every display is gone, including
# both maps, and the only hint is one line in a log nobody is tailing. The stack
# normally passes these in from the vehicle description; standalone RViz has to
# repeat them. They match golfcart_vehicle_description.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="${REPO_ROOT}/src/launcher/golfcart_launch/rviz/golfcart_ntu.rviz"

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
