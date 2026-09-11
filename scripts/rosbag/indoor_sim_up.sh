#!/usr/bin/env bash
# indoor_sim_up.sh - the indoor replay stack, born on bag time.
#
#   just indoor-test up ["pose_source:=ndt ..."]
#
# Waits for /clock before launching, and that wait is the whole point of the
# ordering: the stack runs with use_sim_time:=true against a recording weeks
# older than wall time, so anything started before /clock exists sits at time 0
# and is yanked forward when playback begins. RViz drops its latched map
# displays; the pose initializer's stamps land days from every scan.
#
# `just indoor-test bag` publishes /clock from a PAUSED player, so this can
# wait for it without any sensor data having moved yet.
#
# The two defaults below are this replay's subject, not the vehicle's
# configuration. indoor_logging_sim.launch.xml defaults to what the CART runs
# (pose_initializer:=gnss, pose_source:=cuda_ndt), because a launch file that
# lies about the vehicle is worse than one that needs a flag. What THIS script
# exists to exercise is the board cold start, so it asks for the board
# initializer by name, and anything the caller passes wins over it.
set -eo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/rosbag/indoor_sim_lib.sh"
sim_source_env "${REPO_ROOT}"

LAUNCH_ARGS="$*"
LAUNCH_ARGS="$(sim_default_arg "${LAUNCH_ARGS}" "pose_initializer:=board")"

if ! has_topic /clock; then
    wait_for 90 "/clock (start the bag first: just indoor-test bag)" has_topic /clock \
        || die "no /clock; the stack must be born on bag time"
fi

say "launching indoor_logging_sim.launch.xml ${LAUNCH_ARGS}"

# exec, and not merely for tidiness: `just indoor-test run` supervises this
# through GNU parallel, which signals the process it started and nothing
# below it. play_launch ignores SIGTERM (the systemd units use
# KillSignal=SIGINT for the same reason), so if it were a child of this shell
# rather than this process, a teardown would leave the whole stack running.
#
# play_launch at 8adc52ad or newer, default (Rust) parser: see the `up` recipe
# in just/indoor-test.just for the version story.
# shellcheck disable=SC2086
cd "${REPO_ROOT}" && exec play_launch launch --web-addr 0.0.0.0:8081 \
    --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
    golfcart_launch indoor_logging_sim.launch.xml rviz:=false ${LAUNCH_ARGS}
