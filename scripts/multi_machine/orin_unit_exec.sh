#!/usr/bin/env bash
# orin_unit_exec.sh - orin-side entry point for golfcart-orin.service.
#
# systemd user units get none of the interactive shell's environment: direnv does
# not run, ~/.bashrc is not sourced, and ~/.local/bin (where `just` lives) is not
# on PATH. Everything the launch needs is therefore set up explicitly here.
#
# play_launch is invoked directly rather than through `just launch-orin` to avoid
# depending on just being installed and on PATH inside the unit. Keep the
# arguments below in sync with that recipe.

set -eo pipefail

WORKSPACE="${GOLFCART_WORKSPACE:-${HOME}/2026-golf-cart}"
cd "${WORKSPACE}"

# `set -u` is deliberately absent: ROS's setup.bash chain reads unbound variables
# (AMENT_TRACE_SETUP_FILES and friends) and aborts the unit under -u with
#   /opt/ros/humble/setup.bash: line 8: AMENT_TRACE_SETUP_FILES: unbound variable
# shellcheck disable=SC1091
source /opt/autoware/1.5.0/setup.bash
# shellcheck disable=SC1091
source "${WORKSPACE}/install/setup.bash"

export PATH="${HOME}/.local/bin:${PATH}"
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI="file://${WORKSPACE}/config/cyclonedds/orin.xml"

# ROS_LOCALHOST_ONLY would confine this host to its own machine, which is the
# exact opposite of what a two-machine deployment needs.
unset ROS_LOCALHOST_ONLY

RECORD="${GOLFCART_RECORD:-false}"

# exec so systemd supervises play_launch itself; with a wrapper shell in between,
# KillMode=control-group still cleans up, but the unit's MainPID would be the
# shell and its exit status would be the shell's.
exec play_launch launch \
    --web-addr 0.0.0.0:8081 \
    golfcart_launch golfcart.launch.yaml \
    host:=orin \
    rviz:=false \
    "record:=${RECORD}"
