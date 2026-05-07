#!/usr/bin/env bash
# Replay a candump -L log onto a (v)CAN interface.
# Usage: ./scripts/can/replay_can.sh [--loop] <log> [target_iface]
set -euo pipefail

LOOP=0
if [[ "${1:-}" == "--loop" || "${1:-}" == "-l" ]]; then
    LOOP=1
    shift
fi

LOG="${1:?log file required}"
TGT="${2:-vcan0}"

if [[ ! -f "$LOG" ]]; then
    echo "ERROR: log file not found: $LOG" >&2
    exit 1
fi

if ! ip link show "$TGT" >/dev/null 2>&1; then
    echo "ERROR: interface $TGT missing. Run: sudo ./scripts/can/up-vcan0.sh $TGT" >&2
    exit 1
fi

SRC_IFACE="$(awk 'NR==1{print $2; exit}' "$LOG")"
if [[ -z "$SRC_IFACE" ]]; then
    echo "ERROR: could not parse source iface from $LOG" >&2
    exit 1
fi

if (( LOOP )); then
    echo "Replaying $LOG ($SRC_IFACE -> $TGT) [loop]"
    exec canplayer -I "$LOG" -l i "${TGT}=${SRC_IFACE}"
else
    echo "Replaying $LOG ($SRC_IFACE -> $TGT)"
    exec canplayer -I "$LOG" "${TGT}=${SRC_IFACE}"
fi
