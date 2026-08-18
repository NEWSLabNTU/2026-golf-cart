#!/usr/bin/env bash
# ntu_sim_run.sh - the whole NTU NDT replay in one command.
#
#   just ntu-test run              # CSIE-1, with RViz
#   just ntu-test run CSIE-2       # another set
#   just ntu-test run CSIE-1 rviz=off
#
# Brings up the bag, the stack and RViz in the one order that works, waits for
# each stage to actually be ready, seeds NDT, then holds until Ctrl-C and tears
# everything down.
#
# WHY THE ORDER IS WHAT IT IS
#
# Everything here runs on sim time, and these recordings are days older than the
# wall clock. Anything started before /clock exists sits at time 0 and is yanked
# days forward the moment playback begins. Two things break that way, and both
# fail silently while continuing to look healthy:
#
#   RViz  latches the maps at t=0, the clock jumps, the displays are dropped.
#         Reads as "the map failed to load" while /map/pointcloud_map holds 6.6M
#         points and RViz is subscribed to it.
#
#   NDT   gets an initial pose stamped days from every scan it holds, rejects
#         the alignment, and reports iteration_num 0 / NVTL 0.0 / no pose output
#         -- while the EKF dead-reckons on IMU and velocity, so the vehicle still
#         moves across the map at 40 Hz and /localization/initialize returned
#         success. Nothing in that picture says "broken".
#
# So: the player starts PAUSED first and publishes /clock alone. Everything else
# is then born on bag time. The pose goes last, because NDT can only refine a
# seed it has scans to match against -- seeding before playback leaves
# pose_initializer blocked in "Call align server" forever.
#
# WAITING, NOT SLEEPING
#
# Each stage waits on the condition that matters -- clock present, service up,
# cloud flowing -- rather than on a guessed duration. Fixed sleeps are how this
# sequence gets flaky on a loaded machine, and a too-short one reproduces exactly
# the silent failures above.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# scripts/env.sh is the single source for the environment -- Autoware sourcing,
# the workspace overlay, CYCLONEDDS_URI, RMW_IMPLEMENTATION -- and CLAUDE.md says
# not to re-derive any of it here. It matters: without the overlay, play_launch
# dies with "Package 'golfcart_launch' not found" AFTER the bag is already up,
# so the failure arrives two minutes into the run rather than at the start.
# `ros2` itself still works from /opt/ros, which is what makes it confusing.
#
# Sourced with -u off: env.sh is written for interactive shells and reads unset
# variables (AMENT_TRACE_SETUP_FILES among them).
set +u
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/env.sh"
set -u

# env.sh only warns about a host that cannot create a DDS domain, because builds
# and ordinary shells do not need one. This does: every process below is a ROS
# node. Refuse now rather than start a bag that dies on rmw_create_node, which
# surfaces two minutes later as a misleading "no /clock".
golfcart_require_dds || exit 1

SET_NAME="${1:-CSIE-1}"
RVIZ="${2:-on}"
[ "${RVIZ}" = "rviz=off" ] && RVIZ=off
LOG_DIR="${REPO_ROOT}/log/ntu-test"
mkdir -p "${LOG_DIR}"

BAG_LOG="${LOG_DIR}/bag.log"
STACK_LOG="${LOG_DIR}/stack.log"
RVIZ_LOG="${LOG_DIR}/rviz.log"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    printf '\n'
    say "stopping"
    "${REPO_ROOT}/scripts/rosbag/ntu_sim_down.sh" || true
}
trap cleanup EXIT INT TERM

# Wait for a shell condition, printing progress. $1=seconds $2=label, rest=cmd.
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
# One message on a topic proves data is flowing; a rate check needs a window and
# a bare topic-list entry proves only that someone advertised it.
has_data()    { timeout 12 ros2 topic echo --once "$1" >/dev/null 2>&1; }

# The ros2 CLI daemon caches the ROS graph, and it does NOT re-read the DDS
# configuration once running. A daemon started before env.sh set CYCLONEDDS_URI
# lives in a different transport configuration and simply cannot see the
# participants created under the profile -- measured here as `ros2 topic list`
# returning 2 topics while 29 existed, /clock among them.
#
# That is indistinguishable from "the bag failed to start", which is exactly the
# wrong conclusion. Stop it now and let the next call respawn it under the
# environment this script actually runs in.
ros2 daemon stop >/dev/null 2>&1 || true

