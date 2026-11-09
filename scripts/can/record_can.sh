#!/usr/bin/env bash
# Record raw CAN frames (candump -L) as a one-host recording session, Ctrl-C stops.
# Usage: ./scripts/can/record_can.sh [iface]      (no iface: every bus in scope `can`)
#
# Writes recordings/<id>/<role>/<iface>.log, the session layout of
# docs/recording.md. Logs recorded before sessions are in rosbags/can/ and
# still replay with `just can play <file>`. The runner warns when a bus shows
# no frames at start (the VCU bus is on the orin).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -n "${1:-}" ]; then
    exec "${REPO_ROOT}/scripts/recording/record_foreground.sh" "" can --can "$1"
fi
exec "${REPO_ROOT}/scripts/recording/record_foreground.sh" "" can
