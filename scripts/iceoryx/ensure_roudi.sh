#!/usr/bin/env bash
# Make sure iox-roudi is running before anything creates a DDS participant.
#
# The CycloneDDS profiles enable <SharedMemory>, and with SHM on and RouDi
# absent a participant does not fail - it hangs, with nothing printed anywhere
# (measured: still blocked at 60s). A silent hang is the worst failure mode to
# hand an operator, so every foreground path calls this first.
#
# The systemd path does not need it: golfcart-launch.service and
# golfcart-record.service carry Requires=/After=iox-roudi.service. This is for
# `just launch` and the replay scripts, which are not units.
#
# Exit 0 when RouDi is up (or was started); 1 with an explanation when not.
set -uo pipefail

roudi_up() { [ -S /tmp/roudi ] && pgrep -x iox-roudi >/dev/null 2>&1; }

# Follow the config rather than assuming. SharedMemory is currently disabled in
# every profile (iceoryx runs out of publisher ports on a stack this size - see
# the comment in config/cyclonedds/master.xml), and a guard that demanded RouDi
# anyway would block every launch for a transport nothing is using. Keying off
# the profile means flipping <Enable> is the only edit needed in either
# direction.
profile="${CYCLONEDDS_URI#file://}"
if [ -n "${profile}" ] && [ -f "${profile}" ]; then
    grep -q '<Enable>true</Enable>' "${profile}" || exit 0
else
    # No profile resolved: nothing has enabled shared memory, so nothing to do.
    exit 0
fi

roudi_up && exit 0

# Prefer the unit, so a RouDi started here is supervised and stops with the rest
# rather than becoming an orphan nobody knows to clean up.
if systemctl --user list-unit-files iox-roudi.service >/dev/null 2>&1 \
   && systemctl --user cat iox-roudi.service >/dev/null 2>&1; then
    echo "iox-roudi is not running; starting iox-roudi.service..." >&2
    systemctl --user start iox-roudi.service 2>/dev/null || true
    for _ in $(seq 1 50); do
        roudi_up && { echo "iox-roudi is ready." >&2; exit 0; }
        sleep 0.2
    done
fi

{
    echo ""
    echo "ERROR: iox-roudi is not running, and the CycloneDDS profiles enable"
    echo "       <SharedMemory>. Starting ROS in this state does not fail - it"
    echo "       HANGS, with no message, at participant creation."
    echo ""
    echo "  Install the unit (once per machine):"
    echo "      just service install master        # or: install-orin"
    echo ""
    echo "  Or start it by hand:"
    echo "      systemctl --user start iox-roudi.service"
    echo ""
    echo "  Or turn shared memory off in config/cyclonedds/*.xml:"
    echo "      <SharedMemory><Enable>false</Enable></SharedMemory>"
    echo ""
} >&2
exit 1
