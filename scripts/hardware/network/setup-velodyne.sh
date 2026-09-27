#!/usr/bin/env bash

# Script to create NetworkManager profile for static IP connection (e.g., LiDAR)
# Created for Golf Cart project

set -e

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
CONNECTIONS_DIR="/etc/NetworkManager/system-connections"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Setting up static IP NetworkManager profile..."

# Define template directories
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
mkdir -p "${TEMPLATE_DIR}"

# Check for Velodyne LiDAR connection template
VELODYNE_TEMPLATE="${TEMPLATE_DIR}/velodyne.nmconnection.in"
if [ ! -f "${VELODYNE_TEMPLATE}" ]; then
  echo "Velodyne template not found at ${VELODYNE_TEMPLATE}. Please create it first."
  exit 1
fi

# Generate connection file from template
echo "Generating NetworkManager profile from template..."
# Streamed straight into place: a fixed /tmp name is owned by whoever ran
# this first, and fs.protected_regular stops even root from rewriting it.
echo "Installing NetworkManager profile..."
install -m 600 /dev/stdin "${CONNECTIONS_DIR}/velodyne.nmconnection" < "${VELODYNE_TEMPLATE}"

# Reload NetworkManager connections
echo "Reloading NetworkManager connections..."
nmcli connection reload

echo "Done. Static IP connection 'velodyne' is now available."
echo "You can activate it with:"
echo "  sudo nmcli connection up velodyne"
