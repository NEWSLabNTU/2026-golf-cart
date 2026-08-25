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
#   GOLFCART_HOST                  resolved role / profile name
#   GOLFCART_DDS_PROFILE           same value (kept for existing callers)
#   GOLFCART_DDS_PROFILE_SOURCE    role | env | marker | fallback | invalid-*
#   CYCLONEDDS_URI                 file:// URI of the profile XML
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

    if [ "$source_of" = "fallback" ] && [ "$quiet" != "1" ] && [ ! -f "$warn_stamp" ]; then
        echo "No config/host marker; using the loopback DDS profile."
        echo "Two-machine operation needs one. On this machine run:"
        echo "    echo master > config/host      # or: orin"
        touch "$warn_stamp" 2>/dev/null || true
    fi

    GOLFCART_HOST="$profile"
    GOLFCART_DDS_PROFILE="$profile"
    GOLFCART_DDS_PROFILE_SOURCE="$source_of"
    CYCLONEDDS_URI="file://${xml}"
    export GOLFCART_HOST GOLFCART_DDS_PROFILE GOLFCART_DDS_PROFILE_SOURCE CYCLONEDDS_URI
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

    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

    # Unset ROS_LOCALHOST_ONLY if present
    if [[ -v ROS_LOCALHOST_ONLY ]]; then
        echo 'WARNING: ROS_LOCALHOST_ONLY variable is present. Unsetting it.'
        unset ROS_LOCALHOST_ONLY
    fi

    # Source ROS 2 Humble
    _golfcart_relax_shell_opts
    source /opt/ros/humble/setup.bash
    _golfcart_restore_shell_opts
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
    rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)
    if [ "${rmem}" -lt 16777216 ]; then
        problems="${problems}
  - net.core.rmem_max is ${rmem}; the DDS profile requires at least 16777216"
    fi
    # Only when the resolved profile actually enables shared memory. With SHM
    # on and RouDi absent, participant creation HANGS rather than failing, so
    # nothing downstream ever prints an error - but SHM is off by default here
    # (iceoryx runs out of publisher ports on a stack this size), and demanding
    # RouDi regardless would block every launch for an unused transport.
    _gc_profile="${CYCLONEDDS_URI#file://}"
    if [ -n "${_gc_profile}" ] && [ -f "${_gc_profile}" ] \
       && grep -q '<Enable>true</Enable>' "${_gc_profile}" 2>/dev/null \
       && ! { [ -S /tmp/roudi ] && pgrep -x iox-roudi >/dev/null 2>&1; }; then
        problems="${problems}
  - iox-roudi is not running, and the DDS profiles enable <SharedMemory>.
    Start it with:  systemctl --user start iox-roudi.service"
    fi
    unset _gc_profile
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
# IMU_SOURCE / CAMERA_MODEL reach the sensor kit only as environment variables:
# the launch-argument path is swallowed by two installed Autoware files that
# forward a fixed set of arguments. See config/sensors.conf.
if [ -f "${GOLFCART_REPO_ROOT}/config/sensors.conf" ]; then
    # shellcheck source=/dev/null
    . "${GOLFCART_REPO_ROOT}/config/sensors.conf"
    export IMU_SOURCE CAMERA_MODEL
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

# The DDS profiles are CycloneDDS XML, so the RMW has to match them. Set
# unconditionally: the branch above only exports it when Autoware is missing, and
# a unit that inherits a different RMW would silently ignore CYCLONEDDS_URI.
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp

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
