#!/usr/bin/env bash
# Install NetworkManager profiles for LiDAR ethernet interfaces.
# Bound by MAC address. The profiles are setup/host/master/etc/NetworkManager/
# system-connections/*.nmconnection; edit them there (or `just host capture`).
# Velodyne VLP-32C  : 192.168.7.1/24  (currently enP5p4s0)
# Seyond Falcon L   : 172.168.1.1/24  (currently enP5p5s0)

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTCFG="${SCRIPT_DIR}/../../../setup/golfcart_setup/hostcfg.py"
TARGET_DIR="/etc/NetworkManager/system-connections"

# Installs and reloads NetworkManager if anything changed. A profile still
# under its old hand-made name ("falcon k lidar") is replaced, not duplicated.
python3 "${HOSTCFG}" install --role master \
  --target "${TARGET_DIR}/velodyne-vlp32c.nmconnection" \
  --target "${TARGET_DIR}/seyond-falcon-l.nmconnection"

echo
echo "Done. Verify with:"
echo "  nmcli connection show"
echo "  ip -4 addr show"
echo
echo "Activate explicitly if needed:"
echo "  sudo nmcli connection up 'Velodyne 32C LiDAR'"
echo "  sudo nmcli connection up 'Seyond Falcon L LiDAR'"
