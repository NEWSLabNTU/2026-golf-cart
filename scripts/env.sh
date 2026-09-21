#!/usr/bin/env bash
# Golf Cart shell environment. Sourceable from a bare (non-direnv) shell:
#
#     source scripts/env.sh
#
# `.envrc` sources this same file, so direnv shells and plain shells cannot
# drift apart: all of the logic lives here, and `.envrc` only adds the direnv
# specific `watch_file` calls.
#
# Sourcing modes (environment variables, both optional):
#   GOLFCART_ENV_RESOLVE_ONLY=1  define the helpers and resolve the DDS profile,
#                                but skip the heavyweight environment setup
#                                (Autoware/ROS sourcing, CUDA, workspace overlay).
#                                Used by scripts/doctor.sh.
#   GOLFCART_ENV_QUIET=1         suppress the informational/warning banners.
#
# Do not `set -e`/`set -u` here: this file is sourced into interactive shells.

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "scripts/env.sh must be sourced, not executed:  source scripts/env.sh" >&2
    exit 64
fi

# Repo root, resolved from this file rather than $PWD so a bare shell can source
# it from anywhere.
GOLFCART_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export GOLFCART_REPO_ROOT

# ── DDS profile resolution ───────────────────────────────────────────────────
#
# Precedence:
#   1. GOLFCART_ENV_ROLE — the caller states the role outright
#   2. an explicitly exported GOLFCART_DDS_PROFILE
#   3. the `config/host` marker file (one word: master|orin); the older
#      `.golfcart-host` in the repo root is still read if `config/host` is absent
#   4. loopback
#
# A marker-derived multi-machine role is then DEMOTED to loopback if the other
# machine does not answer a ping. The master profile binds Cyclone to the shared
# 192.168.125.0/24 LAN and puts every topic on it, including two LiDARs' worth of
# PointCloud2. That segment is 100 Mb/s: measured 2026-09-21, a solo `just launch`
# on the master pushed 11993 KiB/s against a 12800 KiB/s ceiling and took ssh to
# the orin down with it, which is a miserable thing to debug because the symptom
# (cannot reach the orin) looks nothing like the cause (the profile assumes it is
# there). With the orin genuinely offline none of that traffic has a reader, so
# the demotion costs nothing and the loopback profile keeps it on `lo`.
#
# Only a `marker` role is demoted. A GOLFCART_ENV_ROLE is a statement of intent
# from a caller that knows better: the systemd units in particular must not
# change transport because a ping happened to drop, so `just launch-all` keeps
# the profile it was installed with.
#
# GOLFCART_DDS_PROBE=0 is the override, and it is deliberately NOT
# `GOLFCART_DDS_PROFILE=master`. That variable only counts as explicit when it
# DIFFERS from what the marker resolves to — see the "explicit export wins"
# block below, which cannot tell a deliberate export from this file inheriting
# its own previous one. On a master whose marker already says `master` the two
# are identical, so it reads as `marker` and gets demoted like any other.
# Suggesting it as the escape hatch would hand someone a knob that silently
# does nothing in exactly the case they are trying to escape.
#
# GOLFCART_ENV_ROLE exists for the systemd units, which are told their role by an
# installer-written drop-in (Environment=GOLFCART_HOST=master|orin) and must not
# depend on the marker file: a unit whose role came from a marker someone edited
# would silently join the wrong DDS domain. It is deliberately a separate name
# from GOLFCART_HOST, which this function *exports* — reusing that would make a
# re-source of this file treat our own previous export as an override and stop
# tracking marker edits.
#
# The chosen name must have a matching config/cyclonedds/<name>.xml. A name
# without one falls back to loopback *loudly*: silently running the wrong
# profile is the exact failure this machinery exists to remove.
#
# Sets (and exports):
#   GOLFCART_HOST                  the MACHINE: master | orin | loopback.
#                                  A demotion does NOT change this - the box is
#                                  still the master when the orin is switched
#                                  off. The justfile's host:= and
#                                  record_unit_exec.sh's topic list key on it.
#   GOLFCART_DDS_PROFILE           the TRANSPORT: which cyclonedds/<name>.xml.
#                                  Same word as GOLFCART_HOST except after a
#                                  demotion, which moves this to loopback and
#                                  leaves the machine alone.
#   GOLFCART_DDS_DEMOTED_FROM      set only while demoted: the role it came from
#   GOLFCART_DDS_PROFILE_SOURCE    role | env | marker | marker-demoted |
#                                  fallback | invalid-*
#   CYCLONEDDS_URI                 file:// URI of the profile XML

