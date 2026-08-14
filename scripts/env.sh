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
#   1. an explicitly exported GOLFCART_DDS_PROFILE
#   2. the `.golfcart-host` marker file in the repo root (one word: master|orin)
#   3. loopback
#
# The chosen name must have a matching config/cyclonedds/<name>.xml. A name
# without one falls back to loopback *loudly*: silently running the wrong
# profile is the exact failure this machinery exists to remove.
#
# Sets (and exports):
#   GOLFCART_HOST                  resolved role / profile name
#   GOLFCART_DDS_PROFILE           same value (kept for existing callers)
#   GOLFCART_DDS_PROFILE_SOURCE    env | marker | fallback | invalid-env | invalid-marker
#   CYCLONEDDS_URI                 file:// URI of the profile XML
golfcart_resolve_dds_profile() {
    local root="${GOLFCART_REPO_ROOT}"
    local marker="${root}/.golfcart-host"
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

    # Validate: a safe bare token with a matching profile file.
    local xml="${root}/config/cyclonedds/${profile}.xml"
    if ! printf '%s' "$profile" | grep -Eq '^[A-Za-z0-9_-]+$' || [ ! -f "$xml" ]; then
        if [ "$quiet" != "1" ]; then
            echo "============================================================" >&2
            echo "ERROR: unknown DDS profile '${profile}'" >&2
            case "$source_of" in
                marker) echo "  named by ${marker}" >&2 ;;
                env)    echo "  named by \$GOLFCART_DDS_PROFILE" >&2 ;;
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
        echo "No .golfcart-host marker; using the loopback DDS profile."
        echo "Two-machine operation needs one. On this machine run:"
        echo "    echo master > .golfcart-host      # or: orin"
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

    # CycloneDDS Configuration - Check sysctl (warn once)
    # Check if values are sufficient (not exact equality)
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    ipfrag_time=$(sysctl -n net.ipv4.ipfrag_time 2>/dev/null || echo "999")
    ipfrag_thresh=$(sysctl -n net.ipv4.ipfrag_high_thresh 2>/dev/null || echo "0")

    if [ "$rmem_max" -lt 2147483647 ] || \
       [ "$ipfrag_time" -gt 3 ] || \
       [ "$ipfrag_thresh" -lt 134217728 ]; then
        if [ ! -f "${GOLFCART_REPO_ROOT}/.envrc.sysctl-warned" ]; then
            echo "┌────────────────────────────────────────────────────────────┐"
            echo "│ WARNING: CycloneDDS kernel buffers not configured         │"
            echo "│ You may experience packet loss with high-bandwidth data   │"
            echo "│ To fix: cd setup && just cyclonedds-sysctl                │"
            echo "└────────────────────────────────────────────────────────────┘"
            touch "${GOLFCART_REPO_ROOT}/.envrc.sysctl-warned" 2>/dev/null || true
        fi
    fi

    # Source ROS 2 Humble
    _golfcart_relax_shell_opts
    source /opt/ros/humble/setup.bash
    _golfcart_restore_shell_opts
fi

# ── CycloneDDS profile ───────────────────────────────────────────────────────
# GOLFCART_DDS_PROFILE selects config/cyclonedds/<profile>.xml:
#   loopback  single-machine (default; identical to the old root cyclonedds.xml)
#   master    cart AGX Orin  on the GolfCart AP (192.168.13.1)
#   orin      slave Jetson   on the GolfCart AP (192.168.13.2)
# The profile normally comes from the gitignored `.golfcart-host` marker; see
# golfcart_resolve_dds_profile above. just launch-master / launch-orin set the
# URI themselves, so this only affects plain shells and `just launch`.
#
# No `ros2 daemon stop` here on purpose: a daemon's DDS context is fixed when it
# starts, so this file cannot repair a running one, and stopping it would be a
# surprising side effect of opening a shell. `just doctor` reports it instead.
golfcart_resolve_dds_profile

# ── Recording ────────────────────────────────────────────────────────────────
# Record to the external SSD when it is mounted. The root filesystem has only a
# couple of GB free and recording runs at roughly 15MB/s, so a bag fills it in
# under two minutes. An explicit GOLFCART_BAG_DIR still wins, and hosts without
# the SSD (the orin) fall back to ~/rosbags.
if [ -d /mnt/external ] && [ -w /mnt/external ]; then
    export GOLFCART_BAG_DIR="${GOLFCART_BAG_DIR:-/mnt/external/rosbags}"
fi

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
