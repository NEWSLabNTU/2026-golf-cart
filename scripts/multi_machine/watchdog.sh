#!/usr/bin/env bash
# watchdog.sh - orin-side; stop the local golfcart units when the master vanishes.
#
# Covers the failure the ssh teardown cannot: network cut, AP/switch down, or the
# master hard powered off. In those cases orin_remote.sh never gets to run its
# stop, so without this the orin would keep running the ZED - and, since
# recording was split into its own unit, keep filling its disk with a bag nobody
# is left to close.
#
# Ping-based on purpose. A DDS heartbeat would cover no additional failure mode -
# "master dead, network up" is already handled by the ssh stop - while adding a
# ROS dependency to a process whose whole job is to survive ROS being broken.
#
# This unit is independent (no PartOf=); it manages its own exit instead. See
# docs/design/orin_provisioning_implementation_plan.md section 4.5.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"

# The deployment's addresses live in one tracked file rather than a hardcoded
# copy per script. It may legitimately be absent (fresh checkout, or a machine
# provisioned before that file existed), so the old default still stands behind
# it, and an explicit environment override still wins over both.
CONF="${REPO_DIR}/config/multi_machine.conf"
if [ -f "${CONF}" ]; then
    # shellcheck disable=SC1090
    source "${CONF}"
fi

MASTER_IP="${GOLFCART_MASTER_IP:-${MASTER_IP:-192.168.125.100}}"
INTERVAL="${GOLFCART_WATCHDOG_INTERVAL:-5}"
MAX_MISSES="${GOLFCART_WATCHDOG_MISSES:-6}"
SELF_UNIT="golfcart-watchdog.service"
# The watchdog can be started a moment before the unit it is protecting, so
# "nothing active" is only a shutdown signal after this window has passed.
STARTUP_GRACE="${GOLFCART_WATCHDOG_STARTUP_GRACE:-60}"

log() { printf 'watchdog: %s\n' "$1"; }

# Every golfcart-* unit that is up, minus this one. Stopping ourselves here would
# race our own exit for no benefit, and systemd stops us anyway once we return.
active_units() {
    systemctl --user list-units --no-legend --plain 'golfcart-*.service' 2>/dev/null \
        | awk -v self="${SELF_UNIT}" '($3 == "active" || $3 == "activating") && $1 != self { print $1 }'
}

# Each cycle costs the ping timeout (2s) plus INTERVAL, so the real time to fire
# is MAX_MISSES * (INTERVAL + 2) - about 42s at the defaults, not 30s.
log "watching ${MASTER_IP} every ${INTERVAL}s, stopping all golfcart-* units after ${MAX_MISSES} misses (~$(( MAX_MISSES * (INTERVAL + 2) ))s)"

misses=0
started_at="${SECONDS}"
while true; do
    units="$(active_units)"

    if [ -z "${units}" ]; then
        # Nothing left to protect. Exit rather than ping forever: this machine may
        # simply be in use standalone, and a watchdog that outlives its units
        # would stop the next launch's units the moment the master is unreachable
        # for an unrelated reason.
        if (( SECONDS - started_at >= STARTUP_GRACE )); then
            log "no golfcart-* unit active - nothing to watch, exiting"
            exit 0
        fi
    elif ping -c 1 -W 2 "${MASTER_IP}" >/dev/null 2>&1; then
        if (( misses > 0 )); then
            log "master reachable again after ${misses} miss(es)"
        fi
        misses=0
    else
        misses=$(( misses + 1 ))
        log "master unreachable (${misses}/${MAX_MISSES})"
    fi

    if (( misses >= MAX_MISSES )); then
        log "master gone for ~$(( MAX_MISSES * (INTERVAL + 2) ))s - stopping: ${units//$'\n'/ }"
        # --no-block: a stop of golfcart-record.service blocks for as long as the
        # bag takes to finalize (its TimeoutStopSec is minutes), and we do not
        # want the remaining units held hostage by that.
        # shellcheck disable=SC2086
        systemctl --user --no-block stop ${units}
        exit 0
    fi

    sleep "${INTERVAL}"
done