# The other machine's address, from the one file that holds it. Sourced in a
# subshell because this runs BEFORE the main body sources multi_machine.conf
# (scripts/doctor.sh resolves the profile with GOLFCART_ENV_RESOLVE_ONLY, which
# returns long before that point) and must not leak the conf's variables into
# the caller's shell.
golfcart_peer_addr() {
    local role="$1" conf="${GOLFCART_REPO_ROOT}/config/multi_machine.conf"
    [ -f "$conf" ] || return 1
    (
        # shellcheck source=/dev/null
        . "$conf" >/dev/null 2>&1 || exit 1
        case "$role" in
            # ORIN_SSH is user@addr; the expansion also copes with a bare addr.
            master) printf '%s\n' "${ORIN_SSH##*@}" ;;
            orin)   printf '%s\n' "${MASTER_IP:-}" ;;
            *)      exit 1 ;;
        esac
    )
}

# 0 = up, 1 = definitely down, 2 = could not tell. Only a 1 demotes: failing to
# probe must not silently change transport.
#
# Cached briefly because .envrc sources this file on every directory entry and
# every new shell, and the down case costs the full ping timeout each time. The
# TTL is short enough that bringing the orin up is noticed within a few seconds
# of the next shell; `rm` the file, or pass GOLFCART_DDS_PROBE=0, to bypass it.
golfcart_peer_reachable() {
    local addr="$1"
    [ -n "$addr" ] || return 2
    command -v ping >/dev/null 2>&1 || return 2

    local key cache ttl=15 now mtime cached
    key=$(printf '%s' "$addr" | tr -c '0-9A-Za-z._-' '_')
    cache="${TMPDIR:-/tmp}/.golfcart-peer-$(id -u)-${key}"
    now=$(date +%s 2>/dev/null || echo 0)

    if [ -f "$cache" ]; then
        mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
        if [ "$now" -gt 0 ] && [ $(( now - mtime )) -lt "$ttl" ]; then
            read -r cached < "$cache" 2>/dev/null || cached=""
            [ "$cached" = "up" ] && return 0
            [ "$cached" = "down" ] && return 1
        fi
    fi

    if ping -c1 -W1 "$addr" >/dev/null 2>&1; then
        echo up > "$cache" 2>/dev/null || true
        return 0
    fi
    echo down > "$cache" 2>/dev/null || true
    return 1
}

