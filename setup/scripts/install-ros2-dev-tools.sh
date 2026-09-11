#!/usr/bin/env bash
# Install ROS 2 development tools
# Converted from ansible/roles/ros2_dev_tools/tasks/main.yaml

set -e

echo "Installing ROS 2 development tools..."

# ros-dev-tools lives in the ROS apt source, which the ros2 step adds. Without
# it apt says "Unable to locate package ros-dev-tools" -- true, and no help at
# all about which earlier step was skipped. `after` in the registry orders this
# behind ros2 but never selects it, so a partial run can still land here first.
# One compgen per pattern, not one `ls` over both: `ls a b` exits non-zero when
# EITHER argument is missing, and only one of the two spellings ever exists.
if ! compgen -G '/etc/apt/sources.list.d/ros2*.sources' >/dev/null \
   && ! compgen -G '/etc/apt/sources.list.d/ros2*.list' >/dev/null; then
    echo "The ROS 2 apt source is not configured; ros-dev-tools cannot be found." >&2
    echo "Run the ros2 step first:  ./setup.sh --only ros2" >&2
    exit 1
fi

sudo apt-get update
sudo apt-get install -y \
    python3-colcon-mixin \
    python3-flake8-docstrings \
    python3-pip \
    python3-pytest-cov \
    ros-dev-tools \
    python3-flake8-blind-except \
    python3-flake8-builtins \
    python3-flake8-class-newline \
    python3-flake8-comprehensions \
    python3-flake8-deprecated \
    python3-flake8-import-order \
    python3-flake8-quotes \
    python3-pytest-repeat \
    python3-pytest-rerunfailures

# Build-time dependencies of Rust crates in this workspace that compile C from
# source. nasm is needed by turbojpeg-sys, which golfcart_aruco_detector pulls
# in: without it libjpeg-turbo's SIMD paths cannot be assembled and the build
# stops at
#
#     error: failed to run custom build command for `turbojpeg-sys v1.2.0`
#
# which names the crate rather than the missing assembler.
sudo apt-get install -y nasm

# Initialize rosdep if not already done
if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    echo "Initializing rosdep..."
    sudo rosdep init
fi

# Rust support for colcon (colcon-cargo-ros2) is a separate step:
#   just colcon-cargo-ros2
# It is part of the default `just setup` chain.

echo "ROS 2 development tools installation complete."
