#!/usr/bin/env bash
# run.sh - the two-machine deployment on one machine, with the link measured.
#
#   scripts/testing/link_sim/run.sh baseline|spdp [OUT_DIR]
#   just link sim baseline && just link sim spdp && just link sim-compare A B
#
# What runs, and what is real:
#
# WHAT IS BEING MEASURED, AND THEREFORE WHAT HAS TO BE REAL: routing. Which
# topic leaves which interface, to how many readers, as multicast or unicast.
# CycloneDDS decides that from the FLOW - publishers, subscribers, and how many
# reader PROCESSES a writer has - and never from what a sample contains. So the
# flow here is the one `just launch-all` produces, on both hosts, and only the
# sample bytes are synthetic.
#
#   master   the REAL stack: `ros2 launch golfcart_launch golfcart.launch.yaml
#            host:=master` at launch-all's own defaults - use_cuda true, so
#            pointcloud_backend cuda, and pose_source cuda_ndt. ~160 nodes,
#            ~624 topics. Plus the REAL recorder, `ros2 bag record` on
#            config/recording/master_topics.txt, because the recorder is a
#            second reader of every raw cloud and runs on every test drive.
#   orin     the REAL stack too: `golfcart.launch.yaml host:=orin`, as
#            launch-all starts it there, plus synthetic_sensors.py orin for the
#            ZED X's topics and the REAL recorder on
#            config/recording/orin_topics.txt.
#   drivers  synthetic_sensors.py master: VLP-32C, Falcon, three GMSL cameras,
#            vehicle status, on the real topic names with the real point and
#            frame sizes. Read that file's header for where each number is
#            from. Everything downstream of those topics is Autoware.
#   wire     one veth pair on the real addresses, shaped to 100 Mbit/s each
#            way with tbf (the segment's negotiated rate), so the counters read
#            as what the link delivers and the qdisc counts what it drops.
#   profile  ONE DDS domain on the LAN in both modes - this measures the
#            multicast scope, not a domain split, so the graph is identical
#            and only AllowMulticast differs.
#            `baseline`: the profiles frozen in baseline/, AllowMulticast
#            default, which is what the cart ran.
#            `spdp`: config/cyclonedds/{master,orin}.xml as checked in,
#            AllowMulticast spdp. Multicast carries SPDP participant
#            announcements only; data and SEDP go unicast, and a local
#            reader's unicast locator is this host's own address, so the
#            kernel routes it over lo instead of out the NIC.
#   operator `ros2 topic list` every 10 s on both hosts; one 15 s
#            `ros2 topic echo` of the ZED image on the master.
#   RViz     LINK_SIM_RVIZ=1: the REAL rviz2 with golfcart.rviz on the master,
#            on a private TurboVNC display started here (software GL). It is
#            a third reader of both raw clouds and a reader of the three GMSL
#            images, the concatenated cloud, the map and ~140 more.
#   ZED view LINK_SIM_ZED_IMAGE=1: RViz also shows the ZED image, the way an
#            operator would drag it in. One domain in both modes, so RViz
#            simply subscribes and the orin->master direction carries it.
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
#   classes.txt       bytes by direction x domain x multicast|unicast
#                     (sniff.py). THE line of this experiment: the
#                     master->orin multicast-data row.
#   qdisc.txt         tbf statistics at the end: sent, dropped, overlimits
#   consumers.txt     rates at the REAL consumers on the master, and the
#                     link delay of the IMU, measured mid-run
#   graph.txt         reader counts of the big topics; what a fresh CLI sees
#   summary.md        tables (summarize.py)
#   *.log, bags/      every process, and the two recordings
set -uo pipefail

MODE="${1:-}"
case "$MODE" in
    baseline|spdp) ;;
    *) echo "usage: $0 baseline|spdp [OUT_DIR]" >&2; exit 64 ;;
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
RVIZ="${LINK_SIM_RVIZ:-0}"
ZED_IMAGE="${LINK_SIM_ZED_IMAGE:-0}"
MASTER_IP=192.168.125.100
ORIN_IP=192.168.125.101

