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

# One environment, one place. scripts/env.sh is what `.envrc` sources too, so a
# unit and the terminal you debug it from cannot drift apart - which they did
# while this script kept its own copy of the Autoware sourcing, the DDS profile,
# RMW_IMPLEMENTATION, PATH and the ROS_LOCALHOST_ONLY unset.
#
# GOLFCART_ENV_ROLE, not the .golfcart-host marker: a unit is told its role by the
# installer's drop-in and must not depend on a file someone can edit underneath
# it. QUIET because the banners belong in a terminal, not the journal.
#
# `set -u` is deliberately not enabled: ROS's setup.bash chain reads unbound
# variables (AMENT_TRACE_SETUP_FILES and friends) and would abort the unit.
export GOLFCART_ENV_ROLE="${HOST}"
export GOLFCART_ENV_QUIET=1
# shellcheck source=/dev/null
source "${WORKSPACE}/scripts/env.sh"

# Fail loudly rather than start with the wrong DDS profile. env.sh falls back to
# loopback on an unknown name, which for a unit means a stack that runs but
# cannot see the other machine - the hardest failure here to diagnose from
# outside. Catch it at start instead.
if [ "${GOLFCART_DDS_PROFILE}" != "${HOST}" ]; then
    echo "launch_unit_exec: no CycloneDDS profile for GOLFCART_HOST='${HOST}'" >&2
    echo "                  resolved to '${GOLFCART_DDS_PROFILE}' instead" >&2
    exit 1
fi

# exec so systemd supervises play_launch itself; with a wrapper shell in between,
# KillMode=control-group still cleans up, but the unit's MainPID would be the
# shell and its exit status would be the shell's - and KillSignal=SIGINT would
# reach the shell, not play_launch.
#
# Headless always: RViz stays an interactive tool (`just tool rviz`), since a
# unit has no display to draw on.
# shellcheck disable=SC2086
exec play_launch launch \
    --web-addr 0.0.0.0:8081 \
    golfcart_launch golfcart.launch.yaml \
    "host:=${HOST}" \
    rviz:=false \
    ${GOLFCART_LAUNCH_ARGS:-}
