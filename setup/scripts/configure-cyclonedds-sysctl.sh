#!/usr/bin/env bash
# Configure CycloneDDS kernel network buffers (system-wide)
# Based on: https://autowarefoundation.github.io/autoware-documentation/main/installation/additional-settings-for-developers/network-configuration/dds-settings/

set -e

echo "Configuring CycloneDDS kernel network buffers (system-wide)..."
echo ""
echo "Settings to be applied:"
echo "  ip link set lo multicast on"
echo "  net.core.rmem_max=2147483647"
echo "  net.core.rmem_default=16777216"
echo "  net.core.wmem_max=16777216"
echo "  net.core.netdev_max_backlog=8192"
echo "  net.ipv4.ipfrag_time=3"
echo "  net.ipv4.ipfrag_high_thresh=134217728"
echo ""

echo "Enable lo multicast"
sudo ip link set lo multicast on

# Apply immediately
echo "Applying sysctl settings..."
sudo sysctl -w net.core.rmem_max=2147483647
sudo sysctl -w net.core.rmem_default=16777216
sudo sysctl -w net.core.wmem_max=16777216
sudo sysctl -w net.core.netdev_max_backlog=8192
sudo sysctl -w net.ipv4.ipfrag_time=3
sudo sysctl -w net.ipv4.ipfrag_high_thresh=134217728

# Make persistent across reboots.
#
# Numbered 99- so it applies last. The previous name, 10-cyclone-max.conf, lost
# to the ZED SDK's /etc/sysctl.d/60-zed-buffers.conf, which sets
# net.core.rmem_max=1048576 - a *lower* value. The result on the orin was
# CycloneDDS failing outright:
#   failed to increase socket receive buffer size to at least 10485760 bytes,
#   current is 2097152 bytes
#   rmw_create_node: failed to create domain
# because SocketReceiveBufferSize min="10MB" in our profiles is a hard minimum.
echo "Creating persistent configuration..."
sudo tee /etc/sysctl.d/99-cyclonedds-max.conf > /dev/null << 'EOF'
# CycloneDDS kernel network buffer optimization
# Configured by Golf Cart setup
# Numbered 99- to win against the ZED SDK's 60-zed-buffers.conf, which sets a
# lower net.core.rmem_max.
# See: https://autowarefoundation.github.io/autoware-documentation/main/installation/additional-settings-for-developers/network-configuration/dds-settings/

# --- receive path -----------------------------------------------------------
# rmem_max is the ceiling Cyclone's SocketReceiveBufferSize can reach via
# setsockopt. The profiles ask for 16MB as a HARD minimum, so a lower ceiling
# here does not degrade anything - it aborts node creation outright.
net.core.rmem_max=2147483647

# rmem_default is what a socket gets when nobody calls setsockopt. Raised
# because the drops we were chasing were at the SOCKET buffer, not the device
# backlog: /proc/net/snmp showed 1308 UDP RcvbufErrors/s with the stack up, and
# every one of those costs a NACK plus a retransmit scheduled on Cyclone's
# "tev" thread - the hottest thread on the machine. Note this is a per-socket
# default for the whole system, charged as packets actually arrive rather than
# preallocated.
net.core.rmem_default=16777216

# --- send path --------------------------------------------------------------
# wmem_max was the asymmetry: rmem_max had been raised to 2GB while this stayed
# at the 208kB stock value, so Cyclone could never grow a send buffer.
net.core.wmem_max=16777216

# --- device backlog ---------------------------------------------------------
# Per-CPU queue between the driver and the NET_RX softirq. Measured at 0 drops
# and 0 time_squeeze with the stack up, so this is headroom rather than a fix:
# loopback alone was carrying 205k packets/s against a stock backlog of 1000.
net.core.netdev_max_backlog=8192

# --- IP fragmentation -------------------------------------------------------
net.ipv4.ipfrag_time=3
net.ipv4.ipfrag_high_thresh=134217728
EOF

# Drop the old lower-priority file so the two cannot disagree.
#
# Everything 10-cyclone-max.conf used to carry is now in the 99- file above, so
# this removal migrates it rather than discarding it. Keep it that way: a 10-
# file is applied FIRST and therefore loses every key it shares with a
# higher-numbered one, which is the whole reason this moved to 99-.
if [ -f /etc/sysctl.d/10-cyclone-max.conf ]; then
    echo "Removing superseded /etc/sysctl.d/10-cyclone-max.conf..."
    echo "  (its settings are carried by 99-cyclonedds-max.conf)"
    sudo rm -f /etc/sysctl.d/10-cyclone-max.conf
fi

echo ""
echo "✓ Kernel buffers configured successfully!"
echo "  Settings will persist across reboots."
echo ""
echo "Verify configuration:"
echo "  sysctl net.core.rmem_max net.core.rmem_default net.core.wmem_max \\"
echo "        net.core.netdev_max_backlog net.ipv4.ipfrag_time net.ipv4.ipfrag_high_thresh"
echo ""

# Remove warning marker if it exists (force .envrc to re-check)
GOLFCART_ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "Error: cannot resolve repo root"; exit 1; }
if [ -f "$GOLFCART_ROOT/.envrc.sysctl-warned" ]; then
    rm -f "$GOLFCART_ROOT/.envrc.sysctl-warned"
    echo "Note: .envrc will re-check configuration on next activation"
fi
