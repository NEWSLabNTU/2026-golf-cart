#!/usr/bin/env bash
# Install camera driver and tools for TIER IV C1 cameras
# The GMSL2-USB 3.0 Conversion Kit presents the C1 as a standard UVC device,
# so the standard usb_cam ROS 2 driver is used (v4l2_camera is unavailable
# in the Humble arm64 apt repo).
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

printf "${YELLOW}→${NC} Installing TIER IV C1 camera driver (usb_cam + v4l-utils)...\n"

sudo apt-get update -qq
sudo apt-get install -y \
    ros-humble-usb-cam \
    v4l-utils

# Verify installation
printf "${YELLOW}→${NC} Verifying installation...\n"

if bash -c "source /opt/ros/humble/setup.bash && ros2 pkg list 2>/dev/null | grep -q usb_cam"; then
    printf "${GREEN}✓${NC} usb_cam installed\n"
else
    printf "${RED}✗${NC} usb_cam not found after installation\n"
    exit 1
fi

# Install udev rules template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_SRC="${SCRIPT_DIR}/../files/99-tier4-camera.rules"

if [[ -f "$RULES_SRC" ]]; then
    printf "${YELLOW}→${NC} Installing udev rules template...\n"
    sudo cp "$RULES_SRC" /etc/udev/rules.d/99-tier4-camera.rules
    sudo chmod 644 /etc/udev/rules.d/99-tier4-camera.rules
    sudo udevadm control --reload-rules
    printf "${GREEN}✓${NC} udev rules template installed\n"
else
    printf "${YELLOW}⚠${NC} udev rules template not found at ${RULES_SRC}, skipping\n"
fi

printf "${GREEN}✓${NC} TIER IV C1 camera driver installation complete\n"
printf "\n"
printf "Next steps (when cameras are physically connected):\n"
printf "  1. Plug in GMSL2-USB converters and run: v4l2-ctl --list-devices\n"
printf "  2. Identify USB port paths: udevadm info -a /dev/video0 | grep KERNELS\n"
printf "  3. Edit /etc/udev/rules.d/99-tier4-camera.rules with actual port paths\n"
printf "  4. Reload: sudo udevadm control --reload-rules && sudo udevadm trigger\n"
printf "  5. Verify: ls -la /dev/tier4-cam-*\n"
printf "\n"
printf "See setup/files/99-tier4-camera.rules for detailed instructions.\n"
