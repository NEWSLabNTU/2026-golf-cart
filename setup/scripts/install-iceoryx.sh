#!/usr/bin/env bash
# Install the Iceoryx runtime that CycloneDDS's shared-memory transport needs.
#
# The three iceoryx packages normally arrive as dependencies of
# ros-humble-cyclonedds, but "normally" is not a guarantee to build a hard
# runtime dependency on: config/cyclonedds/*.xml enables <SharedMemory>, and a
# host without iox-roudi does not merely lose zero-copy - every ROS process
# hangs at participant creation with no message. So install them by name.
set -e

echo "Installing Iceoryx runtime for CycloneDDS shared memory..."
echo ""

PKGS=(
    ros-humble-iceoryx-posh      # provides iox-roudi
    ros-humble-iceoryx-hoofs
    ros-humble-iceoryx-binding-c
)

MISSING=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ ${#MISSING[@]} -eq 0 ]; then
    echo "✓ All Iceoryx packages already installed."
else
    echo "Installing: ${MISSING[*]}"
    sudo apt-get update
    sudo apt-get install -y "${MISSING[@]}"
fi

ROUDI="$(command -v iox-roudi || echo /opt/ros/humble/bin/iox-roudi)"
if [ ! -x "${ROUDI}" ]; then
    echo "ERROR: iox-roudi still not present at ${ROUDI}" >&2
    exit 1
fi
echo "✓ iox-roudi: ${ROUDI}"

# Verify Cyclone was actually built with shared-memory support. A Cyclone
# compiled without it silently ignores <SharedMemory> - the config parses, the
# option is simply never registered - so the check is for the option itself.
LIBDDSC="$(ldconfig -p 2>/dev/null | awk '/libddsc\.so/ {print $NF; exit}')"
LIBDDSC="${LIBDDSC:-/opt/ros/humble/lib/aarch64-linux-gnu/libddsc.so}"
if [ -f "${LIBDDSC}" ] && strings "${LIBDDSC}" | grep -q 'CycloneDDS/Domain/SharedMemory'; then
    echo "✓ CycloneDDS has shared-memory support compiled in."
else
    echo "WARNING: ${LIBDDSC} does not register CycloneDDS/Domain/SharedMemory." >&2
    echo "         <SharedMemory> in the profiles will be ignored." >&2
fi

echo ""
echo "RouDi runs as a systemd user unit, installed with the other units:"
echo "    just service install master        # or: install-orin"
echo ""
echo "Mempool sizes live in config/iceoryx/roudi.toml."
echo "Verify once installed:"
echo "    systemctl --user start iox-roudi.service"
echo "    systemctl --user status iox-roudi.service"
