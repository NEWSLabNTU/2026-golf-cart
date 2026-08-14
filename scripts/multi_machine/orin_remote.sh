#!/usr/bin/env bash
# orin_remote.sh - master-side control of units on the orin (slave) host.
#
# Deliberately NOT a launch entry. play_launch 0.5.1 drops `executable:` actions
# from its replay and runs them during the dump phase instead, where a long-lived
# process blocks the dump forever; see docs/design/multi_machine_deployment.md
# (Amendments). The orchestrator is also not a ROS node, so it is driven from the
# `just launch-master` recipe with a shell EXIT trap.
#
# The mechanism is ssh + `systemctl --user`. A ROS service or topic was rejected:
# it would only work while DDS is healthy and something is running to host it,
# coupling recording to exactly the thing it has to stay independent of
# (docs/design/orin_provisioning_implementation_plan.md section 4.4).
#
# Key-based ssh is mandatory, not a convenience: every call here uses
# BatchMode=yes so it fails in five seconds instead of hanging on a password
# prompt no caller has a terminal to answer. Run scripts/multi_machine/setup_ssh.sh
# once per master.
#
# Usage:
#   orin_remote.sh [--required|--optional] <verb> [unit...]
#
#   verbs:
#     start  <unit>...    restart the units (a stale unit from a previous run is
#                         replaced), after waiting for the orin to come up
#     stop   <unit>...    stop the units
#     status [unit]...    print is-active for the units (default: all of them)
#     ping                reachability probe only; exit 0 if the orin answers
#
#   units (alias -> unit file):
#     launch    -> golfcart-launch.service
#     record    -> golfcart-record.service
#     watchdog  -> golfcart-watchdog.service
#   A full `name.service` is also accepted verbatim.
#
# Failure policy, and why it differs per unit:
#   A missing or unreachable orin must never block or fail the master. So for
#   `launch` (and `watchdog`) an unreachable orin is a loud warning and exit 0.
#   Recording is the documented exception (section 4.6): the master still records
#   on its own, but a half-recorded session is a result you must not discover
#   later, so the failure is reported and the exit status is non-zero. Override
#   either way with --required / --optional before the verb.
#
# Exit codes: 0 ok (or a tolerated absent orin), 1 remote failure on a required
# unit, 2 usage error.
#
# Legacy forms still accepted, so the pre-split callers keep working:
#   orin_remote.sh start [true|false]   # true also starts the recorder
#   orin_remote.sh stop                 # stops the launch unit only
#
# Environment:
#   GOLFCART_ORIN_SSH   ssh destination for the orin, overrides ORIN_SSH from
#                       config/multi_machine.conf
#   GOLFCART_ORIN_WAIT  seconds to wait for the orin to become reachable (60)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${REPO_ROOT}/config/multi_machine.conf"
# One tracked copy of the destination, shared with the watchdog and bag_fetch;
# absent conf falls through to the same default the conf ships with.
# shellcheck source=/dev/null
[ -f "${CONF}" ] && . "${CONF}"

ORIN="${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}"
WAIT="${GOLFCART_ORIN_WAIT:-60}"

WATCHDOG_UNIT="golfcart-watchdog.service"
ALL_UNITS=(golfcart-launch.service golfcart-record.service "${WATCHDOG_UNIT}")

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

# The golf cart key lives at a dedicated, non-default path so setup_ssh.sh never
# has to touch the user's own id_* keys. ssh only tries default names by itself,
# so that path has to be named explicitly here or it is invisible - which is how
# a key that worked by hand (held by the desktop agent) failed under systemd,
# where there is no agent. Added only when present, so a host that has not run
# setup_ssh.sh yet still falls back to the default keys and the agent.
ORIN_KEY="${ORIN_SSH_KEY:-${GOLFCART_ORIN_SSH_KEY:-${HOME}/.ssh/golfcart_orin}}"
[ -f "${ORIN_KEY}" ] && SSH_OPTS+=(-i "${ORIN_KEY}")

log() { printf 'orin_remote: %s\n' "$1" >&2; }

usage() {
    echo "Usage: $0 [--required|--optional] <start|stop|status|ping> [unit...]" >&2
    echo "       units: launch | record | watchdog | <name>.service" >&2
    exit 2
}

# Alias -> unit file. Anything already ending in .service passes through, so a
# unit this script has never heard of can still be driven without editing it.
resolve_unit() {
    case "$1" in
      launch)    echo "golfcart-launch.service" ;;
      record)    echo "golfcart-record.service" ;;
      watchdog)  echo "${WATCHDOG_UNIT}" ;;
      *.service) echo "$1" ;;
      *)         log "ERROR: unknown unit '$1'"; exit 2 ;;
    esac
}

