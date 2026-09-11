#!/usr/bin/env bash
# indoor_sim_down.sh - stop the indoor replay: stack, bag player, RViz, fake-tf.
#
#   just indoor-test down
#
# Mirrors ntu_sim_down.sh, and matches on argv fields rather than on the
# process name for the two reasons given there: `comm` is truncated to 15
# characters so `*_node` patterns miss, and `pkill -f` matches this script's
# own command line and kills the sweeper mid-sweep.
#
# play_launch ignores SIGTERM, so the stack gets SIGINT first, exactly as the
# systemd units do with KillSignal=SIGINT. The two board nodes are Python and
# show up as `/usr/bin/python3 <install path>/board_detector_node`, which the
# /opt/ros and /opt/autoware sweeps do not see, so they get a sweep of their
# own after play_launch has had its chance.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIDFILE="${REPO_ROOT}/log/indoor-test/supervisor.pid"

# A run started by `just indoor-test run` has a supervisor: GNU parallel, whose
# pid is in the file above. Stopping that one process is the whole teardown,
# and it is the RIGHT teardown, because parallel kills the four jobs it
# started and nothing else. The pattern sweep below stays for the staged path
# (`just indoor-test bag` / `up` / `rviz` in separate terminals), which has no
# supervisor to ask -- but it matches on argv, so it cannot tell this run's
# processes from anyone else's on the same machine. Prefer the pidfile.
stop_supervisor() {
    [ -f "${PIDFILE}" ] || return 1
    local pid
    pid=$(cat "${PIDFILE}" 2>/dev/null)
    [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || { rm -f "${PIDFILE}"; return 1; }

    printf 'Stopping the indoor replay via its supervisor (pid %s):\n' "${pid}"
    # INT, because that is what parallel turns into its own --termseq for the
    # jobs, and what play_launch needs.
    kill -INT "${pid}" 2>/dev/null
    local deadline=$((SECONDS + 30))
    while [ $SECONDS -lt $deadline ] && kill -0 "${pid}" 2>/dev/null; do sleep 1; done
    if kill -0 "${pid}" 2>/dev/null; then
        printf '  supervisor did not exit in 30s; falling back to the sweep\n'
        kill -TERM "${pid}" 2>/dev/null
        return 1
    fi
    rm -f "${PIDFILE}"
    printf '  supervisor stopped; its jobs went with it\n'
    return 0
}

# Everything in this script's own process group is excluded, and that is not
# hygiene: `ps -eo args | awk '$0 ~ /bag play/'` matches the awk command line
# itself, so the sweep used to report "bag player stopped" on a machine with
# no replay running, having killed its own pipeline. A sweeper that cannot
# tell its own processes from its targets reports nonsense in both directions.
#
# The filtering happens after the match rather than inside it, so the
# conditions below keep addressing `ps -eo pid,args` fields ($2 is the
# executable, $3 its first argument) and do not have to know about this.
pids_matching() {   # $1 = awk condition on the ps line
    local mypgid pid pgid
    mypgid=$(ps -o pgid= -p $$ | tr -d ' ')
    ps -eo pid,args --no-headers | awk "$1 {print \$1}" | while read -r pid; do
        pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d ' ')
        [ "${pgid}" = "${mypgid}" ] && continue
        printf '%s\n' "${pid}"
    done
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

if stop_supervisor; then
    # Still sweep, but only to report: a supervised run should leave nothing,
    # and if it did, that is a bug worth seeing rather than hiding.
    printf '\nChecking for anything left behind:\n'
else
    echo "Stopping the indoor replay:"
fi
sweep "bag player"     '$0 ~ /bag play/'
# The stock `ros2 launch` process that `up` runs; SIGINT makes it stop its
# own children first. Matched on the launch file so an unrelated ros2 launch
# on the machine is left alone.
sweep "ros2 launch"    '$0 ~ /ros2 launch golfcart_launch indoor_logging_sim/'
sweep "play_launch"    '$2 ~ /play_launch/'
sweep "rviz2"          '$2 ~ /rviz2$/'
sweep "board nodes"    '$3 ~ /reflective_pose_(ros|autoware)\/(board_detector_node|board_pose_initializer)$/'
# Catches `just indoor-test fake-tf`, and also the vehicle description's own
# static publishers when the stack is up; both are meant to go.
sweep "static tf"      '$2 ~ /static_transform_publisher$/'
sweep "autoware nodes" '$2 ~ "^/opt/autoware/[0-9.]+/lib"'
sweep "ros nodes"      '$2 ~ "^/opt/ros/[a-z]+/lib"'

sleep 1
left=$(ps -eo pid,args --no-headers \
       | awk '$2 ~ "^/opt/autoware/[0-9.]+/lib" || $2 ~ "^/opt/ros/[a-z]+/lib" || $2 ~ /rviz2$/ || $3 ~ /reflective_pose_(ros|autoware)\//' \
       | wc -l)
echo
if [ "$left" -eq 0 ]; then
    echo "  clean, no ROS processes left"
else
    echo "  WARNING: ${left} ROS processes survived:" >&2
    ps -eo pid,etime,args --no-headers \
      | awk '$3 ~ "^/opt/autoware/[0-9.]+/lib" || $3 ~ "^/opt/ros/[a-z]+/lib" || $4 ~ /reflective_pose_(ros|autoware)\//' | cut -c1-100 >&2
    exit 1
fi
