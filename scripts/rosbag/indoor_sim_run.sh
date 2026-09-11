#!/usr/bin/env bash
# indoor_sim_run.sh - the whole indoor cold-start replay, supervised by parallel.
#
#   just indoor-test run                 # with RViz
#   just indoor-test run rviz=off
#   just indoor-test run on "pose_source:=ndt"
#
# Four processes have to live at once and die together: the bag player, the
# stack, RViz, and the conductor that releases the player once the stack is
# up. GNU parallel owns all four.
#
# It used to be `cmd &` per process plus `trap cleanup EXIT INT TERM`, where
# cleanup ran a sweep that killed ROS processes BY PATTERN. Two ways that
# failed, both seen:
#
#   * the trap fires on EXIT, including the exit of a run that has already
#     been superseded, so a stale run tears down the one that replaced it;
#   * matching on argv kills every matching process on the machine, not the
#     ones this run started, so it takes a colleague's stack with it.
#
# parallel replaces both. One supervisor owns exactly the four jobs it
# started, `--halt now,done=1` means the first job to finish (normally the bag
# reaching its end, or any job failing) tears down the other three, and the
# teardown signal sequence is explicit.
#
# --termseq INT,3000,TERM,2000,KILL,25 is not decoration. play_launch ignores
# SIGTERM, exactly as the systemd units assume with KillSignal=SIGINT, so the
# sequence has to lead with INT and give it time. Measured: parallel signals
# the process it started and NOTHING BELOW IT, so every job here execs its
# long-lived process rather than backgrounding it. A job that forks and waits
# leaves its child running after the teardown.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/rosbag/indoor_sim_lib.sh"
sim_source_env "${REPO_ROOT}"

# Every process below is a ROS node, so a host that cannot create a DDS domain
# must be refused here rather than two minutes in as a misleading "no /clock".
golfcart_require_dds || exit 1
command -v parallel >/dev/null || die "GNU parallel is not installed (setup step: dev-tools)"

RVIZ="${1:-on}"
[ "${RVIZ}" = "rviz=off" ] && RVIZ=off
shift 1 2>/dev/null || true
LAUNCH_ARGS="$*"

LOG_DIR="${REPO_ROOT}/log/indoor-test"
mkdir -p "${LOG_DIR}"
JOBS="${LOG_DIR}/jobs.txt"
PIDFILE="${LOG_DIR}/supervisor.pid"

sim_reset_ros2_daemon

# Each line is one job, run through a shell, so each can redirect its own log.
# Order in this file is not execution order: parallel starts them together and
# each waits for the condition it needs. That is the point of the design, and
# why there is no sleep anywhere in it.
{
    printf 'exec %q > %q 2>&1\n' \
        "${REPO_ROOT}/scripts/rosbag/indoor_sim_bag.sh" "${LOG_DIR}/bag.log"
    printf 'exec %q %s > %q 2>&1\n' \
        "${REPO_ROOT}/scripts/rosbag/indoor_sim_up.sh" "${LAUNCH_ARGS}" "${LOG_DIR}/stack.log"
    printf 'exec %q\n' "${REPO_ROOT}/scripts/rosbag/indoor_sim_conduct.sh"
    if [ "${RVIZ}" = "on" ] && [ -n "${DISPLAY:-}" ]; then
        # The wait lives in the script, so this stays one plain exec like the
        # rest. Job lines that need shell features are a portability trap: see
        # PARALLEL_SHELL below.
        #
        # RViz is a supervised job like the others, so if it exits the replay
        # ends. That is the right behaviour for a window you asked for and
        # watched die, and the wrong one for a machine with no X server at
        # all, which is why the DISPLAY check is here rather than inside the
        # script: a headless host skips the job instead of tearing the run
        # down two seconds after it starts.
        printf 'exec %q > %q 2>&1\n' \
            "${REPO_ROOT}/scripts/rosbag/indoor_sim_rviz.sh" "${LOG_DIR}/rviz.log"
    fi
} > "${JOBS}"

if [ "${RVIZ}" = "on" ] && [ -z "${DISPLAY:-}" ]; then
    RVIZ="off (no DISPLAY)"
    warn "rviz=on but DISPLAY is unset; skipping RViz rather than failing the run"
fi

say "starting the indoor replay (rviz=${RVIZ}) under GNU parallel"
printf '    jobs: %s\n    logs: %s/{bag,stack,rviz}.log\n' "${JOBS}" "${LOG_DIR}"

# The pidfile is written BEFORE the exec on purpose: exec keeps this process
# id, so the number below is parallel's own, and `just indoor-test down` can
# stop exactly this run instead of sweeping the machine.
echo $$ > "${PIDFILE}"

# exec, so Ctrl-C from the terminal reaches parallel directly. No trap: the
# supervisor is the thing that tears down, and a trap here could only fire
# after parallel had already returned.
# parallel runs each job line through $SHELL, and the shell a developer happens
# to log in with is not a property of this replay: fish parses none of the
# redirections below the way bash does. Pin it.
export PARALLEL_SHELL=/bin/bash

exec parallel --halt now,done=1 --termseq INT,3000,TERM,2000,KILL,25 \
    --line-buffer --jobs 0 :::: "${JOBS}"
