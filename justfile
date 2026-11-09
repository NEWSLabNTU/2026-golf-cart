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
# Simulators (planning, logging replay) and synthetic cameras on v4l2loopback
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
#
#   just up [ARGS...]     both hosts, as systemd units; returns at once
#   just down             both hosts, orin first; recording left alone
#   just run [ARGS...]    this host only, play_launch in the foreground
#   just logs             follow this host's unit
#
# ARGS are golfcart.launch.yaml arguments, `key:=value`, plus `@name` for
# config/launch/<name>.args, expanded in place; later args win
# (`just up @mingda-loop planning_speed_limit:=0.5`). scripts/launch/args.py
# expands them, adds host:=, master_ip:= and link_topics:= for this host's role,
# and prints the final list before anything starts.
#
# There is no CAN TX switch: the vehicle interface always transmits; the cart's
# power switch is the master enable.
#
# Every launch first runs scripts/rmw/ensure.sh, which fails loudly on two
# otherwise silent problems: a stale ros2 daemon from the other RMW, and (under
# zenoh) a missing or non-multicast interface.
# ============================================================================

# Teardown is `just down`; the orin's watchdog covers a master that never runs it.
# Start the stack on BOTH hosts as systemd units; returns at once. ARGS: [launch args, @file]
[positional-arguments]
up *ARGS:
    #!/usr/bin/env bash
    set -uo pipefail
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
    # Expand once, here, so both hosts get the same list even if the orin's
    # checkout has different arg files; the orin's _up-local sees no @ left.
    OUT=$(python3 {{justfile_directory()}}/scripts/launch/args.py --label "up args" "$@") || exit 2
    EXPANDED=()
    [ -n "${OUT}" ] && mapfile -t EXPANDED <<< "${OUT}"
    just _up-local "${EXPANDED[@]}" || exit 1
    # A missing orin does not fail the master, but the vehicle interface lives there.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just _up-local "${EXPANDED[@]}" \
            || echo "WARNING: could not start the orin - continuing without it; no vehicle interface, the cart cannot be driven" >&2
    fi
    echo
    echo "web UI: http://localhost:8081    logs: just logs    stop: just down"

# Stop the stack on BOTH hosts, orin first. Leaves any recording running.
down:
    #!/usr/bin/env bash
    set -uo pipefail
    RC=0
    # The orin first, while this host can still reach it.
    if [[ "${GOLFCART_USE_ORIN:-1}" == "1" ]]; then
        ./scripts/multi_machine/on_orin.sh just _down-local || RC=1
    fi
    just _down-local || RC=1
    exit $RC

# This host's unit only; `up` runs it here and, over ssh, on the orin. ARGS
# reach the unit through .golfcart-launch.args (gitignored), rewritten on EVERY
# start (empty when there are none), so no flag outlives the start that asked
# for it. launch_unit_exec.sh reads it and adds the host-derived args.
[private]
[positional-arguments]
_up-local *ARGS:
    #!/usr/bin/env bash
    set -uo pipefail
    REPO={{justfile_directory()}}
    "${REPO}/scripts/rmw/ensure.sh" || exit 2
    python3 "${REPO}/scripts/launch/args.py" --quiet --write "${REPO}/.golfcart-launch.args" "$@" || exit 2
    # Show what the unit will run: the same call launch_unit_exec.sh makes, with
    # the role the installer's drop-in gives the unit.
    ROLE=$(systemctl --user show -p Environment --value golfcart-launch.service 2>/dev/null \
        | tr ' ' '\n' | sed -n 's/^GOLFCART_HOST=//p')
    python3 "${REPO}/scripts/launch/args.py" --label "$(hostname) runs" \
        --host "${ROLE:-master}" --no-rviz --from "${REPO}/.golfcart-launch.args" >/dev/null || exit 2
    # Retired transport: an older launch-up left its flags in the user manager's
    # environment. Nothing reads it now; clear it so `systemctl show-environment`
    # cannot mislead.
    systemctl --user unset-environment GOLFCART_LAUNCH_ARGS 2>/dev/null || true
    # restart, not start: replaces a stale unit left by a previous run.
    if ! systemctl --user restart golfcart-launch.service; then
        echo "golfcart-launch.service failed to start on $(hostname)." >&2
        echo "Not installed yet?  just service install <role>" >&2
        exit 1
    fi
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"

# This host's unit only; `down` runs it here and on the orin.
[private]
_down-local:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user stop golfcart-launch.service
    RC=$?
    echo "$(hostname): launch $(systemctl --user is-active golfcart-launch.service)"
    exit $RC

# host:= comes from config/host (master/orin, plus master_ip:= and
# link_topics:=), else host:=all; host:=all would start the ZED driver on a
# machine without one. An explicit host:= in ARGS wins. rviz only with DISPLAY.
# Run the stack on THIS host only, in the foreground (Ctrl-C stops). ARGS: [launch args, @file]
[positional-arguments]
run *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    {{justfile_directory()}}/scripts/rmw/ensure.sh || exit 2
    RVIZ=()
    [ -n "${DISPLAY:-}" ] || RVIZ=(--no-rviz)
    OUT=$(python3 {{justfile_directory()}}/scripts/launch/args.py \
        --label "run args" --host auto "${RVIZ[@]}" "$@") || exit 2
    LAUNCH_ARGS=()
    [ -n "${OUT}" ] && mapfile -t LAUNCH_ARGS <<< "${OUT}"
    exec play_launch launch \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        --web-addr 0.0.0.0:8081 \
        golfcart_launch golfcart.launch.yaml \
        "${LAUNCH_ARGS[@]}"

# Follow this host's stack log.
logs:
    journalctl --user -u golfcart-launch.service -f

# ============================================================================
# Checks and audits
# ============================================================================

# Run sensor & interface health check (LiDAR, GNSS, IMU, cameras, CAN, system)
check-sensors:
    ./scripts/check/run.sh

# Audit launch files for silently-ignored arguments and unparseable comments.
audit-launch:
    python3 ./scripts/check/audit_launch.py

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
