#!/usr/bin/env bash
# run.sh - two hosts, one wire, one measurement.
#
#   scripts/testing/link_sim/run.sh baseline|split [OUT_DIR]
#   just link sim baseline && just link sim split && just link sim-compare
#
# Builds a master and an orin out of two network namespaces joined by a veth
# pair, on the real addresses (192.168.125.100/.101) so the real
# config/cyclonedds/{master,orin}.xml profiles run unchanged, and measures
# what crosses the veth. `baseline` runs the pre-split profiles frozen in
# baseline/; `split` runs the current ones plus one golfcart_domain_bridge
# per host, reading the real config/link/topics.yaml.
#
# Needs no root. `unshare -Urn` gives an unprivileged user namespace in which
# this user is root over its own network namespaces, and that is enough for
# veth, nested namespaces, and a raw socket on the veth. The script re-executes
# itself under unshare; do not run it under sudo.
#
# The master runs Autoware's planning simulator (the real launch, ~136 nodes,
# ~550 topics: the discovery load), a synthetic LiDAR fan-out (fake_lidar.py:
# the byte load the planning simulator lacks), and probe.py, the IMU consumer.
# The orin runs fake_zed.py, the ZED's topics at the ZED's rates and sizes.
# Both hosts run `ros2 topic list` every 10 s, the way an operator does, and
# the master briefly `ros2 topic echo`es the ZED image once, the way an
# operator does by mistake.
#
# Everything measured is written under OUT_DIR:
#   link.csv          per-second veth counters (scripts/check/link_pressure.sh)
#   phases.txt        second offsets of startup / steady / echo windows
#   classes.txt       bytes by direction x domain x multicast|unicast (sniff.py)
#   probe.txt         IMU rate and latency at the master, orin rows seen
#   graph.txt         node and topic counts the orin's CLI sees
#   summary.md        the tables, from summarize.py
#   *.log             every process
#
# What "the simulation is not the vehicle" means here, so nobody over-reads
# it: the veth has no 100 Mb/s ceiling and drops nothing, so every byte the
# stacks offer is delivered and counted. That is the right instrument for
# "how much do they offer", which is what the split changes. It says nothing
# about what a saturated i226 does, and the CPU numbers are this machine's.
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
    baseline|split) ;;
    *) echo "usage: $0 baseline|split [OUT_DIR]" >&2; exit 64 ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd)
OUT="${2:-${REPO_ROOT}/log/link_sim/${MODE}_$(date +%Y%m%d_%H%M%S)}"

# Tunables
STARTUP="${LINK_SIM_STARTUP:-40}"      # s: stack coming up; discovery burst lives here
STEADY="${LINK_SIM_STEADY:-60}"        # s: measured window after startup
ECHO_AT="${LINK_SIM_ECHO_AT:-20}"      # s into steady: master echoes the ZED image
ECHO_FOR="${LINK_SIM_ECHO_FOR:-15}"    # s
CHURN_EVERY="${LINK_SIM_CHURN_EVERY:-10}"
STACK="${LINK_SIM_STACK:-planning}"    # planning | none
MASTER_IP=192.168.125.100
ORIN_IP=192.168.125.101

# ── re-exec inside a user+net namespace ──────────────────────────────────────
if [ "${LINK_SIM_INNER:-}" != "1" ]; then
    if ! unshare -Urn true 2>/dev/null; then
        echo "link_sim: unprivileged user namespaces are not available here" >&2
        echo "  (kernel.unprivileged_userns_clone=0 or an AppArmor restriction)" >&2
        exit 1
    fi
    mkdir -p "$OUT"
    export LINK_SIM_INNER=1
    exec unshare -Urn "$0" "$MODE" "$OUT"
fi

mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1
echo "link_sim: mode=$MODE out=$OUT startup=${STARTUP}s steady=${STEADY}s stack=$STACK"

# ── environment ──────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || exit 1
export GOLFCART_ENV_ROLE=master GOLFCART_ENV_QUIET=1
# ROS setup files read unbound variables; relax -u around them.
set +u
# shellcheck source=/dev/null
. ./scripts/env.sh
# A scratch build of the bridge (colcon --install-base) can be handed in when
# the workspace itself is not built, as on a laptop running only this.
if [ -n "${LINK_SIM_BRIDGE_WS:-}" ] && [ -f "${LINK_SIM_BRIDGE_WS}/setup.bash" ]; then
    # shellcheck source=/dev/null
    . "${LINK_SIM_BRIDGE_WS}/setup.bash"
fi
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
unset ROS_DOMAIN_ID

case "$MODE" in
    baseline)
        MASTER_URI="file://${SCRIPT_DIR}/baseline/master.xml"
        ORIN_URI="file://${SCRIPT_DIR}/baseline/orin.xml"
        ;;
    split)
        MASTER_URI="file://${REPO_ROOT}/config/cyclonedds/master.xml"
        ORIN_URI="file://${REPO_ROOT}/config/cyclonedds/orin.xml"
        # The binary itself, not `ros2 run`: the python wrapper in between
        # would be what receives the stop signal, and it does not pass
        # SIGTERM on.
        BRIDGE="$(ros2 pkg prefix golfcart_domain_bridge 2>/dev/null)/lib/golfcart_domain_bridge/domain_bridge"
        if [ ! -x "$BRIDGE" ]; then
            echo "link_sim: golfcart_domain_bridge is not built (just build, or LINK_SIM_BRIDGE_WS=)" >&2
            exit 1
        fi
        ;;
esac
export GOLFCART_LINK_TOPICS="${REPO_ROOT}/config/link/topics.yaml"
LINK_DOMAIN="${GOLFCART_LINK_DOMAIN_ID:-42}"

# ── the two hosts ────────────────────────────────────────────────────────────
ip link set lo up; ip link set lo multicast on
ip link add vm type veth peer name vo
ip addr add "${MASTER_IP}/24" dev vm; ip link set vm up
unshare -n sleep infinity & ORIN_NS=$!
sleep 0.3
ip link set vo netns "$ORIN_NS"
nsenter -n -t "$ORIN_NS" sh -c "ip link set lo up; ip link set lo multicast on; ip addr add ${ORIN_IP}/24 dev vo; ip link set vo up"
ping -c1 -W1 "$ORIN_IP" >/dev/null || { echo "link_sim: veth is not up" >&2; exit 1; }

# Foreground forms, for one-off queries.
on_master() { env CYCLONEDDS_URI="$MASTER_URI" GOLFCART_HOST=master "$@"; }
on_orin()   { nsenter -n -t "$ORIN_NS" env CYCLONEDDS_URI="$ORIN_URI" GOLFCART_HOST=orin "$@"; }

# Background forms. The subshell execs, so $! is the process itself and a
# signal to it reaches it; a backgrounded function call would leave a bash
# in between that defers SIGINT until its child exits, which is never.
PIDS=()
spawn_master() { ( exec env CYCLONEDDS_URI="$MASTER_URI" GOLFCART_HOST=master "$@" ) & PIDS+=($!); }
spawn_orin()   { ( exec nsenter -n -t "$ORIN_NS" env CYCLONEDDS_URI="$ORIN_URI" GOLFCART_HOST=orin "$@" ) & PIDS+=($!); }
alive() { local p; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
cleanup() {
    echo "link_sim: stopping"
    # SIGINT first: it is what play_launch and systemd send, and what ros2
    # launch turns into an orderly shutdown of its children. Then escalate.
    local sig
    for sig in INT TERM KILL; do
        for p in "${PIDS[@]}"; do kill -"$sig" "$p" 2>/dev/null; done
        for _ in $(seq 1 10); do alive || break; sleep 1; done
        alive || break
        echo "link_sim: still running after SIG$sig: $(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && ps -o pid=,cmd= -p "$p"; done | tr '\n' ';')"
    done
    kill "$ORIN_NS" 2>/dev/null
    # Named PIDs only: a bare `wait` would also wait on the tee that holds
    # this script's stdout, which never ends while the script is alive.
    wait "${PIDS[@]}" "$ORIN_NS" 2>/dev/null
}
trap cleanup EXIT

# ── instruments, first, so the startup burst is in the numbers ───────────────
TOTAL=$((STARTUP + STEADY))
./scripts/check/link_pressure.sh vm "$TOTAL" "$OUT/link.csv" > "$OUT/link_pressure.txt" & PIDS+=($!)
# A raw socket works here because inside the user namespace this user holds
# CAP_NET_RAW over its own network namespace. (tcpdump does not: it insists
# on dropping to a gid the namespace cannot set.)
python3 "$SCRIPT_DIR/sniff.py" vm "$OUT/classes.txt" "$MASTER_IP" "0,${LINK_DOMAIN}" 2> "$OUT/sniff.err" & SNIFF_PID=$!
T0=$(date +%s)
mark() { echo "$1 $(( $(date +%s) - T0 ))" >> "$OUT/phases.txt"; }
mark start

# ── orin ─────────────────────────────────────────────────────────────────────
spawn_orin python3 "$SCRIPT_DIR/fake_zed.py" > "$OUT/orin_fake_zed.log" 2>&1
if [ "$MODE" = split ]; then
    spawn_orin "$BRIDGE" --role orin > "$OUT/orin_bridge.log" 2>&1
fi

# ── master ───────────────────────────────────────────────────────────────────
if [ "$MODE" = split ]; then
    spawn_master "$BRIDGE" --role master > "$OUT/master_bridge.log" 2>&1
fi
spawn_master python3 "$SCRIPT_DIR/fake_lidar.py" pub > "$OUT/master_fake_lidar.log" 2>&1
for i in 1 2 3; do
    spawn_master python3 "$SCRIPT_DIR/fake_lidar.py" sub > "$OUT/master_fake_lidar_sub$i.log" 2>&1
done
if [ "$STACK" = planning ]; then
    spawn_master ros2 launch autoware_launch planning_simulator.launch.xml \
        map_path:="${REPO_ROOT}/data/sample-map-planning" \
        vehicle_model:=sample_vehicle sensor_model:=sample_sensor_kit rviz:=false \
        > "$OUT/master_planning_sim.log" 2>&1
fi
spawn_master python3 "$SCRIPT_DIR/probe.py" "$TOTAL" "$OUT/probe.txt" > "$OUT/master_probe.log" 2>&1

# ── timeline ─────────────────────────────────────────────────────────────────
churn() {
    # What an operator does: a fresh CLI participant on each host, discovering
    # everything it can see. --no-daemon so it is a new participant every time.
    on_orin ros2 topic list --no-daemon > /dev/null 2>&1 &
    on_master ros2 topic list --no-daemon > /dev/null 2>&1 &
}

sleep "$STARTUP"
mark steady_start
{
    echo "orin sees, domain 0:"
    echo "  nodes  $(on_orin ros2 node list --no-daemon 2>/dev/null | wc -l)"
    echo "  topics $(on_orin ros2 topic list --no-daemon 2>/dev/null | wc -l)"
    if [ "$MODE" = split ]; then
        echo "orin sees, link domain ${LINK_DOMAIN}:"
        echo "  nodes  $(on_orin env ROS_DOMAIN_ID="$LINK_DOMAIN" ros2 node list --no-daemon 2>/dev/null | wc -l)"
        echo "  topics $(on_orin env ROS_DOMAIN_ID="$LINK_DOMAIN" ros2 topic list --no-daemon 2>/dev/null | wc -l)"
    fi
    echo "master sees, domain 0:"
    echo "  nodes  $(on_master ros2 node list --no-daemon 2>/dev/null | wc -l)"
    echo "  topics $(on_master ros2 topic list --no-daemon 2>/dev/null | wc -l)"
} > "$OUT/graph.txt"

elapsed=0
echo_started=0
while [ "$elapsed" -lt "$STEADY" ]; do
    sleep "$CHURN_EVERY"; elapsed=$((elapsed + CHURN_EVERY))
    churn
    if [ "$echo_started" = 0 ] && [ "$elapsed" -ge "$ECHO_AT" ]; then
        echo_started=1
        mark echo_start
        on_master timeout "$ECHO_FOR" ros2 topic echo --no-daemon \
            /sensing/camera/zed/rgb/color/rect/image/compressed sensor_msgs/msg/CompressedImage \
            --field header.stamp.sec > "$OUT/master_echo_image.log" 2>&1 &
        ( sleep "$ECHO_FOR"; mark echo_end ) &
    fi
done
mark end
sleep 2  # let the sampler write its last line

# ── results ──────────────────────────────────────────────────────────────────
# The sniffer stops first: tearing down the orin's namespace takes the veth
# with it, and a raw socket on a vanished interface errors out before it can
# write its table.
kill -INT "$SNIFF_PID" 2>/dev/null; wait "$SNIFF_PID" 2>/dev/null
cleanup
trap - EXIT
python3 "$SCRIPT_DIR/summarize.py" "$OUT" > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "link_sim: results in $OUT"
