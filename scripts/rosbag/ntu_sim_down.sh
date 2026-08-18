#!/usr/bin/env bash
# ntu_sim_down.sh - stop the NTU replay: stack, bag player and RViz.
#
#   just ntu-sim-down
#
# Matches on argv[0] rather than on the process name, for two reasons that both
# cost real debugging time to find:
#
#   pkill -x matches `comm`, which the kernel truncates to 15 characters, so
#   `autoware_ndt_scan_matcher_node` is stored as `autoware_ndt_sc` and never
#   matches a `*_node` pattern. A sweep written that way reports success while
#   leaving the whole localization stack running.
#
#   pkill -f matches the full command line -- including this script's own, since
#   the pattern appears in it. That kills the sweeper mid-sweep.
#
# play_launch ignores SIGTERM, so the stack gets SIGINT first, exactly as the
# systemd units do with KillSignal=SIGINT. A bare `ros2 launch` killed with
# SIGTERM also leaves its children reparented to init, which is where the
# multi-day orphan pile-ups in this repo have come from.
set -uo pipefail

pids_matching() {   # $1 = awk condition on argv[0]
    ps -eo pid,args --no-headers | awk "$1 {print \$1}"
}

sweep() {
    local label="$1" cond="$2" pids
    pids=$(pids_matching "$cond")
    [ -z "$pids" ] && { printf '  %-22s none\n' "$label"; return; }
    # shellcheck disable=SC2086
    kill -INT $pids 2>/dev/null
    sleep 3
    pids=$(pids_matching "$cond")
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null
        sleep 2
        pids=$(pids_matching "$cond")
        # shellcheck disable=SC2086
        [ -n "$pids" ] && kill -KILL $pids 2>/dev/null
    fi
    printf '  %-22s stopped\n' "$label"
}

echo "Stopping the NTU replay:"
sweep "bag player"  '$0 ~ /bag play/'
sweep "play_launch" '$2 ~ /play_launch/'
sweep "rviz2"       '$2 ~ /rviz2$/'
sweep "autoware nodes" '$2 ~ "^/opt/autoware/[0-9.]+/lib"'
sweep "ros nodes"      '$2 ~ "^/opt/ros/[a-z]+/lib"'

sleep 1
left=$(ps -eo pid,args --no-headers \
       | awk '$2 ~ "^/opt/autoware/[0-9.]+/lib" || $2 ~ "^/opt/ros/[a-z]+/lib" || $2 ~ /rviz2$/' \
       | wc -l)
echo
if [ "$left" -eq 0 ]; then
    echo "  clean — no ROS processes left"
else
    echo "  WARNING: ${left} ROS processes survived:" >&2
    ps -eo pid,etime,args --no-headers \
      | awk '$3 ~ "^/opt/autoware/[0-9.]+/lib" || $3 ~ "^/opt/ros/[a-z]+/lib"' | cut -c1-100 >&2
    exit 1
fi
