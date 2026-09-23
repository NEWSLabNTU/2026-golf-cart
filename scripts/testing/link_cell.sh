#!/usr/bin/env bash
# link_cell.sh - run ONE cell of the vehicle matrix in
# docs/research/performance/link-multicast-and-monitor-scope.md.
#
#   scripts/testing/link_cell.sh default shared
#   scripts/testing/link_cell.sh default perhost
#   scripts/testing/link_cell.sh spdp    shared
#   scripts/testing/link_cell.sh spdp    perhost
#
# Run it ON THE MASTER. It sets the multicast axis on BOTH hosts, launches both
# stacks, records on both, measures each direction of the wire at the same
# instant, and tears everything down. Everything it learns lands in
#   log/link_cells/<multicast>-<monitor>_<timestamp>/
# and the last thing it prints is that directory.
#
# Why each piece is here:
#   - The recorder is started in every cell on purpose. The mechanism under test
#     is "a topic with two or more reader PROCESSES makes CycloneDDS pick the
#     multicast locator"; on the master the recorder is the second reader of every
#     raw cloud. A cell without it does not reproduce the vehicle's traffic.
#   - The orin's watchdog is stopped for the duration. It pings the master every
#     5 s and stops all golfcart units after 6 misses (~42 s); a saturated link
#     drops ICMP, so in the `default` cells it would tear the orin's stack down
#     mid-measurement and the cell would read LOWER than reality.
#   - Both pressure samples run concurrently, so master->orin and orin->master
#     describe the same 60 seconds.
#   - `ros2 topic hz` is used only on the two SMALL topics. Subscribing to a point
#     cloud would add a reader process and change the very decision being measured.
#
# LINK_CELL_RVIZ=1 additionally runs the real RViz on the master for the whole
# cell. That is a third axis, and it is opt-in because it only proves something
# in ONE place: under `spdp`, RViz's 71 display subscriptions are a third LOCAL
# reader, so the wire must NOT move. If it does, a subscription the design
# assumes is local is crossing the link, or the profile did not take. Under
# `default` it proves nothing - every cloud already has two readers, so the
# multicast locator is already chosen and a third reader changes no routing.
# RViz is not part of `just launch-all` (launch_unit_exec.sh passes rviz:=false),
# so this is the only way to measure it.
#
# Knobs (environment): LINK_CELL_STARTUP, LINK_CELL_STEADY, LINK_CELL_SAMPLE,
# LINK_CELL_IFACE, LINK_CELL_ORIN_IFACE, LINK_CELL_RVIZ, LINK_CELL_DISPLAY.
set -uo pipefail

MULTICAST="${1:-}"
MONITOR="${2:-}"
case "${MULTICAST}" in default | spdp) ;; *)
	echo "usage: link_cell.sh <default|spdp> <shared|perhost>" >&2
	exit 2
	;;
esac
case "${MONITOR}" in shared | perhost) ;; *)
	echo "usage: link_cell.sh <default|spdp> <shared|perhost>" >&2
	exit 2
	;;
esac

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)"
cd "${REPO_DIR}" || exit 1

# This script calls ros2 itself (daemon, topic hz, bag info), so it needs the
# same environment the units get: Autoware sourced, CYCLONEDDS_URI pointing at
# this host's profile, GOLFCART_BAG_DIR resolved. One source, as everywhere else.
# shellcheck source=/dev/null
[ -z "${GOLFCART_BAG_DIR:-}" ] && . "${REPO_DIR}/scripts/env.sh"

STARTUP="${LINK_CELL_STARTUP:-90}" # launch-all to a stack that publishes
STEADY="${LINK_CELL_STEADY:-20}"   # recorder started to first sample
SAMPLE="${LINK_CELL_SAMPLE:-60}"   # seconds of wire measured
IFACE="${LINK_CELL_IFACE:-enP5p3s0}"
ORIN_IFACE="${LINK_CELL_ORIN_IFACE:-eno1}"
RVIZ="${LINK_CELL_RVIZ:-0}"
RVIZ_DISPLAY="${LINK_CELL_DISPLAY:-:0}"
RVIZ_PID=""

ON_ORIN="${REPO_DIR}/scripts/multi_machine/on_orin.sh"
MASTER_XML="${REPO_DIR}/config/cyclonedds/master.xml"

STAMP="$(date +%Y%m%d-%H%M%S)"
CELL="${MULTICAST}-${MONITOR}"
[ "${RVIZ}" = "1" ] && CELL="${CELL}-rviz"
OUT="${REPO_DIR}/log/link_cells/${CELL}_${STAMP}"
mkdir -p "${OUT}" || exit 1

log() { printf '[link_cell %s] %s\n' "$(date +%H:%M:%S)" "$1" | tee -a "${OUT}/run.log"; }
run() { "$@" >>"${OUT}/run.log" 2>&1; }

