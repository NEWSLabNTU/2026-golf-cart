#!/usr/bin/env bash
# down-vcan0.sh — Tear down a virtual CAN interface.
#
#   sudo ./scripts/can/down-vcan0.sh           # vcan0
#   sudo ./scripts/can/down-vcan0.sh vcan1

set -euo pipefail

IFACE="${1:-vcan0}"

if (( EUID != 0 )); then
    echo "ERROR: this script needs root (use sudo)." >&2
    exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Interface $IFACE not present — nothing to do."
    exit 0
fi

echo "Bringing $IFACE down..."
ip link set down "$IFACE" || true
echo "Removing $IFACE..."
ip link delete "$IFACE"
echo "Done."