golfcart_resolve_dds_profile() {
    local root="${GOLFCART_REPO_ROOT}"
    # config/ is the single place configuration lives; the repo-root dotfile is
    # the older location and is still honoured so an existing checkout keeps
    # working after a pull.
    local marker="${root}/config/host"
    [ -f "$marker" ] || marker="${root}/.golfcart-host"
    local warn_stamp="${root}/.envrc.host-warned"
    local quiet="${GOLFCART_ENV_QUIET:-0}"

    local from_marker="" profile="" source_of="" raw=""

    # Undo any demotion this function performed on a previous source, so the
    # peer is probed again rather than inheriting the verdict.
    #
    # Without this the "explicit export wins" block below reads our own
    # GOLFCART_DDS_PROFILE=loopback as a deliberate choice — it now differs from
    # both the marker and GOLFCART_HOST, which is exactly the shape that test is
    # looking for — and the demotion sticks even after the orin comes back.
    if [ -n "${GOLFCART_DDS_DEMOTED_FROM:-}" ] &&
       [ "${GOLFCART_DDS_PROFILE:-}" = "loopback" ]; then
        GOLFCART_DDS_PROFILE="${GOLFCART_DDS_DEMOTED_FROM}"
        unset GOLFCART_DDS_DEMOTED_FROM
    fi

    if [ -f "$marker" ]; then
        # First whitespace-separated word of the first non-empty, non-comment line.
        raw=$(sed -e 's/#.*//' "$marker" 2>/dev/null | tr -d '\r' | awk 'NF {print $1; exit}') || raw=""
        from_marker="$raw"
    fi

    if [ -n "$from_marker" ]; then
        profile="$from_marker"
        source_of="marker"
    else
        profile="loopback"
        source_of="fallback"
        if [ -f "$marker" ] && [ "$quiet" != "1" ]; then
            echo "WARNING: ${marker} is empty; using the loopback DDS profile." >&2
        fi
    fi

    # An explicit export wins. "Explicit" means a value that differs from what
    # this function would resolve on its own — that way re-sourcing this file
    # (which inherits our own previous export) still tracks the marker, while a
    # deliberate `export GOLFCART_DDS_PROFILE=orin` still overrides it.
    if [ -n "${GOLFCART_DDS_PROFILE:-}" ] && [ "${GOLFCART_DDS_PROFILE}" != "$profile" ] &&
       [ "${GOLFCART_DDS_PROFILE}" != "${GOLFCART_HOST:-}" ]; then
        profile="${GOLFCART_DDS_PROFILE}"
        source_of="env"
    fi

    # A stated role outranks everything: the caller knows which machine it is.
    if [ -n "${GOLFCART_ENV_ROLE:-}" ]; then
        profile="${GOLFCART_ENV_ROLE}"
        source_of="role"
    fi

    # Validate: a safe bare token with a matching profile file.
    local xml="${root}/config/cyclonedds/${profile}.xml"
    if ! printf '%s' "$profile" | grep -Eq '^[A-Za-z0-9_-]+$' || [ ! -f "$xml" ]; then
        if [ "$quiet" != "1" ]; then
            echo "============================================================" >&2
            echo "ERROR: unknown DDS profile '${profile}'" >&2
            case "$source_of" in
                marker) echo "  named by ${marker}" >&2 ;;
                env)    echo "  named by \$GOLFCART_DDS_PROFILE" >&2 ;;
                role)   echo "  named by \$GOLFCART_ENV_ROLE" >&2 ;;
            esac
            echo "  no such file: config/cyclonedds/${profile}.xml" >&2
            echo "  available:    $(golfcart_dds_profiles | tr '\n' ' ')" >&2
            echo "  FALLING BACK TO loopback — cross-machine topics will not appear." >&2
            echo "============================================================" >&2
        fi
        source_of="invalid-${source_of}"
        profile="loopback"
        xml="${root}/config/cyclonedds/loopback.xml"
    fi

    # Transport follows the machine unless the demotion below separates them.
    local dds_profile="$profile"

    # Demote a marker-derived multi-machine role when the peer is not there.
    # After validation, so this can only ever act on a profile that resolved.
    if [ "${GOLFCART_DDS_PROBE:-1}" != "0" ] &&
       [ "$source_of" = "marker" ] && [ "$profile" != "loopback" ]; then
        local peer peer_rc
        peer=$(golfcart_peer_addr "$profile" 2>/dev/null) || peer=""
        golfcart_peer_reachable "$peer"; peer_rc=$?
        if [ "$peer_rc" = "1" ]; then
            if [ "$quiet" != "1" ]; then
                echo "NOTE: peer ${peer} did not answer; using the loopback DDS profile" \
                     "instead of '${profile}'." >&2
                echo "      Cross-machine topics will not appear." \
                     "To keep '${profile}' anyway: GOLFCART_DDS_PROBE=0" >&2
            fi
            # Only the TRANSPORT changes. `profile` stays the machine role, so
            # GOLFCART_HOST below still says `master`.
            #
            # Conflating the two broke `just launch` outright while this was
            # being written. The justfile derives `host:=` from GOLFCART_HOST;
            # anything that is not master or orin falls through to `host:=all`,
            # which puts the is_orin group in scope, which includes
            # camera.launch.xml with camera_model:=zedx, which resolves
            # $(find-pkg-share zed_wrapper) — a package `just build` skips on
            # any host without the ZED SDK. The launch then dies naming a
            # package nobody asked for. That is the exact failure the comment
            # at the host:= block in the justfile exists to prevent.
            #
            # The machine is still the master when the orin is switched off.
            # Only where its packets go has changed.
            GOLFCART_DDS_DEMOTED_FROM="$profile"
            export GOLFCART_DDS_DEMOTED_FROM
            dds_profile="loopback"
            xml="${root}/config/cyclonedds/loopback.xml"
            source_of="marker-demoted"
        fi
    fi

    if [ "$source_of" = "fallback" ] && [ "$quiet" != "1" ] && [ ! -f "$warn_stamp" ]; then
        echo "No config/host marker; using the loopback DDS profile."
        echo "Two-machine operation needs one. On this machine run:"
        echo "    echo master > config/host      # or: orin"
        touch "$warn_stamp" 2>/dev/null || true
    fi

    # GOLFCART_HOST is the MACHINE; GOLFCART_DDS_PROFILE is the TRANSPORT. They
    # are the same word except when a demotion has separated them, and callers
    # want different ones: the justfile's host:= and record_unit_exec.sh's
    # per-host topic list key on the machine, CYCLONEDDS_URI on the transport.
    GOLFCART_HOST="$profile"
    GOLFCART_DDS_PROFILE="$dds_profile"
    GOLFCART_DDS_PROFILE_SOURCE="$source_of"
    CYCLONEDDS_URI="file://${xml}"
    export GOLFCART_HOST GOLFCART_DDS_PROFILE GOLFCART_DDS_PROFILE_SOURCE CYCLONEDDS_URI
}

