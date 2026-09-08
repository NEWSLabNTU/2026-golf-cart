#!/usr/bin/env bash
# The one middleware precondition check that every launch path calls.
#
#     scripts/rmw/ensure.sh          # fix what can be fixed, explain what cannot
#     scripts/rmw/ensure.sh --status # report only, change nothing, always exit 0
#
# It replaces the direct call to scripts/iceoryx/ensure_roudi.sh in the launch
# recipes, and dispatches on GOLFCART_RMW. It also does the one thing neither
# middleware's own check can: deal with a ros2 daemon left behind by the OTHER
# middleware.
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

# The address the zenoh session profile binds, and the interface that owns it.
# Discovery is multicast here -- there is no router -- so an interface without
# the MULTICAST flag means nodes never find each other, silently.
zenoh_listen_addr() {
    [ -n "${ZENOH_SESSION_CONFIG_URI:-}" ] || return 1
    sed -n 's|^ *"tcp/\([0-9.]*\):0".*|\1|p' "${ZENOH_SESSION_CONFIG_URI}" | head -1
}
zenoh_iface_for() {
    ip -o addr show 2>/dev/null | awk -v a="$1" '$4 ~ "^"a"/" {print $2; exit}'
}

if [ "${STATUS_ONLY}" = "1" ]; then
    printf 'GOLFCART_RMW       %s\n' "${GOLFCART_RMW:-cyclonedds}"
    printf 'RMW_IMPLEMENTATION %s\n' "${WANT_RMW}"
    printf 'host role          %s (from %s)\n' \
        "${GOLFCART_HOST:-?}" "${GOLFCART_DDS_PROFILE_SOURCE:-?}"
    case "${GOLFCART_RMW:-cyclonedds}" in
        zenoh)
            printf 'session config     %s\n' "${ZENOH_SESSION_CONFIG_URI:-(unset - rmw_zenoh defaults, which expect a router)}"
            addr="$(zenoh_listen_addr || true)"
            if [ -n "$addr" ]; then
                iface="$(zenoh_iface_for "$addr")"
                printf 'listen address     %s (%s)\n' "$addr" "${iface:-no interface has this address}"
                if [ -n "$iface" ] && ip link show "$iface" 2>/dev/null | grep -q MULTICAST; then
                    printf 'discovery          multicast, %s has MULTICAST\n' "$iface"
                else
                    printf 'discovery          multicast, but %s lacks MULTICAST - nodes will not find each other\n' "${iface:-?}"
                fi
            else
                printf 'discovery          rmw_zenoh defaults (router on localhost:7447)\n'
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
        # No router to start -- discovery is multicast. What CAN be wrong is the
        # interface: the session profile advertises a fixed LAN address, and if
        # nothing owns it, or the interface carrying it has no MULTICAST flag,
        # every node comes up and discovers nobody with no error anywhere.
        addr="$(zenoh_listen_addr || true)"
        if [ -n "$addr" ]; then
            iface="$(zenoh_iface_for "$addr")"
            if [ -z "$iface" ]; then
                {
                    echo ""
                    echo "ERROR: the zenoh session profile binds ${addr}, but no interface"
                    echo "       on this host has that address."
                    echo "         ${ZENOH_SESSION_CONFIG_URI}"
                    echo "       Nodes would start, publish, and discover nobody."
                    echo "       Check the LAN is up, or regenerate the profiles after"
                    echo "       fixing config/multi_machine.conf:"
                    echo "           scripts/zenoh/generate_profiles.sh"
                    echo ""
                } >&2
                exit 1
            fi
            if ! ip link show "$iface" 2>/dev/null | grep -q MULTICAST; then
                {
                    echo ""
                    echo "ERROR: ${iface} (${addr}) has no MULTICAST flag."
                    echo "       This deployment runs no Zenoh router, so multicast"
                    echo "       scouting is the only way nodes discover each other."
                    echo "       Enable it:  sudo ip link set ${iface} multicast on"
                    echo ""
                } >&2
                exit 1
            fi
        fi
        ;;
    *)
        # No-op unless the resolved CycloneDDS profile enables <SharedMemory>,
        # which it does not today.
        "${REPO_ROOT}/scripts/iceoryx/ensure_roudi.sh" || exit 1
        ;;
esac

exit 0
