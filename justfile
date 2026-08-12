# Golf Cart Development Commands
# Use `just --list` to see all available commands

# ============================================================================
# Core Commands
# ============================================================================

# Default recipe: show all available commands
default:
    @just --list

# Initialize and update all git submodules
checkout:
    git submodule update --init --recursive --checkout

# Run interactive setup (installs ROS 2, dependencies, etc.)
setup:
    ./setup.sh

# Build this project. Pass --clean to wipe caches first. ROS / Autoware env via .envrc.
build *FLAGS="":
    #!/usr/bin/env bash
    set -e
    if [[ "{{FLAGS}}" == *"--clean"* ]]; then
        just clean --yes
    fi
    just build_seyond
    # The ZED packages need the ZED SDK headers/libs; the master has no SDK, so
    # skip them there instead of failing the whole build.
    ZED_IGNORE=()
    if [[ ! -d /usr/local/zed ]]; then
        echo "→ ZED SDK not found at /usr/local/zed — skipping ZED packages"
        ZED_IGNORE=(--packages-ignore zed_components zed_wrapper zed_ros2 zed_debug)
    fi
    colcon build \
        --base-paths src \
        --symlink-install \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --cargo-args --release \
        "${ZED_IGNORE[@]}"

build_seyond:
    cd src/sensor_component/external/seyond_ros_driver && ./build.bash

# Run tests for packages in src/ directory
test:
    #!/usr/bin/env bash
    colcon test \
        --base-paths src \
        --return-code-on-test-failure; \
    TEST_EXIT_CODE=$?; \
    echo "" && \
    colcon test-result --verbose; \
    exit $TEST_EXIT_CODE

# Clean up built binaries (use --yes or --no-confirm to skip prompt)
clean *FLAGS="":
    #!/usr/bin/env bash
    do_clean() {
        rm -rf build install log
        while IFS= read -r -d '' pkg; do
            [[ -f "$pkg/Cargo.toml" ]] && (cd "$pkg" && cargo clean)
        done < <(find src -name package.xml -printf '%h\0')
        SEYOND_DIR=src/sensor_component/external/seyond_ros_driver
        rm -rf "$SEYOND_DIR"/build "$SEYOND_DIR"/install "$SEYOND_DIR"/devel "$SEYOND_DIR"/log "$SEYOND_DIR"/src/CMakeLists.txt
        echo "Cleaned build artifacts (cargo target/, seyond build dirs included)."
    }
    if [[ "{{FLAGS}}" == *"--yes"* ]] || [[ "{{FLAGS}}" == *"--no-confirm"* ]]; then
        do_clean
    else
        while true; do \
            read -p 'Are you sure to clean up? (yes/no) ' yn; \
            case $yn in \
                yes ) do_clean; break;; \
                no ) break;; \
                * ) echo 'Please enter yes or no.';; \
            esac \
        done
    fi

# ============================================================================
# Launch Commands - Start systems
# ============================================================================

# Launch Golf Cart system with web UI at http://localhost:8081
launch ARGS="":
    #!/usr/bin/env bash
    if [ -n "$DISPLAY" ]; then \
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml {{ARGS}}; \
    else \
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml \
            rviz:=false {{ARGS}}; \
    fi

# Launch the master host profile (everything except the ZED camera)
# NOTE: the argument is positional. `just launch ARGS="..."` does NOT work -
# just has no NAME=value syntax for recipe parameters, so the whole token is
# passed through as a launch argument and host silently stays at its default.
# CYCLONEDDS_URI is set here rather than left to .envrc so the recipe works
# without direnv; the default loopback profile would isolate the two hosts.
launch-master ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    export CYCLONEDDS_URI="file://{{justfile_directory()}}/config/cyclonedds/master.xml"
    REMOTE="{{justfile_directory()}}/scripts/multi_machine/orin_remote.sh"
    # The orchestrator runs here rather than as a launch entry: play_launch drops
    # `executable:` actions from its replay. Set GOLFCART_USE_ORIN=0 to run the
    # master alone.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        RECORD=false
        [[ "{{ARGS}}" == *"record:=true"* ]] && RECORD=true
        # A missing orin must not block the master, so failure here is ignored;
        # the trap is still armed, since a half-started unit needs stopping too.
        "$REMOTE" start "$RECORD" || true
        # INT and TERM as well as EXIT: bash does not run an EXIT trap when it is
        # killed by an untrapped signal, and being killed is the normal way this
        # recipe ends. The orin's watchdog is the backstop if even this is missed.
        # Disarm on entry, or Ctrl-C runs the handler twice - once for INT, once
        # for the EXIT that follows - costing a second pointless ssh round-trip.
        stop_orin() { trap - EXIT INT TERM; "$REMOTE" stop; }
        trap stop_orin EXIT INT TERM
    fi
    just launch "host:=master {{ARGS}}"

