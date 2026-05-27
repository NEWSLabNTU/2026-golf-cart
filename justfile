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
    colcon build \
        --base-paths src \
        --symlink-install \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --cargo-args --release

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

# Launch keyboard control GUI (requires X11/DISPLAY; use after `just launch`)
control-keyboard:
    ros2 launch control_test keyboard_control.launch.xml

# Launch bare vehicle interface node in read-only mode (CAN RX only, tx disabled)
# Safe bench test — populates /vehicle/status/* without commanding motion
# Override interface: just control-vehicle-test CAN=can0
control-vehicle-test CAN="vcan0":
    ros2 launch golfcart_vehicle_launch vehicle_interface_test.launch.xml \
        can_interface:={{CAN}} tx_enabled:=false

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


