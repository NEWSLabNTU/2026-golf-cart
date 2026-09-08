# Middleware selection and the Zenoh router lifecycle.
#
# Which RMW this host runs is config/runtime.conf's GOLFCART_RMW, not a flag:
# both machines have to agree, and the two middlewares share no wire protocol,
# so a mismatched pair does not fail -- it comes up cleanly and never sees the
# other side's topics. See config/zenoh/README.md.

# Show the effective middleware, its config, and the daemon state
[no-cd]
status:
    @{{justfile_directory()}}/scripts/rmw/ensure.sh --status

# Check preconditions and fix what can be fixed (what every launch path calls)
[no-cd]
ensure:
    @{{justfile_directory()}}/scripts/rmw/ensure.sh

# Run this host's Zenoh router in the foreground. Ctrl-C stops it.
#
# The supervised path is the systemd unit (`just service install master`), which
# is what `just launch` starts on its own. This is for a bench run, or for
# watching what the router says while chasing a discovery problem.
[no-cd]
router:
    @{{justfile_directory()}}/scripts/zenoh/router_unit_exec.sh

# Stop the ros2 daemon. Needed after changing GOLFCART_RMW by hand.
#
# The daemon binds its middleware at startup and keeps it for its whole life,
# and its port is 11511 + ROS_DOMAIN_ID with no RMW in it -- so a daemon from the
# other setting sits on the same port and answers `ros2 topic list` from a
# middleware where nothing is published. Nothing errors; the graph is just empty.
# `just launch` handles this for you; a bare `ros2 topic list` does not.
[no-cd]
daemon-stop:
    @ros2 daemon stop 2>/dev/null || true
    @pkill -f 'ros2cli\.daemon' 2>/dev/null || true
    @echo "ros2 daemon stopped; the next ros2 command respawns it on the current RMW."

# Regenerate config/zenoh/*.json5 from the installed rmw_zenoh_cpp defaults
[no-cd]
regen:
    @{{justfile_directory()}}/scripts/zenoh/generate_profiles.sh

# Fail if config/zenoh/ has drifted from the installed rmw_zenoh_cpp defaults
[no-cd]
check:
    @{{justfile_directory()}}/scripts/zenoh/generate_profiles.sh --check

# What this host's Zenoh sessions are actually connected to.
#
# The single most useful command when master and orin cannot see each other: it
# lists the peers and routers this host has LINKS to, which is a different
# question from what discovery told it exists. An orin that shows only its own
# router has not federated; see config/zenoh/README.md.
[no-cd]
peers:
    #!/usr/bin/env bash
    set -uo pipefail
    if ! timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/7447' 2>/dev/null; then
        echo "No Zenoh router listening on 127.0.0.1:7447 on this host." >&2
        echo "Start one:  just rmw router" >&2
        exit 1
    fi
    # The router's REST plugin is not enabled in rmw_zenoh's shipped config, so
    # there is no HTTP endpoint to ask. `ros2 node list` is the portable stand-in:
    # under zenoh it is answered through the same gossip that peering depends on,
    # so a node from the far host appearing here IS the federation working.
    echo "Nodes visible from this host (empty across hosts => routers not federated):"
    ros2 node list 2>/dev/null | sed 's/^/  /'
    echo
    echo "TCP links on the Zenoh port:"
    ss -tnp 2>/dev/null | awk 'NR==1 || /:7447/' | sed 's/^/  /'
