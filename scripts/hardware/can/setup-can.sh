#!/usr/bin/env bash
# Install CAN module autoload and systemd-networkd interface configs for can0/can1.
# Replaces scripts/setup-can.sh (modprobe + ip link) with persistent boot-time setup.
# Pinmux (devmem writes) assumed already applied via DT or prior boot.

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/templates"

if ! command -v candump >/dev/null 2>&1 || ! command -v canplayer >/dev/null 2>&1; then
  echo "Installing can-utils (candump/canplayer/cansend)..."
  apt-get update
  apt-get install -y can-utils
fi

install -m 0644 "${TEMPLATES}/can.conf"        /etc/modules-load.d/can.conf
install -m 0644 "${TEMPLATES}/80-can0.network" /etc/systemd/network/80-can0.network
install -m 0644 "${TEMPLATES}/80-can1.network" /etc/systemd/network/80-can1.network

echo "Loading CAN modules now..."
modprobe can
modprobe can_raw
modprobe mttcan

echo "Enabling systemd-networkd..."
systemctl enable --now systemd-networkd
systemctl restart systemd-networkd

echo
echo "Done. Verify with:"
echo "  ip -details link show can0"
echo "  ip -details link show can1"
echo "  candump can0"
