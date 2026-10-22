#!/usr/bin/env bash
# board_check.sh - run the reflective board detector and judge it.
#
#   scripts/testing/board_check.sh SOURCE SCENARIO RVIZ DURATION [BAG] [CHECK_ARGS...]
#
# Called by `just tool board-check`, which parses the KEY=VALUE options; run
# that instead. SOURCE is live or bag:
#
#   live  the VLP-32C driver, the vehicle TF and the detector, from
#         board_detector_live.launch.xml, exactly as `just tool board-detector`
#         starts them. The checker watches for DURATION seconds (0 = Ctrl-C).
#   bag   the same launch with the driver off and on bag time, and BAG played
#         with --clock in its place. The run ends when the bag does, unless
#         DURATION is shorter.
#
# Either way the detector reads the production files under
# golfcart_launch/config/localization/reflective_pose: board_detector.param.yaml
# and scenarios/SCENARIO/detector.yaml. Nothing is copied or overridden.
set -euo pipefail

SOURCE=$1 SCENARIO=$2 RVIZ=$3 DURATION=$4 BAG=${5:-}
shift 5 || shift $#
CHECK_ARGS=("$@")

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

LAUNCH_ARGS=(reflective_pose_scenario:="$SCENARIO" rviz:="$RVIZ")
case "$SOURCE" in
    live) LAUNCH_ARGS+=(lidar:=true use_sim_time:=false) ;;
    bag)
        if [ ! -f "$BAG/metadata.yaml" ]; then
            echo "No rosbag2 directory at: $BAG" >&2
            echo "Copy the basement bag from the NAS (see scripts/rosbag/indoor_sim_bag.sh)," >&2
            echo "or pass bag=PATH." >&2
            exit 2
        fi
        LAUNCH_ARGS+=(lidar:=false use_sim_time:=true) ;;
    *) echo "source must be live or bag, not '$SOURCE'" >&2; exit 2 ;;
esac

# Each child runs under setsid, so its pid is also its process group, and the
# whole group is signalled: launch and every node under it, not launch alone.
# SIGTERM, not SIGINT: a background job of a non-interactive shell starts with
# SIGINT ignored, and ros2 launch (Python) keeps that disposition, so an INT
# here was found to leave the launch and both nodes running.
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for _ in $(seq 20); do
        alive=0
        for pid in "${PIDS[@]}"; do kill -0 -- "-$pid" 2>/dev/null && alive=1; done
        [ "$alive" = 0 ] && return
        sleep 0.5
    done
    for pid in "${PIDS[@]}"; do kill -KILL -- "-$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
# Ctrl-C belongs to the checker, which turns it into a report. This shell only
# notes it, so it is still here to collect the exit status afterwards.
STOP=0
trap 'STOP=1' INT

# Own process group, so a Ctrl-C at the terminal reaches the checker (which
# turns it into a report) and not the launch underneath it mid-report.
setsid ros2 launch golfcart_launch board_detector_live.launch.xml "${LAUNCH_ARGS[@]}" \
    > >(sed -u 's/^/[launch] /') 2>&1 &
PIDS+=($!)

# The detector needs a few seconds to come up and subscribe. Wait for its
# diagnostics rather than a fixed sleep, up to 30 s.
for _ in $(seq 30); do
    if ros2 node list --no-daemon 2>/dev/null | grep -qx /board_detector; then break; fi
    sleep 1
done

CHECK=(python3 "$REPO_ROOT/scripts/testing/board_check.py" --duration "$DURATION" "${CHECK_ARGS[@]}")

if [ "$SOURCE" = live ]; then
    status=0
    "${CHECK[@]}" || status=$?
    exit "$status"
fi

"${CHECK[@]}" &
CHECKER=$!
setsid ros2 bag play "$BAG" --clock \
    > >(sed -u 's/^/[bag] /') 2>&1 &
PLAYER=$!
PIDS+=("$PLAYER")

# Whichever ends first: the bag running out, or the checker's own duration.
# When the bag is done, give the detector a batch to finish, then ask the
# checker for its report.
while [ "$STOP" = 0 ] && kill -0 "$CHECKER" 2>/dev/null && kill -0 "$PLAYER" 2>/dev/null; do
    sleep 0.5
done
if kill -0 "$CHECKER" 2>/dev/null; then
    [ "$STOP" = 1 ] || sleep 2
    kill -INT "$CHECKER"
fi
status=0
wait "$CHECKER" || status=$?
exit "$status"
