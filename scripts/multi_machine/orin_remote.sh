#!/usr/bin/env bash
# orin_remote.sh - master-side control of the orin (slave) host's stack.
#
# Deliberately NOT a launch entry. play_launch 0.5.1 drops `executable:` actions
# from its replay and runs them during the dump phase instead, where a long-lived
# process blocks the dump forever; see docs/design/multi_machine_deployment.md
# (Amendments). The orchestrator is also not a ROS node, so it is driven from the
# `just launch-master` recipe with a shell EXIT trap.
#
# Usage:
#   orin_remote.sh start [true|false]   # second argument enables recording
#   orin_remote.sh stop
#   orin_remote.sh status
#
# Environment:
#   GOLFCART_ORIN_SSH   ssh destination for the orin (default jetson@192.168.125.101)
#   GOLFCART_ORIN_WAIT  seconds to wait for the orin to become reachable (default 60)

set -euo pipefail

ORIN="${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}"
WAIT="${GOLFCART_ORIN_WAIT:-60}"
UNIT="golfcart-orin.service"
WATCHDOG="golfcart-orin-watchdog.service"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

log() { printf 'orin_remote: %s\n' "$1" >&2; }

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

case "${1:-}" in
  start)
    RECORD="${2:-false}"
    log "waiting for ${ORIN} (up to ${WAIT}s)..."
    if ! wait_for_orin; then
        # Deliberately non-fatal: the master stack is useful on its own, and the
        # design calls for the master to be unaffected when the orin is absent.
        log "ERROR: ${ORIN} unreachable after ${WAIT}s - continuing without it"
        exit 1
    fi
    log "starting ${UNIT} (record=${RECORD})"
    # set-environment before restart so the unit picks up the recording flag;
    # restart rather than start so a stale unit from a previous run is replaced.
    ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "systemctl --user set-environment GOLFCART_RECORD=${RECORD} && \
         systemctl --user restart ${UNIT} && \
         systemctl --user restart ${WATCHDOG}"
    log "orin stack started"
    ;;

  stop)
    log "stopping ${UNIT} on ${ORIN}"
    # Best-effort: if the orin or the network is already gone, its watchdog stops
    # the unit locally, so a failure here is not an error worth propagating.
    if ! ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "systemctl --user stop ${WATCHDOG} ${UNIT}" 2>/dev/null; then
        log "could not reach ${ORIN} to stop it - its watchdog will do so locally"
    fi
    ;;

  status)
    ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "systemctl --user is-active ${UNIT} ${WATCHDOG}" || true
    ;;

  *)
    echo "Usage: $0 <start [record]|stop|status>" >&2
    exit 2
    ;;
esac
