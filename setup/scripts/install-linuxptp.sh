#!/usr/bin/env bash
# Install linuxptp + ptp4l/phc2sys systemd units + ptp4l.conf. The master only.
#
# The files are setup/host/master/etc/{linuxptp/ptp4l.conf,
# systemd/system/ptp4l.service, systemd/system/phc2sys.service}, installed by
# setup/golfcart_setup/hostcfg.py (manifest step: linuxptp).
#
# Files (interface hardcoded to enP5p5s0 — Falcon Seyond LiDAR iface on the
# Jetson AGX Orin Dev Kit). Adjust unit ExecStart `-i` flag if running on
# a host with a different PTP-capable interface.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTCFG="$(cd "$SCRIPT_DIR/.." && pwd)/golfcart_setup/hostcfg.py"
SKIP_INSTALL=${SKIP_INSTALL:-0}

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

if [ "$SKIP_INSTALL" -eq 0 ]; then
    printf "${YELLOW}→${NC} Installing linuxptp apt package...\n"
    sudo apt-get update
    sudo apt-get install -y linuxptp
fi

printf "${YELLOW}→${NC} Installing ptp4l.conf + ptp4l/phc2sys units from setup/host/master...\n"
# --role master: these are the master's files whatever config/host says; the
# step itself is master-only (Step.roles / Requires.role).
python3 "$HOSTCFG" install --role master --step linuxptp

printf "${YELLOW}→${NC} Enabling + starting ptp4l, phc2sys...\n"
sudo systemctl enable --now ptp4l.service phc2sys.service

printf "${GREEN}✓${NC} linuxptp installed\n"
printf "${YELLOW}Note:${NC} verify with 'systemctl status ptp4l phc2sys' and 'journalctl -u ptp4l -f'\n"