# Launch the orin host profile (ZED X camera only)
launch-orin ARGS="":
    CYCLONEDDS_URI="file://{{justfile_directory()}}/config/cyclonedds/orin.xml" \
        just launch "host:=orin {{ARGS}}"

# Launch Autoware planning simulator with Golf Cart vehicle
launch-sim-planning:
    play_launch launch \
        --web-addr 0.0.0.0:8081 \
        autoware_launch planning_simulator.launch.xml \
        map_path:={{justfile_directory()}}/data/ntu-campus-planning/r01 \
        vehicle_model:=golfcart_vehicle \
        sensor_model:=golfcart_sensor_kit

# Launch logging simulation for rosbag replay testing
launch-sim-logging ARGS="":
    #!/usr/bin/env bash
    if [ -n "$DISPLAY" ]; then \
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch logging_simulation.launch.yaml {{ARGS}}; \
    else \
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch logging_simulation.launch.yaml \
            rviz:=false {{ARGS}}; \
    fi

# ============================================================================
# Tool Commands - Development and monitoring tools
# ============================================================================

# Launch RViz with Golf Cart configuration
tool-rviz:
    rviz2 -d ./src/launcher/golfcart_launch/rviz/golfcart.rviz

# Launch PlotJuggler for data visualization
tool-plotjuggler:
    ros2 run plotjuggler plotjuggler

# Launch manual keyboard control
tool-controller:
    ros2 run control_test keyboard_control

# Launch drive monitor TUI (shows pose, speed, component states)
tool-tui:
    python3 ./scripts/testing/drive/run.py

# ============================================================================
# Control Commands - Control system testing
# ============================================================================

# Launch vehicle control test (basic_control.launch.xml)
control-basic:
    play_launch launch control_test basic_control.launch.xml

# Run trajectory player with straight_10m.yaml (10m straight line)
control-straight:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=straight_10m.yaml

# Run trajectory player with circle.yaml (circular path)
control-circle:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=circle.yaml

# Terminal keyboard controller (autoware_manual_control), commanding /control/command/*
# Pair with `just vehicle-interface` in a second terminal. The driver switches the
# vehicle to autonomous on its own controls — this only reports the mode it sees on
# start (--no-mode-check skips that). Needs a real terminal: raw-tty key reads.
manual-control *ARGS="":
    ./scripts/control/keyboard_control_direct.sh {{ARGS}}

# Launch ONLY the vehicle interface, via the Autoware entry launch file
# (golfcart_autoware.launch.xml with every other module disabled).
# ⚠️  tx_enabled defaults to true: CAN TX is live and the cart will move.
# Override both: just vehicle-interface can1 false
vehicle-interface CAN="can0" TX="true":
    play_launch launch golfcart_launch golfcart_autoware.launch.xml \
        vehicle_model:=golfcart_vehicle \
        sensor_model:=golfcart_sensor_kit \
        map_path:={{justfile_directory()}}/data/COSS-map-planning \
        launch_vehicle:=true \
        launch_vehicle_interface:=true \
        launch_system:=false \
        launch_map:=false \
        launch_sensing:=false \
        launch_sensing_driver:=false \
        launch_localization:=false \
        launch_perception:=false \
        launch_planning:=false \
        launch_control:=false \
        launch_api:=false \
        rviz:=false \
        can_interface:={{CAN}} \
        tx_enabled:={{TX}}

# Launch keyboard control GUI (requires X11/DISPLAY; use after `just launch`)
control-keyboard:
    ros2 launch control_test keyboard_control.launch.xml

# Launch bare vehicle interface node, read-only by default (CAN RX only, tx disabled)
# Safe bench test — populates /vehicle/status/* without commanding motion
# Positional args, in order: just control-vehicle-test can0 true
# ⚠️  TX=true puts real frames on the bus and can command motion
control-vehicle-test CAN="vcan0" TX="false":
    ros2 launch golfcart_vehicle_launch vehicle_interface_test.launch.xml \
        can_interface:={{CAN}} tx_enabled:={{TX}}

# Launch teleop GUI + vehicle interface on real CAN bus (tx enabled — DRIVES THE CART)
# ⚠️  Requires X11 display. Requires can0 up. Commands actual motor/steering.
# Override interface: just control-teleop-real CAN=can0
control-teleop-real CAN="can0":
    ros2 launch golfcart_vehicle_launch teleop_bench.launch.xml \
        can_interface:={{CAN}} tx_enabled:=true

# Decode live CAN frames using vehicle DBC (CAX_ADS_CAN.dbc)
# Usage: just can-decode          (defaults to can0)
#        just can-decode can1
can-decode IFACE="can0":
    candump {{IFACE}} | cantools decode \
        src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc

# ============================================================================
# Check Commands - Sensor health checks
# ============================================================================

# Run sensor & interface health check (LiDAR, GNSS, IMU, cameras, CAN, system)
check-sensors:
    ./scripts/check/run.sh

