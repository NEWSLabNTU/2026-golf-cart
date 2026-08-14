#!/usr/bin/env bash
# launch_unit_exec.sh - entry point for golfcart-launch.service on BOTH hosts.
#
# Replaces master_unit_exec.sh and orin_unit_exec.sh, which had drifted into
# near-copies: the only real differences were the CycloneDDS profile and the
# host:= argument, both derived here from GOLFCART_HOST (set by the drop-in that
# setup/scripts/install-host-service.sh writes).
#
# systemd user units get none of the interactive shell's environment: direnv does
# not run, ~/.bashrc is not sourced, and ~/.local/bin (where play_launch lives) is
# not on PATH. Everything the launch needs is therefore set up explicitly here.
#
# play_launch is invoked directly rather than through a `just` recipe to avoid
# depending on just being installed and on PATH inside the unit.
#
# Recording is NOT started here. It is golfcart-record.service's job now, which
# is what keeps `ros2 bag` out of play_launch's process group - and out of
# whatever play_launch's shutdown does to its children that produced the 0-byte
# metadata.yaml.

set -eo pipefail

WORKSPACE="${GOLFCART_WORKSPACE:-${HOME}/2026-golf-cart}"
cd "${WORKSPACE}"

HOST="${GOLFCART_HOST:-master}"
PROFILE="${WORKSPACE}/config/cyclonedds/${HOST}.xml"
# Fail loudly rather than start with the wrong DDS profile: a typo'd role would
# otherwise fall through to Cyclone's default (localhost-ish discovery) and
# produce a stack that runs but cannot see the other machine - the hardest
# failure in this system to diagnose from the outside.
if [ ! -f "${PROFILE}" ]; then
    echo "launch_unit_exec: no CycloneDDS profile for GOLFCART_HOST='${HOST}'" >&2
    echo "                  expected ${PROFILE}" >&2
    exit 1
fi

# `set -u` is deliberately absent: ROS's setup.bash chain reads unbound variables
# (AMENT_TRACE_SETUP_FILES and friends) and aborts the unit under -u with
#   /opt/ros/humble/setup.bash: line 8: AMENT_TRACE_SETUP_FILES: unbound variable
# shellcheck disable=SC1091
source /opt/autoware/1.5.0/setup.bash
# shellcheck disable=SC1091
source "${WORKSPACE}/install/setup.bash"

export PATH="${HOME}/.local/bin:${PATH}"
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI="file://${PROFILE}"

# ROS_LOCALHOST_ONLY would confine this host to its own machine, which is the
# exact opposite of what a two-machine deployment needs.
unset ROS_LOCALHOST_ONLY

# exec so systemd supervises play_launch itself; with a wrapper shell in between,
# KillMode=control-group still cleans up, but the unit's MainPID would be the
# shell and its exit status would be the shell's - and KillSignal=SIGINT would
# reach the shell, not play_launch.
#
# Headless always: RViz stays an interactive tool (`just tool-rviz`), since a
# unit has no display to draw on.
# shellcheck disable=SC2086
exec play_launch launch \
    --web-addr 0.0.0.0:8081 \
    golfcart_launch golfcart.launch.yaml \
    "host:=${HOST}" \
    rviz:=false \
    ${GOLFCART_LAUNCH_ARGS:-}
