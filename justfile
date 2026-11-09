# Golf Cart Development Commands
# Use `just --list` to see all available commands.
#
# `just --list` shows the comment line directly above a recipe as its
# description, so keep that line last.

# ============================================================================
# Core Commands
# ============================================================================

# Show all available commands, modules expanded
default:
    @just --list --list-submodules

# ============================================================================
# Modules: `just <module>` lists its recipes; call as `just bag play` or `just bag::play`.
# A module may not share a name with a root recipe (hard error for the whole justfile).
# ============================================================================

# NTU campus NDT replay test — see `just ntu-test` for the ordered sequence
mod ntu-test 'just/ntu-test.just'
# Indoor cold start from the reflective board, no GNSS — `just indoor-test` for the sequence
mod indoor-test 'just/indoor-test.just'
# Rosbag recording and playback
mod bag 'just/bag.just'
# Recording lifecycle, independent of the launch
mod record 'just/record.just'
# Multi-machine systemd user units
mod service 'just/service.just'
# Vehicle interface bring-up, bench testing and control tests
mod vehicle 'just/vehicle.just'
# CAN bus record, replay and decode
mod can 'just/can.just'
# Development and monitoring tools
mod tool 'just/tool.just'
# Synthetic cameras on v4l2loopback, for working with no hardware attached
mod sim 'just/sim.just'
# Diagnostic graph: inspect it, and inject faults into it
mod diag 'just/diag.just'
# Initial pose per map: capture a start spot once, then init from it, no RViz click
mod pose 'just/pose.just'
# GNSS / RTK: verify the setup, then test the receiver against the NTRIP caster
mod gnss 'just/gnss.just'
# Middleware: which RMW this host runs, and the Zenoh router lifecycle
mod rmw 'just/rmw.just'
# The master/orin link: what crosses it, how much, and the two-host simulation
mod link 'just/link.just'
# CPU / kernel profiling of the running stack
mod profile 'just/profile.just'

# The cart in the NTU twin on Isaac Sim: `just twin` (Phase 10)
mod twin 'just/twin.just'

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
    # Packages a given host cannot build get skipped rather than failing the
    # whole build (scripts/colcon_ignore.sh says which, and why). One list, not
    # one per reason: colcon's --packages-ignore takes the LAST occurrence and
    # discards earlier ones.
    mapfile -t IGNORE_PKGS < <("{{justfile_directory()}}/scripts/colcon_ignore.sh")
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

# With autoware-localrepo 1.5.0-3 or later this runs autoware-download-models
# (ARGS pass through, e.g. `--only lidar_centerpoint`); older installs symlink.
# Download or link Autoware models into data/autoware_data (writable, for TensorRT)
setup-autoware-data *ARGS:
    ./scripts/setup_autoware_data.sh {{ARGS}}