# ============================================================================
# Bag Commands - Rosbag recording and playback
# ============================================================================

# Record outdoor sensor topics to rosbags/ directory
bag-record:
    ./scripts/rosbag/record_outdoor.sh

# Record the phase 3B indoor mapping run: LiDAR + IMU for SLAM, cameras for 3C
bag-record-indoor:
    ./scripts/rosbag/record_indoor_mapping.sh

# Play the most recent outdoor recording
bag-play:
    #!/usr/bin/env bash
    LATEST=$(ls -td rosbags/outdoor_* 2>/dev/null | head -1); \
    if [ -z "$LATEST" ]; then \
        echo "No outdoor recordings found in rosbags/"; \
        exit 1; \
    fi; \
    echo "Playing: $LATEST"; \
    ros2 bag play "$LATEST" --clock

# Fetch the orin's rosbags to this host. ARGS: --latest, --list, or a bag name.
bag-fetch-orin ARGS="":
    ./scripts/multi_machine/bag_fetch_orin.sh {{ARGS}}

# Merge per-host bags into one. ARGS: [-o OUTPUT] <bag> <bag> [bag ...]
bag-merge ARGS="":
    ./scripts/multi_machine/bag_merge.sh {{ARGS}}

# Replay a bag in RViz. BAG defaults to the newest merged_*/master_* bag found.
# ARGS: rate:=2.0 start_offset:=40.0 play_args:=--loop rviz:=false
bag-replay BAG="" ARGS="":
    #!/usr/bin/env bash
    set -eo pipefail
    BAG="{{BAG}}"
    BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
    if [ -z "${BAG}" ]; then
        # Newest merged bag first: it has both hosts in it. Fall back to a
        # master bag so this still works before anything has been merged.
        #
        # Deliberately no `ls ... | head`: ls exits 2 when one of the two globs
        # matches nothing, and with pipefail + set -e that killed the recipe
        # before it printed anything. nullglob plus a plain loop has no such edge.
        shopt -s nullglob
        for candidate in "${BAG_DIR}"/merged_* "${BAG_DIR}"/master_*; do
            [ -d "${candidate}" ] || continue
            if [ -z "${BAG}" ] || [ "${candidate}" -nt "${BAG}" ]; then
                BAG="${candidate}"
            fi
        done
        shopt -u nullglob
        if [ -z "${BAG}" ]; then
            echo "No bag given and none found in ${BAG_DIR}" >&2
            echo "Set GOLFCART_BAG_DIR, or pass one:" >&2
            echo "  just bag-replay <bag> [\"rate:=2.0 start_offset:=40.0\"]" >&2
            exit 1
        fi
        echo "Replaying newest bag: ${BAG}"
    elif [ ! -d "${BAG}" ] && [ -d "${BAG_DIR}/${BAG}" ]; then
        BAG="${BAG_DIR}/${BAG}"
    fi
    ros2 launch golfcart_launch bag_replay.launch.xml bag:="${BAG}" {{ARGS}}

# Record raw CAN frames (candump -L format) to rosbags/can/
can-record IFACE="can0":
    ./scripts/can/record_can.sh {{IFACE}}

# Replay a CAN log onto vcan0. Defaults to most recent log in rosbags/can/.
can-play LOG="":
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
can-test LOG="" LOOP="1":
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
      "ros2 launch golfcart_vehicle_launch vehicle_interface_test.launch.xml can_interface:=vcan0" \
      "sleep 3 && ./scripts/can/replay_can.sh $LOOP_FLAG \"$F\" vcan0"

# ============================================================================
# Simulation Commands - Full simulation scenarios
# ============================================================================

# Run COSS Park simulation (launch + rosbag feed + localization recording)
# Requires: rosbag data from NTU COSS Park (run ./scripts/rosbag/download-test-rosbag.sh)
sim-coss-park:
    #!/usr/bin/env bash
    parallel --line-buffer ::: \
        "just launch-sim-logging" \
        "sleep 40 && ros2 bag play data/rosbags/outdoor_20251226_153115/ --clock -l -r 1.0" \
        "sleep 45 && ./scripts/rosbag/record_localization.sh"

# ============================================================================
# oToBrite Setup - AFE R750 only
# https://ess-wiki.advantech.com.tw/view/AFE_R750_Development#oToBrite_Camera
# ============================================================================

advantech-r750-otobrite-setup-and-reboot:
    #!/usr/bin/env bash
    if [ -f "$HOME/insmod-otocam.sh" ]; then
        echo "oToBrite module has set"
    fi
    read -p "The device will be rebooted immediately, continue? (y/N)" yyyes
    yyyes="${yyyes:-n}"
    case "$yyyes" in 
        [Yy]*)
    echo "Start to setup and reboot"
    cd /usr/local/bin/otocam
    sudo ./set_otocam_agxorin_64g.sh
    ;;
    *)
    exit 0
    ;;
    esac


