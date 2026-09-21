#!/usr/bin/env bash
# run.sh - the two-machine deployment on one machine, with the link measured.
#
#   scripts/testing/link_sim/run.sh baseline|split [OUT_DIR]
#   just link sim baseline && just link sim split && just link sim-compare A B
#
# What runs, and what is real:
#
#   master   the REAL stack: `ros2 launch golfcart_launch golfcart.launch.yaml
#            host:=master`, drivers off, CPU NDT and CPU preprocessing (this box
#            has no colcon cargo extension for the Rust matcher; the DDS graph
#            is the same). ~157 nodes, ~620 topics. Plus the REAL recorder,
#            `ros2 bag record` on config/recording/master_topics.txt, because
#            the recorder is a second reader of every raw cloud and runs on
#            every test drive.
#   orin     synthetic_sensors.py orin (the ZED X's topics at the ZED's rates,
#            sizes from the wrapper config and cart bags), the REAL recorder on
#            config/recording/orin_topics.txt, and under `split` the bridge.
#   drivers  synthetic_sensors.py master: VLP-32C, Falcon, three GMSL cameras,
#            vehicle status, on the real topic names with the real point and
#            frame sizes. Read that file's header for where each number is
#            from. Everything downstream of those topics is Autoware.
#   wire     one veth pair on the real addresses, shaped to 100 Mbit/s each
#            way with tbf (the segment's negotiated rate), so the counters read
#            as what the link delivers and the qdisc counts what it drops.
#   profile  `baseline`: config/cyclonedds as it was before the split, frozen
#            in baseline/, one domain on the LAN, no bridge.
#            `split`: what is checked in, plus one bridge per host from the
#            launch, reading config/link/topics.yaml.
#   operator `ros2 topic list` every 10 s on both hosts; one 15 s
#            `ros2 topic echo` of the ZED image on the master.
#
# What is NOT real, so nobody over-reads the numbers: the bytes inside the
# sensor messages; the orin's own stack (it is a driver and a recorder here,
# which is what it is on the cart minus the system monitor); the NIC (a veth
# with a token bucket is not an i226 behind a 4G router's switch); the CPU.
#
# No root: `unshare -Urn` gives a user namespace in which this user owns its
# network namespaces, which covers veth, nested namespaces, tc and a raw
# socket. The script re-executes itself under it.
#
# Output, under OUT_DIR:
#   link.csv          per-second veth counters (scripts/check/link_pressure.sh)
#   phases.txt        second offsets of the startup / steady / echo windows
#   classes.txt       bytes by direction x domain x multicast|unicast (sniff.py)
#   qdisc.txt         tbf statistics at the end: sent, dropped, overlimits
#   consumers.txt     rates at the REAL consumers on the master, and the
#                     link delay of the IMU, measured mid-run
#   graph.txt         reader counts of the big topics; what a fresh CLI sees
#   summary.md        tables (summarize.py)
#   *.log, bags/      every process, and the two recordings
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
    baseline|split) ;;
    *) echo "usage: $0 baseline|split [OUT_DIR]" >&2; exit 64 ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../../.." && pwd)
OUT="${2:-${REPO_ROOT}/log/link_sim/${MODE}_$(date +%Y%m%d_%H%M%S)}"

STARTUP="${LINK_SIM_STARTUP:-70}"      # s: the stack coming up
STEADY="${LINK_SIM_STEADY:-90}"        # s: measured window after startup
ECHO_AT="${LINK_SIM_ECHO_AT:-50}"      # s into steady: master echoes the ZED image
ECHO_FOR="${LINK_SIM_ECHO_FOR:-15}"    # s
CHURN_EVERY="${LINK_SIM_CHURN_EVERY:-10}"
LINK_RATE="${LINK_SIM_LINK_RATE:-100mbit}"   # what enP5p3s0 negotiates
MASTER_IP=192.168.125.100
ORIN_IP=192.168.125.101

# ── re-exec inside a user+net namespace ──────────────────────────────────────
if [ "${LINK_SIM_INNER:-}" != "1" ]; then
    if ! unshare -Urn true 2>/dev/null; then
        echo "link_sim: unprivileged user namespaces are not available here" >&2
        exit 1
    fi
    mkdir -p "$OUT"
    export LINK_SIM_INNER=1
    exec unshare -Urn "$0" "$MODE" "$OUT"
fi

mkdir -p "$OUT/bags"
exec > >(tee -a "$OUT/run.log") 2>&1
echo "link_sim: mode=$MODE out=$OUT startup=${STARTUP}s steady=${STEADY}s link=${LINK_RATE}"

