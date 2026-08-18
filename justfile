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
    source "{{justfile_directory()}}/scripts/_env_guard.sh"
    if [[ "{{FLAGS}}" == *"--clean"* ]]; then
        just clean --yes
    fi
    just build_seyond
    # Packages a given host cannot build get skipped rather than failing the
    # whole build. One list, not one per reason: colcon's --packages-ignore
    # takes the LAST occurrence and discards earlier ones, so passing the flag
    # twice silently drops the first set. That is not hypothetical — the ZED
    # skip stopped working the moment the DBC skip was added below it.
    IGNORE_PKGS=()
    # The ZED packages need the ZED SDK headers/libs; the master has no SDK.
    #
    # Test for the CMake config, not the directory. An uninstalled SDK can still
    # leave /usr/local/zed behind holding only `resources/`, and the directory
    # test then passes while `find_package(ZED)` fails -- zed_components dies
    # mid-build instead of being skipped, which is what happens on this
    # workstation today.
    if ! compgen -G "/usr/local/zed/zed-config*.cmake" > /dev/null \
       && ! compgen -G "/usr/local/zed/lib/libsl_zed*" > /dev/null; then
        echo "→ ZED SDK not found at /usr/local/zed — skipping ZED packages"
        IGNORE_PKGS+=(zed_components zed_wrapper zed_ros2 zed_debug)
    fi
    # golfcart_vehicle_interface generates its CAN bindings from the vendor DBC at
    # build time, and that file is proprietary and gitignored. Only the machine
    # wired to the CAN bus needs the package at all, so a host without the DBC
    # skips it. Put the DBC in place and it builds again automatically.
    VEHICLE_IF=src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface
    if [[ -z "${CAX_ADS_DBC:-}" && ! -f "{{justfile_directory()}}/${VEHICLE_IF}/CAX_ADS_CAN.dbc" ]]; then
        echo "→ CAX_ADS_CAN.dbc not found — skipping golfcart_vehicle_interface"
        echo "  (needed only on the machine driving the CAN bus; see README)"
        IGNORE_PKGS+=(golfcart_vehicle_interface)
    fi
    IGNORE_ARGS=()
    if [[ ${#IGNORE_PKGS[@]} -gt 0 ]]; then
        IGNORE_ARGS=(--packages-ignore "${IGNORE_PKGS[@]}")
    fi
    colcon build \
        --base-paths src \
        --symlink-install \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --cargo-args --release \
        "${IGNORE_ARGS[@]}"

# Symlink the packaged Autoware models into a writable tree so TensorRT can
# write its .engine files beside them. See scripts/setup_autoware_data.sh.
#
# just --list shows only the LAST comment line, so the description goes here.
# Link Autoware model data into data/autoware_data (writable, for TensorRT)
setup-autoware-data:
    ./scripts/setup_autoware_data.sh

# Compile the TensorRT engines this stack needs, ahead of the first launch.
#
# Autoware compiles an .onnx into a .engine inside the NODE'S CONSTRUCTOR the
# first time it runs. On the Orin that is minutes per model — measured, 94 s for
# the small traffic-light classifier alone — during which the node is not up and
# perception is unavailable. Doing it here turns that into a provisioning step.
#
# Engines are specific to the TensorRT version AND the GPU, so this must run ON
# THE TARGET BOARD. It cannot be baked into an image built elsewhere, and it
# must be re-run after an Autoware or JetPack upgrade.
#
# The model set below is the one `perception_preset:=camera_lidar_fusion`
# actually resolves to — derived by resolving the launch and listing every node
# that references a .onnx. Re-derive it if the preset changes:
#
#     play_launch resolve golfcart_launch golfcart.launch.yaml \
#       launch_perception:=true perception_preset:=camera_lidar_fusion -o /tmp/m.yaml
#
# `autoware_shape_estimation` is deliberately absent: it uses TensorRT but ships
# no `build_only` argument, so its pointnet engine is still built on first use.
# That is one model rather than six, and it succeeds now that the directory is
# writable.
#
# just --list shows only the LAST comment line, so the description goes here.
# Compile TensorRT engines ahead of time (minutes; run on the target board)
build-engines:
    #!/usr/bin/env bash
    # No `set -u`: ROS's own setup.bash reads unbound variables and dies under
    # it (AMENT_TRACE_SETUP_FILES). No `set -e` either — one model failing must
    # not hide the rest, and the summary at the end reports what actually
    # landed.
    set -o pipefail
    just setup-autoware-data
    source /opt/ros/humble/setup.bash
    source /opt/autoware/1.5.0/setup.bash
    DATA="${GOLFCART_DATA_PATH:-{{justfile_directory()}}/data/autoware_data}"

    # Each entry: <package> <launch file> [extra args]. `build_only:=true` makes
    # the node exit as soon as its engine is written — an Autoware-provided
    # argument, so the builder settings match what the node will later expect.
    # Building with trtexec by hand would not guarantee that.
    build() {
        local pkg="$1" launch="$2"; shift 2
        echo "=== ${pkg} ${launch}"
        local start=$SECONDS
        # Stream the TensorRT lines rather than piping into `tail`, which
        # buffers the whole build and shows nothing for minutes — on a step
        # that takes minutes per model, silence is indistinguishable from a
        # hang. `--line-buffered` matters for the same reason.
        #
        # Not fatal on failure: one model failing must not hide the others, and
        # the summary below reports what actually landed.
        ros2 launch "${pkg}" "${launch}" data_path:="${DATA}" build_only:=true "$@" 2>&1 \
            | grep --line-buffered -iE "engine generation|engine build|error|fail" \
            | sed -u 's/^/    /' || true
        echo "    (${pkg}: $((SECONDS - start))s)"
    }

    build autoware_lidar_centerpoint lidar_centerpoint.launch.xml model_name:=centerpoint_tiny
    build autoware_traffic_light_classifier car_traffic_light_classifier.launch.xml
    build autoware_traffic_light_classifier pedestrian_traffic_light_classifier.launch.xml
    build autoware_traffic_light_fine_detector traffic_light_fine_detector.launch.xml

    echo
    echo "=== engines in ${DATA}"
    find "${DATA}" -name '*.engine' -type f -printf '  %P  %s bytes\n' | sort

build_seyond:
    cd src/sensor_component/external/seyond_ros_driver && ./build.bash

# Run tests for packages in src/ directory
test:
    #!/usr/bin/env bash
    source "{{justfile_directory()}}/scripts/_env_guard.sh"
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

# ARGS is one string: an optional `tx=on|off` token plus any golfcart.launch.yaml
# arguments. tx= is stripped out and turned into an environment variable; see
# config/vehicle.conf for why it cannot be a launch argument.
#
# ⚠️  tx=on puts real frames on can0 and the cart can be commanded into motion.
#
# just --list shows only the LAST comment line, so the description goes here, at
# the bottom. Moving it up silently replaces it with whatever line ends up last.
# Launch the system, web UI at http://localhost:8081. ARGS: [tx=on|off] [launch args]
launch ARGS="":
    #!/usr/bin/env bash
    set -euo pipefail
    # tx= is not a launch argument and cannot be: the installed
    # tier4_vehicle_launch/vehicle.launch.xml forwards a fixed set of arguments
    # and drops the rest, so vehicle_interface.launch.xml reads the environment
    # instead. Strip the token here and export it. See config/vehicle.conf.
    # Two steps, not `eval "$(...)"`: eval of an empty string succeeds, so a
    # failing tx_switch would otherwise sail past both `||` and set -e.
    TX_VARS=$({{justfile_directory()}}/scripts/tx_switch.sh {{ARGS}}) || exit 2
    eval "${TX_VARS}"
    if [ "${GOLFCART_TX_SET}" = 1 ]; then
        export GOLFCART_TX_ENABLED
    fi
    if [ "${GOLFCART_TX_ENABLED:-false}" = true ]; then
        printf '\033[1;31mCAN TX ENABLED — the cart can move. Ctrl-C to abort.\033[0m\n'
        for i in 3 2 1; do printf '  starting in %d...\r' "$i"; sleep 1; done
        printf '                       \n'
    fi
    if [ -n "${DISPLAY:-}" ]; then
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml ${GOLFCART_LAUNCH_ARGS}
    else
        play_launch launch \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml \
            rviz:=false ${GOLFCART_LAUNCH_ARGS}
    fi

# ── This host only. The same recipes exist on both machines; the master drives
# ── the orin by running them over there, not by reimplementing them here.

# ⚠️  tx=on puts real frames on can0 and the cart can be commanded into motion.
# Start this host's stack. ARGS: [tx=on|off] [launch args]
launch-up ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    # tx= is pulled out first: it is not a launch argument (the installed
    # tier4_vehicle_launch/vehicle.launch.xml drops unknown ones) but an
    # environment variable the unit reads. See config/vehicle.conf.
    # Two steps, not `eval "$(...)"`: eval of an empty string succeeds, so a
    # failing tx_switch would otherwise sail past the `||`.
    TX_VARS=$({{justfile_directory()}}/scripts/tx_switch.sh {{ARGS}}) || exit 2
    eval "${TX_VARS}"
    # Per-invocation launch arguments reach the unit through the user manager's
    # environment. set-environment persists, so launch-down clears it - otherwise
    # today's flags silently apply to tomorrow's launch. TX is the case where
    # that would be dangerous rather than merely confusing, so an invocation
    # that does not say tx= explicitly clears it back to the config default.
    if [ -n "${GOLFCART_LAUNCH_ARGS}" ]; then
        systemctl --user set-environment GOLFCART_LAUNCH_ARGS="${GOLFCART_LAUNCH_ARGS}"
    else
        systemctl --user unset-environment GOLFCART_LAUNCH_ARGS
    fi
    if [ "${GOLFCART_TX_SET}" = 1 ]; then
        systemctl --user set-environment GOLFCART_TX_ENABLED="${GOLFCART_TX_ENABLED}"
    else
        systemctl --user unset-environment GOLFCART_TX_ENABLED
    fi
    if [ "${GOLFCART_TX_ENABLED:-false}" = true ]; then
        printf '\033[1;31m%s: CAN TX ENABLED — the cart can move.\033[0m\n' "$(hostname)"
    fi
    # restart, not start: replaces a stale unit left by a previous run.
    if ! systemctl --user restart golfcart-launch.service; then
        echo "golfcart-launch.service failed to start on $(hostname)." >&2
        echo "Not installed yet?  just service-install <role>" >&2
        exit 1
    fi
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"

# Stop this host's stack. Leaves any recording running.
launch-down:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user stop golfcart-launch.service
    RC=$?
    systemctl --user unset-environment GOLFCART_LAUNCH_ARGS GOLFCART_TX_ENABLED
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"
    exit $RC

# Start this host's recorder.
record-up:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user restart golfcart-record.service
    RC=$?
    echo "$(hostname): record $(systemctl --user is-active golfcart-record.service)"
    exit $RC

# Stop this host's recorder and let it finalize its bag.
record-down:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user stop golfcart-record.service
    RC=$?
    echo "$(hostname): record $(systemctl --user is-active golfcart-record.service)"
    exit $RC

# What this host's golfcart units are doing.
host-status:
    #!/usr/bin/env bash
    for u in golfcart-launch golfcart-record golfcart-watchdog; do
        state=$(systemctl --user is-active "${u}.service" 2>/dev/null)
        [ "$state" = "inactive" ] && ! systemctl --user cat "${u}.service" >/dev/null 2>&1 && continue
        printf '%s: %-18s %s\n' "$(hostname)" "${u#golfcart-}" "$state"
    done
    # Whether the interface may transmit is the one piece of state that decides
    # if the cart can move, and no unit name shows it. Report it next to them.
    #
    # The user manager's environment is the authority: launch-up either sets it
    # or unsets it on every invocation, so it matches what a running unit was
    # started with. With nothing set, the unit would resolve config/vehicle.conf,
    # so that is what gets reported instead.
    TX=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^GOLFCART_TX_ENABLED=//p')
    TX_FROM=unit-env
    if [ -z "${TX}" ]; then
        TX=$(unset GOLFCART_TX_ENABLED; . {{justfile_directory()}}/config/vehicle.conf 2>/dev/null; echo "${GOLFCART_TX_ENABLED:-false}")
        TX_FROM=config/vehicle.conf
    fi
    if [ "${TX}" = true ]; then
        printf '%s: \033[1;31m%-18s %s\033[0m  (%s)\n' "$(hostname)" "can tx" "ENABLED" "${TX_FROM}"
    else
        printf '%s: %-18s %s  (%s)\n' "$(hostname)" "can tx" "off" "${TX_FROM}"
    fi

# ── Both hosts, driven from the master ──────────────────────────────────────

# ⚠️  tx=on puts real frames on can0 and the cart can be commanded into motion.
# Start the stack on BOTH hosts; returns immediately. ARGS: [tx=on|off] [launch args]
launch-all ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    # NOTE: ARGS is positional. `just launch-all ARGS="..."` does NOT work:
    # just has no NAME=value syntax for recipe parameters.
    #
    # Both hosts run under systemd, so nothing blocks a terminal and no EXIT trap
    # orchestrates the orin: teardown is `just stop-all`, and the orin's
    # watchdog covers the case where this machine never gets to run it.
    # Split the tx= token off before deciding what each host gets. The master
    # keeps ARGS whole - its own launch-up re-parses the token.
    TX_VARS=$({{justfile_directory()}}/scripts/tx_switch.sh {{ARGS}}) || exit 2
    eval "${TX_VARS}"
    just launch-up "{{ARGS}}" || exit 1
    # The orin runs the identical recipe from its own checkout. A missing orin
    # must never fail the master, so its status is reported and discarded.
    #
    # It gets the launch arguments WITHOUT the tx= token. CAN is the master's
    # alone - the orin has no bus and golfcart.launch.yaml gates the vehicle
    # group on is_master - so tx there could only ever be noise, and its own
    # launch-up then explicitly clears GOLFCART_TX_ENABLED rather than leaving a
    # value from an earlier run in the orin's user manager.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just launch-up "${GOLFCART_LAUNCH_ARGS}" \
            || echo "WARNING: could not start the orin - continuing without it" >&2
    fi
    echo
    echo "web UI: http://localhost:8081    logs: just logs    stop: just stop-all"

# Stop the stack on BOTH hosts. Leaves any recording running.
stop-all:
    #!/usr/bin/env bash
    set -uo pipefail
    RC=0
    # The orin first, while this host can still reach it. Recording is deliberately
    # untouched on both sides: `just record-stop` is its own verb.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just launch-down || RC=1
    fi
    just launch-down || RC=1
    exit $RC

# Follow this host's stack log.
logs:
    journalctl --user -u golfcart-launch.service -f

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
# Vehicle Interface - standalone bring-up and bench testing
# ============================================================================

# Vehicle interface on its own, without Autoware. Bench and bring-up.
# Options are KEY=VALUE in any order:
#   can=can0|vcan0     SocketCAN interface                          (default can0)
#   tx=on|off          CAN TX master enable                         (default off)
#   converter=on|off   robot_state_publisher + velocity converter   (default off)
# With tx=off the node only listens: /vehicle/status/* and /diagnostics fill in
# and the cart cannot be commanded into motion.
# For keys, run `just manual-control` in a second terminal.
# ⚠️  tx=on puts real frames on the bus and can command motion.
vehicle-interface *OPTS="":
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
                echo "Usage: just vehicle-interface [can=IFACE] [tx=on|off] [converter=on|off]" >&2
                echo "       keyboard control is a separate recipe: just manual-control" >&2
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
# Run in a second terminal next to `just vehicle-interface` — keys are read from a
# raw tty, so this must own a real terminal and cannot live inside a launch file.
# Keys: x drive, c reverse, v park, u/o speed, j/l steer, i/k zero, s status, z mode.
# Limits are the cart's: 5 m/s ceiling in 0.25 m/s steps, 0.349 rad in 1° steps.
# Extra ARGS are appended to --ros-args, e.g. just manual-control "-p max_speed:=2.0"
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
# ============================================================================

# Run trajectory player with straight_10m.yaml (10m straight line)
# Needs the vehicle stack up: just vehicle-interface converter=on
control-straight:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=straight_10m.yaml

# Run trajectory player with circle.yaml (circular path)
# Needs the vehicle stack up: just vehicle-interface converter=on
control-circle:
    ros2 run control_test trajectory_player --ros-args -p trajectory_file:=circle.yaml

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

# Replay a merged NTU campus bag into the logging simulation (see
# ntu_logging_sim.launch.xml). SET is CSIE-1, CSIE-2 or BLVD-1.
bag-play-ntu SET="CSIE-1" ARGS="":
    ./scripts/rosbag/play_ntu_sim.sh {{SET}} {{ARGS}}

# ── NTU NDT replay test ─────────────────────────────────────────────────────
#
# Run these in order, each in its own terminal (1-3 stay running):
#
#   just ntu-sim-bag CSIE-1     # 1. bag PAUSED — publishes /clock only
#   just ntu-sim-up             # 2. stack, no RViz
#   just ntu-sim-rviz           # 3. RViz, point cloud actually visible
#   just ntu-sim-resume         # 4. let the sensors flow
#   just ntu-sim-init CSIE-1    # 5. seed NDT, once LiDAR is flowing
#   just ntu-sim-report         # 6. score it
#   just ntu-sim-down           # stop everything
#
# The order is not cosmetic. The bag leads so that everything after it is born
# on bag time; the pose comes last so NDT has scans to match against. Getting
# either wrong fails silently and still looks like it is working — see the
# comment at the top of scripts/rosbag/ntu_sim_bag.sh.

# 1. Start a merged NTU bag PAUSED, publishing /clock only.
ntu-sim-bag SET="CSIE-1" ARGS="":
    ./scripts/rosbag/ntu_sim_bag.sh {{SET}} {{ARGS}}

# 2. Bring up the logging simulation (sensor drivers off, no RViz).
ntu-sim-up ARGS="":
    play_launch launch --parser python --web-addr 0.0.0.0:8081 \
        golfcart_launch ntu_logging_sim.launch.xml rviz:=false {{ARGS}}

# 3. RViz with the point cloud map rendered visibly, on bag time.
ntu-sim-rviz:
    ./scripts/rosbag/ntu_sim_rviz.sh

# 4. Release the paused player so sensor data starts flowing.
ntu-sim-resume:
    ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume

# Pause playback again (to inspect a frame, or to re-seed the pose).
ntu-sim-pause:
    ros2 service call /rosbag2_player/pause rosbag2_interfaces/srv/Pause

# Stop the replay stack, the player and RViz.
ntu-sim-down:
    ./scripts/rosbag/ntu_sim_down.sh

# 5. Re-apply a captured initial pose so an NTU replay starts unattended.
ntu-sim-init SET="CSIE-1":
    python3 ./scripts/localization/set_initial_pose.py {{SET}}

# Capture the current converged pose for a set, after placing one in RViz.
ntu-sim-capture SET="CSIE-1":
    python3 ./scripts/localization/capture_initial_pose.py {{SET}}

# Score a running NDT replay on pose quality (scatter, yaw step), not on NVTL.
ntu-sim-report ARGS="":
    python3 ./scripts/localization/ndt_quality_report.py {{ARGS}}

# Audit launch files for silently-ignored arguments and unparseable comments.
audit-launch:
    python3 ./scripts/check/audit_launch.py

# Record everything the ArUco indoor localizer needs (phase 3D-7).
# Name the scenario so the bag is readable without opening it:
#   just bag-record-aruco bench_static_1board_3m
bag-record-aruco SCENARIO="session":
    ./scripts/rosbag/record_aruco.sh {{SCENARIO}}

# Report corner sigma, detection geometry and coverage from a recorded bag.
bag-report-aruco BAG:
    python3 ./scripts/analysis/aruco_bag_report.py {{BAG}}

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

# ============================================================================
# Multi-machine services (systemd user units, one role per machine)
# ============================================================================

# Install this host's systemd user units. ROLE: master or orin.
service-install ROLE:
    ./setup/scripts/install-host-service.sh {{ROLE}}

# Remove this host's systemd user units. ROLE: master or orin.
service-remove ROLE:
    ./setup/scripts/install-host-service.sh {{ROLE}} --remove

# Provision the orin over ssh (may prompt for its password and sudo).
service-install-orin:
    # Runs before key-based ssh necessarily exists, and lingering needs the
    # orin's sudo - hence the tty. Every other remote call is BatchMode=yes.
    ./scripts/multi_machine/on_orin.sh --tty just service-install orin

# Unit states on both hosts.
service-status:
    #!/usr/bin/env bash
    just host-status
    ./scripts/multi_machine/on_orin.sh just host-status \
        || echo "orin: unreachable" >&2

# Generate an ssh key if needed and copy it to the orin (one password prompt).
ssh-setup DEST="":
    ./scripts/multi_machine/setup_ssh.sh {{DEST}}

# ============================================================================
# Recording - independent of the launch, start it whenever you want
# ============================================================================

# Start recording on both hosts, each to its own local disk.
record-start:
    #!/usr/bin/env bash
    set -o pipefail
    # Works whether or not the launch service is running: the recorder is its own
    # unit and shares no process tree with play_launch.
    RC=0
    # This host first: if the orin is unreachable we still want this bag. Unlike
    # the launch, a missing orin IS a failure here - half a recording is a result
    # you need to know about before you drive.
    just record-up || RC=1
    ./scripts/multi_machine/on_orin.sh just record-up || RC=1
    exit $RC

# Stop recording on both hosts and let each finalize its bag.
record-stop:
    #!/usr/bin/env bash
    set -o pipefail
    RC=0
    # Stop both even if the first fails - a half-stopped pair is worse than either.
    just record-down || RC=1
    ./scripts/multi_machine/on_orin.sh just record-down || RC=1
    exit $RC

# Is either host recording?
record-status:
    #!/usr/bin/env bash
    printf '%s: record %s\n' "$(hostname)" "$(systemctl --user is-active golfcart-record.service)"
    ./scripts/multi_machine/on_orin.sh systemctl --user is-active golfcart-record.service \
        | sed 's/^/orin: record /' || echo "orin: unreachable" >&2

# Environment, DDS profile, units and disk - run this when topics do not show up.
doctor:
    ./scripts/doctor.sh

# The same diagnostic, run on the orin over ssh.
doctor-orin:
    ./scripts/multi_machine/on_orin.sh ./scripts/doctor.sh

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
      "ros2 launch golfcart_vehicle_launch vehicle_interface_standalone.launch.xml can_interface:=vcan0" \
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


