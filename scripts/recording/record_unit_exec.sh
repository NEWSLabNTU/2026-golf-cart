#!/usr/bin/env bash
# record_unit_exec.sh — ExecStart target for golfcart-record.service.
#
# One script for both hosts: the role comes from GOLFCART_HOST, and everything
# role-specific (topic list, DDS profile, bag name) is derived from it.
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
# CYCLONEDDS_URI and the SSD-preferring GOLFCART_BAG_DIR - all of which this
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

OUTPUT_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"

TOPIC_FILE="${WORKSPACE}/config/recording/${ROLE}_topics.txt"
if [ ! -f "${TOPIC_FILE}" ]; then
    echo "record_unit_exec: topic list not found: ${TOPIC_FILE}" >&2
    echo "record_unit_exec: expected one topic per line ('#' comments allowed)" >&2
    exit 1
fi

# Strip comments (whole-line and trailing) and surrounding whitespace, then drop
# blank lines.
TOPICS=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "${line}" ] && TOPICS+=("${line}")
done < "${TOPIC_FILE}"

if [ "${#TOPICS[@]}" -eq 0 ]; then
    echo "record_unit_exec: ${TOPIC_FILE} lists no topics — refusing to record nothing" >&2
    exit 1
fi

BAG_NAME="${ROLE}_$(date +%Y%m%d_%H%M%S)"

mkdir -p "${OUTPUT_DIR}"
echo "record_unit_exec: role=${ROLE} writing ${OUTPUT_DIR}/${BAG_NAME} (${#TOPICS[@]} topics)"

# exec so systemd supervises `ros2 bag record` itself and its SIGINT lands on the
# recorder rather than on a wrapper shell. Bag finalization — the metadata.yaml
# that was 0 bytes on every foreground-stopped bag — depends on the recorder
# receiving that signal directly.
# Middleware preconditions, as in launch_unit_exec.sh. This matters more here
# than anywhere else: with GOLFCART_RMW=zenoh and no router, `ros2 bag record`
# starts, subscribes, reports no error, and writes a bag containing zero messages
# on every topic. A recording is the one artefact of a test drive that cannot be
# taken again, so it is worth refusing to start over.
"${WORKSPACE}/scripts/rmw/ensure.sh" || exit 1

exec ros2 bag record -o "${OUTPUT_DIR}/${BAG_NAME}" "${TOPICS[@]}"
