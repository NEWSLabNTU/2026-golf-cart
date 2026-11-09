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

# Fail loudly rather than start with the wrong transport profile. env.sh falls
# back to loopback on an unknown name, which for a unit means a stack that runs
# but cannot see the other machine - the hardest failure here to diagnose from
# outside. Catch it at start instead.
#
# The role is resolved once and shared by both middlewares, so this check is not
# CycloneDDS-specific even though the profile variable is named for it: under
# GOLFCART_RMW=zenoh the same name selects config/zenoh/<role>-session.json5.
if [ "${GOLFCART_DDS_PROFILE}" != "${HOST}" ]; then
    echo "launch_unit_exec: no transport profile for GOLFCART_HOST='${HOST}'" >&2
    echo "                  resolved to '${GOLFCART_DDS_PROFILE}' instead" >&2
    echo "                  (GOLFCART_RMW=${GOLFCART_RMW:-cyclonedds})" >&2
    exit 1
fi

# Middleware preconditions, the same gate `just run` and `just up` call. It is
# here rather than expressed as a Requires= on the router unit because it has to
# be CONDITIONAL: under CycloneDDS there is no router to want, and under zenoh a
# missing one is fatal in total silence - every node starts, publishes, and is
# discovered by nobody. It also clears a ros2 daemon left over from the other
# middleware, which otherwise answers every graph query from an empty world.
"${WORKSPACE}/scripts/rmw/ensure.sh" || exit 1

# Arguments. `just up` (via the private _up-local recipe) rewrites
# .golfcart-launch.args on every start, empty when there are none; a missing
# file means the unit was started by hand and gets no extra args. This replaced
# GOLFCART_LAUNCH_ARGS in the user manager's environment, which persisted until
# something cleared it, so one day's flags could reach the next day's start.
#
# scripts/launch/args.py adds host:=, master_ip:= (config/multi_machine.conf)
# and link_topics:= (config/link/topics.yaml) for this role - launch arguments,
# not environment - and prints the final list into the journal.
#
# Headless always: RViz stays an interactive tool (`just tool rviz`), since a
# unit has no display to draw on.
ARGS_OUT=$(python3 "${WORKSPACE}/scripts/launch/args.py" \
    --label "launch_unit_exec: ${HOST} args" \
    --host "${HOST}" --no-rviz \
    --from "${WORKSPACE}/.golfcart-launch.args") || exit 1
LAUNCH_ARGS=()
[ -n "${ARGS_OUT}" ] && mapfile -t LAUNCH_ARGS <<< "${ARGS_OUT}"

# exec so systemd supervises play_launch itself; with a wrapper shell in between,
# KillMode=control-group still cleans up, but the unit's MainPID would be the
# shell and its exit status would be the shell's - and KillSignal=SIGINT would
# reach the shell, not play_launch.
exec play_launch launch \
    --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
    --web-addr 0.0.0.0:8081 \
    golfcart_launch golfcart.launch.yaml \
    "${LAUNCH_ARGS[@]}"
