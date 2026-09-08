#!/usr/bin/env bash
# Make sure this host's Zenoh router is up before anything opens a session.
#
# Analogous to scripts/iceoryx/ensure_roudi.sh, and for the same reason: a
# transport precondition that fails SILENTLY is worse than one that fails loudly,
# so every foreground path checks it first.
#
# What goes wrong without a router. rmw_zenoh's session config ships with
# multicast scouting DISABLED, so a node's only way to learn that other nodes
# exist is gossip from the router it connects to on tcp/localhost:7447. With no
# router, node startup does not fail -- it prints
#
#     Unable to connect to a Zenoh router after 1 attempt(s) ... Proceeding
#     with initialization but other peers will not discover or receive data
#     from peers in this session until a router is started.
#
# once, at debug-ish severity, in the middle of a launch that prints thousands of
# lines, and then every node runs happily and publishes into the void. There is
# no error, no crash, and no empty-topic symptom to grep for -- `ros2 topic list`
# just shows a graph with one node in it.
#
# Exit 0 when the router is up (or was started); 1 with an explanation when not.
set -uo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Follow the config rather than assuming, exactly as ensure_roudi.sh does: this
# is a no-op under CycloneDDS, so the launch recipe can call it unconditionally.
if [ -z "${GOLFCART_RMW:-}" ]; then
    GOLFCART_RMW=$(
        GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 \
        bash -c "source '${REPO_ROOT}/scripts/env.sh'; printf '%s' \"\${GOLFCART_RMW}\""
    ) || GOLFCART_RMW=cyclonedds
fi
[ "${GOLFCART_RMW}" = "zenoh" ] || exit 0

# Test what the sessions actually need -- a TCP listener on 7447 -- rather than
# `pgrep rmw_zenohd`. A router that is running but wedged before it bound its
# listener is indistinguishable from an absent one as far as every node on this
# host is concerned, and pgrep would call it healthy.
router_up() {
    timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7447' 2>/dev/null
}

router_up && exit 0

# Prefer the unit, so a router started here is supervised and stops with the rest
# rather than becoming an orphan nobody knows to clean up.
if systemctl --user cat golfcart-zenoh-router.service >/dev/null 2>&1; then
    echo "Zenoh router is not running; starting golfcart-zenoh-router.service..." >&2
    systemctl --user start golfcart-zenoh-router.service 2>/dev/null || true
    for _ in $(seq 1 50); do
        router_up && { echo "Zenoh router is ready." >&2; exit 0; }
        sleep 0.2
    done
fi

{
    echo ""
    echo "ERROR: GOLFCART_RMW=zenoh, but no Zenoh router is listening on"
    echo "       127.0.0.1:7447 on this host."
    echo ""
    echo "  Starting the stack in this state does not fail. Every node comes up,"
    echo "  publishes, and is seen by nobody -- multicast scouting is off in"
    echo "  rmw_zenoh's session config, so the router is the ONLY way nodes"
    echo "  discover each other."
    echo ""
    echo "  Install the unit (once per machine):"
    echo "      just service install master        # or: install-orin"
    echo ""
    echo "  Or start it by hand, in its own terminal:"
    echo "      just rmw router"
    echo ""
    echo "  Or go back to CycloneDDS, in config/runtime.conf:"
    echo "      GOLFCART_RMW=cyclonedds"
    echo ""
} >&2
exit 1
