#!/usr/bin/env bash

# Script to create NetworkManager profile for WiFi AP
# Created for Golf Cart project

set -eo pipefail  # a failed sed must not install an empty profile

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONNECTIONS_DIR="/etc/NetworkManager/system-connections"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Get MAC address of wlan0 and extract last 6 characters
if [ -e /sys/class/net/wlan0/address ]; then
  MAC_ADDR=$(cat /sys/class/net/wlan0/address | tr -d ':' | tail -c 7)
else
  echo "Warning: Could not get MAC address of wlan0, using default identifier"
  MAC_ADDR="UNKN"
fi

WIFI_AP_NAME="GolfCart-AP-${MAC_ADDR}"
echo "Setting up WiFi AP NetworkManager profile..."

# Define template directories
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
mkdir -p "${TEMPLATE_DIR}"

# Create WiFi AP connection template
WIFI_AP_TEMPLATE="${TEMPLATE_DIR}/golfcart-ap.nmconnection.in"
if [ ! -f "${WIFI_AP_TEMPLATE}" ]; then
  echo "WiFi AP template not found at ${WIFI_AP_TEMPLATE}. Please create it first."
  exit 1
fi

# Generate connection file from template
echo "Generating NetworkManager profile from template..."

# Replace placeholders in WiFi AP template
# Streamed straight into place: a fixed /tmp name is owned by whoever ran
# this first, and fs.protected_regular stops even root from rewriting it.
sed "s/@WIFI_AP_NAME@/${WIFI_AP_NAME}/g" "${WIFI_AP_TEMPLATE}" \
  | install -m 600 /dev/stdin "${CONNECTIONS_DIR}/golfcart-ap.nmconnection"

# Reload NetworkManager connections
echo "Reloading NetworkManager connections..."
nmcli connection reload

echo "Done. WiFi AP connection '${WIFI_AP_NAME}' is now available."
echo "You can activate it with:"
echo "  sudo nmcli connection up \"${WIFI_AP_NAME}\""
