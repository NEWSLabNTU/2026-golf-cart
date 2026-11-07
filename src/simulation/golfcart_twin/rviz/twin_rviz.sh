#!/usr/bin/env bash
# twin_rviz.sh - the twin demo's RViz, beside the Isaac editor.
#
#   src/simulation/golfcart_twin/rviz/twin_rviz.sh
#
# Started on its own, like scripts/rosbag/ntu_sim_rviz.sh and for the same reason: RViz needs
# the vehicle parameters, or it drops the whole config ("Statically typed parameter
# 'wheel_radius' must be initialized") and comes up empty. They come from the vehicle
# description itself, not a copy. use_sim_time: the twin runs on Isaac's clock.
# Source Autoware (and this workspace) first, in the ego's ROS domain and RMW.
set -eo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../../.." && pwd)"
CONFIG="${HERE}/twin_demo.rviz"
VEHICLE_INFO="${REPO_ROOT}/src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/config/vehicle_info.param.yaml"

for f in "${CONFIG}" "${VEHICLE_INFO}"; do
    [ -f "${f}" ] || { echo "missing: ${f}" >&2; exit 1; }
done

exec rviz2 -d "${CONFIG}" --ros-args -p use_sim_time:=true --params-file "${VEHICLE_INFO}"
