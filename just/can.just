# CAN bus record, replay and decode
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...` path
# in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so without this `just vehicle` would bring up the vehicle interface and
# `just ntu-test` would start a bag. Naming it `default` makes the harmless
# thing the accident.
# List this module's recipes
default:
    @just --list can

# Record raw CAN frames (candump -L format) to rosbags/can/
record IFACE="can0":
    ./scripts/can/record_can.sh {{IFACE}}

# Replay a CAN log onto vcan0. Defaults to most recent log in rosbags/can/.
play LOG="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{LOG}}" ]; then
        F="{{LOG}}"
    else
        F=$(ls -t rosbags/can/*.log 2>/dev/null | head -1 || true)
        [ -n "$F" ] || { echo "No logs in rosbags/can/"; exit 1; }
    fi
    ./scripts/can/replay_can.sh "$F" vcan0

# Offline vehicle interface test: vcan0 + vehicle_interface_test launch + replay log
# Loops the replay by default so topics keep flowing; pass LOOP=0 to play once.
test LOG="" LOOP="1":
    #!/usr/bin/env bash
    set -euo pipefail
    if ! ip link show vcan0 >/dev/null 2>&1; then
        sudo ./scripts/can/up-vcan0.sh vcan0
    fi
    if [ -n "{{LOG}}" ]; then
        F="{{LOG}}"
    else
        F=$(ls -t rosbags/can/*.log 2>/dev/null | head -1 || true)
        [ -n "$F" ] || { echo "No logs in rosbags/can/"; exit 1; }
    fi
    LOOP_FLAG=""
    if [ "{{LOOP}}" = "1" ] || [ "{{LOOP}}" = "true" ]; then
        LOOP_FLAG="--loop"
    fi
    parallel --line-buffer ::: \
      "ros2 launch golfcart_vehicle_launch vehicle_interface_standalone.launch.xml can_interface:=vcan0" \
      "sleep 3 && ./scripts/can/replay_can.sh $LOOP_FLAG \"$F\" vcan0"

# ============================================================================
# Simulation Commands - Full simulation scenarios

# Decode live CAN frames using vehicle DBC (CAX_ADS_CAN.dbc)
# Usage: just can decode          (defaults to can0)
#        just can decode can1
# Decode live CAN frames using the vehicle DBC (CAX_ADS_CAN.dbc)
decode IFACE="can0":
    candump {{IFACE}} | cantools decode \
        src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc
