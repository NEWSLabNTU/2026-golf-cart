#!/usr/bin/env bash
# indoor_sim_bag.sh - start the basement VLP-32C bag PAUSED, publishing /clock only.
#
#   just indoor-test bag
#
# The bag path lives HERE and nowhere else: GOLFCART_INDOOR_BAG overrides it,
# and the default is the repo-local copy of vlp32_1 from the 2026-08-20
# basement survey, the only recording of the board so far. Never point this at
# the NAS: copy the bag into the gitignored rosbags/ first, once, and replay the
# copy. The NAS is an sshfs mount shared by several people and sessions.
#
#   mkdir -p rosbags/basement
#   cp -r ~/nas/"autoveh/dataset/2026-08-20 GLIM pointcloud mapping bags/rosbags/vlp32_1" rosbags/basement/
#
# Paused on purpose, for the reason ntu_sim_bag.sh spells out: the stack runs
# with use_sim_time:=true and the recording is weeks older than wall time, so
# anything started before /clock exists sits at time 0 and is yanked forward
# when playback begins. RViz drops its latched map displays; the board
# detector's TF lookup and the pose initializer's stamps land days away from
# every scan. Starting paused publishes /clock at the bag's first timestamp
# without moving any sensor data, so everything launched afterwards is born
# on bag time. Resume with `just indoor-test resume` once the stack is up.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BAG="${GOLFCART_INDOOR_BAG:-${REPO_ROOT}/rosbags/basement/vlp32_1}"

if [ ! -d "${BAG}" ]; then
    echo "No bag directory at: ${BAG}" >&2
    echo "Copy it from the NAS into rosbags/basement/ (see the top of this file)," >&2
    echo "or set GOLFCART_INDOOR_BAG to a local rosbag2 directory." >&2
    exit 1
fi

[ -f "${REPO_ROOT}/install/setup.bash" ] && source "${REPO_ROOT}/install/setup.bash"

echo "Starting ${BAG} PAUSED (clock only)."
echo "  next: just indoor-test up      # stack, now born on bag time"
echo "        just indoor-test resume  # let the scans flow"
echo

# One 3.7 GB topic at 10 Hz; the raised read-ahead keeps the scan rate steady
# rather than letting the default queue starve and jitter it.
exec ros2 bag play "${BAG}" --clock --start-paused --read-ahead-queue-size 5000 "$@"
