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

# One sed per host, on the one element that is the whole axis. Nothing else in
# the profile is touched, and the profiles are copied into OUT as proof.
set_multicast() {
	local value="$1"
	sed -i "s|<AllowMulticast>[^<]*</AllowMulticast>|<AllowMulticast>${value}</AllowMulticast>|" "${MASTER_XML}"
	"${ON_ORIN}" sed -i "s|<AllowMulticast>[^<]*</AllowMulticast>|<AllowMulticast>${value}</AllowMulticast>|" config/cyclonedds/orin.xml
}

# Leave the vehicle in the branch's resting state whatever happens, including a
# Ctrl-C in the middle of a saturated cell.
cleanup() {
	log "cleanup: stopping record and stack, restoring spdp"
	if [ -n "${RVIZ_PID}" ]; then
		kill "${RVIZ_PID}" 2>/dev/null
		pkill -f 'rviz2 .*golfcart' 2>/dev/null
	fi
	run just record stop
	run just stop-all
	set_multicast spdp
	log "cleanup done"
}
trap cleanup EXIT INT TERM

log "cell ${MULTICAST}/${MONITOR}: startup ${STARTUP}s, steady ${STEADY}s, sample ${SAMPLE}s"

# A running ros2 daemon holds the profile it started with, so a cell that only
# edited the XML would measure the previous cell's transport.
run just stop-all
run ros2 daemon stop
run "${ON_ORIN}" ros2 daemon stop

set_multicast "${MULTICAST}"
cp "${MASTER_XML}" "${OUT}/master.xml"
"${ON_ORIN}" cat config/cyclonedds/orin.xml >"${OUT}/orin.xml" 2>/dev/null
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

log "stopping the orin watchdog for the duration of this cell"
run "${ON_ORIN}" systemctl --user stop golfcart-watchdog.service

log "starting recorders on both hosts"
run just record start
sleep "${STEADY}"

log "sampling the wire for ${SAMPLE}s, both directions at once"
"${REPO_DIR}/scripts/check/link_pressure.sh" "${IFACE}" "${SAMPLE}" "${OUT}/master_pressure.csv" \
	>"${OUT}/master_to_orin.txt" 2>&1 &
MPID=$!
"${ON_ORIN}" ./scripts/check/link_pressure.sh "${ORIN_IFACE}" "${SAMPLE}" \
	>"${OUT}/orin_to_master.txt" 2>&1 &
OPID=$!
wait "${MPID}" "${OPID}"

# Small topics only. Both are the ones that degrade first when the wire fills:
# the twist estimator needs the ZED IMU and its /tf, and imu_corrector's output
# is reliable, so a drop there means the link is badly gone.
log "rates of the two small cross-link topics"
for topic in /sensing/imu/imu_data /localization/twist_estimator/twist_with_covariance; do
	echo "== ${topic}" >>"${OUT}/topic_hz.txt"
	timeout 20 ros2 topic hz "${topic}" >>"${OUT}/topic_hz.txt" 2>&1
done

log "multicast groups on both hosts"
{
	echo "== master"
	just link groups
	echo "== orin"
	"${ON_ORIN}" just link groups
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

# The trap restores spdp; say so in the log so a reader of OUT knows the vehicle
# is not left on whatever this cell set.
log "cell complete: ${OUT}"
echo "${OUT}"
