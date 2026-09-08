#!/usr/bin/env bash
# ExecStart for golfcart-zenoh-router.service.
#
# A wrapper rather than an ExecStart straight at the binary, for the same reason
# roudi_unit_exec.sh is one: the installer's drop-in writes a bare
# "ExecStart=<path>" with no arguments, so anything that needs an environment
# needs a script.
#
# The router is a HARD dependency of every ROS process once GOLFCART_RMW=zenoh.
# rmw_zenoh ships with multicast scouting disabled, so gossip from this router is
# the only way nodes learn that other nodes exist. With it absent, nothing fails
# and nothing hangs - every node comes up and publishes to nobody. See
# scripts/zenoh/ensure_router.sh.
set -euo pipefail

WORKSPACE="${GOLFCART_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"

export GOLFCART_ENV_QUIET=1
# The router creates no ROS node and no DDS participant, so the readiness gate
# in env.sh would be circular here in exactly the way it is for RouDi: the check
# exists to protect ROS processes, and this is the process they wait on.
export GOLFCART_SKIP_DDS_CHECK=1
# shellcheck source=/dev/null
source "${WORKSPACE}/scripts/env.sh"

if [ "${GOLFCART_RMW:-cyclonedds}" != "zenoh" ]; then
    echo "router_unit_exec: GOLFCART_RMW=${GOLFCART_RMW:-cyclonedds}, not zenoh." >&2
    echo "                  Nothing to run. Set it in config/runtime.conf." >&2
    exit 1
fi

# env.sh exported ZENOH_ROUTER_CONFIG_URI for the master/orin roles and left it
# UNSET for loopback, where rmw_zenoh's shipped default is exactly what is
# wanted. Both are correct; only a URI naming a file that does not exist is not,
# and rmw_zenohd's own failure for that is a Rust panic about a missing path,
# which reads as a broken binary rather than a broken config.
if [ -n "${ZENOH_ROUTER_CONFIG_URI:-}" ] && [ ! -f "${ZENOH_ROUTER_CONFIG_URI}" ]; then
    echo "router_unit_exec: ZENOH_ROUTER_CONFIG_URI points at a missing file:" >&2
    echo "                  ${ZENOH_ROUTER_CONFIG_URI}" >&2
    echo "                  Regenerate it:  scripts/zenoh/generate_profiles.sh" >&2
    exit 1
fi

ROUTER="$(command -v rmw_zenohd || echo /opt/ros/humble/lib/rmw_zenoh_cpp/rmw_zenohd)"
if [ ! -x "${ROUTER}" ]; then
    echo "router_unit_exec: rmw_zenohd not found. Install it with:" >&2
    echo "                  sudo apt install ros-humble-rmw-zenoh-cpp" >&2
    exit 1
fi

echo "zenoh router: role=${GOLFCART_HOST} config=${ZENOH_ROUTER_CONFIG_URI:-<rmw_zenoh default>}" >&2
exec "${ROUTER}"