# ── RMW selection ────────────────────────────────────────────────────────────
#
# GOLFCART_RMW (config/runtime.conf) picks the middleware; the role resolved by
# golfcart_resolve_dds_profile above picks the profile within it.
#
# Call this AFTER that function -- it reads $GOLFCART_HOST -- and AFTER Autoware's
# setup.bash, which exports an RMW_IMPLEMENTATION of its own and would otherwise
# win. That ordering is the whole reason this is a function called at the bottom
# rather than an export next to the profile resolution.
#
# Sets (and exports):
#   GOLFCART_RMW                 validated middleware name: cyclonedds | zenoh
#   RMW_IMPLEMENTATION           rmw_cyclonedds_cpp | rmw_zenoh_cpp
#   CYCLONEDDS_URI               kept under cyclonedds, UNSET under zenoh
#   ZENOH_SESSION_CONFIG_URI     set under zenoh when a profile exists for the role
#   ZENOH_ROUTER_CHECK_ATTEMPTS  -1 under zenoh: skip the router check entirely
#
# The unsets are load-bearing, not tidiness. Each RMW ignores the other's
# variables, so a stale CYCLONEDDS_URI cannot misconfigure zenoh -- but it can
# absolutely mislead the person running `env | grep -i dds` to find out why two
# hosts stopped seeing each other, and that is the failure this file exists to
# make legible.
golfcart_resolve_rmw() {
    local root="${GOLFCART_REPO_ROOT}"
    local quiet="${GOLFCART_ENV_QUIET:-0}"

    # runtime.conf is sourced here as well as in the main body below. The
    # GOLFCART_ENV_RESOLVE_ONLY path (scripts/doctor.sh, and the host-role probe
    # in the launch recipe) never reaches that body and still has to know which
    # RMW this host is on. Every key in runtime.conf is written ${VAR:-default},
    # so sourcing it twice is idempotent and an exported override still wins.
    if [ -z "${GOLFCART_RMW:-}" ] && [ -f "${root}/config/runtime.conf" ]; then
        # shellcheck source=/dev/null
        . "${root}/config/runtime.conf"
    fi
    GOLFCART_RMW="${GOLFCART_RMW:-cyclonedds}"

    case "${GOLFCART_RMW}" in
        zenoh)
            # Refuse to half-switch. Without the package, RMW_IMPLEMENTATION
            # names a library that rmw_implementation cannot dlopen, and every
            # ros2 process dies with "failed to load shared library" -- which
            # reads as a broken install, not as a middleware that was never
            # installed. Fall back loudly instead, exactly as an unknown DDS
            # profile does above.
            if [ ! -f /opt/ros/humble/lib/librmw_zenoh_cpp.so ] \
               && ! (command -v ros2 >/dev/null 2>&1 && ros2 pkg prefix rmw_zenoh_cpp >/dev/null 2>&1); then
                if [ "$quiet" != "1" ]; then
                    echo "============================================================" >&2
                    echo "ERROR: GOLFCART_RMW=zenoh, but rmw_zenoh_cpp is not installed." >&2
                    echo "  Install it on THIS host:" >&2
                    echo "      sudo apt install ros-humble-rmw-zenoh-cpp" >&2
                    echo "  FALLING BACK TO cyclonedds." >&2
                    echo "============================================================" >&2
                fi
                GOLFCART_RMW=cyclonedds
            fi
            ;;
    esac

    case "${GOLFCART_RMW}" in
        zenoh)
            RMW_IMPLEMENTATION=rmw_zenoh_cpp
            unset CYCLONEDDS_URI
            local sess="${root}/config/zenoh/${GOLFCART_HOST}-session.json5"
            # There is deliberately no loopback profile. Single-machine
            # operation wants precisely rmw_zenoh's shipped defaults -- peer
            # sessions on localhost, one local router, no LAN listener -- and
            # leaving both variables UNSET guarantees that in a way a
            # checked-in byte-identical copy cannot, because the copy can drift
            # when the package is upgraded. See config/zenoh/README.md.
            if [ -f "$sess" ]; then
                ZENOH_SESSION_CONFIG_URI="$sess"; export ZENOH_SESSION_CONFIG_URI
                # These profiles run NO Zenoh router -- peers discover each other
                # by multicast, the way CycloneDDS does with SPDP. Without this,
                # every node spends a second looking for a router that does not
                # exist and then logs a warning about proceeding without one.
                # -1 means "skip the check"; 0 would mean "wait forever".
                ZENOH_ROUTER_CHECK_ATTEMPTS=-1; export ZENOH_ROUTER_CHECK_ATTEMPTS
            else
                # No profile for this role (loopback). Fall back to rmw_zenoh's
                # shipped defaults, which DO expect a router on localhost:7447 --
                # so leave the router check alone rather than disabling a check
                # that is, for that configuration, correct.
                unset ZENOH_SESSION_CONFIG_URI ZENOH_ROUTER_CHECK_ATTEMPTS
            fi
            ;;
        *)
            GOLFCART_RMW=cyclonedds
            RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
            unset ZENOH_SESSION_CONFIG_URI ZENOH_ROUTER_CHECK_ATTEMPTS
            ;;
    esac

    export GOLFCART_RMW RMW_IMPLEMENTATION
}

