#!/usr/bin/env bash
# Install ros-humble-gscam (GStreamer camera bridge for ROS 2)
# Used for any GStreamer-compatible camera source (USB, CSI, RTSP, etc.)
#
# Requires: ROS 2 Humble

set -eo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check ROS 2 is installed
if [[ ! -f /opt/ros/humble/setup.bash ]]; then
    printf "${RED}Error:${NC} ROS 2 Humble not found at /opt/ros/humble\n"
    printf "Install ROS 2 first: ./setup.sh ros2\n"
    exit 1
fi

printf "${YELLOW}→${NC} Installing gscam (GStreamer camera bridge)...\n"

sudo apt-get update -qq
sudo apt-get install -y \
    ros-humble-gscam \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly

# Verify installation
printf "${YELLOW}→${NC} Verifying installation...\n"

if bash -c "source /opt/ros/humble/setup.bash && ros2 pkg list 2>/dev/null | grep -q gscam"; then
    printf "${GREEN}✓${NC} gscam installed\n"
else
    printf "${RED}✗${NC} gscam not found after installation\n"
    exit 1
fi

printf "${GREEN}✓${NC} gscam installation complete\n"