# ── re-exec inside a user+net namespace ──────────────────────────────────────
if [ "${LINK_SIM_INNER:-}" != "1" ]; then
    if ! unshare -Urn true 2>/dev/null; then
        echo "link_sim: unprivileged user namespaces are not available here" >&2
        exit 1
    fi
    mkdir -p "$OUT"
    # RViz needs an X display with GLX. TurboVNC's Xvnc provides one with no
    # GPU and no session, rendered by llvmpipe. It has to start OUT HERE, as
    # the real user: inside the user namespace root maps to this user and
    # Xvnc's check that /etc/turbovncserver-security.conf is owned by root
    # fails. The socket in /tmp/.X11-unix is visible from inside regardless.
    XVNC_PID=""
    if [ "$RVIZ" = 1 ]; then
        XVNC=/opt/TurboVNC/bin/Xvnc
        [ -x "$XVNC" ] || XVNC=$(command -v Xvnc || true)
        if [ -z "$XVNC" ]; then
            echo "link_sim: LINK_SIM_RVIZ=1 needs Xvnc (TurboVNC)" >&2
            exit 1
        fi
        export LINK_SIM_DISPLAY=":$((90 + RANDOM % 9))"
        "$XVNC" "$LINK_SIM_DISPLAY" -geometry 1600x1000 -depth 24 -SecurityTypes None -localhost \
            -rfbport $((5900 + ${LINK_SIM_DISPLAY#:})) -fp /usr/share/fonts/X11/misc \
            -dridir /usr/lib/x86_64-linux-gnu/dri -registrydir /usr/lib/xorg > "$OUT/xvnc.log" 2>&1 & XVNC_PID=$!
        sleep 2
        if ! kill -0 "$XVNC_PID" 2>/dev/null; then
            echo "link_sim: Xvnc did not start; see $OUT/xvnc.log" >&2
            exit 1
        fi
    fi
    export LINK_SIM_INNER=1
    unshare -Urn "$0" "$MODE" "$OUT"
    rc=$?
    [ -n "$XVNC_PID" ] && kill "$XVNC_PID" 2>/dev/null
    exit $rc
fi

mkdir -p "$OUT/bags"
exec > >(tee -a "$OUT/run.log") 2>&1
echo "link_sim: mode=$MODE out=$OUT startup=${STARTUP}s steady=${STEADY}s link=${LINK_RATE} rviz=${RVIZ} zed_image=${ZED_IMAGE}"

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
# The sensor kit reads these from the environment (config/sensors.conf).
# CAMERA_MODEL=none rather than the cart's gmslcam: there are no capture
# devices here, and with launch_sensing_driver:=false the camera launch is not
# reached anyway. It costs the flow nothing, because the camera TOPICS - the
# part routing depends on - are published by synthetic_sensors.py under the
# real names, and their subscribers (the recorder, RViz) are real.
# IMU_SOURCE=zed as the cart runs today.
export CAMERA_MODEL=none IMU_SOURCE=zed
# One domain in both modes: this experiment changes the multicast scope and
# nothing else, so the DDS graph on either side of the comparison is the same.
DOMAIN=0

if ! ros2 pkg prefix golfcart_launch >/dev/null 2>&1; then
    echo "link_sim: golfcart_launch is not built; run just build first" >&2
    exit 1
fi

# Per-host environment. Same domain, same graph, same everything in both
# modes; the ONLY difference is which CycloneDDS profile is loaded, and the
# only line that differs between those two profiles is AllowMulticast.
# The control is DERIVED FROM THE LIVE PROFILE, not from a frozen copy, and
# this matters more than it looks. scripts/testing/link_sim/baseline/ holds the
# profiles as they were before the domain split, and they predate c228d87 -
# they have no <SocketSendBufferSize>, which on its own costs the two LiDARs
# about eight of their ten frames per second (see master.xml). Running that as
# the control would compare two changes at once and credit AllowMulticast with
# the send-buffer fix as well. So baseline mode takes config/cyclonedds/*.xml
# and rewrites exactly one element back to "default". Everything else -
# interface, domain, buffers, heartbeat, watermarks - is byte-identical
# between the two legs, and profiles.diff in OUT_DIR proves it.
case "$MODE" in
    baseline) WANT_MULTICAST=default ;;
    spdp)     WANT_MULTICAST=spdp ;;
esac
for host in master orin; do
    python3 - "${REPO_ROOT}/config/cyclonedds/${host}.xml" "$OUT/${host}.xml" "$WANT_MULTICAST" <<'PYX'
import sys
src, dst, want = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
n = s.count("<AllowMulticast>")
if n != 1:
    sys.exit(f"link_sim: expected one AllowMulticast in {src}, found {n}")
import re
s = re.sub(r"<AllowMulticast>[^<]*</AllowMulticast>",
           f"<AllowMulticast>{want}</AllowMulticast>", s)
open(dst, "w").write(s)
PYX
    [ $? -eq 0 ] || exit 1
done
diff -u "${REPO_ROOT}/config/cyclonedds/master.xml" "$OUT/master.xml" > "$OUT/profiles.diff"
# Provenance. profiles.diff only shows the one element this script rewrites,
# which says nothing about whether the checked-out profile was itself edited
# to fit the machine the simulation is running on. Record that too, so a run
# taken on a box that cannot meet the real profile's socket buffers carries
# the deviation with it instead of looking like the vehicle's configuration.
git -C "$REPO_ROOT" diff -- config/cyclonedds > "$OUT/profile_local_edits.diff" 2>/dev/null || true
if [ -s "$OUT/profile_local_edits.diff" ]; then
    echo "link_sim: WARNING config/cyclonedds has uncommitted edits; see profile_local_edits.diff"
fi
MASTER_URI="file://$OUT/master.xml"
ORIN_URI="file://$OUT/orin.xml"
MASTER_ENV=(CYCLONEDDS_URI="$MASTER_URI" GOLFCART_HOST=master ROS_DOMAIN_ID="$DOMAIN")
ORIN_ENV=(CYCLONEDDS_URI="$ORIN_URI" GOLFCART_HOST=orin ROS_DOMAIN_ID="$DOMAIN")

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

on_master() { env "${MASTER_ENV[@]}" "$@"; }
on_orin()   { nsenter -n -t "$ORIN_NS" env "${ORIN_ENV[@]}" "$@"; }
PIDS=()
spawn_master() { ( exec env "${MASTER_ENV[@]}" "$@" ) & PIDS+=($!); }
spawn_orin()   { ( exec nsenter -n -t "$ORIN_NS" env "${ORIN_ENV[@]}" "$@" ) & PIDS+=($!); }

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

# The display was started by the outer process (see the re-exec above).
RVIZ_CONFIG="$(ros2 pkg prefix golfcart_launch)/share/golfcart_launch/rviz/golfcart.rviz"
RVIZ_DISPLAY="${LINK_SIM_DISPLAY:-}"
if [ "$RVIZ" = 1 ]; then
    if [ -z "$RVIZ_DISPLAY" ] || ! command -v rviz2 >/dev/null; then
        echo "link_sim: LINK_SIM_RVIZ=1 needs a display from the outer process and rviz2" >&2
        exit 1
    fi
    if [ "$ZED_IMAGE" = 1 ]; then
        # golfcart.rviz plus one Image display on the ZED's compressed topic,
        # written the way the file's three GMSL panels are: the panel an
        # operator adds to look at the camera.
        python3 - "$RVIZ_CONFIG" "$OUT/golfcart_zed.rviz" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
panel = """    - Class: rviz_default_plugins/Image
      Enabled: true
      Max Value: 1
      Median window: 5
      Min Value: 0
      Name: ZED
      Normalize Range: true
      Topic:
        Depth: 5
        Durability Policy: Volatile
        History Policy: Keep Last
        Reliability Policy: Reliable
        Value: /sensing/camera/zed/rgb/color/rect/image/compressed
      Value: true
"""
marker = "  Enabled: true\n  Global Options:"
assert marker in s, "unexpected golfcart.rviz layout"
s = s.replace(marker, panel + marker, 1)
open(dst, "w").write(s)
PY
        RVIZ_CONFIG="$OUT/golfcart_zed.rviz"
    fi
fi

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
python3 "$SCRIPT_DIR/sniff.py" vm "$OUT/classes.txt" "$MASTER_IP" "$DOMAIN" 2> "$OUT/sniff.err" & SNIFF_PID=$!
T0=$(date +%s)
mark() { echo "$1 $(( $(date +%s) - T0 ))" >> "$OUT/phases.txt"; }
mark start

# What is deliberately NOT passed, and why it is the whole point of this file.
#
# This simulation exists to measure ROUTING: which topic goes out of which
# interface, to how many readers, over multicast or unicast. That is decided by
# the DDS FLOW - who publishes, who subscribes, and how many reader processes a
# writer has - and not at all by what the samples contain. So the sample bytes
# are synthetic and the flow must be the real one.
#
# Which means the launch arguments have to be the ones `just launch-all` uses.
# Only the four that stand in for absent hardware are overridden:
#
#   launch_sensing_driver:=false    no LiDAR, no camera, no GNSS on this box;
#                                   synthetic_sensors.py publishes those topics
#                                   instead, so the flow keeps its sources
#   launch_vehicle_interface:=false no CAN bus
#   use_gnss:=false                 no receiver
#   rviz:=false                     RViz is started separately below, so it can
#                                   be the variable under test
#
# Everything else is left at golfcart.launch.yaml's defaults, which is what the
# unit gets under launch-all: use_cuda true, therefore pointcloud_backend cuda,
# and pose_source cuda_ndt. Those two are NOT cosmetic here. The CUDA backend
# replaces three preprocessing nodes per LiDAR with one
# CudaPointcloudPreprocessorNode and carries the cloud over cuda_blackboard, so
# it changes the READER COUNT on exactly the topics whose multicast decision is
# being measured. An earlier revision of this file pinned `use_cuda:=false
# pose_source:=ndt` because the workstation had no colcon cargo extension; that
# made the run cheap and the result not comparable.

# ── orin ─────────────────────────────────────────────────────────────────────
# The orin runs its REAL stack, as `just launch-all` starts it there. Without
# this the orin was a bare publisher plus a recorder: two participants against
# the master's ~160, subscribing to nothing the master sends. Its discovery
# traffic, its subscriptions and its share of the link were all missing from
# the measurement.
spawn_orin python3 "$SCRIPT_DIR/synthetic_sensors.py" orin > "$OUT/orin_sensors.log" 2>&1
spawn_orin ros2 launch golfcart_launch golfcart.launch.yaml host:=orin \
    launch_sensing_driver:=false launch_vehicle_interface:=false \
    use_gnss:=false rviz:=false \
    > "$OUT/orin_stack.log" 2>&1
spawn_orin ros2 bag record -o "$OUT/bags/orin" "${ORIN_TOPICS[@]}" > "$OUT/orin_record.log" 2>&1

# ── master ───────────────────────────────────────────────────────────────────
spawn_master python3 "$SCRIPT_DIR/synthetic_sensors.py" master > "$OUT/master_sensors.log" 2>&1
spawn_master ros2 launch golfcart_launch golfcart.launch.yaml host:=master \
    launch_sensing_driver:=false launch_vehicle_interface:=false \
    use_gnss:=false rviz:=false \
    > "$OUT/master_stack.log" 2>&1
sleep 20  # let the containers exist before the recorder's discovery burst
spawn_master ros2 bag record -o "$OUT/bags/master" "${MASTER_TOPICS[@]}" > "$OUT/master_record.log" 2>&1
if [ "$RVIZ" = 1 ]; then
    spawn_master env DISPLAY="$RVIZ_DISPLAY" LIBGL_ALWAYS_SOFTWARE=1 QT_X11_NO_MITSHM=1 \
        rviz2 -d "$RVIZ_CONFIG" > "$OUT/master_rviz.log" 2>&1
fi

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
    echo "readers (domain ${DOMAIN}):"
    for t in /sensing/lidar/vlp32/velodyne_points /sensing/lidar/vlp32/pointcloud \
             /sensing/lidar/falcon/iv_points /sensing/lidar/concatenated/pointcloud \
             /sensing/camera/zed/imu/data /tf /sensing/camera/left/image_raw/compressed \
             /sensing/camera/zed/rgb/color/rect/image/compressed; do
        echo "  $t $(on_master timeout 15 ros2 topic info --no-daemon "$t" 2>/dev/null | awk '/Subscription count/ {print "subs=" $3} /Publisher count/ {print "pubs=" $3}' | tr '\n' ' ')"
    done
    echo "orin sees, domain ${DOMAIN}:"
    echo "  nodes  $(on_orin ros2 node list --no-daemon 2>/dev/null | wc -l)"
    echo "  topics $(on_orin ros2 topic list --no-daemon 2>/dev/null | wc -l)"
    echo "master sees, domain ${DOMAIN}:"
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
# Per-topic counts, which matrix.py reads as "scans kept". This is the metric
# that says whether the pipeline was healthy while the link was being measured,
# so it has to survive the bags being deleted afterwards - they are several GB
# and nothing else reads them.
RUN_NAME=$(basename "$OUT")
for b in master orin; do
    echo "== ${RUN_NAME} ${b} bag"
    on_master ros2 bag info "$OUT/bags/$b" 2>/dev/null \
        | grep -E 'Duration|Topic: .*(velodyne_points|iv_points|image/compressed|imu/data)'
done > "$OUT/bag_counts.txt"
python3 "$SCRIPT_DIR/summarize.py" "$OUT" > "$OUT/summary.md"

# ── validity gate ────────────────────────────────────────────────────────────
#
# A quiet link is only good news if the stack was busy. A run where the
# publishers never started, the stack died in startup or the recorder attached
# to nothing also produces a beautifully empty wire, and read on its own it
# looks exactly like the result this experiment is trying to find. So state the
# work done BEFORE the link numbers, and refuse to call the run usable when
# there is none.
#
# The threshold is deliberately loose. It is not a performance bar - the
# baseline leg is EXPECTED to do badly, that is the finding - it only
# separates "the pipeline ran" from "nothing happened".
EXPECT_SCANS=$(( (STARTUP + STEADY) * 10 * 60 / 100 ))   # 10 Hz, 60% of wall
{
    echo "== work done during the run (read this before any link number)"
    for t in velodyne_points iv_points; do
        n=$(grep -m1 "master bag" -A6 "$OUT/bag_counts.txt" 2>/dev/null \
            | grep -m1 "$t" | sed -n 's/.*Count: \([0-9]*\).*/\1/p')
        echo "   master recorder kept ${n:-0} ${t} (a healthy run is ~$(( (STARTUP + STEADY) * 10 )))"
    done
    grep -A1 'hz /sensing/imu/imu_data' "$OUT/consumers.txt" 2>/dev/null | tail -1 \
        | sed 's/^/   imu_corrector /'
    grep -A1 'twist_with_covariance' "$OUT/consumers.txt" 2>/dev/null | tail -1 \
        | sed 's/^/   gyro_odometer  /'
} > "$OUT/validity.txt"

VELO=$(grep -m1 'velodyne_points' "$OUT/validity.txt" | sed -n 's/.*kept \([0-9]*\).*/\1/p')
if [ "${VELO:-0}" -lt 1 ]; then
    echo "INVALID: the master recorder kept no Velodyne scans at all." >> "$OUT/validity.txt"
    echo "         Nothing was flowing, so the link numbers below mean nothing." >> "$OUT/validity.txt"
    echo "         Check master_stack.log, orin_stack.log and master_sensors.log." >> "$OUT/validity.txt"
fi

cat "$OUT/validity.txt"
echo
cat "$OUT/summary.md"
echo "link_sim: results in $OUT"
if [ "${VELO:-0}" -lt 1 ]; then
    echo "link_sim: RUN IS NOT USABLE - see validity.txt" >&2
    exit 3
fi
