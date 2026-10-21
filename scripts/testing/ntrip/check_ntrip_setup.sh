#!/bin/bash
# NTRIP/RTK setup verification for the u-blox ZED-F9P.
#
# Checks that the pieces `just launch use_ntrip:=true` needs are in place:
# the source-built driver (NEWSLabNTU/ublox submodule), the apt NTRIP client,
# the sensor kit's configuration and its account file, the device, the caster.
# Nothing here talks to the receiver; run it before a field test, not during.

set -e

cd "$(dirname "$0")/../../.."

echo "========================================="
echo "Golf Cart NTRIP/RTK Setup Verification"
echo "========================================="
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -n "Sourcing environment... "
# shellcheck source=/dev/null
source scripts/env.sh
echo -e "${GREEN}OK${NC}"

# 1. Driver from src/sensor_component/external/ublox, NTRIP client from apt
echo ""
echo "1. Checking driver and NTRIP client packages..."
for pkg in ublox_gps ntrip_client; do
    if ros2 pkg list | grep -q "^$pkg$"; then
        echo -e "   ${GREEN}✓${NC} $pkg found at $(ros2 pkg prefix "$pkg")"
    else
        echo -e "   ${RED}✗${NC} $pkg NOT found"
        echo "   ublox_gps: just checkout && just build"
        echo "   ntrip_client: ./setup.sh --only ros-deps (ros-humble-ntrip-client)"
        exit 1
    fi
done
if dpkg -l ros-humble-ublox-gps 2>/dev/null | grep -q '^ii'; then
    echo -e "   ${YELLOW}⚠${NC} apt ros-humble-ublox-gps is still installed. The workspace build"
    echo "     takes precedence, but the apt driver has no RTCM input at all; remove"
    echo "     it so a missing workspace build cannot silently fall back to it:"
    echo "     sudo apt remove ros-humble-ublox-gps ros-humble-ublox-msgs ros-humble-ublox-serialization"
fi

# 2. Message packages the two nodes exchange
echo ""
echo "2. Checking message packages..."
for pkg in mavros_msgs nmea_msgs ublox_msgs; do
    if ros2 pkg list | grep -q "^$pkg$"; then
        echo -e "   ${GREEN}✓${NC} $pkg found"
    else
        echo -e "   ${RED}✗${NC} $pkg NOT found"
        echo "   ./setup.sh --only ros-deps"
        exit 1
    fi
done

# 3. Sensor kit configuration
echo ""
echo "3. Checking golfcart_sensor_kit_launch configuration..."
if ros2 pkg list | grep -q "^golfcart_sensor_kit_launch$"; then
    echo -e "   ${GREEN}✓${NC} golfcart_sensor_kit_launch package found"
    KIT_SHARE=$(ros2 pkg prefix golfcart_sensor_kit_launch)/share/golfcart_sensor_kit_launch
    for f in launch/gnss.launch.xml config/ublox_f9p.yaml; do
        if [ -e "$KIT_SHARE/$f" ]; then
            echo -e "   ${GREEN}✓${NC} $f"
        else
            echo -e "   ${RED}✗${NC} $f NOT found (expected $KIT_SHARE/$f)"
            exit 1
        fi
    done
else
    echo -e "   ${RED}✗${NC} golfcart_sensor_kit_launch NOT found: just build"
    exit 1
fi

# 4. The account. The kit's ntrip_client.param.yaml is gitignored (the repo is
# public) and made from the .example beside it. Checked in the source tree, and
# in the install share, which only symlinks it after a rebuild.
echo ""
echo "4. Checking NTRIP account file..."
NTRIP_PARAM_FILE=src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/ntrip_client.param.yaml
if [ -f "$NTRIP_PARAM_FILE" ]; then
    echo -e "   ${GREEN}✓${NC} $NTRIP_PARAM_FILE"
    if [ ! -e "$KIT_SHARE/config/ntrip_client.param.yaml" ]; then
        echo -e "   ${RED}✗${NC} not installed yet: just build"
        exit 1
    fi
    if grep -qE 'CHANGE_ME|^\s*(username|password):\s*""\s*$' "$NTRIP_PARAM_FILE"; then
        echo -e "   ${RED}✗${NC} username or password is still a placeholder"
        exit 1
    fi
else
    echo -e "   ${RED}✗${NC} $NTRIP_PARAM_FILE is missing."
    echo "     cp it from ntrip_client.param.yaml.example beside it, fill in the account"
    echo "     (config/ntrip_credentials.txt on a vehicle that has it), then just build."
    exit 1
fi

# 5. Hardware (optional, does not fail)
echo ""
echo "5. Checking hardware..."
if [ -e /dev/ublox-gps ]; then
    echo -e "   ${GREEN}✓${NC} u-blox receiver at /dev/ublox-gps -> $(readlink -f /dev/ublox-gps)"
elif ls /dev/ttyACM* &>/dev/null; then
    echo -e "   ${YELLOW}⚠${NC} /dev/ttyACM* present but no /dev/ublox-gps symlink"
    echo "     udev rule missing: ./setup.sh --only ublox-udev"
else
    echo -e "   ${YELLOW}⚠${NC} No u-blox receiver detected (fine on the host without it)"
fi

# 6. Caster. e-GNSS drops ICMP, so TCP, not ping.
echo ""
echo "6. Checking caster reachability..."
HOST=$(sed -nE 's/^\s*host:\s*"?([^"#[:space:]]+)"?.*/\1/p' "$NTRIP_PARAM_FILE" | head -1)
PORT=$(sed -nE 's/^\s*port:\s*([0-9]+).*/\1/p' "$NTRIP_PARAM_FILE" | head -1)
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${HOST}/${PORT}" 2>/dev/null; then
    echo -e "   ${GREEN}✓${NC} ${HOST}:${PORT} reachable"
else
    echo -e "   ${YELLOW}⚠${NC} ${HOST}:${PORT} not reachable (offline, firewalled, or no uplink)"
fi

echo ""
echo "========================================="
echo "Setup verification complete"
echo "========================================="
echo ""
echo "Next:"
echo "  just launch use_ntrip:=true"
echo "  ros2 topic hz /sensing/gnss/ntrip/rtcm       # corrections arriving (bursty, ~1 Hz epochs)"
echo "  ros2 topic echo /sensing/gnss/ublox/rxmrtcm  # flags: 0 means the receiver accepted them"
echo "  ros2 topic echo /sensing/gnss/ublox/nav_sat_fix --once"
echo ""
echo "Bring-up history and the GGA-uplink caveat:"
echo "  SETUP_LOG.md in NEWSLabNTU/ublox_f9p_ws (private; retired 2026-10-21)"
