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

# A one-host session, scope `can`: recordings/<id>/<role>/<iface>.log (candump -L).
# No IFACE: every bus the scope lists for this host. Ctrl-C stops.
# Record raw CAN frames (candump -L) as a session in the foreground
record IFACE="":
    ./scripts/can/record_can.sh {{IFACE}}

# LOG: a .log file, or a session id (its first non-empty log here). Default: the
# newest non-empty log in recordings/, then rosbags/can/ (pre-session logs).
# Replay a CAN log onto vcan0
play LOG="":
    #!/usr/bin/env bash
    set -euo pipefail
    F=$(just can _find-log "{{LOG}}")
    ./scripts/can/replay_can.sh "$F" vcan0

[private]
_find-log LOG="":
    #!/usr/bin/env bash
    set -euo pipefail
    L="{{LOG}}"
    if [ -n "$L" ] && [ -f "$L" ]; then echo "$L"; exit 0; fi
    if [ -n "$L" ]; then
        for f in recordings/"$L"/*/*.log; do
            [ -s "$f" ] && { echo "$f"; exit 0; }
        done
        echo "No log '$L' (a file, or a session id with a non-empty .log)" >&2; exit 1
    fi
    F=$(python3 scripts/recording/session.py latest can || true)
    [ -n "$F" ] || F=$(ls -t rosbags/can/*.log 2>/dev/null | head -1 || true)
    [ -n "$F" ] || { echo "No non-empty CAN log in recordings/ or rosbags/can/" >&2; exit 1; }
    echo "$F"

# Offline vehicle interface test: vcan0 + vehicle_interface_test launch + replay log
# Loops the replay by default so topics keep flowing; pass LOOP=0 to play once.
test LOG="" LOOP="1":
    #!/usr/bin/env bash
    set -euo pipefail
    if ! ip link show vcan0 >/dev/null 2>&1; then
        sudo ./scripts/can/up-vcan0.sh vcan0
    fi
    F=$(just can _find-log "{{LOG}}")
    LOOP_FLAG=""
    if [ "{{LOOP}}" = "1" ] || [ "{{LOOP}}" = "true" ]; then
        LOOP_FLAG="--loop"
    fi
    parallel --line-buffer ::: \
      "ros2 launch golfcart_vehicle_launch vehicle_interface_standalone.launch.xml can_interface:=vcan0" \
      "sleep 3 && ./scripts/can/replay_can.sh $LOOP_FLAG \"$F\" vcan0"

# Listens with candump on the orin over ssh (CAN_HOST=local: python-can here);
# never sends a frame. ARGS: --once | --seconds N for one snapshot, else ~2 Hz
# until Ctrl-C. Needs the vendor DBC (CAX_ADS_DBC or the crate root).
# Live VCU readout, receive only: VCU states, our commands, rates, can0 errors
vcu-status *ARGS:
    ./scripts/can/vcu_status.py {{ARGS}}

# ============================================================================
# Simulation Commands - Full simulation scenarios

# Decode live CAN frames using vehicle DBC (CAX_ADS_CAN.dbc)
# Usage: just can decode          (defaults to can0)
#        just can decode can1
# Decode live CAN frames using the vehicle DBC (CAX_ADS_CAN.dbc)
decode IFACE="can0":
    candump {{IFACE}} | cantools decode \
        src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc
