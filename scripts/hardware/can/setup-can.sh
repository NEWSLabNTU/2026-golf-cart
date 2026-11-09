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
HOSTCFG="${SCRIPT_DIR}/../../../setup/golfcart_setup/hostcfg.py"

if ! command -v candump >/dev/null 2>&1 || ! command -v canplayer >/dev/null 2>&1; then
  echo "Installing can-utils (candump/canplayer/cansend)..."
  apt-get update
  apt-get install -y can-utils
fi

# The files live in setup/host/master/etc/ (setup/host/manifest.yaml).
python3 "${HOSTCFG}" install --role master --no-reload \
  --target /etc/modules-load.d/can.conf \
  --target /etc/systemd/network/80-can0.network \
  --target /etc/systemd/network/80-can1.network

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
