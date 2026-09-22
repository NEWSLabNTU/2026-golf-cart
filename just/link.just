# The master/orin link.
#
# Both hosts run ONE DDS domain on the LAN. What keeps the link quiet is not a
# domain boundary but the multicast scope: config/cyclonedds/{master,orin}.xml
# set `AllowMulticast` to `spdp`, so multicast carries participant discovery
# only and every sample goes unicast to the readers that asked for it. A local
# reader's unicast locator is this host's own address, which the kernel routes
# over lo, so a cloud with three local readers never reaches the NIC.
#
# These recipes measure the wire and run the two-host simulation behind
# docs/research/system/link-multicast-scope.md.
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

# Topics visible on this host (one domain, so this is also what the other host
# can reach). `-v` shows publisher and subscriber counts per topic, which is
# what decides whether a writer would have used multicast under the old
# profiles.

# Topics, with publisher and subscriber counts
topics:
    ros2 topic list -v

# Nodes visible on this host
nodes:
    ros2 node list

# Rate of one topic: `just link hz /sensing/camera/zed/imu/data`
hz TOPIC:
    ros2 topic hz {{TOPIC}}

# Delay of one topic as it crosses the link (needs a header stamp)
delay TOPIC:
    ros2 topic delay {{TOPIC}}

# What the LAN interface carries, per second, for SECS seconds. The same
# instrument the simulation uses on its veth, so the numbers compare.
#
#   just link pressure                 # enP5p3s0 for 60 s
#   just link pressure eno1 120        # on the orin

# Bytes and packets per second on IFACE (default: the master's LAN NIC)
pressure IFACE="enP5p3s0" SECS="60":
    ./scripts/check/link_pressure.sh {{IFACE}} {{SECS}}

# Which multicast groups this host has actually joined, and on which interface.
# Under `spdp` the only DDS group that should appear on the LAN NIC is the SPDP
# one (239.255.0.1); a data group there means a profile did not take.

# Multicast group memberships per interface
groups:
    @echo "== IGMP memberships (/proc/net/igmp) =="
    @ip maddr show | grep -A2 -E '^[0-9]+:' | grep -E '^[0-9]+:|inet ' || true

# Two hosts, one wire, on this machine: network namespaces joined by a veth
# shaped to 100 Mbit/s, the REAL master stack (golfcart.launch.yaml
# host:=master, drivers replaced by publishers with the real sizes and rates)
# and the real recorders on both sides. No root.
#
# Both modes run ONE domain and the SAME graph. The only difference is
# AllowMulticast, and run.sh derives both profiles from config/cyclonedds so
# that stays true; OUT_DIR/profiles.diff is the proof.
#
#   just link sim baseline                                     # AllowMulticast default
#   just link sim spdp                                         # AllowMulticast spdp
#   LINK_SIM_RVIZ=1 just link sim baseline                     # + the real RViz on the master
#   LINK_SIM_RVIZ=1 LINK_SIM_ZED_IMAGE=1 just link sim spdp    # + RViz showing the ZED image
#   just link sim-compare log/link_sim/baseline_<ts> log/link_sim/spdp_<ts>
#   just link sim-matrix log/link_sim/*                        # one table, both directions
#
# Needs `just build` first; each run writes two bags (several GB) under its
# OUT_DIR. LINK_SIM_STARTUP / LINK_SIM_STEADY (seconds) shorten it;
# LINK_SIM_LINK_RATE changes the shaping (e.g. 1gbit for the interlink). RViz
# needs TurboVNC's Xvnc, which the setup's turbovnc step installs.

# Run the two-host link simulation: MODE is baseline or spdp
sim MODE:
    ./scripts/testing/link_sim/run.sh {{MODE}}

# Side-by-side tables from two simulation runs
sim-compare BASELINE SPDP:
    ./scripts/testing/link_sim/summarize.py {{BASELINE}} {{SPDP}}

# One table across any number of runs: both directions, drops, scans kept
sim-matrix +RUNS:
    ./scripts/testing/link_sim/matrix.py {{RUNS}}