# Which RMW the RUNNING ros2 daemon was started with, or "" if none is running.
#
# The daemon binds its middleware at startup and keeps it for its lifetime, so
# after a GOLFCART_RMW switch a leftover daemon answers `ros2 topic list`,
# `ros2 node list` and every other graph query from the OTHER middleware's view
# of the world -- which is empty. Nothing errors. The stack is up and healthy and
# the CLI reports nothing at all, which is indistinguishable from a launch that
# silently failed.
#
# Read off the daemon's own ARGV, not inferred and not from our environment.
# ros2cli spawns it as `... ros2cli.daemon --rmw-implementation <name>
# --ros-domain-id N`, and its source says those arguments are passed "only for
# visibility in the process list" -- so the process list is exactly where the
# answer is, and it stays correct even when the shell that started the daemon is
# long gone. /proc/<pid>/environ is the fallback for a daemon started some other
# way.
#
# Worth knowing why a stale daemon is invisible rather than noisy: ros2cli's
# get_port() is base 11511 plus ROS_DOMAIN_ID and nothing else. The RMW is not in
# it. So a CycloneDDS daemon and a Zenoh daemon claim the SAME port, the CLI
# happily talks to whichever got there first, and it answers every graph query
# from a middleware where nothing is published.
golfcart_daemon_rmw() {
    local pid args
    for pid in $(pgrep -f 'ros2cli\.daemon|_ros2_daemon' 2>/dev/null); do
        args=$(tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null \
               | grep -A1 -x -- '--rmw-implementation' | tail -1)
        if [ -n "$args" ] && [ "$args" != "--rmw-implementation" ]; then
            printf '%s' "$args"
        else
            tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null \
                | sed -n 's/^RMW_IMPLEMENTATION=//p' | head -1
        fi
        return 0
    done
    return 0
}

# ── Sourcing third-party setup files safely ──────────────────────────────────
# direnv evaluates .envrc under `set -euo pipefail`, and ROS/colcon setup files
# are not written for that (e.g. /opt/ros/humble/setup.bash reads
# $AMENT_TRACE_SETUP_FILES unset). Relax the options around them and restore
# whatever the caller had afterwards.
_golfcart_relax_shell_opts() { _GOLFCART_SAVED_SHOPTS="$-"; set +eu; }
_golfcart_restore_shell_opts() {
    case "${_GOLFCART_SAVED_SHOPTS:-}" in *e*) set -e ;; esac
    case "${_GOLFCART_SAVED_SHOPTS:-}" in *u*) set -u ;; esac
    unset _GOLFCART_SAVED_SHOPTS
    return 0
}

