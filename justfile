# Golf Cart Development Commands
# Use `just --list` to see all available commands

# ============================================================================
# Core Commands
# --list-submodules is not optional. Without it each module collapses to a
# single `bag ...` line and its recipes are invisible, which for a 60-recipe
# repo is the difference between a menu and a riddle.
# Show all available commands, modules expanded
default:
    @just --list --list-submodules

# ============================================================================
# Modules — grouped commands. `just <module>` lists that module's recipes.
#
# Invoke either way:  `just bag play`  or  `just bag::play`
#
# Only families that are entered deliberately live here. The daily verbs
# (build, test, clean, launch, stop-all, logs) stay at the root, partly by
# choice and partly because a module may NOT share a name with a recipe --
# `mod launch` next to `launch:` is a hard error that kills the whole justfile.
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
# GNSS / RTK: verify the setup, then test the receiver against the NTRIP caster
mod gnss 'just/gnss.just'
# Middleware: which RMW this host runs, and the Zenoh router lifecycle
mod rmw 'just/rmw.just'
# The master/orin link: what crosses it, how much, and the two-host simulation
mod link 'just/link.just'

# CPU / kernel profiling of the running stack
mod profile 'just/profile.just'

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
    # Say which install is missing, before sourcing a file that is not there.
    # Reached on a first run whenever this recipe is asked for ahead of the
    # steps that provide it -- `./setup.sh --only tensorrt-engines`, or a run
    # with ros2 or autoware-debian unticked. Without these two checks the
    # failure is `source: /opt/ros/humble/setup.bash: No such file or
    # directory`, which names neither this recipe nor the fix.
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
# Launch Commands - Start systems
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
    # Middleware preconditions, whichever middleware this host is on. Two jobs:
    # stop a ros2 daemon left behind by the OTHER RMW (its XML-RPC port is
    # 11511 + ROS_DOMAIN_ID with no RMW in it, so a stale one answers every graph
    # query from an empty world), and under zenoh confirm the interface this host
    # advertises exists and carries MULTICAST, since with no router that is the
    # only discovery path. Both failures are SILENT, which is why this is a gate
    # and not a hint. See scripts/rmw/ensure.sh.
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
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
    # host:= comes from the config/host marker, not from the "all" default.
    #
    # `host:=all` puts the is_orin group in scope, and that group includes
    # camera.launch.xml with camera_model:=zedx unconditionally — so a plain
    # `just launch` on the Advantech started the ZED driver for a camera that is
    # not attached, against zed_wrapper, which `just build` skips on any host
    # without the ZED SDK. `$(find-pkg-share zed_wrapper)` then aborts the whole
    # launch, and the message names a package nobody asked for.
    #
    # The marker already states which machine this is and config/ is the single
    # source of truth for that, so read it here rather than making every operator
    # remember host:=master. Only master and orin narrow the profile; loopback (or
    # no marker) keeps the historical single-machine `all`, and an explicit
    # host:= in ARGS still wins; see the case below.
    GOLFCART_HOST_ROLE=$(
        GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 \
        bash -c 'source "{{justfile_directory()}}/scripts/env.sh"; printf "%s" "${GOLFCART_HOST}"'
    ) || GOLFCART_HOST_ROLE=""
    case "${GOLFCART_HOST_ROLE}" in
        master | orin) HOST_ARG="host:=${GOLFCART_HOST_ROLE}" ;;
        *)             HOST_ARG="host:=all" ;;
    esac
    # An explicit host:= in ARGS wins outright. Dropping ours rather than
    # appending theirs: play_launch's precedence for a repeated argument is not
    # something to bet the ZED guard on.
    case " ${GOLFCART_LAUNCH_ARGS} " in
        *" host:="*) HOST_ARG="" ;;
    esac
    if [ "${GOLFCART_TX_ENABLED:-false}" = true ]; then
        printf '\033[1;31mCAN TX ENABLED — the cart can move. Ctrl-C to abort.\033[0m\n'
        for i in 3 2 1; do printf '  starting in %d...\r' "$i"; sleep 1; done
        printf '                       \n'
    fi
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

# ── This host only. The same recipes exist on both machines; the master drives
# ── the orin by running them over there, not by reimplementing them here.

# ⚠️  tx=on puts real frames on can0 and the cart can be commanded into motion.
# Start this host's stack. ARGS: [tx=on|off] [launch args]
launch-up ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    # Middleware preconditions, whichever middleware this host is on. Two jobs:
    # stop a ros2 daemon left behind by the OTHER RMW (its XML-RPC port is
    # 11511 + ROS_DOMAIN_ID with no RMW in it, so a stale one answers every graph
    # query from an empty world), and under zenoh confirm the interface this host
    # advertises exists and carries MULTICAST, since with no router that is the
    # only discovery path. Both failures are SILENT, which is why this is a gate
    # and not a hint. See scripts/rmw/ensure.sh.
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
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
    systemctl --user unset-environment GOLFCART_LAUNCH_ARGS GOLFCART_TX_ENABLED
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"
    exit $RC

# ⚠️  tx=on puts real frames on can0 and the cart can be commanded into motion.
# Start the stack on BOTH hosts; returns immediately. ARGS: [tx=on|off] [launch args]
launch-all ARGS="":
    #!/usr/bin/env bash
    set -uo pipefail
    # Middleware preconditions, whichever middleware this host is on. Two jobs:
    # stop a ros2 daemon left behind by the OTHER RMW (its XML-RPC port is
    # 11511 + ROS_DOMAIN_ID with no RMW in it, so a stale one answers every graph
    # query from an empty world), and under zenoh confirm the interface this host
    # advertises exists and carries MULTICAST, since with no router that is the
    # only discovery path. Both failures are SILENT, which is why this is a gate
    # and not a hint. See scripts/rmw/ensure.sh.
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
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
    # untouched on both sides: `just record stop` is its own verb.
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
