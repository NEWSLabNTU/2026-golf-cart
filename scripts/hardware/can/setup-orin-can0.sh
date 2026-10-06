#!/usr/bin/env bash
# Bring up can0 on the AGX Orin's 40-pin header, and keep it up across reboots.
#
#     ./setup.sh --only orin-can0
#
# Wiring: header pin 29 (CAN0_DIN) and pin 31 (CAN0_DOUT) are 3.3 V logic, not a
# bus. They go to a transceiver (a Waveshare SN65HVD230 on the cart): pin 31 to
# its CAN TX, pin 29 to its CAN RX, pin 1 to 3.3V, pin 30 to GND. CANH/CANL of the
# transceiver go to the VCU.
#
# WHY THE PINMUX IS WRITTEN AT ALL
#
# The mttcan driver loads and can0 exists without it, so everything looks fine
# and candump prints nothing. As shipped, both pads read function 1, not CAN
# (function 0), and DOUT is tristated as an input:
#
#     0x0c303018 (CAN0_DIN)  = 0x0000C055   needed 0x0000C458
#     0x0c303010 (CAN0_DOUT) = 0x0000C059   needed 0x0000C400
#
# devmem writes do not survive a reboot, so a unit repeats them every boot.
#
# WHY NOT scripts/hardware/can/setup-can.sh
#
# That is the master's: it configures can1 as well, through systemd-networkd,
# and assumes the pinmux is already right. Here only can0 is wired and the
# pinmux is the part that was missing; one unit does both, in order.
#
# The unit is pulled in by the can0 device itself, not by multi-user.target, so a
# boot where mttcan never loads leaves the unit inactive instead of holding the
# boot for the default device timeout.
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root" >&2
    exit 1
fi

# The pad registers are Tegra234 (Orin) addresses. Writing them on anything else
# pokes unrelated physical memory.
if ! tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | grep -qx 'nvidia,tegra234'; then
    echo "This is not a Tegra234 (Orin) board; refusing to write its pinmux registers." >&2
    exit 1
fi

BITRATE="${CAN_BITRATE:-500000}"     # the Turing Drive VCU
UNIT=/etc/systemd/system/golfcart-can0.service

if ! command -v busybox >/dev/null || ! command -v candump >/dev/null; then
    echo "Installing busybox (devmem) and can-utils..."
    apt-get update
    apt-get install -y busybox can-utils
fi
BUSYBOX="$(command -v busybox)"

if [ -f "${UNIT}" ]; then
    echo "  ${UNIT} already exists — refreshing it"
fi

cat > "${UNIT}" << EOF
[Unit]
Description=can0 on the 40-pin header: pinmux + ${BITRATE} bit/s
BindsTo=sys-subsystem-net-devices-can0.device
After=sys-subsystem-net-devices-can0.device

[Service]
Type=oneshot
# RemainAfterExit so \`systemctl is-active\` says "active" once it has run.
RemainAfterExit=yes
ExecStart=${BUSYBOX} devmem 0x0c303018 32 0x0000c458
ExecStart=${BUSYBOX} devmem 0x0c303010 32 0x0000c400
# The bitrate cannot change while the link is up.
ExecStart=-/usr/sbin/ip link set can0 down
ExecStart=/usr/sbin/ip link set can0 type can bitrate ${BITRATE} sample-point 0.825 restart-ms 50
ExecStart=/usr/sbin/ip link set can0 up
ExecStop=/usr/sbin/ip link set can0 down

[Install]
WantedBy=sys-subsystem-net-devices-can0.device
EOF

systemctl daemon-reload
systemctl enable golfcart-can0.service
systemctl restart golfcart-can0.service

echo ""
din="$("${BUSYBOX}" devmem 0x0c303018)"
dout="$("${BUSYBOX}" devmem 0x0c303010)"
if [ "${din}" = "0x0000C458" ] && [ "${dout}" = "0x0000C400" ] \
        && ip link show can0 | grep -q '[<,]UP[,>]'; then
    echo "✓ can0 is up at ${BITRATE} bit/s, and will be after a reboot."
else
    echo "✗ can0 did not come up as expected (DIN=${din} DOUT=${dout})." >&2
    echo "  Check: systemctl status golfcart-can0" >&2
    exit 1
fi
echo ""
echo "Verify with:"
echo "  ip -details -statistics link show can0"
echo "  candump -tz can0"
