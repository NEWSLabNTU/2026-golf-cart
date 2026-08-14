#!/usr/bin/env bash
# master_unit_exec.sh - master-side entry point for golfcart-master.service.
#
# Mirror of orin_unit_exec.sh. systemd user units get none of the interactive
# shell's environment: direnv does not run, ~/.bashrc is not sourced, and
# ~/.local/bin (where play_launch lives) is not on PATH. Everything the launch
# needs is therefore set up explicitly here.
#
# play_launch is invoked directly rather than through `just launch-master` to
# avoid depending on just being installed and on PATH inside the unit, and
# because the orin orchestration that recipe carries lives in the unit's
# ExecStartPost/ExecStopPost instead.

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
export CYCLONEDDS_URI="file://${WORKSPACE}/config/cyclonedds/master.xml"

# ROS_LOCALHOST_ONLY would confine this host to its own machine, which is the
# exact opposite of what a two-machine deployment needs.
unset ROS_LOCALHOST_ONLY

# Same rule as .envrc, which does not run here: record to the external SSD when
# it is mounted. The root filesystem has only a few GB free and recording runs at
# roughly 15MB/s, so a bag fills it in under two minutes. An explicit
# GOLFCART_BAG_DIR still wins.
if [ -z "${GOLFCART_BAG_DIR:-}" ] && [ -d /mnt/external ] && [ -w /mnt/external ]; then
    GOLFCART_BAG_DIR=/mnt/external/rosbags
fi
export GOLFCART_BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
mkdir -p "${GOLFCART_BAG_DIR}"

RECORD="${GOLFCART_RECORD:-false}"

# exec so systemd supervises play_launch itself; with a wrapper shell in between,
# KillMode=control-group still cleans up, but the unit's MainPID would be the
# shell and its exit status would be the shell's.
#
# Headless always: RViz stays an interactive tool (`just tool-rviz`), since a
# unit has no display to draw on.
# shellcheck disable=SC2086
exec play_launch launch \
    --web-addr 0.0.0.0:8081 \
    golfcart_launch golfcart.launch.yaml \
    host:=master \
    rviz:=false \
    "record:=${RECORD}" \
    ${GOLFCART_MASTER_ARGS:-}
