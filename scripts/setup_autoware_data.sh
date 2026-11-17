#!/usr/bin/env bash
# Build a WRITABLE view of the selected Autoware's model data, in
# $GOLFCART_DATA_PATH (data/autoware_data-<ver>).
#
#   scripts/setup_autoware_data.sh [downloader args...]
#   GOLFCART_AUTOWARE_VERSION=2.1.0 scripts/setup_autoware_data.sh --only lidar_centerpoint
#
# Why this exists
# ---------------
# Autoware's launch files default `data_path` to $HOME/autoware_data, which is
# what its online documentation tells you to create. This deployment installs
# Autoware from Debian packages instead, so the packaged data (when installed
# at all) lives under /opt/autoware/<version>/data — owned by root, mode 0755.
#
# That breaks TensorRT. Every engine path is a parameter derived from the model
# directory, e.g.
#
#     encoder_engine_path: "$(var model_path)/pts_voxel_encoder_$(var model_name).engine"
#     model_path         = $(var data_path)/$(var node_name)
#
# so a node compiles its .onnx and then tries to write the .engine NEXT TO IT.
# In a root-owned directory that write fails:
#
#     [E] [TRT] Fail to open engine file
#     component_node failed: ... Failed to setup TensorRT engine
#
# and because the engine is written at the END of the build, the work is
# discarded and repeated on every launch.
#
# One directory per Autoware version
# ----------------------------------
# The model layout changed between versions (1.5.0's
# lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.onnx is 2.1.0's
# lidar_centerpoint/tiny/pts_backbone_neck_head.onnx), and the downloader
# refuses a directory stamped for another version. So each version has its own,
# data/autoware_data-<ver>, which scripts/autoware_version.sh exports as
# GOLFCART_DATA_PATH and scripts/launch/args.py passes as data_path:=.
#
# Migration: a checkout from before this kept 1.5.0's models in
# data/autoware_data. When data/autoware_data-1.5.0 does not exist and
# data/autoware_data is a real directory, it is MOVED there (a rename: the
# engines stay, nothing is deleted) and data/autoware_data is left as a
# relative symlink to it, so `main`'s launch default ./data/autoware_data keeps
# working.
#
# What this does
# --------------
# Two ways to fill the tree, chosen by what is installed for the version:
#
# 1. autoware-localrepo 1.5.0-3 and later ship autoware-download-models-<suffix>
#    (/opt/autoware/<ver>/bin/autoware-download-models), which fetches the
#    models as this user, verifies each one against its sha256, and drops an
#    engine whose .onnx it replaces. Arguments are passed through, so
#        ./scripts/setup_autoware_data.sh --only lidar_centerpoint
#    fetches one model, and --list shows the rest. If the optional
#    autoware-data debs are installed (offline machines), it links from
#    /opt/autoware/<ver>/data instead of downloading.
#
# 2. Without a downloader but with /opt/autoware/<ver>/data (installs before
#    1.5.0-3), the script mirrors the directory tree and SYMLINKS every file.
#    Reads resolve to the packaged files, and newly written .engine files land
#    in this writable tree. Setting AUTOWARE_DATA_SRC forces this mode.
#
# Only the selected version's downloader and data are used: with several
# versions installed, another version's models would be the wrong ones.
#
# Idempotent: safe to re-run after an Autoware upgrade, which is also when you
# must, because engines are tied to the TensorRT version and the GPU.
set -euo pipefail

GOLFCART_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export GOLFCART_REPO_ROOT
# shellcheck source=scripts/autoware_version.sh
. "${GOLFCART_REPO_ROOT}/scripts/autoware_version.sh"

