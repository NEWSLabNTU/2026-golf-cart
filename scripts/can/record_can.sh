#!/usr/bin/env bash
# Record raw CAN frames to a candump -L log.
# Usage: ./scripts/can/record_can.sh [iface] [out_dir]
set -euo pipefail

IFACE="${1:-can0}"
OUT_DIR="${2:-rosbags/can}"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "ERROR: interface $IFACE not found" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT_DIR}/can_${IFACE}_${TS}.log"

echo "Recording $IFACE -> $OUT (Ctrl-C to stop)"
exec candump -L "$IFACE" > "$OUT"