# ── environment ──────────────────────────────────────────────────────────────
cd "$REPO_ROOT" || exit 1
export GOLFCART_ENV_ROLE=master GOLFCART_ENV_QUIET=1
set +u
# shellcheck source=/dev/null
. ./scripts/env.sh
# shellcheck source=/dev/null
[ -f install/setup.bash ] && . install/setup.bash
set -u
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
unset ROS_DOMAIN_ID
# The sensor kit reads these from the environment (config/sensors.conf). No
# camera driver: gscam with no device hangs, and the GMSL topics come from the
# synthetic drivers anyway. IMU from the ZED, as the cart runs today.
export CAMERA_MODEL=none IMU_SOURCE=zed
export GOLFCART_LINK_TOPICS="${REPO_ROOT}/config/link/topics.yaml"
LINK_DOMAIN="${GOLFCART_LINK_DOMAIN_ID:-42}"

for pkg in golfcart_launch golfcart_domain_bridge; do
    if ! ros2 pkg prefix "$pkg" >/dev/null 2>&1; then
        echo "link_sim: $pkg is not built; run just build first" >&2
        exit 1
    fi
done
BRIDGE="$(ros2 pkg prefix golfcart_domain_bridge)/lib/golfcart_domain_bridge/domain_bridge"

case "$MODE" in
    baseline)
        MASTER_URI="file://${SCRIPT_DIR}/baseline/master.xml"
        ORIN_URI="file://${SCRIPT_DIR}/baseline/orin.xml"
        BRIDGE_ARG="launch_link_bridge:=false"
        ;;
    split)
        MASTER_URI="file://${REPO_ROOT}/config/cyclonedds/master.xml"
        ORIN_URI="file://${REPO_ROOT}/config/cyclonedds/orin.xml"
        BRIDGE_ARG="launch_link_bridge:=true"
        ;;
esac

# ── the two hosts and the wire ───────────────────────────────────────────────
ip link set lo up; ip link set lo multicast on
ip link add vm type veth peer name vo
ip addr add "${MASTER_IP}/24" dev vm; ip link set vm up
unshare -n sleep infinity & ORIN_NS=$!
sleep 0.3
ip link set vo netns "$ORIN_NS"
nsenter -n -t "$ORIN_NS" sh -c "ip link set lo up; ip link set lo multicast on; ip addr add ${ORIN_IP}/24 dev vo; ip link set vo up"
# Token bucket at the link rate on each egress. burst is the NIC's own
# transmit ring's worth; limit is a small switch-port buffer. Beyond it the
# qdisc drops, which is what the cart's link does with a 226 Mbit/s second.
tc qdisc add dev vm root tbf rate "$LINK_RATE" burst 128kb limit 1mb
nsenter -n -t "$ORIN_NS" tc qdisc add dev vo root tbf rate "$LINK_RATE" burst 128kb limit 1mb
ping -c1 -W1 "$ORIN_IP" >/dev/null || { echo "link_sim: veth is not up" >&2; exit 1; }

on_master() { env CYCLONEDDS_URI="$MASTER_URI" GOLFCART_HOST=master "$@"; }
on_orin()   { nsenter -n -t "$ORIN_NS" env CYCLONEDDS_URI="$ORIN_URI" GOLFCART_HOST=orin "$@"; }
PIDS=()
spawn_master() { ( exec env CYCLONEDDS_URI="$MASTER_URI" GOLFCART_HOST=master "$@" ) & PIDS+=($!); }
spawn_orin()   { ( exec nsenter -n -t "$ORIN_NS" env CYCLONEDDS_URI="$ORIN_URI" GOLFCART_HOST=orin "$@" ) & PIDS+=($!); }