# Every remote call is bounded. on_orin.sh passes ConnectTimeout=5, but that
# covers only the handshake: an ssh that has already connected and then loses
# its link - which is what a saturated 100 Mb/s wire does to it - waits forever.
# An unbounded remote call inside the teardown means the storm keeps running
# while the script that was supposed to end it is blocked.
orin() { timeout "${ORIN_TIMEOUT:-60}" "${ON_ORIN}" "$@"; }

# A whole-cell deadline, because the failure this guards against is precisely
# the one that makes a human unable to intervene over the network. On expiry the
# script signals itself, the EXIT trap runs, and the vehicle is put back the way
# it was found.
DEADLINE="${LINK_CELL_DEADLINE:-$((STARTUP + STEADY + SAMPLE + 300))}"
(
	sleep "${DEADLINE}"
	kill -TERM $$ 2>/dev/null
) &
GUARD_PID=$!

# One sed per host, on the one element that is the whole axis. Nothing else in
# the profile is touched, and the profiles are copied into OUT as proof.
set_multicast() {
	local value="$1"
	sed -i "s|<AllowMulticast>[^<]*</AllowMulticast>|<AllowMulticast>${value}</AllowMulticast>|" "${MASTER_XML}"
	orin sed -i "s|<AllowMulticast>[^<]*</AllowMulticast>|<AllowMulticast>${value}</AllowMulticast>|" config/cyclonedds/orin.xml
}

# Leave the vehicle in the branch's resting state whatever happens, including a
# Ctrl-C in the middle of a saturated cell.
# Teardown order matters and is the reverse of `just stop-all`'s. stop-all stops
# the orin FIRST, over ssh, while the master can still reach it - correct when
# the link is healthy, useless when the link is the problem. Here the master's
# own units go down first, because they are what is filling the wire; once they
# are gone the ssh to the orin succeeds and the rest is ordinary.
cleanup() {
	trap '' INT TERM
	kill "${GUARD_PID}" 2>/dev/null
	log "cleanup: master units down first, then the orin"
	if [ -n "${RVIZ_PID}" ]; then
		kill "${RVIZ_PID}" 2>/dev/null
		pkill -f 'rviz2 .*golfcart' 2>/dev/null
	fi
	# Straight at systemd rather than through the recipes: these cannot touch the
	# network, so they cannot hang however bad the link is.
	run systemctl --user stop golfcart-record.service
	run systemctl --user stop golfcart-launch.service
	log "master quiet; stopping the orin"
	run orin systemctl --user stop golfcart-record.service
	run orin systemctl --user stop golfcart-launch.service
	set_multicast spdp
	# Say what the vehicle was left in, so a reader of OUT never has to guess
	# whether a killed cell left `default` in a profile.
	grep -h AllowMulticast "${MASTER_XML}" | tee -a "${OUT}/run.log"
	log "cleanup done"
}
trap cleanup EXIT INT TERM

log "cell ${MULTICAST}/${MONITOR}: startup ${STARTUP}s, steady ${STEADY}s, sample ${SAMPLE}s"

# A running ros2 daemon holds the profile it started with, so a cell that only
# edited the XML would measure the previous cell's transport.
run just stop-all
run ros2 daemon stop
# on_orin.sh puts ~/.local/bin on the remote PATH but sources no ROS environment,
# so a bare `ros2` there is "command not found" and the orin would keep a daemon
# holding the PREVIOUS cell's profile - which shows up later as a data multicast
# group in its groups.txt under spdp, looking exactly like a profile that did not
# take.
run orin bash -c '. scripts/env.sh >/dev/null 2>&1; ros2 daemon stop'

set_multicast "${MULTICAST}"
cp "${MASTER_XML}" "${OUT}/master.xml"
orin cat config/cyclonedds/orin.xml >"${OUT}/orin.xml" 2>/dev/null
grep -n AllowMulticast "${OUT}/master.xml" "${OUT}/orin.xml" | tee -a "${OUT}/run.log"

# `shared` is the control: monitor_host:=any makes every instance watch every
# row, which is what the single shared list did before this branch.
if [ "${MONITOR}" = "shared" ]; then
	log "launching both hosts with monitor_host:=any"
	run just launch-all "monitor_host:=any"
else
	log "launching both hosts (per-host monitor, the branch default)"
	run just launch-all
fi

# The watchdog has to go FIRST, not after the startup wait. It stops every
# golfcart unit after 6 missed pings (~42 s), and the link fills the moment the
# stacks are up - well inside a 90 s wait - so stopping it later means the orin
# is already dead in exactly the cells that matter. The short sleep lets the
# orin's own launch-up start it before we stop it.
sleep 5
log "stopping the orin watchdog for the duration of this cell"
run orin systemctl --user stop golfcart-watchdog.service

log "waiting ${STARTUP}s for the stacks"
sleep "${STARTUP}"

# The real operator verb, not a hand-built rviz2 command line: `just tool rviz`
# is what someone watching the vehicle actually runs, and it loads the same
# golfcart.rviz with its 71 display subscriptions.
if [ "${RVIZ}" = "1" ]; then
	log "starting RViz on the master (DISPLAY=${RVIZ_DISPLAY})"
	DISPLAY="${RVIZ_DISPLAY}" just tool rviz >>"${OUT}/rviz.log" 2>&1 &
	RVIZ_PID=$!
	# RViz subscribes as its displays come up, so the wire must not be sampled
	# until they have. 30 s is the observed time to a drawn window on the Orin.
	sleep 30
fi

log "starting recorders on both hosts"
run just record start
sleep "${STEADY}"

# Who actually reads the clouds, and on which host. This is the direct
# instrument for the mechanism the whole branch rests on: "two or more reader
# PROCESSES" versus "the orin genuinely subscribed". It is a graph query, not a
# subscription, so it adds no reader and cannot perturb the decision it reports.
log "reader census on the raw clouds"
for topic in /sensing/lidar/vlp32/velodyne_points /sensing/camera/zed/rgb/color/rect/image; do
	echo "== ${topic}" >>"${OUT}/readers.txt"
	ros2 topic info -v "${topic}" >>"${OUT}/readers.txt" 2>&1
done

# The MASTER's NIC counters already describe both directions: tx is
# master->orin, rx is orin->master. That is what fills both tables in the doc.
# The orin's own sample is a cross-check only, and it is the fragile one - its
# ssh is opened during saturation and would stream its output back over the
# flooded wire - so it writes to the orin's own log/ and is fetched after the
# wire is quiet again. A failure there must not cost the cell.
log "sampling the wire for ${SAMPLE}s, both directions at once"
timeout $((SAMPLE + 90)) "${ON_ORIN}" bash -c ". scripts/env.sh >/dev/null 2>&1; ./scripts/check/link_pressure.sh ${ORIN_IFACE} ${SAMPLE} > log/link_cell_orin.txt 2>&1" &
OPID=$!
"${REPO_DIR}/scripts/check/link_pressure.sh" "${IFACE}" "${SAMPLE}" "${OUT}/master_nic.csv" \
	>"${OUT}/master_nic.txt" 2>&1
wait "${OPID}" 2>/dev/null

# Small topics only. Both are the ones that degrade first when the wire fills:
# the twist estimator needs the ZED IMU and its /tf, and imu_corrector's output
# is reliable, so a drop there means the link is badly gone.
# The first topic is the CONTROL and is why this loop is trustworthy. It is
# published on this host, by this host's own driver, and crosses nothing; if it
# reads zero then the CLI failed to discover under load and the other two rows
# say nothing about the link. Cell 1 returned an empty file for both cross-link
# topics with no way to tell those cases apart.
log "rates: one local control topic, then the two small cross-link ones"
for topic in /sensing/lidar/vlp32/velodyne_points /sensing/imu/imu_data /localization/twist_estimator/twist_with_covariance; do
	echo "== ${topic}" >>"${OUT}/topic_hz.txt"
	timeout 25 ros2 topic hz --window 20 "${topic}" >>"${OUT}/topic_hz.txt" 2>&1
	echo >>"${OUT}/topic_hz.txt"
done
# Graph size beside the rates: a CLI that discovered nothing and a link that
# delivered nothing look identical in `topic hz` and nothing else.
{
	echo "== graph as this host sees it"
	echo "topics: $(ros2 topic list 2>/dev/null | wc -l)  nodes: $(ros2 node list 2>/dev/null | wc -l)"
} >>"${OUT}/topic_hz.txt" 2>&1

# The orin's groups are collected ON the orin, into its own log/, and fetched
# after teardown. In cell 1 this ran as an ssh during the storm and timed out:
# an ssh opened while the wire is full is not an instrument.
log "multicast groups (master now, orin collected locally)"
run orin bash -c 'ip -4 maddr show > log/link_cell_groups.txt 2>&1'
{
	echo "== master"
	just link groups
} >"${OUT}/groups.txt" 2>&1

log "stopping the recorders and reading the bags"
run just record stop
sleep 5
{
	echo "== master bag"
	BAG="$(ls -dt "${GOLFCART_BAG_DIR:-/mnt/external/rosbags}"/* 2>/dev/null | head -1)"
	echo "${BAG}"
	ros2 bag info "${BAG}" 2>&1 | grep -E 'velodyne_points|falcon|Duration|Messages'
} >"${OUT}/bags.txt" 2>&1

log "stopping both stacks"
run just stop-all

# Now the wire is quiet, so fetching the orin's cross-check costs nothing.
log "fetching the orin's own NIC sample and groups"
orin cat log/link_cell_orin.txt >"${OUT}/orin_nic.txt" 2>/dev/null
{
	echo "== orin"
	orin cat log/link_cell_groups.txt
} >>"${OUT}/groups.txt" 2>&1

# The trap restores spdp; say so in the log so a reader of OUT knows the vehicle
# is not left on whatever this cell set.
log "cell complete: ${OUT}"
echo "${OUT}"
