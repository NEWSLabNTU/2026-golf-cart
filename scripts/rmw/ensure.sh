#!/usr/bin/env bash
# The one middleware precondition check that every launch path calls.
#
#     scripts/rmw/ensure.sh          # fix what can be fixed, explain what cannot
#     scripts/rmw/ensure.sh --status # report only, change nothing, always exit 0
#
# It replaces the direct call to scripts/iceoryx/ensure_roudi.sh in the launch
# recipes, and dispatches to that or to scripts/zenoh/ensure_router.sh depending
# on GOLFCART_RMW. It also does the one thing neither of those can: deal with a
# ros2 daemon left behind by the OTHER middleware.
#
# THE DAEMON
#
# ros2cli's daemon binds its RMW when it starts and keeps it for its whole life
# (default: 2 hours of inactivity). Its XML-RPC port is 11511 + ROS_DOMAIN_ID and
# NOTHING ELSE -- not the RMW -- so a daemon started under CycloneDDS and a
# daemon started under Zenoh contend for the same port, and the CLI talks to
# whichever one is already there without ever checking which middleware it
# speaks.
#
# The result of switching GOLFCART_RMW with a daemon still running is therefore
# not an error. It is `ros2 topic list` printing /parameter_events and /rosout
# while the full stack is up and healthy on the other middleware. Every
# instrument you would reach for to diagnose a launch -- topic list, node list,
# topic hz, topic echo -- reports the same empty world, so the evidence points at
# the launch rather than at the CLI.
#
# `ros2 daemon stop` is enough to fix it, and reaches the daemon regardless of
# which RMW either side is using, precisely because the port does not depend on
# the RMW.
set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1

# Resolve the intended middleware and the helper functions in one subshell-free
# source, so golfcart_daemon_rmw is available here.
if [ -z "${GOLFCART_RMW:-}" ] || ! declare -F golfcart_daemon_rmw >/dev/null 2>&1; then
    saved="$-"; set +eu
    # shellcheck source=/dev/null
    GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 . "${REPO_ROOT}/scripts/env.sh"
    case "$saved" in *e*) set -e ;; esac
    case "$saved" in *u*) set -u ;; esac
fi

WANT_RMW="${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}"
HAVE_RMW="$(golfcart_daemon_rmw)"

if [ "${STATUS_ONLY}" = "1" ]; then
    printf 'GOLFCART_RMW       %s\n' "${GOLFCART_RMW:-cyclonedds}"
    printf 'RMW_IMPLEMENTATION %s\n' "${WANT_RMW}"
    printf 'host role          %s (from %s)\n' \
        "${GOLFCART_HOST:-?}" "${GOLFCART_DDS_PROFILE_SOURCE:-?}"
    case "${GOLFCART_RMW:-cyclonedds}" in
        zenoh)
            printf 'session config     %s\n' "${ZENOH_SESSION_CONFIG_URI:-(unset - rmw_zenoh defaults)}"
            printf 'router config      %s\n' "${ZENOH_ROUTER_CONFIG_URI:-(unset - rmw_zenoh defaults)}"
            if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7447' 2>/dev/null; then
                printf 'local router       UP on 127.0.0.1:7447\n'
            else
                printf 'local router       DOWN - nodes will not discover each other\n'
            fi
            ;;
        *)
            printf 'CYCLONEDDS_URI     %s\n' "${CYCLONEDDS_URI:-(unset)}"
            ;;
    esac
    if [ -z "${HAVE_RMW}" ]; then
        printf 'ros2 daemon        not running\n'
    elif [ "${HAVE_RMW}" = "${WANT_RMW}" ]; then
        printf 'ros2 daemon        running, %s (matches)\n' "${HAVE_RMW}"
    else
        printf 'ros2 daemon        running, %s -- MISMATCH, graph queries will be empty\n' "${HAVE_RMW}"
    fi
    exit 0
fi

# ── Daemon ───────────────────────────────────────────────────────────────────
if [ -n "${HAVE_RMW}" ] && [ "${HAVE_RMW}" != "${WANT_RMW}" ]; then
    echo "ros2 daemon is running under ${HAVE_RMW}, but this host is set to ${WANT_RMW}." >&2
    echo "Stopping it; the CLI will respawn one on the right middleware." >&2
    ros2 daemon stop >/dev/null 2>&1 || true
    # Verify rather than trust. `ros2 daemon stop` asks politely over XML-RPC and
    # reports success on a daemon that has stopped answering but not yet exited;
    # leaving one alive here would defeat the entire point of this check.
    for _ in $(seq 1 25); do
        [ -z "$(golfcart_daemon_rmw)" ] && break
        sleep 0.2
    done
    if [ -n "$(golfcart_daemon_rmw)" ]; then
        echo "  it did not exit; killing it." >&2
        pkill -f 'ros2cli\.daemon' 2>/dev/null || true
        sleep 0.5
    fi
fi

# ── Transport-specific preconditions ─────────────────────────────────────────
case "${GOLFCART_RMW:-cyclonedds}" in
    zenoh)
        "${REPO_ROOT}/scripts/zenoh/ensure_router.sh" || exit 1
        ;;
    *)
        # No-op unless the resolved CycloneDDS profile enables <SharedMemory>,
        # which it does not today.
        "${REPO_ROOT}/scripts/iceoryx/ensure_roudi.sh" || exit 1
        ;;
esac

exit 0
