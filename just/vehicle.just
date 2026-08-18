# Vehicle interface bring-up, bench testing and control tests
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
    @just --list vehicle

# Vehicle interface on its own, without Autoware. Bench and bring-up.
# Options are KEY=VALUE in any order:
#   can=can0|vcan0     SocketCAN interface                          (default can0)
#   tx=on|off          CAN TX master enable                         (default off)
#   converter=on|off   robot_state_publisher + velocity converter   (default off)
# With tx=off the node only listens: /vehicle/status/* and /diagnostics fill in
# and the cart cannot be commanded into motion.
# For keys, run `just vehicle manual-control` in a second terminal.
# ⚠️  tx=on puts real frames on the bus and can command motion.
interface *OPTS="":
    #!/usr/bin/env bash
    set -euo pipefail
    CAN=can0
    TX=false
    CONVERTER=false
    for opt in {{OPTS}}; do
        case "$opt" in
            can=*)                         CAN="${opt#can=}" ;;
            tx=on|tx=true)                 TX=true ;;
            tx=off|tx=false)               TX=false ;;
            converter=on|converter=true)   CONVERTER=true ;;
            converter=off|converter=false) CONVERTER=false ;;
            *)
                echo "Unknown option '$opt'" >&2
                echo "Usage: just vehicle interface [can=IFACE] [tx=on|off] [converter=on|off]" >&2
                echo "       keyboard control is a separate recipe: just vehicle manual-control" >&2
                exit 2 ;;
        esac
    done
    if [[ "$TX" == "true" ]]; then
        printf '\033[1;31mCAN TX ENABLED on %s — the cart can move. Ctrl-C to abort.\033[0m\n' "$CAN"
        for i in 3 2 1; do printf '  starting in %d...\r' "$i"; sleep 1; done
        printf '                       \n'
    fi
    ros2 launch golfcart_vehicle_launch vehicle_interface_standalone.launch.xml \
        can_interface:="$CAN" \
        tx_enabled:="$TX" \
        vehicle_description:="$CONVERTER" \
        velocity_converter:="$CONVERTER"

# Terminal keyboard controller (autoware_manual_control), commanding /control/command/*.
# Run in a second terminal next to `just vehicle interface` — keys are read from a
# raw tty, so this must own a real terminal and cannot live inside a launch file.
# Keys: x drive, c reverse, v park, u/o speed, j/l steer, i/k zero, s status, z mode.
# Limits are the cart's: 5 m/s ceiling in 0.25 m/s steps, 0.349 rad in 1° steps.
# Extra ARGS are appended to --ros-args, e.g. just vehicle manual-control "-p max_speed:=2.0"
manual-control *ARGS="":
    ros2 run autoware_manual_control keyboard_control --ros-args \
        -p mode_backend:=control_mode \
        -p control_cmd_topic:=/control/command/control_cmd \
        -p gear_cmd_topic:=/control/command/gear_cmd \
        -p max_speed:=5.0 \
        -p step_speed:=0.25 \
        -p max_steer_angle:=0.349 \
        -p step_steer_angle:=0.0174 \
        {{ARGS}}

# ============================================================================
# Control Commands - Control system testing

# Run trajectory player with straight_10m.yaml (10m straight line)
# Needs the vehicle stack up: just vehicle interface converter=on
control-straight:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=straight_10m.yaml

# Run trajectory player with circle.yaml (circular path)
# Needs the vehicle stack up: just vehicle interface converter=on
control-circle:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=circle.yaml