alive() { local p; for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
cleanup() {
    echo "link_sim: stopping"
    local sig
    for sig in INT TERM KILL; do
        for p in "${PIDS[@]}"; do kill -"$sig" "$p" 2>/dev/null; done
        for _ in $(seq 1 20); do alive || break; sleep 1; done
        alive || break
        echo "link_sim: still running after SIG$sig: $(for p in "${PIDS[@]}"; do kill -0 "$p" 2>/dev/null && ps -o pid=,comm= -p "$p"; done | tr '\n' ';')"
    done
    kill "$ORIN_NS" 2>/dev/null
    wait "${PIDS[@]}" "$ORIN_NS" 2>/dev/null
}
trap cleanup EXIT

# The recorder, invoked as scripts/recording/record_unit_exec.sh invokes it
# (same list parsing, same `ros2 bag record -o DIR TOPICS...`), but with this
# run's profile rather than the one env.sh would resolve.
record_topics() {
    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && echo "$line"
    done < "$1"
}
mapfile -t MASTER_TOPICS < <(record_topics config/recording/master_topics.txt)
mapfile -t ORIN_TOPICS < <(record_topics config/recording/orin_topics.txt)

# ── instruments first, so startup is in the numbers ──────────────────────────
TOTAL=$((STARTUP + STEADY))
./scripts/check/link_pressure.sh vm "$TOTAL" "$OUT/link.csv" > "$OUT/link_pressure.txt" & PIDS+=($!)
python3 "$SCRIPT_DIR/sniff.py" vm "$OUT/classes.txt" "$MASTER_IP" "0,${LINK_DOMAIN}" 2> "$OUT/sniff.err" & SNIFF_PID=$!
T0=$(date +%s)
mark() { echo "$1 $(( $(date +%s) - T0 ))" >> "$OUT/phases.txt"; }
mark start

# ── orin ─────────────────────────────────────────────────────────────────────
spawn_orin python3 "$SCRIPT_DIR/synthetic_sensors.py" orin > "$OUT/orin_sensors.log" 2>&1
spawn_orin ros2 bag record -o "$OUT/bags/orin" "${ORIN_TOPICS[@]}" > "$OUT/orin_record.log" 2>&1
if [ "$MODE" = split ]; then
    spawn_orin "$BRIDGE" --role orin > "$OUT/orin_bridge.log" 2>&1
fi

# ── master ───────────────────────────────────────────────────────────────────
spawn_master python3 "$SCRIPT_DIR/synthetic_sensors.py" master > "$OUT/master_sensors.log" 2>&1
spawn_master ros2 launch golfcart_launch golfcart.launch.yaml host:=master \
    launch_sensing_driver:=false launch_vehicle_interface:=false \
    use_cuda:=false pose_source:=ndt use_gnss:=false rviz:=false "$BRIDGE_ARG" \
    > "$OUT/master_stack.log" 2>&1
sleep 20  # let the containers exist before the recorder's discovery burst
spawn_master ros2 bag record -o "$OUT/bags/master" "${MASTER_TOPICS[@]}" > "$OUT/master_record.log" 2>&1

# ── timeline ─────────────────────────────────────────────────────────────────
churn() {
    on_orin ros2 topic list --no-daemon > /dev/null 2>&1 &
    on_master ros2 topic list --no-daemon > /dev/null 2>&1 &
}

sleep $((STARTUP - 20))
mark steady_start

# Reader counts of the big topics: two or more reader PROCESSES is what makes
# CycloneDDS choose the multicast locator. `ros2 topic info` creates a
# participant but no reader, so it does not change the answer it reports.
{
    echo "readers (master, domain 0):"
    for t in /sensing/lidar/vlp32/velodyne_points /sensing/lidar/vlp32/pointcloud \
             /sensing/lidar/falcon/iv_points /sensing/lidar/concatenated/pointcloud \
             /sensing/camera/zed/imu/data /tf /sensing/camera/left/image_raw/compressed; do
        echo "  $t $(on_master timeout 15 ros2 topic info --no-daemon "$t" 2>/dev/null | awk '/Subscription count/ {print "subs=" $3} /Publisher count/ {print "pubs=" $3}' | tr '\n' ' ')"
    done
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

# The data path, at the REAL consumers, small topics only (a `ros2 topic hz`
# on a cloud would be a second reader and change what is being measured):
#   imu_corrector's output      the ZED IMU arrived and was accepted
#   gyro_odometer's twist       the IMU could be transformed, so /tf arrived
#   ekf's kinematic_state       the localization chain is alive
#   delay of the IMU itself     link + bridge latency, header stamp to arrival
{
    for t in /sensing/imu/imu_data /localization/twist_estimator/twist_with_covariance /localization/kinematic_state; do
        echo "hz $t"
        on_master timeout 20 ros2 topic hz --window 100 "$t" 2>&1 | grep -E 'average rate|no new messages' | tail -1
    done
    echo "delay /sensing/camera/zed/imu/data"
    on_master timeout 20 ros2 topic delay --window 100 /sensing/camera/zed/imu/data 2>&1 | grep -E 'average delay|no new' | tail -1
} > "$OUT/consumers.txt" 2>&1 &
CONSUMERS_PID=$!

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
wait "$CONSUMERS_PID" 2>/dev/null
sleep 2

# ── results ──────────────────────────────────────────────────────────────────
{
    echo "vm (master -> orin):"; tc -s qdisc show dev vm
    echo "vo (orin -> master):"; nsenter -n -t "$ORIN_NS" tc -s qdisc show dev vo
} > "$OUT/qdisc.txt" 2>&1
kill -INT "$SNIFF_PID" 2>/dev/null; wait "$SNIFF_PID" 2>/dev/null
cleanup
trap - EXIT
for b in master orin; do
    echo "bag $b: $(on_master ros2 bag info "$OUT/bags/$b" 2>/dev/null | grep -E 'Duration|Messages' | tr -s ' ' | tr '\n' ' ')"
done > "$OUT/bags.txt"
python3 "$SCRIPT_DIR/summarize.py" "$OUT" > "$OUT/summary.md"
cat "$OUT/summary.md"
echo "link_sim: results in $OUT"
