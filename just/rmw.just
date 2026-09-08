# Middleware selection.
#
# Which RMW this host runs is config/runtime.conf's GOLFCART_RMW, not a flag:
# both machines have to agree, and the two middlewares share no wire protocol,
# so a mismatched pair does not fail -- it comes up cleanly and never sees the
# other side's topics. See config/zenoh/README.md.
#
# There is no router recipe. This deployment runs NO rmw_zenohd: peers discover
# each other by multicast scouting and link directly, the same shape as the
# CycloneDDS setup it replaces.

# Show the effective middleware, its config, and the daemon state
[no-cd]
status:
    @{{justfile_directory()}}/scripts/rmw/ensure.sh --status

# Check preconditions and fix what can be fixed (what every launch path calls)
[no-cd]
ensure:
    @{{justfile_directory()}}/scripts/rmw/ensure.sh

# The daemon binds its middleware at startup and keeps it for its whole life,
# and its port is 11511 + ROS_DOMAIN_ID with no RMW in it -- so a daemon from the
# other setting sits on the same port and answers `ros2 topic list` from a
# middleware where nothing is published. Nothing errors; the graph is just empty.
# `just launch` handles this for you; a bare `ros2 topic list` does not.

# Stop the ros2 daemon - needed after changing GOLFCART_RMW by hand
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

# The first thing to run when master and orin cannot see each other. Under zenoh
# the peer links ARE the data path, so a host with no links to the other machine
# has failed discovery, whatever the topic list says.

# Show what this host is actually linked to: nodes, peer links, multicast group
[no-cd]
peers:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "Nodes visible from this host (nothing from the far host => discovery failed):"
    ros2 node list 2>/dev/null | sed 's/^/  /'
    echo
    echo "Established peer links (zenoh peers listen on an ephemeral port, so"
    echo "these are matched by peer address rather than by a fixed port):"
    ss -tn state established 2>/dev/null \
      | awk 'NR==1 || /192\.168\.125\./' | sed 's/^/  /'
    echo
    echo "Multicast scouting group (224.0.0.224:7446) membership:"
    ip maddr show 2>/dev/null | grep -B3 '224\.0\.0\.224' | sed 's/^/  /' \
      || echo "  not joined - no zenoh peer is running on this host"
