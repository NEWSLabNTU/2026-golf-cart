# Rosbag recording and playback
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
    @just --list bag

# Play a bag into a running stack (default: newest in recordings/, then $GOLFCART_BAG_DIR),
# without the computed topics the stack recomputes. BAG: session id or path. OPTS: computed=on
play BAG="" *OPTS="":
    #!/usr/bin/env bash
    set -eo pipefail
    GOLFCART_ENV_QUIET=1 source scripts/env.sh
    PLAY_OPTS=()
    for opt in {{OPTS}}; do
        case "$opt" in
            computed=on|computed=true)   PLAY_OPTS+=(--computed) ;;
            computed=off|computed=false) ;;
            *) echo "Usage: just bag play [BAG] [computed=on|off]" >&2; exit 2 ;;
        esac
    done
    if [ -n "{{BAG}}" ]; then
        LATEST=$(python3 scripts/recording/session.py resolve-bag "{{BAG}}") || {
            [ -d "${GOLFCART_BAG_DIR:-${HOME}/rosbags}/{{BAG}}" ] && LATEST="${GOLFCART_BAG_DIR:-${HOME}/rosbags}/{{BAG}}"; }
        [ -n "${LATEST:-}" ] || { echo "No bag '{{BAG}}' (session id, bag dir, or a name in \$GOLFCART_BAG_DIR)" >&2; exit 1; }
    else
        # Sessions first: recordings/<id>/merged, else the newest <id>/<role>/bag.
        LATEST=$(python3 scripts/recording/session.py latest bag || true)
    fi
    if [ -z "${LATEST}" ]; then
        # Bags from before sessions: <role>_<ts>[_NAME], merged_<ts>.
        BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
        for candidate in "${BAG_DIR}"/*_*/metadata.yaml; do
            [ -s "${candidate}" ] || continue
            candidate="$(dirname "${candidate}")"
            if [ -z "${LATEST}" ] || [ "${candidate}" -nt "${LATEST}" ]; then
                LATEST="${candidate}"
            fi
        done
    fi
    if [ -z "${LATEST}" ]; then
        echo "No finalized bag in recordings/ or ${GOLFCART_BAG_DIR:-${HOME}/rosbags}" >&2
        exit 1
    fi
    echo "Playing: ${LATEST}"
    # play.py leaves out the topics of computed classes (config/recording/topics.yaml)
    # and filters the stack's own frames out of /tf; computed=on plays all of it.
    exec python3 scripts/recording/play.py "${PLAY_OPTS[@]}" "${LATEST}" --clock

# ============================================================================
# Multi-machine services (systemd user units, one role per machine)

# Replay a merged NTU campus bag into the logging simulation (see
# ntu_logging_sim.launch.xml). SET is CSIE-1, CSIE-2 or BLVD-1.
play-ntu SET="CSIE-1" ARGS="":
    ./scripts/rosbag/play_ntu_sim.sh {{SET}} {{ARGS}}

# ── NTU NDT replay test ─────────────────────────────────────────────────────
#
# Run these in order, each in its own terminal (1-3 stay running):
#
#   just ntu-test bag CSIE-1     # 1. bag PAUSED — publishes /clock only
#   just ntu-test up             # 2. stack, no RViz
#   just ntu-test rviz           # 3. RViz, point cloud actually visible
#   just ntu-test resume         # 4. let the sensors flow
#   just ntu-test init CSIE-1    # 5. seed NDT, once LiDAR is flowing
#   just ntu-test report         # 6. score it
#   just ntu-test down           # stop everything
#
# The order is not cosmetic. The bag leads so that everything after it is born
# on bag time; the pose comes last so NDT has scans to match against. Getting
# either wrong fails silently and still looks like it is working — see the
# comment at the top of scripts/rosbag/ntu_sim_bag.sh.

# A one-host recording session, scope `ros`, from this terminal; Ctrl-C stops
#
#   just bag record              ->  recordings/<YYYYmmdd_HHMMSS>/<role>/bag
#   just bag record campus_loop  ->  recordings/<YYYYmmdd_HHMMSS>_campus_loop/<role>/bag
#
# Same runner, scopes and layout as `just record start`, which runs it under
# systemd on both hosts. The topics live in config/recording/topics.yaml and
# nowhere else; scope `ros` is this host's half of the first-hand classes.
# Record this host's first-hand topics (scope ros) in the foreground, as a session
record NAME="":
    ./scripts/recording/record_foreground.sh {{NAME}}

# Record everything the ArUco indoor localizer needs (phase 3D-7).
# Name the scenario so the bag is readable without opening it:
#   just bag record-aruco bench_static_1board_3m
# Record an ArUco localizer session (LiDAR, cameras, IMU, TF)
record-aruco SCENARIO="session":
    ./scripts/rosbag/record_aruco.sh {{SCENARIO}}

# Record the phase 3B indoor mapping run: pre-drive checklist, then `bag record`
record-indoor:
    ./scripts/rosbag/record_indoor_mapping.sh

# Merge per-host bags into one (bag dirs, or session halves recordings/<id>/<role>). ARGS: [-o OUTPUT] <bag> <bag> [bag ...]
merge ARGS="":
    ./scripts/multi_machine/bag_merge.sh {{ARGS}}

# BAG: session id, bag path, or a name in $GOLFCART_BAG_DIR; default the newest
# session (merged, else master), then the newest legacy bag.
# Plays EVERY topic, computed ones included, unlike `bag play`: no stack runs
# here, so the recorded localization is the only localization RViz can show.
# Replay a bag in RViz. ARGS: rate:=2.0 start_offset:=40.0 play_args:=--loop rviz:=false
replay BAG="" ARGS="":
    #!/usr/bin/env bash
    set -eo pipefail
    BAG="{{BAG}}"
    BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
    if [ -z "${BAG}" ]; then
        BAG=$(python3 scripts/recording/session.py latest bag || true)
    fi
    if [ -z "${BAG}" ]; then
        # Bags from before sessions. Newest merged bag first: it has both hosts
        # in it. Fall back to a master bag so this works before any merge.
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
            echo "No bag given and none in recordings/ or ${BAG_DIR}" >&2
            echo "Pass one:  just bag replay <session id | bag> [\"rate:=2.0 start_offset:=40.0\"]" >&2
            exit 1
        fi
        echo "Replaying newest bag: ${BAG}"
    elif R=$(python3 scripts/recording/session.py resolve-bag "${BAG}"); then
        BAG="${R}"
    elif [ ! -d "${BAG}" ] && [ -d "${BAG_DIR}/${BAG}" ]; then
        BAG="${BAG_DIR}/${BAG}"
    fi
    ros2 launch golfcart_launch bag_replay.launch.xml bag:="${BAG}" {{ARGS}}

# Fetch the orin's rosbags to this host. ARGS: --latest, --list, or a bag name.
fetch-orin ARGS="":
    ./scripts/multi_machine/bag_fetch_orin.sh {{ARGS}}

# Report corner sigma, detection geometry and coverage from a recorded bag.
report-aruco BAG:
    python3 ./scripts/analysis/aruco_bag_report.py {{BAG}}
