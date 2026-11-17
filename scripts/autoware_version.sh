# shellcheck shell=bash
# autoware_version.sh - which Autoware release this checkout builds and runs.
#
# Sourced by scripts/env.sh and scripts/_env_guard.sh; defines and runs
# golfcart_resolve_autoware_version. Needs GOLFCART_REPO_ROOT, or derives it.
: "${GOLFCART_REPO_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# ── Autoware version ─────────────────────────────────────────────────────────
# Which Autoware release this shell builds and runs against. Several can be
# installed side by side under /opt/autoware/<ver>; colcon workspaces cannot be
# shared between underlays, so each version gets its own build and install
# directory. Resolution, first hit wins:
#
#   1. GOLFCART_AUTOWARE_VERSION already set (a one-off override, or a unit)
#   2. config/autoware-version, one line, gitignored, per host like config/host
#   3. the default in config/runtime.conf
#
# Exports:
#   GOLFCART_AUTOWARE_VERSION  e.g. 2.1.0
#   GOLFCART_AUTOWARE_PREFIX   /opt/autoware/<ver>
#   GOLFCART_AUTOWARE_SUFFIX   the apt package suffix, e.g. 2-1-0
#   GOLFCART_BUILD_DIR         <repo>/build-<ver>
#   GOLFCART_INSTALL_DIR       <repo>/install-<ver>
#   GOLFCART_DATA_PATH         <repo>/data/autoware_data-<ver> (kept if set by
#                              hand; re-derived if derived for another version)
#
# The old single build/ and install/ are never used: a host that pulls this
# runs `just build` once (sourcing the old install/ as an overlay while
# building into the new one would mix two workspaces). `just clean --all`
# removes the old directories. Only the model data falls back:
# data/autoware_data serves 1.5.0 until data/autoware_data-1.5.0 exists, since
# it holds downloaded models and TensorRT engines, not build output.
# scripts/setup_autoware_data.sh (setup step autoware-data) moves it to
# data/autoware_data-1.5.0 and leaves data/autoware_data as a symlink to it.
golfcart_resolve_autoware_version() {
    local root="${GOLFCART_REPO_ROOT}" v=""
    if [ -z "${GOLFCART_AUTOWARE_VERSION:-}" ] && [ -f "${root}/config/autoware-version" ]; then
        read -r v < "${root}/config/autoware-version" || true
        v="${v%%#*}"; v="${v//[[:space:]]/}"
        [ -n "$v" ] && GOLFCART_AUTOWARE_VERSION="$v"
    fi
    if [ -z "${GOLFCART_AUTOWARE_VERSION:-}" ] && [ -f "${root}/config/runtime.conf" ]; then
        # shellcheck source=/dev/null
        . "${root}/config/runtime.conf"
    fi
    GOLFCART_AUTOWARE_VERSION="${GOLFCART_AUTOWARE_VERSION:-1.5.0}"
    if ! [[ "${GOLFCART_AUTOWARE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "WARNING: GOLFCART_AUTOWARE_VERSION='${GOLFCART_AUTOWARE_VERSION}' is not X.Y.Z; using 1.5.0." >&2
        GOLFCART_AUTOWARE_VERSION=1.5.0
    fi
    local ver="${GOLFCART_AUTOWARE_VERSION}"
    GOLFCART_AUTOWARE_PREFIX="/opt/autoware/${ver}"
    GOLFCART_AUTOWARE_SUFFIX="${ver//./-}"
    GOLFCART_BUILD_DIR="${root}/build-${ver}"
    GOLFCART_INSTALL_DIR="${root}/install-${ver}"
    # A GOLFCART_DATA_PATH this function derived carries GOLFCART_DATA_PATH_FOR,
    # the version it was derived for, so a shell that re-resolves under another
    # version re-derives it instead of keeping the other version's models. One
    # set by hand (no _FOR) is kept whatever the version.
    if [ -n "${GOLFCART_DATA_PATH_FOR:-}" ] && [ "${GOLFCART_DATA_PATH_FOR}" != "${ver}" ]; then
        unset GOLFCART_DATA_PATH
    fi
    if [ -z "${GOLFCART_DATA_PATH:-}" ]; then
        GOLFCART_DATA_PATH="${root}/data/autoware_data-${ver}"
        if [ "${ver}" = 1.5.0 ] && [ ! -d "${GOLFCART_DATA_PATH}" ] && [ -d "${root}/data/autoware_data" ]; then
            GOLFCART_DATA_PATH="${root}/data/autoware_data"
        fi
        GOLFCART_DATA_PATH_FOR="${ver}"
        export GOLFCART_DATA_PATH_FOR
    fi
    export GOLFCART_AUTOWARE_VERSION GOLFCART_AUTOWARE_PREFIX GOLFCART_AUTOWARE_SUFFIX \
           GOLFCART_BUILD_DIR GOLFCART_INSTALL_DIR GOLFCART_DATA_PATH
}


golfcart_resolve_autoware_version
