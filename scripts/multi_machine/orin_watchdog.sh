#!/usr/bin/env bash
# orin_watchdog.sh - orin-side; stop the local stack when the master disappears.
#
# Covers the failure the ssh teardown cannot: network cut, AP/switch down, or the
# master hard powered off. In those cases orin_remote.sh never gets to run its
# stop, so without this the orin would keep running the ZED and its recorder
# indefinitely.
#
# Ping-based on purpose. A DDS heartbeat would cover no additional failure mode -
# "master dead, network up" is already handled by the ssh stop - while adding a
# ROS dependency to a process whose whole job is to survive ROS being broken.

set -euo pipefail

MASTER_IP="${GOLFCART_MASTER_IP:-192.168.125.100}"
INTERVAL="${GOLFCART_WATCHDOG_INTERVAL:-5}"
MAX_MISSES="${GOLFCART_WATCHDOG_MISSES:-6}"
UNIT="golfcart-orin.service"

log() { printf 'orin_watchdog: %s\n' "$1"; }

log "watching ${MASTER_IP} every ${INTERVAL}s, stopping ${UNIT} after ${MAX_MISSES} misses"

misses=0
while true; do
    if ping -c 1 -W 2 "${MASTER_IP}" >/dev/null 2>&1; then
        if (( misses > 0 )); then
            log "master reachable again after ${misses} miss(es)"
        fi
        misses=0
    else
        misses=$(( misses + 1 ))
        log "master unreachable (${misses}/${MAX_MISSES})"
    fi

    if (( misses >= MAX_MISSES )); then
        log "master gone for ~$(( MAX_MISSES * INTERVAL ))s - stopping ${UNIT}"
        # --no-block: this process is PartOf the unit being stopped, so a blocking
        # call would wait on its own termination.
        systemctl --user --no-block stop "${UNIT}"
        exit 0
    fi

    sleep "${INTERVAL}"
done