# ── Migration of the pre-version data/autoware_data ──────────────────────────
migrate_legacy_data() {
    local data="${GOLFCART_REPO_ROOT}/data"
    local legacy="${data}/autoware_data" target="${data}/autoware_data-1.5.0"
    [ -L "${legacy}" ] && return 0          # already migrated, or a user's link
    [ -d "${legacy}" ] || return 0          # nothing to migrate
    if [ -e "${target}" ]; then
        echo "note: both data/autoware_data and data/autoware_data-1.5.0 exist;" >&2
        echo "      leaving both alone. 1.5.0 uses data/autoware_data-1.5.0." >&2
        return 0
    fi
    local stamp="${legacy}/.autoware-version" have=""
    [ -f "${stamp}" ] && read -r have < "${stamp}"
    if [ -n "${have}" ] && [ "${have}" != 1.5.0 ]; then
        echo "note: data/autoware_data is stamped for Autoware ${have}, not 1.5.0; not moving it." >&2
        return 0
    fi
    echo "migrating data/autoware_data -> data/autoware_data-1.5.0 (rename; models and engines kept)"
    mv -T -- "${legacy}" "${target}"
    ln -s autoware_data-1.5.0 "${legacy}"
    # Re-derive GOLFCART_DATA_PATH, which may have resolved to the old name.
    if [ -n "${GOLFCART_DATA_PATH_FOR:-}" ]; then
        unset GOLFCART_DATA_PATH
        golfcart_resolve_autoware_version
    fi
}
migrate_legacy_data

FARM="${GOLFCART_DATA_PATH}"
VER="${GOLFCART_AUTOWARE_VERSION}"
PREFIX="${GOLFCART_AUTOWARE_PREFIX}"

report_engines() {
    local engines
    engines=$(find "${FARM}/" -name '*.engine' -type f 2>/dev/null | wc -l)
    echo "engines already built: ${engines}"
    if [ "${engines}" -eq 0 ]; then
        echo
        echo "No TensorRT engines yet. Build them before the first drive:"
        echo "    just build-engines"
        echo "Otherwise the first launch compiles them inline — minutes per model,"
        echo "with perception unavailable until it finishes."
    fi
}

# Mode 1: the per-user downloader of THIS version, unless AUTOWARE_DATA_SRC asks
# for mode 2.
DOWNLOADER=""
if [ -z "${AUTOWARE_DATA_SRC:-}" ]; then
    for candidate in "${PREFIX}/bin/autoware-download-models" \
                     "/usr/bin/autoware-download-models-${GOLFCART_AUTOWARE_SUFFIX}"; do
        if [ -x "${candidate}" ]; then DOWNLOADER="${candidate}"; break; fi
    done
fi

if [ -n "${DOWNLOADER}" ]; then
    args=(--dir "${FARM}")
    if [ -d "${PREFIX}/data" ]; then
        # The optional autoware-data debs are installed: link, no network.
        args+=(--link-from "${PREFIX}/data")
    fi
    echo "autoware:   ${VER}"
    echo "downloader: ${DOWNLOADER}"
    echo "farm:       ${FARM}"
    # The farm is golf-cart's data_path (args.py passes it), so the
    # downloader's closing "launch with data_path:=" hint needs no action.
    "${DOWNLOADER}" "${args[@]}" "$@"
    report_engines
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "ERROR: arguments need autoware-download-models-${GOLFCART_AUTOWARE_SUFFIX} (autoware-localrepo 1.5.0-3 or later)" >&2
    exit 2
fi

# Mode 2: where the packaged models live. Override for a non-default install.
SRC="${AUTOWARE_DATA_SRC:-${PREFIX}/data}"
if [ ! -d "${SRC}" ]; then
    echo "ERROR: no Autoware ${VER} models found." >&2
    echo "  Looked for ${PREFIX}/bin/autoware-download-models (1.5.0-3 and later)" >&2
    echo "  and ${PREFIX}/data (earlier); set AUTOWARE_DATA_SRC to override." >&2
    echo "  Is Autoware ${VER} installed?  ./setup.sh --only autoware-debian" >&2
    exit 1
fi

echo "autoware: ${VER}"
echo "source:   ${SRC}"
echo "farm:     ${FARM}"

mkdir -p "${FARM}"

# Directories first, then a symlink per file. `-P` keeps paths relative to SRC
# so the tree is mirrored rather than nested.
(cd "${SRC}" && find . -mindepth 1 -type d -printf '%P\n') | while IFS= read -r d; do
    mkdir -p "${FARM}/${d}"
done

linked=0
skipped=0
while IFS= read -r f; do
    target="${FARM}/${f}"
    # Never clobber a real file — that is an engine this farm produced, and
    # rebuilding it costs minutes.
    if [ -e "${target}" ] && [ ! -L "${target}" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    ln -sfn "${SRC}/${f}" "${target}"
    linked=$((linked + 1))
done < <(cd "${SRC}" && find . -type f -printf '%P\n')

echo "linked ${linked} file(s), kept ${skipped} local file(s)"
report_engines