# Engines are specific to the TensorRT version and the GPU: run on the target
# board, and again after an Autoware or JetPack upgrade. The model set is what
# perception_preset:=camera_lidar_fusion resolves to; re-derive it with
#     play_launch resolve golfcart_launch golfcart.launch.yaml \
#       launch_perception:=true perception_preset:=camera_lidar_fusion -o /tmp/m.yaml
# shape_estimation has no build_only argument, so it still builds on first use.
# Compile TensorRT engines ahead of time (minutes; run on the target board)
build-engines:
    #!/usr/bin/env bash
    # No `set -u` (ROS setup.bash breaks under it) and no `set -e`: one failed
    # model must not hide the rest; the summary at the end reports what landed.
    set -o pipefail
    for req in /opt/ros/humble/setup.bash:ros2 /opt/autoware/1.5.0/setup.bash:autoware-debian; do
        if [[ ! -f "${req%%:*}" ]]; then
            echo "Not installed: ${req%%:*}" >&2
            echo "Install it first:  ./setup.sh --only ${req##*:}" >&2
            exit 1
        fi
    done
    just setup-autoware-data
    source /opt/ros/humble/setup.bash
    source /opt/autoware/1.5.0/setup.bash
    DATA="${GOLFCART_DATA_PATH:-{{justfile_directory()}}/data/autoware_data}"

    # <package> <launch file> [extra args]; build_only:=true exits once the engine is written.
    build() {
        local pkg="$1" launch="$2"; shift 2
        echo "=== ${pkg} ${launch}"
        local start=$SECONDS
        # Stream progress line by line; a buffered build looks like a hang.
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
        echo "Cleaned build artifacts."
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
# Launch Commands
# ARGS is one string of golfcart.launch.yaml arguments. There is no CAN TX
# switch: the vehicle interface always transmits; the cart's power switch is
# the master enable.
#
# Every launch first runs scripts/rmw/ensure.sh, which fails loudly on two
# otherwise silent problems: a stale ros2 daemon from the other RMW, and (under
# zenoh) a missing or non-multicast interface.
# ============================================================================

# Launch the system, web UI at http://localhost:8081. ARGS: [launch args]
launch ARGS="":
    #!/usr/bin/env bash
    set -euo pipefail
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
    GOLFCART_LAUNCH_ARGS={{quote(ARGS)}}
    # host:= comes from config/host (master/orin), else "all". host:=all would
    # start the ZED driver on a machine without one. An explicit host:= in ARGS wins.
    GOLFCART_HOST_ROLE=$(
        GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 \
        bash -c 'source "{{justfile_directory()}}/scripts/env.sh"; printf "%s" "${GOLFCART_HOST}"'
    ) || GOLFCART_HOST_ROLE=""
    case "${GOLFCART_HOST_ROLE}" in
        master | orin) HOST_ARG="host:=${GOLFCART_HOST_ROLE}" ;;
        *)             HOST_ARG="host:=all" ;;
    esac
    case " ${GOLFCART_LAUNCH_ARGS} " in
        *" host:="*) HOST_ARG="" ;;
    esac
    if [ -n "${DISPLAY:-}" ]; then
        play_launch launch \
            --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml \
            ${HOST_ARG} ${GOLFCART_LAUNCH_ARGS}
    else
        play_launch launch \
            --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch golfcart.launch.yaml \
            ${HOST_ARG} \
            rviz:=false ${GOLFCART_LAUNCH_ARGS}
    fi

# ── This host only. The master drives the orin by running these same recipes there.

# Start this host's stack. ARGS: [launch args]
launch-up ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
    GOLFCART_LAUNCH_ARGS={{quote(ARGS)}}
    # ARGS reach the unit through the user manager's environment, which
    # persists; launch-down clears it so today's flags don't leak into tomorrow.
    if [ -n "${GOLFCART_LAUNCH_ARGS}" ]; then
        systemctl --user set-environment GOLFCART_LAUNCH_ARGS="${GOLFCART_LAUNCH_ARGS}"
    else
        systemctl --user unset-environment GOLFCART_LAUNCH_ARGS
    fi
    # restart, not start: replaces a stale unit left by a previous run.
    if ! systemctl --user restart golfcart-launch.service; then
        echo "golfcart-launch.service failed to start on $(hostname)." >&2
        echo "Not installed yet?  just service install <role>" >&2
        exit 1
    fi
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"

# Stop this host's stack. Leaves any recording running.
launch-down:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user stop golfcart-launch.service
    RC=$?
    systemctl --user unset-environment GOLFCART_LAUNCH_ARGS
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"
    exit $RC

# ARGS is positional: `just launch-all "a:=1"`, not `ARGS="a:=1"`. Teardown is
# `just stop-all`; the orin's watchdog covers a master that never runs it.
# Start the stack on BOTH hosts; returns immediately. ARGS: [launch args]
launch-all ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
    just launch-up {{quote(ARGS)}} || exit 1
    # A missing orin does not fail the master, but the vehicle interface lives there.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just launch-up {{quote(ARGS)}} \
            || echo "WARNING: could not start the orin - continuing without it; no vehicle interface, the cart cannot be driven" >&2
    fi
    echo
    echo "web UI: http://localhost:8081    logs: just logs    stop: just stop-all"

# Stop the stack on BOTH hosts. Leaves any recording running.
stop-all:
    #!/usr/bin/env bash
    set -uo pipefail
    RC=0
    # The orin first, while this host can still reach it.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just launch-down || RC=1
    fi
    just launch-down || RC=1
    exit $RC

# Follow this host's stack log.
logs:
    journalctl --user -u golfcart-launch.service -f

# ============================================================================
# Supervised drives (Phase 8). Board cold start, no GNSS, 1.0 m/s planning
# default, perception off: NO obstacle detection, the driver with the e-stop is
# it. Extra ARGS win. Engage order: docs/roadmaps/8-autonomous-driving.md.
# ============================================================================

# Drive on the basement map (both hosts). ARGS: [launch args]
launch-drive-basement ARGS="":
    just launch-all "pose_initializer:=board reflective_pose_scenario:=basement map_path:=./data/basement-indoor use_gnss:=false planning_speed_limit:=1.0 planning_preset:=slow_indoor {{ARGS}}"

