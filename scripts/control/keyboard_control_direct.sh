#!/bin/bash
# Terminal keyboard controller (autoware_manual_control) for direct vehicle control.
#
# Pairs with `just vehicle-interface`, which brings up the vehicle interface on
# its own. No vehicle_cmd_gate runs in that setup, so the controller's
# /external/selected/* outputs are remapped straight onto /control/command/*,
# which is what golfcart_vehicle_interface subscribes to.
#
# Control mode is the driver's: the interface transmits commands only while the
# VCU reports all four subsystems (MTR, BRK, EPS, Drv) autonomous, and nothing
# here — no service call, no key — can change that. Switch the vehicle over on
# its own controls first. This script reports the mode it sees before starting,
# so a cart that will not move is diagnosed before you press a key.
#
# Usage: just manual-control [--no-mode-check]
set -uo pipefail

cd "$(dirname "$0")/../.."
source install/setup.bash

CHECK_MODE=1
for arg in "$@"; do
    case "$arg" in
        --no-mode-check) CHECK_MODE=0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if [[ "$CHECK_MODE" == "1" ]]; then
    # ControlModeReport: 1=AUTONOMOUS, 4=MANUAL, 5=DISENGAGED, 6=NOT_READY.
    MODE=$(timeout 5 ros2 topic echo --once --field mode \
        /vehicle/status/control_mode 2>/dev/null | tr -d '[:space:]')
    case "$MODE" in
        1) echo "Vehicle reports AUTONOMOUS — commands will reach the cart." ;;
        4) echo "Vehicle reports MANUAL — the driver holds it. Keys will have no effect" \
                "until the vehicle is switched to autonomous on its own controls." ;;
        5) echo "Vehicle reports DISENGAGED — a fault is latched. Clear it with:" \
                "ros2 service call /control/control_mode_request" \
                "autoware_vehicle_msgs/srv/ControlModeCommand '{mode: 4}'" ;;
        6) echo "Vehicle reports NOT_READY — the four VCU subsystem states disagree or" \
                "a report frame is stale. Check 'ros2 topic echo /diagnostics'." ;;
        "") echo "No /vehicle/status/control_mode seen - is the vehicle interface running" \
                 "(just vehicle-interface)?" >&2 ;;
        *) echo "Vehicle reports control mode $MODE." ;;
    esac
fi

# Keyboard reading is raw-tty, so this has to stay in the foreground terminal.
exec ros2 run autoware_manual_control keyboard_control \
    --ros-args \
    -r /external/selected/control_cmd:=/control/command/control_cmd \
    -r /external/selected/gear_cmd:=/control/command/gear_cmd
