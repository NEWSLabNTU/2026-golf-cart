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

# An interface that is up but wired to nothing records an empty file without a
# word: on 2026-11-06 a steering test was recorded on the master, whose can0 is
# up but no longer on the bus (it moved to the orin), and the log was 0 bytes.
# Sample the RX counter for a second and say so before recording.
RX_FILE="/sys/class/net/${IFACE}/statistics/rx_packets"
if [[ -r "$RX_FILE" ]]; then
    RX0=$(cat "$RX_FILE"); sleep 1; RX1=$(cat "$RX_FILE")
    if [[ "$RX1" -eq "$RX0" ]]; then
        echo "WARNING: no frames received on $IFACE in 1 s - this log will be empty." >&2
        echo "  The VCU bus is on the orin (vehicle_host:=orin); this host is $(hostname)." >&2
        echo "  Recording anyway; Ctrl-C if this is the wrong machine." >&2
    fi
fi

mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d_%H%M%S)"
OUT="${OUT_DIR}/can_${IFACE}_${TS}.log"

echo "Recording $IFACE -> $OUT (Ctrl-C to stop)"
exec candump -L "$IFACE" > "$OUT"