# Re-anchored map (3.46 deg yaw from basement-indoor; old poses don't carry over).
# Same `basement` scenario: the board defines the map origin in both.
# NVTL gate 2.1: healthy lock ~2.53, wrong poses 1.5-1.66 (bag master_20261028_192241).
# Drive on the Ming-Da map (both hosts). ARGS: [launch args]
launch-drive-mingda ARGS="":
    just launch-all "pose_initializer:=board reflective_pose_scenario:=basement map_path:=./data/mingda-basement use_gnss:=false planning_speed_limit:=2.0 planning_preset:=slow_indoor ndt_divergence_nvtl_median_gate:=2.1 {{ARGS}}"

# Drive the Ming-Da clockwise loop lane (narrows to 1.5 m / 5.4 km/h under the board)
launch-drive-mingda-loop ARGS="":
    just launch-drive-mingda "lanelet2_map_file:=lanelet2_map_loop.osm {{ARGS}}"

# ============================================================================
# Planning simulators
# ============================================================================

# MAP is a map directory (point it at a scratch copy to try a route); PRESET is
# slow_indoor or default. Then, from another terminal:
#   python3 scripts/testing/sim_route_check.py --start X Y YAW_DEG --goal X Y YAW_DEG
# Keep the goal a few metres short of the lane's end.
# Planning simulator on the basement map. MAP PRESET LANELET
sim-drive-basement MAP="./data/basement-indoor" PRESET="slow_indoor" LANELET="lanelet2_map.osm":
    play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch planning_sim.launch.xml \
        map_path:={{MAP}} \
        lanelet2_map_file:={{LANELET}} \
        planning_preset:={{PRESET}}

# Planning simulator on the Ming-Da loop lane, for `just sim-loop-drive`
sim-drive-mingda-loop PRESET="slow_indoor":
    just sim-drive-basement ./data/mingda-basement {{PRESET}} lanelet2_map_loop.osm

# With sim-drive-mingda-loop up: drive N laps (`--laps 2`; `--check-only` without ROS)
sim-loop-drive *ARGS:
    python3 scripts/testing/sim_loop_drive.py {{ARGS}}

# With `just sim-drive-basement ./data/mingda-basement` up: fault NDT while
# driving and follow the MRM to the CAN frames (vcan0 + mock_vcu).
# `--no-can` on a machine without vcan0 or the vendor DBC.
# MRM end-to-end check on the Ming-Da lane. ARGS go to the script
sim-mrm-check *ARGS:
    python3 scripts/testing/sim_mrm_check.py --start 17.6 -4.9 180 --goal 6.5 -4.9 180 {{ARGS}}

# Launch Autoware planning simulator with Golf Cart vehicle
launch-sim-planning:
    play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        autoware_launch planning_simulator.launch.xml \
        map_path:={{justfile_directory()}}/data/ntu-campus-planning/r01 \
        vehicle_model:=golfcart_vehicle \
        sensor_model:=golfcart_sensor_kit

# Phase 3D-6 stage 2: ArUco localization driving the planning simulator
sim-aruco-planning *ARGS:
    play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch aruco_planning_sim.launch.xml \
        map_path:={{justfile_directory()}}/data/sample-map-planning \
        {{ARGS}}

# Launch logging simulation for rosbag replay testing
launch-sim-logging ARGS="":
    #!/usr/bin/env bash
    if [ -n "$DISPLAY" ]; then \
        play_launch launch \
            --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch logging_simulation.launch.yaml {{ARGS}}; \
    else \
        play_launch launch \
            --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
            --web-addr 0.0.0.0:8081 \
            golfcart_launch logging_simulation.launch.yaml \
            rviz:=false {{ARGS}}; \
    fi

# ============================================================================
# Checks, audits and full-scenario simulation
# ============================================================================

# Run sensor & interface health check (LiDAR, GNSS, IMU, cameras, CAN, system)
check-sensors:
    ./scripts/check/run.sh

# Audit launch files for silently-ignored arguments and unparseable comments.
audit-launch:
    python3 ./scripts/check/audit_launch.py

# Needs the NTU COSS Park rosbag (./scripts/rosbag/download-test-rosbag.sh).
# Run COSS Park simulation (launch + rosbag feed + localization recording)
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

# Install the oToBrite camera module and reboot (AFE R750 only)
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
