#!/usr/bin/env bash

# Create the NetworkManager profile for the master <-> orin interlink.
#
# The two machines sit on the same cart, so they are joined by a direct Ethernet
# cable rather than the WiFi AP the original design assumed: this master has no
# wireless radio at all (empty M.2 Key-E slot), and a wired segment also gives
# 1 Gb/s, working multicast, and PTP hardware timestamping.
#
#   master -> 192.168.13.1/24
#   orin   -> 192.168.13.2/24
#
# The addresses match config/cyclonedds/{master,orin}.xml, which bind by address
# rather than by interface name precisely because the NIC is named differently on
# each machine.
#
# Usage:
#   sudo ./setup-interlink.sh master enP5p6s0
#   sudo ./setup-interlink.sh orin   <iface>

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONNECTIONS_DIR="/etc/NetworkManager/system-connections"

HOST="${1:-}"
IFACE="${2:-}"

case "${HOST}" in
  master) ADDRESS="192.168.13.1" ;;
  orin)   ADDRESS="192.168.13.2" ;;
  *)
    echo "Usage: $0 <master|orin> <interface>" >&2
    exit 1
    ;;
esac

if [ -z "${IFACE}" ]; then
  echo "Usage: $0 <master|orin> <interface>" >&2
  exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

if [ ! -e "/sys/class/net/${IFACE}" ]; then
  echo "Interface ${IFACE} does not exist on this machine." >&2
  echo "Available: $(ls /sys/class/net | tr '\n' ' ')" >&2
  exit 1
fi

ID="interlink-${HOST}"
echo "Setting up interlink profile '${ID}' (${ADDRESS}/24 on ${IFACE})..."

TEMPLATE="${SCRIPT_DIR}/templates/interlink.nmconnection.in"
if [ ! -f "${TEMPLATE}" ]; then
  echo "Interlink template not found at ${TEMPLATE}. Please create it first."
  exit 1
fi

# Generate connection file from template
echo "Generating NetworkManager profile from template..."
sed -e "s/@ID@/${ID}/g" \
    -e "s/@IFACE@/${IFACE}/g" \
    -e "s/@ADDRESS@/${ADDRESS}/g" \
    "${TEMPLATE}" > "/tmp/${ID}.nmconnection"

# Install connection file
echo "Installing NetworkManager profile..."
install -m 600 "/tmp/${ID}.nmconnection" "${CONNECTIONS_DIR}/${ID}.nmconnection"

# Clean up temporary file
rm "/tmp/${ID}.nmconnection"

# Reload NetworkManager connections
echo "Reloading NetworkManager connections..."
nmcli connection reload

echo "Done. Interlink connection '${ID}' is now available."
echo "You can activate it with:"
echo "  sudo nmcli connection up ${ID}"
