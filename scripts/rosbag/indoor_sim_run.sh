#!/usr/bin/env bash
# indoor_sim_run.sh - the whole indoor cold-start replay in one command.
#
#   just indoor-test run                 # with RViz
#   just indoor-test run rviz=off
#   just indoor-test run on "pose_source:=cuda_ndt"
#
# Bag paused, stack, RViz, resume, then WATCH: this replay has no init step of
# its own, because the board detector is the init. What it waits for after
# resuming is the detector's pose on /localization/board_detector/board_pose
# and then board_pose_initializer's call to /localization/initialize, whose
# align result is in the stack log. It holds until Ctrl-C or the end of the
# bag and tears everything down.
#
# The ordering reasons are ntu_sim_run.sh's, in short: everything runs on sim
# time and the recording is weeks old, so anything started before /clock
# exists is yanked forward when playback begins, and RViz drops its latched
# maps while the pose initializer's stamps land days from every scan. The
# player starts PAUSED first and publishes /clock alone.
#
# Each stage waits on the condition that matters rather than on a guessed
# duration; fixed sleeps are how this sequence gets flaky.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# scripts/env.sh is the single source for the environment; without the
# workspace overlay play_launch dies with "Package 'golfcart_launch' not
# found" after the bag is already up. Sourced with -u off: env.sh is written
# for interactive shells and reads unset variables.
set +u
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/env.sh"
set -u

# Every process below is a ROS node, so a host that cannot create a DDS domain
# must be refused here rather than two minutes in as a misleading "no /clock".
golfcart_require_dds || exit 1

RVIZ="${1:-on}"
[ "${RVIZ}" = "rviz=off" ] && RVIZ=off
shift 1 2>/dev/null || true
LAUNCH_ARGS="$*"
LOG_DIR="${REPO_ROOT}/log/indoor-test"
mkdir -p "${LOG_DIR}"

BAG_LOG="${LOG_DIR}/bag.log"
STACK_LOG="${LOG_DIR}/stack.log"
RVIZ_LOG="${LOG_DIR}/rviz.log"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    printf '\n'
    say "stopping"
    "${REPO_ROOT}/scripts/rosbag/indoor_sim_down.sh" || true
}
trap cleanup EXIT INT TERM

wait_for() {
    local timeout="$1" label="$2"; shift 2
    local deadline=$((SECONDS + timeout))
    printf '    waiting for %s ' "${label}"
    while [ $SECONDS -lt $deadline ]; do
        if "$@" >/dev/null 2>&1; then printf ' ok\n'; return 0; fi
        printf '.'; sleep 2
    done
    printf ' TIMEOUT\n'
    return 1
}

has_topic()   { ros2 topic list 2>/dev/null | grep -qx "$1"; }
has_service() { ros2 service list 2>/dev/null | grep -qx "$1"; }
has_node()    { ros2 node list 2>/dev/null | grep -qx "$1"; }
has_data()    { timeout 12 ros2 topic echo --once "$1" >/dev/null 2>&1; }

# The ros2 CLI daemon caches the graph and does not re-read the DDS
# configuration once running; one started under a different CYCLONEDDS_URI
# sees an empty world. Stop it so the next call respawns it under this
# environment.
ros2 daemon stop >/dev/null 2>&1 || true

# ── 1. bag, paused: /clock only ─────────────────────────────────────────────
say "1/4  starting the basement bag paused (publishing /clock only)"
"${REPO_ROOT}/scripts/rosbag/indoor_sim_bag.sh" > "${BAG_LOG}" 2>&1 &
wait_for 60 "/clock" has_topic /clock \
    || die "no /clock. See ${BAG_LOG}. Is GOLFCART_INDOOR_BAG (or the NAS) reachable?"

# ── 2. stack, now born on bag time ──────────────────────────────────────────
say "2/4  bringing up the indoor logging simulation (sensor drivers off)"
# play_launch at 8adc52ad or newer, default (Rust) parser: see the `up`
# recipe in just/indoor-test.just for the version story.
# shellcheck disable=SC2086
( cd "${REPO_ROOT}" && play_launch launch --web-addr 0.0.0.0:8081 \
      --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
      golfcart_launch indoor_logging_sim.launch.xml rviz:=false ${LAUNCH_ARGS} ) > "${STACK_LOG}" 2>&1 &
wait_for 240 "/localization/initialize" has_service /localization/initialize \
    || die "stack never came up. See ${STACK_LOG}"
# Only with pose_initializer:=board, which is the default; a run asked for
# gnss or none legitimately has no detector, so this is a report, not a gate.
if wait_for 30 "/localization/board_detector" has_node /localization/board_detector; then
    board=1
else
    board=0
    printf '    (no board detector; pose_initializer is not board on this run)\n'
fi

if [ "${RVIZ}" = "on" ]; then
    say "3/4  starting RViz"
    "${REPO_ROOT}/scripts/rosbag/indoor_sim_rviz.sh" > "${RVIZ_LOG}" 2>&1 &
    wait_for 90 "rviz2" pgrep -x rviz2 || printf '    (RViz did not start; see %s)\n' "${RVIZ_LOG}"
else
    say "3/4  RViz skipped (rviz=off)"
fi

# ── 4. release the player and watch ─────────────────────────────────────────
say "4/4  resuming playback"
ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume >/dev/null 2>&1 \
    || die "could not resume the player"
wait_for 60 "scans on /sensing/lidar/vlp32/velodyne_points" has_data /sensing/lidar/vlp32/velodyne_points \
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
        printf '    no board pose before the bag ran out; see %s\n' "${STACK_LOG}"
    fi
fi

cat <<BANNER

  Replay running.  rviz=${RVIZ}

    grep -E 'board_pose_initializer|board_detector' ${STACK_LOG}
                                the detector's state and the align result
    just indoor-test pause      freeze playback

    logs: ${LOG_DIR}/{bag,stack,rviz}.log

  Ctrl-C stops everything.
BANNER

while pgrep -f 'bag play' >/dev/null 2>&1; do sleep 5; done
say "playback finished"
