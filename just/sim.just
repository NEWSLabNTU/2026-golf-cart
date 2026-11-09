# Simulators (planning, logging replay, ArUco) and synthetic cameras on
# v4l2loopback, for working without hardware attached
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...` path
# in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so `default` has to come first and has to be the harmless one.
# List this module's recipes
default:
    @just --list sim

# ============================================================================
# Simulators. ARGS are launch arguments, `key:=value`, plus `@name` for
# config/launch/<name>.args (`@sim-basement`, `@sim-mingda-loop`,
# `@sim-ntu-r02`, ...), expanded in place by scripts/launch/args.py, which prints
# the final list first. Later args win. Single host: no host:= / master_ip:=.
# ============================================================================

# planning_sim.launch.xml is autoware_launch's planning_simulator with
# golfcart_vehicle, golfcart_sensor_kit and our planning component, so
# planning_preset:= works (slow_indoor | default; default is stock). map_path:=
# is required. With @sim-basement up, from another terminal:
#   python3 scripts/testing/sim_route_check.py --start X Y YAW_DEG --goal X Y YAW_DEG
# Planning simulator. ARGS: map_path:= or @sim-* file, then overrides
[positional-arguments]
planning *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    RVIZ=()
    [ -n "${DISPLAY:-}" ] || RVIZ=(--no-rviz)
    OUT=$(python3 ./scripts/launch/args.py --label "sim planning args" \
        --require map_path "${RVIZ[@]}" "$@") || exit 2
    mapfile -t LAUNCH_ARGS <<< "${OUT}"
    exec play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch planning_sim.launch.xml \
        "${LAUNCH_ARGS[@]}"

# Logging simulation: the stack, drivers off, against a rosbag you play. ARGS: [launch args, @file]
[positional-arguments]
logging *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    RVIZ=()
    [ -n "${DISPLAY:-}" ] || RVIZ=(--no-rviz)
    OUT=$(python3 ./scripts/launch/args.py --label "sim logging args" "${RVIZ[@]}" "$@") || exit 2
    LAUNCH_ARGS=()
    [ -n "${OUT}" ] && mapfile -t LAUNCH_ARGS <<< "${OUT}"
    exec play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch logging_simulation.launch.yaml \
        "${LAUNCH_ARGS[@]}"

# Its own recipe, not `planning @file`: aruco_planning_sim.launch.xml is a
# different composition (no dummy vehicle; the ArUco localizer under test
# produces the pose). rviz defaults false there. map_path:= is required.
# Phase 3D-6 stage 2: ArUco localization driving the planning simulator. ARGS: [@sim-aruco, overrides]
[positional-arguments]
aruco *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    [ $# -gt 0 ] || set -- @sim-aruco
    OUT=$(python3 ./scripts/launch/args.py --label "sim aruco args" --require map_path "$@") || exit 2
    mapfile -t LAUNCH_ARGS <<< "${OUT}"
    exec play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch aruco_planning_sim.launch.xml \
        "${LAUNCH_ARGS[@]}"

# Its own recipe: three processes, not one launch. `sim logging`, then the NTU
# COSS Park bag (./scripts/rosbag/download-test-rosbag.sh) on a loop, then a
# localization recording. ARGS go to `sim logging`.
# COSS Park scenario: logging sim + rosbag feed + localization recording
[positional-arguments]
coss-park *ARGS:
    #!/usr/bin/env bash
    printf -v SIM '%q ' just sim logging "$@"
    parallel --line-buffer ::: \
        "${SIM}" \
        "sleep 40 && ros2 bag play data/rosbags/outdoor_20251226_153115/ --clock -l -r 1.0" \
        "sleep 45 && ./scripts/rosbag/record_localization.sh"

# With `just sim planning @sim-mingda-loop` up: drive N laps (`--laps 2`; `--check-only` without ROS)
[positional-arguments]
loop-drive *ARGS:
    python3 scripts/testing/sim_loop_drive.py "$@"

# With `just sim planning @sim-mingda` up: fault NDT while driving and follow
# the MRM to the CAN frames (vcan0 + mock_vcu). `--no-can` on a machine without
# vcan0 or the vendor DBC.
# MRM end-to-end check on the Ming-Da lane. ARGS go to the script
[positional-arguments]
mrm-check *ARGS:
    python3 scripts/testing/sim_mrm_check.py --start 17.6 -4.9 180 --goal 6.5 -4.9 180 "$@"

# ============================================================================
# Synthetic cameras
# ============================================================================

# Create three v4l2loopback devices at the real camera geometry (needs sudo)
cameras-up:
    ./scripts/sim/cameras.sh up

# Start three UYVY test sources feeding those devices
cameras-feed:
    ./scripts/sim/cameras.sh feed

# Write gmslcam param files pointing at the synthetic devices
cameras-configs:
    ./scripts/sim/cameras.sh configs

# The NVJPG capacity check from docs/roadmaps/2-camera-image-pipeline.md
# sub-phase A. On the Advantech it is the real answer; anywhere else it measures
# CPU jpegenc and says so. A blank line separates this from the doc comment
# below, because just takes only the LAST contiguous comment block as the
# recipe's description in `just --list`.

# Encoder throughput, one stream against three. No devices or cameras needed.
cameras-bench SECS="10":
    SECS={{SECS}} ./scripts/sim/cameras.sh bench

# What is loaded, what exists, what is running
cameras-status:
    ./scripts/sim/cameras.sh status

# Stop the feeders and unload the module (needs sudo)
cameras-down:
    ./scripts/sim/cameras.sh down

# up + feed + configs, the usual starting sequence
cameras: cameras-up cameras-feed cameras-configs
