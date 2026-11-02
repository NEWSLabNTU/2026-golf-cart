#!/usr/bin/env bash
# Build a WRITABLE view of Autoware's model data at data/autoware_data.
#
# Why this exists
# ---------------
# Autoware's launch files default `data_path` to $HOME/autoware_data, which is
# what its online documentation tells you to create. This deployment installs
# Autoware from Debian packages instead, so the same data lives under
# /opt/autoware/<version>/data — owned by root and mode 0755.
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
# discarded and repeated on every launch. Measured on the AGX Orin: 8 of the
# perception stack's composable nodes failed this way, and zero engines were
# ever cached.
#
# What this does
# --------------
# Two ways to fill the tree, chosen by what is installed:
#
# 1. autoware-localrepo 1.5.0-3 and later ship no models in the default
#    install. They ship autoware-download-models-<ver> instead, which fetches
#    the models as this user, verifies each one against its sha256, and drops
#    an engine whose .onnx it replaces. This script runs it with
#    --dir data/autoware_data. Arguments are passed through, so
#        ./scripts/setup_autoware_data.sh --only lidar_centerpoint
#    fetches one model, and --list shows the rest. If the optional
#    autoware-data debs are installed (offline machines), it links from
#    /opt/autoware/<ver>/data instead of downloading.
#
# 2. Older installs (1.5.0-2 and earlier) have the models under
#    /opt/autoware/<ver>/data and no downloader. The script mirrors the
#    directory tree and SYMLINKS every file, rather than copying. The models
#    are 2.0 GB; the farm is under a megabyte. Reads resolve to the packaged
#    files, and newly written .engine files land in this writable tree.
#    Setting AUTOWARE_DATA_SRC forces this mode.
#
# Idempotent: safe to re-run after an Autoware upgrade, which is also when you
# must, because engines are tied to the TensorRT version and the GPU. After
# the upgrade to 1.5.0-3 the old symlinks dangle; the downloader replaces them
# with real files and deletes the engines built from them, since a dangling
# link cannot prove the engine matches the new model.
set -euo pipefail

GOLFCART_REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FARM="${GOLFCART_DATA_PATH:-${GOLFCART_REPO_ROOT}/data/autoware_data}"

report_engines() {
    local engines
    engines=$(find "${FARM}" -name '*.engine' -type f 2>/dev/null | wc -l)
    echo "engines already built: ${engines}"
    if [ "${engines}" -eq 0 ]; then
        echo
        echo "No TensorRT engines yet. Build them before the first drive:"
        echo "    just build-engines"
        echo "Otherwise the first launch compiles them inline — minutes per model,"
        echo "with perception unavailable until it finishes."
    fi
}

# Mode 1: the per-user downloader, unless AUTOWARE_DATA_SRC asks for mode 2.
DOWNLOADER=""
if [ -z "${AUTOWARE_DATA_SRC:-}" ]; then
    for candidate in /opt/autoware/*/bin/autoware-download-models; do
        [ -x "${candidate}" ] && DOWNLOADER="${candidate}"
    done
fi

if [ -n "${DOWNLOADER}" ]; then
    # /opt/autoware/<ver>/bin/autoware-download-models -> /opt/autoware/<ver>
    prefix=$(dirname -- "$(dirname -- "${DOWNLOADER}")")
    args=(--dir "${FARM}")
    if [ -d "${prefix}/data" ]; then
        # The optional autoware-data debs are installed: link, no network.
        args+=(--link-from "${prefix}/data")
    fi
    echo "downloader: ${DOWNLOADER}"
    echo "farm:       ${FARM}"
    # The farm is already golf-cart's data_path (golfcart.launch.yaml), so the
    # downloader's closing "launch with data_path:=" hint needs no action.
    "${DOWNLOADER}" "${args[@]}" "$@"
    report_engines
    exit 0
fi

if [ "$#" -gt 0 ]; then
    echo "ERROR: arguments need autoware-download-models (autoware-localrepo 1.5.0-3 or later)" >&2
    exit 2
fi

# Where the packaged models live. Override for a non-default Autoware install.
SRC="${AUTOWARE_DATA_SRC:-}"
if [ -z "${SRC}" ]; then
    # Prefer whatever /opt/autoware exposes; there is normally one version.
    for candidate in /opt/autoware/*/data; do
        [ -d "${candidate}" ] && SRC="${candidate}"
    done
fi

if [ -z "${SRC}" ] || [ ! -d "${SRC}" ]; then
    echo "ERROR: no Autoware models found." >&2
    echo "  Looked for /opt/autoware/*/bin/autoware-download-models (1.5.0-3 and later)" >&2
    echo "  and /opt/autoware/*/data (earlier); set AUTOWARE_DATA_SRC to override." >&2
    exit 1
fi

echo "source: ${SRC}"
echo "farm:   ${FARM}"

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
