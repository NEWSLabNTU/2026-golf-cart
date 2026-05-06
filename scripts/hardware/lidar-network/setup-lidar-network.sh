#!/usr/bin/env bash
# Install NetworkManager profiles for LiDAR ethernet interfaces.
# Bound by MAC address — edit templates if hardware MAC differs per box.
# Velodyne VLP-32C  : 192.168.7.1/24  (currently enP5p4s0)
# Seyond Falcon L   : 172.168.1.1/24  (currently enP5p5s0)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/templates"
TARGET_DIR="/etc/NetworkManager/system-connections"

for f in velodyne-vlp32c.nmconnection seyond-falcon-l.nmconnection; do
  echo "Installing ${f}..."
  install -m 0600 -o root -g root "${TEMPLATES}/${f}" "${TARGET_DIR}/${f}"
done

echo "Reloading NetworkManager..."
nmcli connection reload

echo
echo "Done. Verify with:"
echo "  nmcli connection show"
echo "  ip -4 addr show"
echo
echo "Activate explicitly if needed:"
echo "  sudo nmcli connection up 'Velodyne 32C LiDAR'"
echo "  sudo nmcli connection up 'Seyond Falcon L LiDAR'"
