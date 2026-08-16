#!/usr/bin/env bash
# play_ntu_sim.sh - replay a merged NTU campus bag into the logging simulation.
#
#   just bag-play-ntu CSIE-1            # or CSIE-2, BLVD-1
#   just bag-play-ntu CSIE-1 "--rate 0.5 --start-offset 30"
#
# --clock is not optional. The stack is launched with use_sim_time:=true, so
# without a clock publisher every node blocks forever on a time that never
# advances, and the symptom is a graph that comes up healthy and does nothing.
set -eo pipefail

MERGED_DIR="${GOLFCART_NTU_BAGS:-/home/aeon/Downloads/2026-08-14_NTU-campus/merged}"
SET_NAME="${1:-CSIE-1}"
shift || true

BAG="${MERGED_DIR}/${SET_NAME}"
if [ ! -d "${BAG}" ]; then
    echo "No merged bag at ${BAG}" >&2
    echo "Available:" >&2
    ls -1 "${MERGED_DIR}" 2>/dev/null | sed 's/^/  /' >&2
    echo >&2
    echo "Merge one with:  just bag-merge -o ${MERGED_DIR}/<SET> <master_bag> <orin_bag>" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "${REPO_ROOT}/install/setup.bash" ] && source "${REPO_ROOT}/install/setup.bash"

echo "Replaying ${BAG}"
echo "  the stack must already be up: ros2 launch golfcart_launch ntu_logging_sim.launch.xml"
echo "  NDT needs an initial pose — set one in RViz (2D Pose Estimate) before or"
echo "  shortly after starting playback; GNSS was off for these runs."
echo
exec ros2 bag play "${BAG}" --clock "$@"
