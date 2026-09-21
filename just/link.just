# The master/orin link.
#
# Under the master and orin profiles domain 0 is bound to `lo` and cannot reach
# the wire; only the link domain (GOLFCART_LINK_DOMAIN_ID, config/runtime.conf)
# is on the LAN, and its only participant per host is golfcart_domain_bridge,
# which copies config/link/topics.yaml across. These recipes look at that
# domain, measure the wire, and run the two-host simulation that produced
# docs/research/system/domain-split-link-pressure.md.
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory and every ./scripts/... path
# breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so `default` has to come first and has to be the harmless one.
# List this module's recipes
default:
    @just --list link

# The link domain is a different ROS domain, so a bare `ros2 topic list` (domain
# 0, on lo) never shows it. These set ROS_DOMAIN_ID for one command. The daemon
# is per domain too (port 11511 + id), so the first call starts one.

# Topics on the wire: `ros2 topic list` in the link domain
topics:
    ROS_DOMAIN_ID="${GOLFCART_LINK_DOMAIN_ID:-42}" ros2 topic list -v

# Nodes on the wire: should be exactly the two bridges
nodes:
    ROS_DOMAIN_ID="${GOLFCART_LINK_DOMAIN_ID:-42}" ros2 node list

# Rate of one topic as it crosses the link: `just link hz /sensing/camera/zed/imu/data`
hz TOPIC:
    ROS_DOMAIN_ID="${GOLFCART_LINK_DOMAIN_ID:-42}" ros2 topic hz {{TOPIC}}

# Delay of one topic as it crosses the link (needs a header stamp)
delay TOPIC:
    ROS_DOMAIN_ID="${GOLFCART_LINK_DOMAIN_ID:-42}" ros2 topic delay {{TOPIC}}

# What the LAN interface carries, per second, for SECS seconds. The same
# instrument the simulation uses on its veth, so the numbers compare.
#
#   just link pressure                 # enP5p3s0 for 60 s
#   just link pressure eno1 120        # on the orin

# Bytes and packets per second on IFACE (default: the master's LAN NIC)
pressure IFACE="enP5p3s0" SECS="60":
    ./scripts/check/link_pressure.sh {{IFACE}} {{SECS}}

# The bridge on its own, for a host whose stack is not up (e.g. recording only,
# or checking the orin's topics reach here before launching anything). The
# launch starts one of these itself under host:=master / host:=orin; do not run
# both.

# Run the link bridge standalone for this host's role (from config/host)
bridge:
    ros2 run golfcart_domain_bridge domain_bridge --role "${GOLFCART_HOST}"

# Two hosts, one wire, on this machine: network namespaces joined by a veth,
# the real profiles, the real topic list, Autoware's planning simulator as the
# master load. No root. `baseline` runs the pre-split profiles frozen in
# scripts/testing/link_sim/baseline/; `split` runs what is checked in.
#
#   just link sim baseline
#   just link sim split
#   just link sim-compare log/link_sim/baseline_<ts> log/link_sim/split_<ts>
#
# LINK_SIM_STARTUP / LINK_SIM_STEADY (seconds) and LINK_SIM_STACK=none shorten
# it; LINK_SIM_BRIDGE_WS=<install dir> points at a scratch build of the bridge
# when the workspace is not built.

# Run the two-host link simulation: MODE is baseline or split
sim MODE:
    ./scripts/testing/link_sim/run.sh {{MODE}}

# Side-by-side tables from two simulation runs
sim-compare BASELINE SPLIT:
    ./scripts/testing/link_sim/summarize.py {{BASELINE}} {{SPLIT}}