# List the available profile names, one per line.
golfcart_dds_profiles() {
    local f
    for f in "${GOLFCART_REPO_ROOT}"/config/cyclonedds/*.xml; do
        [ -f "$f" ] || continue
        basename "$f" .xml
    done
}

if [ "${GOLFCART_ENV_RESOLVE_ONLY:-0}" = "1" ]; then
    golfcart_resolve_dds_profile
    golfcart_resolve_rmw
else

# ── Autoware / ROS 2 ─────────────────────────────────────────────────────────
if [ -f /opt/autoware/1.5.0/setup.bash ]; then
    # Source Autoware 1.5.0 environment if available
    _golfcart_relax_shell_opts
    source /opt/autoware/1.5.0/setup.bash
    _golfcart_restore_shell_opts
else
    # Fallback: Manual Autoware and ROS 2 setup
    if [ "${GOLFCART_ENV_QUIET:-0}" != "1" ]; then
        echo "=========================================="
        echo "INFO: /opt/autoware/autoware-env not found"
        echo "INFO: Please source your Autoware installation manually:"
        echo "      source \$AUTOWARE_DIR/install/setup.bash"
        echo "=========================================="
    fi

    # RMW_IMPLEMENTATION is NOT set here. golfcart_resolve_rmw at the bottom
    # of this file owns it, for both branches, and must run after whichever
    # setup.bash was sourced.

    # Unset ROS_LOCALHOST_ONLY if present
    if [[ -v ROS_LOCALHOST_ONLY ]]; then
        echo 'WARNING: ROS_LOCALHOST_ONLY variable is present. Unsetting it.'
        unset ROS_LOCALHOST_ONLY
    fi

    # Source ROS 2 Humble -- if it is there. On a machine where setup has not
    # run yet neither /opt/autoware nor /opt/ros exists, and sourcing blind
    # reports `/opt/ros/humble/setup.bash: No such file or directory` from
    # inside whatever sourced this file: direnv on cd, `just build`'s env
    # guard, a systemd unit exec script. Say what is missing instead, and
    # return without an environment rather than aborting -- .envrc must not
    # make the directory unenterable, and the callers that do need ROS check
    # for it themselves.
    if [ -f /opt/ros/humble/setup.bash ]; then
        _golfcart_relax_shell_opts
        source /opt/ros/humble/setup.bash
        _golfcart_restore_shell_opts
    elif [ "${GOLFCART_ENV_QUIET:-0}" != "1" ]; then
        echo "=========================================="
        echo "INFO: ROS 2 Humble not found at /opt/ros/humble either."
        echo "INFO: Nothing in this repo will build or run until it is installed:"
        echo "      ./setup.sh          # or: ./setup.sh --only ros2"
        echo "=========================================="
    fi
fi

# ── CycloneDDS host requirements ─────────────────────────────────────────────
#
# Deliberately OUTSIDE the Autoware if/else above. This check used to live in the
# `else` branch -- the one taken only when /opt/autoware is ABSENT -- so on every
# correctly provisioned machine it was dead code. That is why no one had ever
# seen its warning, and why .envrc.sysctl-warned did not exist on a host whose
# buffers were in fact too small to create a DDS domain.
# Two separate thresholds, and conflating them is what made this bite:
#
#   FATAL       every profile in config/cyclonedds/ declares
#               <SocketReceiveBufferSize min="10MB"/>, and CycloneDDS treats
#               `min` as a hard requirement. Below it EVERY ros2 process dies
#               at startup with "rmw_create_node: failed to create domain".
#               The loopback profile additionally pins `lo`, which then also
#               needs the MULTICAST flag.
#
#   SUBOPTIMAL  the tuned values (2GB buffer, ipfrag settings) prevent packet
#               loss with high-bandwidth data. Worth having, not fatal.
#
# The old code checked only the tuned values, called the result a warning,
# and silenced it permanently with a .envrc.sysctl-warned marker. So a host
# that could not create a DDS domain at all reported "you may experience
# packet loss" -- once -- and then said nothing ever again. The failure that
# follows is unrecognisable: the bag player dies, `ros2 topic list` shows
# nothing, and it reads as a broken bag or a broken launch.
rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
ipfrag_time=$(sysctl -n net.ipv4.ipfrag_time 2>/dev/null || echo "999")
ipfrag_thresh=$(sysctl -n net.ipv4.ipfrag_high_thresh 2>/dev/null || echo "0")
wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "0")
netdev_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "0")

# Kept as a function so the two audiences get different treatment. Sourcing
# env.sh only WARNS -- `just build`, `just test` and an ordinary shell have no
# use for a DDS domain and must not be blocked by one. Commands that actually
# start ROS call golfcart_require_dds and refuse to run.
golfcart_dds_problems() {
    local problems="" rmem
    # Every check below is about CycloneDDS: the 16MB floor comes from the
    # <SocketReceiveBufferSize min=> in config/cyclonedds/*.xml, and the lo
    # MULTICAST flag matters only because the loopback profile pins that
    # interface. Zenoh needs neither -- it carries data over TCP -- so under
    # zenoh this function has nothing to say, and saying it anyway would send
    # an operator to tune sysctls that cannot affect anything.
    # Zenoh's own precondition is that the interface carrying this host's LAN
    # address has the MULTICAST flag, and that is checked where it can be acted
    # on: scripts/rmw/ensure.sh.
    [ "${GOLFCART_RMW:-cyclonedds}" = "cyclonedds" ] || return 0
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    if [ "${rmem}" -lt 16777216 ]; then
        problems="${problems}
  - net.core.rmem_max is ${rmem}; the DDS profile requires at least 16777216"
    fi
    if [ "${CYCLONEDDS_URI:-}" != "${CYCLONEDDS_URI#*loopback.xml}" ] \
       && ! ip link show lo 2>/dev/null | grep -q MULTICAST; then
        problems="${problems}
  - the loopback profile pins the lo interface, and lo has no MULTICAST flag"
    fi
    [ -n "${problems}" ] || return 0
    printf '%s\n' "${problems}"
    return 1
}

# Call this from anything that starts ROS nodes:
#
#     golfcart_require_dds || exit 1
#
# Returns non-zero, and explains, when the host cannot create a DDS domain.
golfcart_require_dds() {
    local problems
    problems=$(golfcart_dds_problems) && return 0
    [ -n "${GOLFCART_SKIP_DDS_CHECK:-}" ] && return 0
    {
        echo ""
        echo "ERROR: this host cannot run ROS with the configured DDS profile."
        echo "${problems}"
        echo ""
        echo "  Every ros2 process would fail with:"
        echo "      rmw_create_node: failed to create domain, error Error"
        echo ""
        echo "  Fix it with the setup script:"
        echo "      ./setup.sh                 # menu -> Network configuration (DDS)"
        echo "      ./setup.sh network-dds     # or just this one step"
        echo ""
        echo "  Both persist across reboots. To bypass (it will not make ROS"
        echo "  work): export GOLFCART_SKIP_DDS_CHECK=1"
        echo ""
    } >&2
    return 1
}

# Warn on load. NOT silenced by a marker file, unlike the tuning note below: a
# host in this state cannot run ROS at all, and the previous once-ever warning
# is precisely how that went unnoticed until a bag replay failed with what
# looked like a missing /clock.
if [ "${GOLFCART_ENV_QUIET:-0}" != "1" ] && [ -z "${GOLFCART_SKIP_DDS_CHECK:-}" ]; then
    if ! _golfcart_dds_problems=$(golfcart_dds_problems); then
        {
            echo ""
            echo "WARNING: this host cannot create a DDS domain — ROS will not start."
            echo "${_golfcart_dds_problems}"
            echo "  Builds are unaffected. Fix before launching: ./setup.sh network-dds"
            echo ""
        } >&2
    fi
    unset _golfcart_dds_problems
fi

# Suboptimal-but-usable: still only worth saying once.
if [ "$rmem_max" -lt 2147483647 ] || \
   [ "$ipfrag_time" -gt 3 ] || \
   [ "$ipfrag_thresh" -lt 134217728 ] || \
   [ "$wmem_max" -lt 16777216 ] || \
   [ "$netdev_backlog" -lt 8192 ]; then
    if [ ! -f "${GOLFCART_REPO_ROOT}/.envrc.sysctl-warned" ]; then
        echo "┌────────────────────────────────────────────────────────────┐"
        echo "│ NOTE: CycloneDDS kernel buffers are not fully tuned        │"
        echo "│ ROS works; high-bandwidth topics may drop packets.         │"
        echo "│ To tune: ./setup.sh cyclonedds-sysctl                     │"
        echo "└────────────────────────────────────────────────────────────┘"
        touch "${GOLFCART_REPO_ROOT}/.envrc.sysctl-warned" 2>/dev/null || true
    fi
fi

# ── Sensor selection ─────────────────────────────────────────────────────────
# IMU_SOURCE / CAMERA_MODEL / GNSS_RECEIVER reach the sensor kit only as
# environment variables:
# the launch-argument path is swallowed by two installed Autoware files that
# forward a fixed set of arguments. See config/sensors.conf.
#
# POINTCLOUD_BACKEND crosses the same gap but is NOT set here. It is a per-run
# choice rather than a per-machine one, so golfcart.launch.yaml declares it as a
# launch argument and set_env's it just before the include. Nothing needs to
# resolve it at shell level.
if [ -f "${GOLFCART_REPO_ROOT}/config/sensors.conf" ]; then
    # shellcheck source=/dev/null
    . "${GOLFCART_REPO_ROOT}/config/sensors.conf"
    export IMU_SOURCE CAMERA_MODEL GNSS_RECEIVER
fi

# ── NTRIP account ────────────────────────────────────────────────────────────
# gnss.launch.xml loads the NTRIP client's parameters from
# $(env NTRIP_PARAM_FILE <the sensor kit's credential-less default>). The
# account is a secret, so it lives in the gitignored config/ntrip.param.yaml
# (copy config/ntrip.param.yaml.example) and is exported only when that file
# exists; otherwise the variable stays unset and the launch default applies.
# An already-exported NTRIP_PARAM_FILE wins, like every other key here. Only
# read when `just launch use_ntrip:=true` starts the client.
if [ -f "${GOLFCART_REPO_ROOT}/config/ntrip.param.yaml" ]; then
    export NTRIP_PARAM_FILE="${NTRIP_PARAM_FILE:-${GOLFCART_REPO_ROOT}/config/ntrip.param.yaml}"
fi

# ── Multi-machine addresses ──────────────────────────────────────────────────
# config/multi_machine.conf is the only place either machine's address is
# written down. It was already the single source for the ssh-based scripts in
# scripts/multi_machine/, which each source it directly; exporting the master's
# address here extends that to the launch tree.
#
# golfcart.launch.yaml declares a `master_ip` argument defaulting to
# $(env GOLFCART_MASTER_IP), which is how ntp_monitor on the orin learns which
# host to measure its clock against. Deliberately no fallback literal in the
# launch file: a second copy of an address is exactly what this avoids, and an
# unset variable fails loudly at launch rather than silently measuring against
# the wrong machine.
#
# The conf assigns MASTER_IP from ${GOLFCART_MASTER_IP:-...}, so an address
# exported before this point still wins and the round-trip is stable.
if [ -f "${GOLFCART_REPO_ROOT}/config/multi_machine.conf" ]; then
    # shellcheck source=/dev/null
    . "${GOLFCART_REPO_ROOT}/config/multi_machine.conf"
    export GOLFCART_MASTER_IP="${MASTER_IP}"
fi

# ── play_launch runtime ──────────────────────────────────────────────────────
# GOLFCART_CONTAINER_MODE picks how composable nodes are run. It is resolved
# here rather than baked into each caller so that `just launch`, the systemd
# units and the replay scripts cannot disagree about it. See config/runtime.conf
# for what each mode costs.
if [ -f "${GOLFCART_REPO_ROOT}/config/runtime.conf" ]; then
    # shellcheck source=/dev/null
    . "${GOLFCART_REPO_ROOT}/config/runtime.conf"
    export GOLFCART_CONTAINER_MODE
fi

# ── Vehicle interface ────────────────────────────────────────────────────────
# GOLFCART_TX_ENABLED is an environment variable for the same forced reason:
# the installed tier4_vehicle_launch/vehicle.launch.xml forwards three arguments
# to our vehicle_interface.launch.xml and drops the rest. See config/vehicle.conf.
if [ -f "${GOLFCART_REPO_ROOT}/config/vehicle.conf" ]; then
    # shellcheck source=/dev/null
    . "${GOLFCART_REPO_ROOT}/config/vehicle.conf"
    export GOLFCART_TX_ENABLED
fi

# RMW_IMPLEMENTATION is resolved below by golfcart_resolve_rmw, together with
# the matching transport config. It must happen after Autoware's setup.bash,
# which exports an RMW of its own, and after the profile role is known.

# ROS_LOCALHOST_ONLY would confine this host to itself, the exact opposite of
# what a two-machine deployment needs. Autoware's setup.bash unsets it too, but
# not every path goes through that.
unset ROS_LOCALHOST_ONLY

# ── CycloneDDS profile ───────────────────────────────────────────────────────
# GOLFCART_DDS_PROFILE selects config/cyclonedds/<profile>.xml:
#   loopback  single-machine (default; identical to the old root cyclonedds.xml)
#   master    cart AGX Orin  on the GolfCart AP (192.168.13.1)
#   orin      slave Jetson   on the GolfCart AP (192.168.13.2)
# The profile normally comes from the gitignored `config/host` marker; see
# golfcart_resolve_dds_profile above. The systemd units derive their own URI from
# GOLFCART_HOST, so this only affects plain shells and `just launch`.
#
# No `ros2 daemon stop` here on purpose: a daemon's DDS context is fixed when it
# starts, so this file cannot repair a running one, and stopping it would be a
# surprising side effect of opening a shell. `just service doctor` reports it instead.
golfcart_resolve_dds_profile
golfcart_resolve_rmw

# ── Recording ────────────────────────────────────────────────────────────────
# Record to the external SSD when it is mounted. The root filesystem has only a
# couple of GB free and recording runs at roughly 15MB/s, so a bag fills it in
# under two minutes. An explicit GOLFCART_BAG_DIR still wins, and hosts without
# the SSD (the orin) fall back to ~/rosbags.
if [ -d /mnt/external ] && [ -w /mnt/external ]; then
    export GOLFCART_BAG_DIR="${GOLFCART_BAG_DIR:-/mnt/external/rosbags}"
fi

# ── PATH ─────────────────────────────────────────────────────────────────────
# ~/.local/bin holds `just` and `play_launch`. A systemd unit gets no login shell
# and no ~/.profile, so without this the units cannot find play_launch at all.
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) export PATH="${HOME}/.local/bin:${PATH}" ;;
esac

# ── CUDA ─────────────────────────────────────────────────────────────────────
# CUDA toolchain (JetPack 6.2 / L4T R36 only) — required by cuda_ffi build.rs
if [ -r /etc/nv_tegra_release ] && grep -q '^# R36' /etc/nv_tegra_release && [ -x /usr/local/cuda/bin/nvcc ]; then
    export CUDA_HOME=/usr/local/cuda
    export CUDA_PATH="$CUDA_HOME"
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
fi

# ── Workspace overlay ────────────────────────────────────────────────────────
# Source workspace if it has been built
if [ -f "${GOLFCART_REPO_ROOT}/install/setup.bash" ]; then
    _golfcart_relax_shell_opts
    source "${GOLFCART_REPO_ROOT}/install/setup.bash"
    _golfcart_restore_shell_opts
fi

fi  # GOLFCART_ENV_RESOLVE_ONLY
