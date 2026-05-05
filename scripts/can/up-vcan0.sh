#!/usr/bin/env bash
# up-vcan0.sh — Bring up a virtual CAN interface for the bench rig.
#
# Idempotent: safe to re-run. Defaults to `vcan0` but accepts an arg.
#
#   sudo ./scripts/can/up-vcan0.sh           # vcan0
#   sudo ./scripts/can/up-vcan0.sh vcan1     # named differently

set -euo pipefail

IFACE="${1:-vcan0}"

if (( EUID != 0 )); then
    echo "ERROR: this script needs root (use sudo)." >&2
    exit 1
fi

if ! lsmod | grep -q '^vcan'; then
    echo "Loading vcan kernel module..."
    modprobe vcan
fi

if ip link show "$IFACE" >/dev/null 2>&1; then
    echo "Interface $IFACE already exists."
else
    echo "Creating $IFACE..."
    ip link add dev "$IFACE" type vcan
fi

if ip link show "$IFACE" | grep -q '<.*UP'; then
    echo "Interface $IFACE already UP."
else
    echo "Bringing $IFACE up..."
    ip link set up "$IFACE"
fi

ip -details link show "$IFACE"
