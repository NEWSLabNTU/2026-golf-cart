#!/usr/bin/env bash
# Install linuxptp + ptp4l/phc2sys systemd units + ptp4l.conf
#
# Files (interface hardcoded to enP5p5s0 — Falcon Seyond LiDAR iface on the
# Jetson AGX Orin Dev Kit). Adjust unit ExecStart `-i` flag if running on
# a host with a different PTP-capable interface.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="$(cd "$SCRIPT_DIR/../files/linuxptp" && pwd)"
SKIP_INSTALL=${SKIP_INSTALL:-0}

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ "$SKIP_INSTALL" -eq 0 ]; then
    printf "${YELLOW}→${NC} Installing linuxptp apt package...\n"
    sudo apt-get update
    sudo apt-get install -y linuxptp
fi

printf "${YELLOW}→${NC} Installing /etc/linuxptp/ptp4l.conf...\n"
sudo install -d -m 0755 /etc/linuxptp
sudo install -m 0644 "$FILES_DIR/ptp4l.conf" /etc/linuxptp/ptp4l.conf

printf "${YELLOW}→${NC} Installing systemd units (ptp4l, phc2sys)...\n"
sudo install -m 0644 "$FILES_DIR/ptp4l.service"   /etc/systemd/system/ptp4l.service
sudo install -m 0644 "$FILES_DIR/phc2sys.service" /etc/systemd/system/phc2sys.service

printf "${YELLOW}→${NC} Reloading systemd...\n"
sudo systemctl daemon-reload

printf "${YELLOW}→${NC} Enabling + starting ptp4l, phc2sys...\n"
sudo systemctl enable --now ptp4l.service phc2sys.service

printf "${GREEN}✓${NC} linuxptp installed\n"
printf "${YELLOW}Note:${NC} verify with 'systemctl status ptp4l phc2sys' and 'journalctl -u ptp4l -f'\n"
