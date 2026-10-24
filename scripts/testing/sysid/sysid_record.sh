#!/usr/bin/env bash
# sysid_record.sh - record what sysid_fit.py needs, as a bag and a CAN log side by side.
#
#   scripts/testing/sysid/sysid_record.sh NAME [CAN_HOST]     # Ctrl-C to stop
#
# Phase 8, V4. Run on the machine that runs sysid_steps.py, in a shell that
# sourced scripts/env.sh, then drive the steps from a second terminal.
#
# Where: Autoware's vehicle_cmd_gate publishes control_cmd whenever the stack is
# up (golfcart.launch.yaml passes launch_control "true", not an argument), and
# sysid_steps.py refuses to share the topic. So the vehicle day runs on the
# ORIN, without the stack: `just vehicle interface` (can0), the ZED for its IMU
# (`ros2 launch golfcart_sensor_kit_launch camera.launch.xml camera_model:=zedx`),
# this script, and sysid_steps.py. The link hop to the master is then not in
# the measured delay; add it from `just link pressure` if it is not negligible.
#
# Writes $GOLFCART_BAG_DIR/sysid-NAME/ (rosbag2) and, beside it,
# $GOLFCART_BAG_DIR/sysid-NAME.can.log (candump -L of the vehicle bus).
#
#   bag   the command as published and the reports as Autoware reads them,
#         stamped on arrival here. Plus the ZED IMU (the yaw-rate channel, the
#         only view of LEFT steering while the VCU's left report reads 0) and
#         the control mode, so steps taken outside AUTO are rejected.
#   CAN   the interface's slew-limited setpoints and the VCU's raw reports on
#         one clock: the VCU's own delay, without the interface and the report
#         tick. CAN_HOST: auto (default: local if this machine has can0, else
#         the orin over ssh, like `just can vcu-status`), local, orin, none.
#
# The vehicle topics are also in config/recording/master_topics.txt; this list
# is the small one, so a sysid bag is megabytes, not the LiDAR's gigabytes.
set -euo pipefail

NAME=${1:?usage: sysid_record.sh NAME [auto|local|orin|none]}
CAN_HOST=${2:-auto}
if [ "$CAN_HOST" = auto ]; then
  if ip link show can0 >/dev/null 2>&1; then CAN_HOST=local; else CAN_HOST=orin; fi
fi
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
OUT="${GOLFCART_BAG_DIR:?source scripts/env.sh first: it sets GOLFCART_BAG_DIR}/sysid-$NAME"
CAN_LOG="$OUT.can.log"

TOPICS=(
  /control/command/control_cmd
  /control/command/gear_cmd
  /control/command/emergency_cmd
  /vehicle/emergency_stop
  /vehicle/status/steering_status
  /vehicle/status/velocity_status
  /vehicle/status/actuation_status
  /vehicle/status/control_mode
  /vehicle/status/gear_status
  /sensing/camera/zed/imu/data
  /sensing/imu/imu_data
)

[ -e "$OUT" ] && { echo "exists: $OUT" >&2; exit 1; }

CAN_PID=
case "$CAN_HOST" in
  none) ;;
  local)
    candump -L can0 > "$CAN_LOG" &
    CAN_PID=$! ;;
  orin)
    # shellcheck disable=SC1091
    source "$REPO/config/multi_machine.conf"
    KEY=()
    [ -n "${ORIN_SSH_KEY:-}" ] && [ -f "$ORIN_SSH_KEY" ] && KEY=(-i "$ORIN_SSH_KEY")
    # -T: no tty, so the pipe closing on our exit ends candump on the orin.
    ssh -T "${KEY[@]}" "$ORIN_SSH" 'exec candump -L can0' > "$CAN_LOG" &
    CAN_PID=$! ;;
  *) echo "CAN_HOST must be auto, local, orin or none" >&2; exit 1 ;;
esac
trap '[ -n "$CAN_PID" ] && kill "$CAN_PID" 2>/dev/null; true' EXIT

echo "bag: $OUT"
[ -n "$CAN_PID" ] && echo "CAN: $CAN_LOG ($CAN_HOST)"
echo "now, in another terminal: python3 scripts/testing/sysid/sysid_steps.py PROFILE"
echo "afterwards: python3 scripts/testing/sysid/sysid_fit.py $OUT${CAN_PID:+ --can $CAN_LOG}"
ros2 bag record -o "$OUT" "${TOPICS[@]}"
