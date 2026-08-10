#!/usr/bin/env bash
# install-chrony-timesync.sh - align the master's and orin's clocks.
#
# The two hosts record separate bags. Cross-referencing them needs their clocks
# closer together than the ~hundreds of milliseconds error bound that the 4G NTP
# pools give each host independently. Making the master a local time server and
# the orin its client brings that to sub-millisecond over the LAN.
#
# Run ON THE HOST being configured:
#   sudo ./setup/scripts/install-chrony-timesync.sh master
#   sudo ./setup/scripts/install-chrony-timesync.sh orin
#
# PTP note: on the master, phc2sys pushes CLOCK_REALTIME out to the Falcon NIC's
# hardware clock (-s CLOCK_REALTIME -c enP5p5s0). chrony disciplines
# CLOCK_REALTIME, so the two cooperate rather than fight - chrony sets the system
# clock, phc2sys propagates it to the LiDAR. Do not point phc2sys the other way
# while chrony is running.

set -eo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
SRC="${REPO_DIR}/setup/files/chrony"

ROLE="${1:-}"

case "${ROLE}" in
  master)
    DST="/etc/chrony/conf.d/golfcart-master.conf"
    FILE="${SRC}/golfcart-master.conf"
    ;;
  orin)
    DST="/etc/chrony/sources.d/golfcart-orin.sources"
    FILE="${SRC}/golfcart-orin.sources"
    ;;
  *)
    echo "Usage: $0 <master|orin>" >&2
    exit 2
    ;;
esac

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root" >&2
  exit 1
fi

if ! command -v chronyd >/dev/null 2>&1; then
    echo "ERROR: chrony is not installed. apt install chrony" >&2
    exit 1
fi

if [ ! -d "$(dirname "${DST}")" ]; then
    echo "ERROR: $(dirname "${DST}") does not exist - is this chrony new enough?" >&2
    exit 1
fi

echo "Installing ${FILE} -> ${DST}"
install -m 644 "${FILE}" "${DST}"

# systemd-timesyncd and chrony both discipline the system clock; running the two
# together makes the offset jump around unpredictably.
if systemctl is-enabled systemd-timesyncd >/dev/null 2>&1; then
    echo "Disabling systemd-timesyncd (conflicts with chrony)..."
    systemctl disable --now systemd-timesyncd
fi

echo "Restarting chrony..."
systemctl restart chrony

echo
echo "Done. Verify with:"
if [ "${ROLE}" = "master" ]; then
    echo "  chronyc clients          # the orin should appear once it polls"
else
    echo "  chronyc sources          # 192.168.125.100 should be selected (^*)"
    echo "  chronyc tracking         # check System time offset"
fi
