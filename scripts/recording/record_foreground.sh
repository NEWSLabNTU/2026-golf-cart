#!/usr/bin/env bash
# record_foreground.sh — record this host's topic list from a terminal.
#
# Usage: scripts/recording/record_foreground.sh [NAME]
#        just bag record [NAME]
#
# The terminal counterpart of golfcart-record.service (`just record start`):
# the same list, config/recording/<role>_topics.txt, read by the same function
# (scripts/recording/topics.sh), written to the same $GOLFCART_BAG_DIR, named
# the same way, <role>_<YYYYmmdd_HHMMSS>, with _NAME appended when given. There
# is no second list to keep in step; edit the config file, not this script.
#
# The role is the one scripts/env.sh resolves for this checkout (config/host).
# Under master or orin it records that host's list. Any other role is one
# machine running everything, so it records both lists.
#
# Ctrl-C stops it and finalizes the bag. The 0-byte metadata.yaml in
# docs/roadblocks.md is a play_launch child being stopped, not a recorder in a
# terminal; `exec` below makes the SIGINT land on `ros2 bag record` itself.

set -eo pipefail
# No `set -u`: the ROS setup chain that env.sh sources reads unbound variables.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${1:-}"

cd "${REPO_ROOT}"
export GOLFCART_ENV_QUIET=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/env.sh"
# shellcheck source=topics.sh
source "${REPO_ROOT}/scripts/recording/topics.sh"

ROLE="${GOLFCART_HOST:-}"
case "${ROLE}" in
    master | orin) LISTS=("config/recording/${ROLE}_topics.txt") ;;
    *)             LISTS=(config/recording/master_topics.txt config/recording/orin_topics.txt)
                   ROLE="${ROLE:-local}" ;;
esac

mapfile -t TOPICS < <(golfcart_recording_topics "${LISTS[@]}")
if [ "${#TOPICS[@]}" -eq 0 ]; then
    echo "record_foreground: ${LISTS[*]} lists no topics — refusing to record nothing" >&2
    exit 1
fi

OUTPUT_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
BAG_NAME="${ROLE}_$(date +%Y%m%d_%H%M%S)${NAME:+_${NAME}}"
mkdir -p "${OUTPUT_DIR}"

echo "record_foreground: role=${ROLE} writing ${OUTPUT_DIR}/${BAG_NAME} (${#TOPICS[@]} topics)"
echo "  from ${LISTS[*]}"
df -h --output=avail,target "${OUTPUT_DIR}" | tail -1 | awk '{print "  free: " $1 " on " $2}'
echo "Press Ctrl-C to stop."

# Same gate as the unit: under zenoh with no router, `ros2 bag record` starts
# cleanly and writes zero messages on every topic.
"${REPO_ROOT}/scripts/rmw/ensure.sh" || exit 1

exec ros2 bag record -o "${OUTPUT_DIR}/${BAG_NAME}" "${TOPICS[@]}"
