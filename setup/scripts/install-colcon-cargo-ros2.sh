#!/usr/bin/env bash
# Rust build support: colcon-cargo-ros2, plus clang/libclang for bindgen
#
# The Rust packages — golfcart_vehicle_interface, cuda_ndt_matcher,
# golfcart_aruco_detector and the gmslcam camera driver — build with
# ament_cargo, and `just build` passes --cargo-args accordingly. Without
# this extension colcon does not process them at all: it reports them as "not
# processed", every dependent fails looking for their package.sh, and the rest
# of the workspace aborts. The error names the missing package.sh rather than
# the missing extension, so it is worth installing up front.

set -e

# ---------------------------------------------------------------------------
# clang and libclang-dev
#
# bindgen loads libclang at *runtime* through libloading, so a missing
# libclang-dev is not a link error at build time: the crate that uses it panics
# mid-build with
#
#   Unable to find libclang: "couldn't find any valid shared libraries
#   matching: ['libclang.so', ...]"
#
# naming neither apt nor this package. `clang` itself comes along because the
# cc crate shells out to a C compiler for the CUDA and CAN glue.
# ---------------------------------------------------------------------------
if ! dpkg -s libclang-dev >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    echo "Installing clang and libclang-dev (bindgen needs libclang at runtime)..."
    sudo apt-get update
    sudo apt-get install -y clang libclang-dev
else
    echo "clang and libclang-dev already installed."
fi

# ---------------------------------------------------------------------------
# python3-tomli
#
# The extension reads each package's Cargo.toml with `tomllib`, which Python
# 3.10 (Ubuntu 22.04) does not have, and falls back to `tomli`, which its wheel
# does not declare. With neither, the read silently returns an empty manifest,
# so a crate that pins an interface version -- gmslcam wants
# `builtin_interfaces = "1.2.2"` -- gets a generated crate stamped 0.0.0 and
# the build fails inside cargo:
#
#   failed to select a version for the requirement `builtin_interfaces = "^1.2.2"`
#   candidate versions found which didn't match: 0.0.0
#
# naming neither Python nor tomli. Packages that ask for `*` never notice.
# ---------------------------------------------------------------------------
if ! python3 -c 'import tomllib' >/dev/null 2>&1 && ! python3 -c 'import tomli' >/dev/null 2>&1; then
    echo "Installing python3-tomli (colcon-cargo-ros2 reads Cargo.toml with it on Python < 3.11)..."
    sudo apt-get install -y python3-tomli
else
    echo "TOML reader for colcon-cargo-ros2 already present."
fi

# 0.5.1 is the floor: earlier releases do not emit the [patch.crates-io]
# entries the two Rust packages rely on, so a stale install fails the build
# while still importing cleanly. An import check alone would never notice.
REQUIRED_VERSION="0.5.1"

installed_version() {
    python3 - <<'PY' 2>/dev/null
import importlib.metadata as m
try:
    print(m.version("colcon-cargo-ros2"))
except m.PackageNotFoundError:
    pass
PY
}

version_ok() {
    local have="$1"
    [[ -n "$have" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$REQUIRED_VERSION" "$have" | sort -V | head -1)" == "$REQUIRED_VERSION" ]]
}

HAVE="$(installed_version)"

if version_ok "$HAVE"; then
    echo "colcon-cargo-ros2 ${HAVE} already installed (>= ${REQUIRED_VERSION})."
else
    if [[ -n "$HAVE" ]]; then
        echo "colcon-cargo-ros2 ${HAVE} is older than ${REQUIRED_VERSION}; upgrading..."
    else
        echo "Installing colcon-cargo-ros2 (>= ${REQUIRED_VERSION})..."
    fi
    # --no-deps is not an optimisation. The extension depends on colcon-core,
    # which depends on empy; without this pip installs its own copies into
    # ~/.local, shadowing the apt python3-colcon-* and python3-empy that ROS
    # Humble pins. It picks empy 4.x, and rosidl_adapter needs 3.x:
    #
    #   AttributeError: module 'em' has no attribute 'BUFFERED_OPT'
    #
    # which surfaces as a message-generation failure in whichever package
    # generates interfaces first, naming neither pip nor empy. Those
    # dependencies are already installed from apt on any ROS machine.
    pip3 install --user -U --no-deps "colcon-cargo-ros2>=${REQUIRED_VERSION}"

    HAVE="$(installed_version)"
    if ! version_ok "$HAVE"; then
        echo "ERROR: colcon-cargo-ros2 ${HAVE:-<none>} installed, need >= ${REQUIRED_VERSION}" >&2
        exit 1
    fi
    echo "colcon-cargo-ros2 ${HAVE} installed."
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo
    echo "WARNING: cargo not found. The Rust packages cannot build without it."
    echo "  Install the toolchain, then re-run the build:"
    echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    echo
fi
