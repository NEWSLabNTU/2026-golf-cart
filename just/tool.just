# Development and monitoring tools
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
    @just --list tool

# Launch RViz with Golf Cart configuration
rviz:
    rviz2 -d ./src/launcher/golfcart_launch/rviz/golfcart.rviz

# RViz for driving: fixed frame AND camera on the map, so the vehicle moves over
# the map instead of the map scrolling past a vehicle that stays put, plus a green
# arrow along the EKF heading (the vehicle model is a symmetric box). golfcart.rviz
# follows base_link, which makes forward motion look like the map moving backward.
rviz-drive:
    rviz2 -d ./src/launcher/golfcart_launch/rviz/golfcart_drive.rviz

# Check sensor transforms: cameras and LiDARs on one sphere at base_link
sphere:
    # Read-only. LCTK computes the extrinsics; this shows what the running
    # system believes them to be, so a wrong one is visible rather than
    # computed. docs/guides/sphere_sensor_view.md says how to read it.
    rviz2 -d ./src/tools/golfcart_sphere_view/config/sphere_view.rviz

# The sphere view against synthetic sensors, with no vehicle attached
sphere-demo:
    #!/usr/bin/env bash
    # Three cameras and a wall with a doorway in it. For working on the display
    # itself: it proves nothing about any real calibration, because the
    # synthetic sensors agree with each other by construction.
    set -euo pipefail
    PACKAGE=./src/tools/golfcart_sphere_view
    python3 "$PACKAGE/test/fake_camera.py" &
    CAMERAS=$!
    python3 "$PACKAGE/test/fake_lidar.py" &
    LIDAR=$!
    # Kill the publishers however RViz exits, including a Ctrl-C that lands on
    # the whole process group.
    trap 'kill $CAMERAS $LIDAR 2>/dev/null || true' EXIT
    rviz2 -d "$PACKAGE/test/sphere_view_demo.rviz"

# Launch PlotJuggler for data visualization
plotjuggler:
    ros2 run plotjuggler plotjuggler

# Launch drive monitor TUI (shows pose, speed, component states)
tui *ARGS:
    python3 ./scripts/testing/drive/run.py {{ARGS}}

# ============================================================================
# Vehicle Interface - standalone bring-up and bench testing

# Launch manual keyboard control
controller:
    ros2 run control_test keyboard_control

# The reflective board detector alone on the live cart, with its RViz layout:
# VLP-32C driver, the vehicle's calibrated TF, and the detector with the stack's
# own config (board_detector_live.launch.xml). Nothing initializes localization.
#
#   just tool board-detector                                  # basement scenario
#   just tool board-detector "reflective_pose_scenario:=sim rviz:=false"
#
# It opens the VLP-32C's UDP port, so the stack must be down: on a shared port
# the second driver hears nothing and the detector looks blind for no reason.
# Inspect the reflective board detector live, without the stack (needs the stack stopped)
board-detector ARGS="":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/_env_guard.sh
    if [[ "$(systemctl --user is-active golfcart-launch 2>/dev/null)" == "active" ]]; then
        echo "golfcart-launch.service is running and holds the VLP-32C: just stop-all first" >&2
        exit 1
    fi
    ros2 launch golfcart_launch board_detector_live.launch.xml {{ARGS}}

# The board detector under the production config, watched and judged: PASS
# needs TF, enough detections, a high enough detection rate, and every pose
# near the median one (scripts/testing/board_check.py says exactly how much).
# Options are KEY=VALUE, any order:
#
#   just tool board-check                         # live VLP-32C, Ctrl-C ends the run
#   just tool board-check duration=30             # live, 30 s
#   just tool board-check source=bag              # replay rosbags/basement/vlp32_1
#   just tool board-check source=bag rviz=off duration=60
#   just tool board-check scenario=sim bag=PATH
#
# Anything else is passed to the checker: min-detections=, min-rate=,
# max-xy-m=, max-yaw-deg=, quiet=on. Live, the stack must be down, as for
# board-detector: two drivers on the VLP-32C's port and the second hears nothing.
# Run the board detector on the production config and print PASS/FAIL
board-check *OPTS="":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/_env_guard.sh
    SOURCE=live SCENARIO=basement RVIZ=true DURATION=0
    BAG="${GOLFCART_INDOOR_BAG:-$PWD/rosbags/basement/vlp32_1}"
    CHECK=()
    for opt in {{OPTS}}; do
        case "$opt" in
            source=live|source=bag)    SOURCE="${opt#source=}" ;;
            scenario=*)                SCENARIO="${opt#scenario=}" ;;
            rviz=on|rviz=true)         RVIZ=true ;;
            rviz=off|rviz=false)       RVIZ=false ;;
            duration=*)                DURATION="${opt#duration=}" ;;
            bag=*)                     BAG="${opt#bag=}" ;;
            min-detections=*|min-rate=*|max-xy-m=*|max-yaw-deg=*)
                                       CHECK+=("--${opt%%=*}" "${opt#*=}") ;;
            quiet=on|quiet=true)       CHECK+=(--quiet) ;;
            *)
                echo "Unknown option '$opt'" >&2
                echo "Usage: just tool board-check [source=live|bag] [scenario=NAME] [rviz=on|off]" >&2
                echo "       [duration=S] [bag=PATH] [min-detections=N] [min-rate=R]" >&2
                echo "       [max-xy-m=M] [max-yaw-deg=D] [quiet=on]" >&2
                exit 2 ;;
        esac
    done
    if [[ "$SOURCE" == live && "$(systemctl --user is-active golfcart-launch 2>/dev/null)" == "active" ]]; then
        echo "golfcart-launch.service is running and holds the VLP-32C: just stop-all first" >&2
        exit 1
    fi
    exec scripts/testing/board_check.sh "$SOURCE" "$SCENARIO" "$RVIZ" "$DURATION" "$BAG" "${CHECK[@]}"

# ============================================================================
# Ming-Da rehearsal (docs/handover/2026-10-22-mingda-rehearsal.md). All three run
# on the MASTER, in a terminal, with `just launch-drive-mingda` up; none engages.

# Where does the planning chain stop? Sets the route to the Ming-Da goal
# (allow_goal_modification false), counts every stage down to control_cmd, and
# lists the nodes' recent "waiting for" lines. `just tool plan-probe --no-route`
# only observes; any scripts/testing/mingda/plan_probe.py flag passes through.
# Set the Ming-Da route and report the first silent planning stage
plan-probe *ARGS="":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/_env_guard.sh
    python3 scripts/testing/mingda/plan_probe.py {{ARGS}}

# Record localization, the speed chain and the raw VLP-32C while the driver
# creeps ~1 m forward in manual. Ctrl-C to stop; the bag lands in
# $GOLFCART_BAG_DIR/NAME. Then `just tool creep-report <that path>`.
# Record a manual creep for the localization-loss diagnosis
creep-record NAME="":
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/_env_guard.sh
    exec scripts/testing/mingda/creep_record.sh {{NAME}}

# Summarize a creep bag: speed sources integrated to distance, pose sources'
# displacement and largest jump, NDT scores, a 0.5 s timeline, and whether the
# VCU's distance matches the board's.
# Summarize a creep bag (speed chain vs board vs NDT)
creep-report BAG:
    #!/usr/bin/env bash
    set -euo pipefail
    source scripts/_env_guard.sh
    python3 scripts/testing/mingda/creep_report.py {{BAG}}
