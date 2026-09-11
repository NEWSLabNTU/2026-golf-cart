#!/usr/bin/env bash
# indoor_sim_conduct.sh - wait for the stack, release the player, report.
#
# Not run by hand: `just indoor-test run` starts it as one of the jobs GNU
# parallel supervises, beside the bag, the stack and RViz. It is the only job
# that does not own a long-lived process, which is why it ends by sleeping
# rather than returning: under `--halt now,done=1` the FIRST job to finish
# tears down the rest, and that job must be the bag reaching its end.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/rosbag/indoor_sim_lib.sh"
sim_source_env "${REPO_ROOT}"

LOG_DIR="${REPO_ROOT}/log/indoor-test"
STACK_LOG="${LOG_DIR}/stack.log"

wait_for 240 "/localization/initialize" has_service /localization/initialize \
    || die "stack never came up. See ${STACK_LOG}"

# Only with pose_initializer:=board, which is what `just indoor-test up`
# asks for; a run told to use gnss or none legitimately has no detector, so
# this is a report rather than a gate.
if wait_for 30 "/localization/board_detector" has_node /localization/board_detector; then
    board=1
else
    board=0
    warn "(no board detector; pose_initializer is not board on this run)"
fi

say "resuming playback"
ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume >/dev/null 2>&1 \
    || die "could not resume the player"
wait_for 60 "scans on /sensing/lidar/vlp32/velodyne_points" \
    has_data /sensing/lidar/vlp32/velodyne_points \
    || die "no scans arriving from the bag"

if [ "${board}" = 1 ]; then
    # The detector publishes only when it trusts a pose, and the cart has to
    # be stopped near the board for that, so this can take most of the bag.
    # Not fatal: no pose is a finding about the bag or the gates, and the
    # stack log says which (diagnostics from /localization/board_detector).
    if wait_for 235 "a board pose on /localization/board_detector/board_pose" \
            has_data /localization/board_detector/board_pose; then
        printf '    board pose published; the initializer acts on it next\n'
    else
        warn "no board pose before the bag ran out; see ${STACK_LOG}"
    fi
fi

cat <<BANNER

  Replay running.

    grep -E 'board_pose_initializer|board_detector' ${STACK_LOG}
                                the detector's state and the align result
    just indoor-test pause      freeze playback
    just indoor-test down       stop everything (from another terminal)

    logs: ${LOG_DIR}/{bag,stack,rviz}.log

  Ctrl-C here stops everything. So does the bag reaching its end.
BANNER

# Hold the job open. The bag's own exit is what ends the run.
exec sleep infinity
