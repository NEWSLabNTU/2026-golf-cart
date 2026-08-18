#!/usr/bin/env bash
# ntu_sim_bag.sh - start a merged NTU bag PAUSED, publishing /clock only.
#
#   just ntu-test bag CSIE-1
#
# Paused on purpose, and the ordering it enables is the whole point.
#
# The stack runs with use_sim_time:=true, and these recordings are ~3.9 days
# older than wall time. Anything started before a clock exists sits at time 0
# and then gets yanked days forward when playback begins. Two things break that
# way, both silently:
#
#   RViz  latches the maps at t=0, the clock jumps, and the displays are
#         dropped -- which looks exactly like "the map failed to load", while
#         /map/pointcloud_map is sitting there fully populated.
#
#   NDT   receives an initial pose stamped days away from every scan it holds,
#         rejects the alignment, and reports iteration_num 0 / NVTL 0.0 while
#         the EKF dead-reckons on IMU and velocity -- so the vehicle still moves
#         across the map at 40 Hz and nothing looks wrong.
#
# Starting paused publishes /clock at the bag's first timestamp without moving
# any sensor data, so everything launched afterwards is born on bag time.
# Resume with `just ntu-test resume` once the stack is up.
set -eo pipefail

MERGED_DIR="${GOLFCART_NTU_BAGS:-/home/aeon/Downloads/2026-08-14_NTU-campus/merged}"
SET_NAME="${1:-CSIE-1}"
shift || true

BAG="${MERGED_DIR}/${SET_NAME}"
if [ ! -d "${BAG}" ]; then
    echo "No merged bag at ${BAG}" >&2
    echo "Available:" >&2
    ls -1 "${MERGED_DIR}" 2>/dev/null | sed 's/^/  /' >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ -f "${REPO_ROOT}/install/setup.bash" ] && source "${REPO_ROOT}/install/setup.bash"

echo "Starting ${BAG} PAUSED (clock only)."
echo "  next: just ntu-test up      # stack, now born on bag time"
echo "        just ntu-test resume  # let the sensors flow"
echo

# read-ahead raised because the default queue starves on this bag and delays
# messages, which shows up later as a jittery scan rate rather than as an error.
exec ros2 bag play "${BAG}" --clock --start-paused --read-ahead-queue-size 5000 "$@"
