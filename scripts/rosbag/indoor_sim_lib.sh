#!/usr/bin/env bash
# Shared helpers for the indoor replay scripts. Sourced, never executed.
#
# Each stage of the replay waits on the condition that matters rather than on
# a guessed duration: fixed sleeps are how this sequence gets flaky, and they
# are also what makes a run unreproducible on a slower machine.

# scripts/env.sh is the single source for the environment; without the
# workspace overlay play_launch dies with "Package 'golfcart_launch' not
# found". Sourced with -u off: env.sh is written for interactive shells and
# reads unset variables.
sim_source_env() {
    local repo_root="$1"
    set +u
    # shellcheck source=/dev/null
    source "${repo_root}/scripts/env.sh"
    set -u
}

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m    %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

has_topic()   { ros2 topic list 2>/dev/null | grep -qx "$1"; }
has_service() { ros2 service list 2>/dev/null | grep -qx "$1"; }
has_node()    { ros2 node list 2>/dev/null | grep -qx "$1"; }
# NOT `ros2 topic echo --once`: that resolves the message type through the
# graph before subscribing, and during an 83-node startup the lookup can
# outlast any timeout worth waiting for. Two runs reported "no scans arriving"
# while the player logged "Resuming play." and published for 80 s. The helper
# subscribes directly, BEST_EFFORT, which is how sensor topics are published.
has_data() {
    local repo_root="${SIM_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    timeout 40 python3 "${repo_root}/scripts/rosbag/wait_for_message.py" \
        "$1" --timeout 30 --quiet >/dev/null 2>&1
}

# wait_for <timeout_seconds> <label> <predicate...>
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

# The ros2 CLI daemon caches the graph and does not re-read the DDS
# configuration once running; one started under a different CYCLONEDDS_URI
# sees an empty world. Stop it so the next call respawns it under this
# environment.
sim_reset_ros2_daemon() { ros2 daemon stop >/dev/null 2>&1 || true; }

# Add `key:=value` unless the caller already set that key. Launch arguments
# are how a run differs from the default, so a default supplied here must
# never beat one the user typed.
sim_default_arg() {   # sim_default_arg <args-string> <key:=value>
    local args="$1" pair="$2" key="${2%%:=*}"
    case " ${args} " in
        *" ${key}:="*) printf '%s' "${args}" ;;
        *) printf '%s %s' "${pair}" "${args}" ;;
    esac
}
