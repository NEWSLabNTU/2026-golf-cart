#!/usr/bin/env bash
# record_unit_exec.sh — ExecStart target for golfcart-record.service.
#
# One script for both hosts: the role comes from GOLFCART_HOST, and everything
# role-specific (DDS profile, which half of the session) is derived from it.
# What is recorded is the scope's, config/recording/scopes.yaml.
#
# WHY RECORDING IS ITS OWN UNIT: until 2026-08-14 the recorders ran as `node:`
# entries inside golfcart.launch.yaml, i.e. as play_launch children. Every
# multi-gigabyte bag stopped from the foreground came out with a 0-byte
# metadata.yaml (docs/roadblocks.md, "play_launch does not finalize bags when
# stopped from the foreground"): the data was intact, only finalization was
# lost. A controlled pair of runs on 2026-08-14 — same size, same disk, minutes
# apart — showed the systemd-supervised bag finalizing and the foreground one
# not, so supervision was the variable, not bag size. Taking the recorder out of
# play_launch's process tree dissolves that roadblock at its root: play_launch's
# shutdown, whatever it is doing wrong, can no longer reach the recorder.

set -eo pipefail

# `set -u` is deliberately absent: ROS's setup.bash chain reads unbound variables
# (AMENT_TRACE_SETUP_FILES and friends) and aborts the unit under -u with
#   /opt/ros/humble/setup.bash: line 8: AMENT_TRACE_SETUP_FILES: unbound variable
# This has bitten us before; do not "tighten" it.

WORKSPACE="${GOLFCART_WORKSPACE:-${HOME}/2026-golf-cart}"
ROLE="${GOLFCART_HOST:-master}"

case "${ROLE}" in
    master | orin) ;;
    *)
        echo "record_unit_exec: GOLFCART_HOST must be 'master' or 'orin', got '${ROLE}'" >&2
        exit 2
        ;;
esac

cd "${WORKSPACE}"

# One environment, one place. scripts/env.sh is what `.envrc` sources too, so the
# recorder and the terminal you debug it from cannot drift apart. It supplies the
# Autoware/ROS overlay, RMW_IMPLEMENTATION, the ROS_LOCALHOST_ONLY unset, PATH,
# CYCLONEDDS_URI - all of which this
# script used to carry its own copy of.
#
# The recorder must join the same DDS domain as the stack it is recording: on the
# wrong profile it discovers nothing and writes an empty bag that still looks
# plausible until you open it. GOLFCART_ENV_ROLE states the role outright rather
# than trusting the .golfcart-host marker, which a unit must not depend on.
export GOLFCART_ENV_ROLE="${ROLE}"
export GOLFCART_ENV_QUIET=1
# shellcheck source=/dev/null
source "${WORKSPACE}/scripts/env.sh"

if [ "${GOLFCART_DDS_PROFILE}" != "${ROLE}" ]; then
    echo "record_unit_exec: no CycloneDDS profile for role '${ROLE}'" >&2
    echo "                  resolved to '${GOLFCART_DDS_PROFILE}' instead" >&2
    exit 1
fi

# The session runner does the rest: it reads the session id and scope that
# `just record start` / `just record up` wrote to .golfcart-record.args just
# before starting this unit (rewritten on every start, so nothing outlives the
# start that asked for it), starts the scope's recorders (ros2 bag, candump,
# tshark) as its children under recordings/<id>/<role>/, and stops them on the
# SIGINT systemd sends. It runs scripts/rmw/ensure.sh itself when the scope
# records ROS: with GOLFCART_RMW=zenoh and no router, `ros2 bag record` starts,
# subscribes, reports no error and writes zero messages on every topic.
#
# exec, so systemd's main PID is the runner. KillMode=control-group delivers
# KillSignal=SIGINT to every recorder directly; `--unit` tells the runner not
# to forward a second one (bag finalization, the metadata.yaml that was 0 bytes
# on every foreground-stopped bag, must not be interrupted).
exec python3 "${WORKSPACE}/scripts/recording/session.py" run --unit \
    --role "${ROLE}" --args-file "${WORKSPACE}/.golfcart-record.args"
