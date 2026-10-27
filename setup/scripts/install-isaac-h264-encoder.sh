#!/usr/bin/env bash
# Install Isaac ROS's H.264 encoder and image_proc for the ZED X stereo video
# (zed_stereo_video:=true in zed.launch.xml). The orin only: the encoder drives
# the Jetson's NVENC.
#
# Needs NVIDIA's Isaac ROS apt repository (Isaac ROS 3.2 for JetPack 6). This
# script does not add it: an apt source with a signing key is a decision for
# whoever owns the machine, not something to slip in. If the packages have no
# candidate, it says so and stops.
#
# Requires: ROS 2 Humble

set -eo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

PACKAGES=(ros-humble-isaac-ros-h264-encoder ros-humble-isaac-ros-image-proc)

if [[ ! -f /opt/ros/humble/setup.bash ]]; then
    printf "${RED}Error:${NC} ROS 2 Humble not found at /opt/ros/humble\n"
    exit 1
fi

sudo apt-get update -qq

for pkg in "${PACKAGES[@]}"; do
    if ! apt-cache policy "$pkg" | grep -q 'Candidate: [0-9]'; then
        printf "${RED}Error:${NC} %s has no apt candidate.\n" "$pkg"
        printf "Add the Isaac ROS apt repository first:\n"
        printf "  https://nvidia-isaac-ros.github.io/getting_started/isaac_apt_repository.html\n"
        exit 1
    fi
done

printf "${YELLOW}→${NC} Installing %s...\n" "${PACKAGES[*]}"
sudo apt-get install -y "${PACKAGES[@]}"

if bash -c "source /opt/ros/humble/setup.bash && ros2 pkg prefix isaac_ros_h264_encoder >/dev/null 2>&1"; then
    printf "${GREEN}✓${NC} isaac_ros_h264_encoder installed\n"
else
    printf "${RED}✗${NC} isaac_ros_h264_encoder not found after installation\n"
    exit 1
fi

printf "Rebuild the ZED wrapper afterwards (just build): zed.param.yaml keeps\n"
printf "debug.disable_nitros true, so its image topics do not change.\n"
