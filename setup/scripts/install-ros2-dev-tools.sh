#!/usr/bin/env bash
# Install ROS 2 development tools
# Converted from ansible/roles/ros2_dev_tools/tasks/main.yaml

set -e

echo "Installing ROS 2 development tools..."

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

# Initialize rosdep if not already done
if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    echo "Initializing rosdep..."
    sudo rosdep init
fi

# Rust support for colcon.
#
# Two packages build with ament_cargo — golfcart_vehicle_interface and
# cuda_ndt_matcher — and `just build` passes --cargo-args accordingly. Without
# this extension colcon does not process them at all: it reports them as "not
# processed", every dependent fails looking for their package.sh, and the rest
# of the workspace aborts. The error names the missing package.sh rather than
# the missing extension, so it is worth installing up front.
if python3 -c 'import colcon_cargo_ros2' >/dev/null 2>&1; then
    echo "colcon-cargo-ros2 already installed."
else
    echo "Installing colcon-cargo-ros2..."
    # Note: this pins setuptools below 80, so it may downgrade an existing
    # newer setuptools in the user environment.
    python3 -m pip install --user colcon-cargo-ros2
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo
    echo "WARNING: cargo not found. The Rust packages cannot build without it."
    echo "  Install the toolchain, then re-run the build:"
    echo "    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    echo
fi

echo "ROS 2 development tools installation complete."