# ── 1. bag, paused: /clock only ─────────────────────────────────────────────
say "1/5  starting ${SET_NAME} paused (publishing /clock only)"
"${REPO_ROOT}/scripts/rosbag/ntu_sim_bag.sh" "${SET_NAME}" > "${BAG_LOG}" 2>&1 &
wait_for 60 "/clock" has_topic /clock \
    || die "no /clock. See ${BAG_LOG} -- does the bag ${SET_NAME} exist?"

# ── 2. stack, now born on bag time ──────────────────────────────────────────
say "2/5  bringing up the logging simulation (sensor drivers off)"
( cd "${REPO_ROOT}" && play_launch launch --parser python --web-addr 0.0.0.0:8081 \
      golfcart_launch ntu_logging_sim.launch.xml rviz:=false ) > "${STACK_LOG}" 2>&1 &
# The initialize service is the real readiness signal: it appears only once
# pose_initializer is up, which is the thing step 5 talks to.
wait_for 240 "/localization/initialize" has_service /localization/initialize \
    || die "stack never came up. See ${STACK_LOG}"

if [ "${RVIZ}" = "on" ]; then
    say "3/5  starting RViz"
    "${REPO_ROOT}/scripts/rosbag/ntu_sim_rviz.sh" > "${RVIZ_LOG}" 2>&1 &
    wait_for 90 "rviz2" pgrep -x rviz2 || printf '    (RViz did not start; see %s)\n' "${RVIZ_LOG}"
else
    say "3/5  RViz skipped (rviz=off)"
fi

# ── 4. release the player ───────────────────────────────────────────────────
say "4/5  resuming playback"
ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume >/dev/null 2>&1 \
    || die "could not resume the player"
# NDT's own input, not the raw driver topic -- the downsampler sits between them
# and a seed sent before it produces anything is the silent-rejection case.
wait_for 120 "NDT input cloud" has_data /localization/util/downsample/pointcloud \
    || die "no cloud on /localization/util/downsample/pointcloud"

# ── 5. seed NDT ─────────────────────────────────────────────────────────────
#
# Retried, and verified against ndt_scan_matcher rather than against the
# service's own return code, because /localization/initialize reports success
# on a path that leaves NDT switched OFF.
#
# pose_initializer does: deactivate NDT -> align -> reactivate. The align fails
# whenever an input is missing (no map in NDT, no accepted scan, no TF), and
# LocalizationModule::align_pose THROWS on that -- so the reactivate never runs.
# is_activated_ is written only by that trigger service, so nothing turns it back
# on later. Meanwhile the EKF dead-reckons on IMU and velocity: kinematic_state
# keeps publishing at 40 Hz and the vehicle drives across the map, while NDT
# contributes nothing. See scripts/localization/check_ndt_activated.py.
say "5/5  seeding NDT from the captured pose"
seeded=0
for attempt in 1 2 3; do
    python3 "${REPO_ROOT}/scripts/localization/set_initial_pose.py" "${SET_NAME}" \
        || die "initialization request failed"
    if python3 "${REPO_ROOT}/scripts/localization/check_ndt_activated.py" --timeout 20; then
        seeded=1
        break
    fi
    printf '    attempt %d: NDT did not activate, retrying\n' "${attempt}"
    # A scan the matcher will accept is the usual missing input, so give playback
    # a moment to deliver more before asking again.
    sleep 5
done
[ "${seeded}" = "1" ] || die "NDT never activated -- it is latched off and will not recover on its own"

wait_for 60 "localization to converge" has_data /localization/kinematic_state \
    || printf '    (no kinematic_state yet -- check NDT score against its threshold)\n'

cat <<BANNER

  Replay running.  set=${SET_NAME}  rviz=${RVIZ}

    just ntu-test report        score it (scatter, yaw step)
    just ntu-test pause         freeze playback
    just ntu-test capture ${SET_NAME}  re-capture the pose, now NDT-converged

    logs: ${LOG_DIR}/{bag,stack,rviz}.log

  Ctrl-C stops everything.
BANNER

# Hold the terminal so Ctrl-C reaches the trap. Exits on its own when the
# player finishes the bag.
while pgrep -f 'bag play' >/dev/null 2>&1; do sleep 5; done
say "playback finished"