wait_for_orin() {
    local deadline=$(( SECONDS + WAIT ))
    while (( SECONDS < deadline )); do
        if ssh "${SSH_OPTS[@]}" "${ORIN}" true 2>/dev/null; then
            return 0
        fi
        sleep 3
    done
    return 1
}

# --- argument parsing -------------------------------------------------------

REQUIRED=""   # empty = decide from the unit list

while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --required) REQUIRED=1 ;;
      --optional) REQUIRED=0 ;;
      *) usage ;;
    esac
    shift
done

VERB="${1:-}"
shift || true

case "${VERB}" in
  start|stop|status|ping) ;;
  *) usage ;;
esac

UNITS=()

# Legacy `start true|false`: the recording flag used to be a second positional
# argument, back when one unit carried both jobs.
if [[ "${VERB}" == "start" && "${1:-}" =~ ^(true|false)$ ]]; then
    UNITS=(golfcart-launch.service)
    if [[ "$1" == "true" ]]; then
        UNITS+=(golfcart-record.service)
    fi
    shift
else
    for arg in "$@"; do
        # Explicit `|| exit`: resolve_unit runs in a command substitution, where
        # its own exit only ends the subshell and would otherwise append an
        # empty unit name.
        unit="$(resolve_unit "${arg}")" || exit 2
        UNITS+=("${unit}")
    done
fi

if (( ${#UNITS[@]} == 0 )); then
    case "${VERB}" in
      # Bare `stop` is the legacy teardown from the launch-master trap: it stops
      # the launch and nothing else. It must not reach the recorder - recording
      # outlives the stack on purpose, and a trap firing on Ctrl-C would
      # otherwise silently end a session the operator is still recording.
      start|stop) UNITS=(golfcart-launch.service) ;;
      status)     UNITS=("${ALL_UNITS[@]}") ;;
    esac
fi

# Default policy: required as soon as the recorder is involved, tolerant
# otherwise. See the failure-policy note in the header.
if [[ -z "${REQUIRED}" ]]; then
    REQUIRED=0
    for u in "${UNITS[@]}"; do
        if [[ "${u}" == "golfcart-record.service" ]]; then
            REQUIRED=1
        fi
    done
fi

# Report an orin-side failure with the severity the unit list calls for.
fail() {
    if (( REQUIRED )); then
        log "ERROR: $1"
        exit 1
    fi
    log "WARNING: $1 - continuing without the orin"
    exit 0
}

# --- verbs ------------------------------------------------------------------

case "${VERB}" in
  ping)
    # No wait loop: this is the "is it there right now" probe for doctor-style
    # callers, which want an answer, not a minute of patience.
    if ssh "${SSH_OPTS[@]}" "${ORIN}" true 2>/dev/null; then
        log "${ORIN} reachable"
        exit 0
    fi
    log "${ORIN} unreachable"
    exit 1
    ;;

  start)
    log "waiting for ${ORIN} (up to ${WAIT}s)..."
    wait_for_orin || fail "${ORIN} unreachable after ${WAIT}s"

    # The watchdog is started, never restarted, and started alongside whatever
    # else is going up: it is now its own unit guarding every golfcart-* unit
    # (section 4.5), so restarting it here would reset the guard on a recording
    # that is already running. It exits by itself once nothing is left to guard.
    START_CMD="systemctl --user start ${WATCHDOG_UNIT}"
    for u in "${UNITS[@]}"; do
        if [[ "${u}" != "${WATCHDOG_UNIT}" ]]; then
            # restart, not start: a unit left behind by a previous run is
            # replaced rather than silently kept.
            START_CMD="${START_CMD} && systemctl --user restart ${u}"
        fi
    done

    log "starting on ${ORIN}: ${UNITS[*]}"
    if ! ssh "${SSH_OPTS[@]}" "${ORIN}" "${START_CMD}"; then
        fail "failed to start ${UNITS[*]} on ${ORIN}"
    fi
    log "started: ${UNITS[*]}"
    ;;

  stop)
    log "stopping on ${ORIN}: ${UNITS[*]}"
    # Best-effort for the tolerant units: if the orin or the network is already
    # gone, its watchdog stops everything locally, so a failure here is not an
    # error worth propagating. For the recorder it is - an orin that keeps
    # recording while the link is merely flaky (master still pingable, so the
    # watchdog never fires) fills its disk unattended.
    if ! ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "systemctl --user stop ${UNITS[*]}" 2>/dev/null; then
        fail "could not reach ${ORIN} to stop ${UNITS[*]}"
    fi
    ;;

  status)
    # is-active exits non-zero for anything inactive, which is information here,
    # not an error - print it and move on.
    ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "systemctl --user is-active ${UNITS[*]}" || true
    ;;
esac
