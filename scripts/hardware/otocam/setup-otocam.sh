#!/usr/bin/env bash
# Install OTOCAM GMSL camera kernel modules + boot config.
# Replaces vendor scripts: insmod-otocam.sh, set_otocam_agxorin_64g.sh.
#
# Workflow per boot becomes automatic:
#   1. extlinux loads DTB overlay /usr/local/bin/otocam/agxorin/oto.dtbo
#   2. systemd-modules-load auto-loads max9296 + nv_imx390
#   3. modprobe.d applies clk_en=1 to max9296
#
# Prerequisites: vendor blob present at /usr/local/bin/otocam/ with
#   max9296.ko, nv_imx390.ko, agxorin/oto.dtbo
# Kernel must be 5.15.148-tegra (modules ABI-bound).

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${SCRIPT_DIR}/modules"
KVER="$(uname -r)"
EXTRA_DIR="/lib/modules/${KVER}/extra/otocam"
EXTLINUX="/boot/extlinux/extlinux.conf"
DTBO="/usr/local/bin/otocam/agxorin/oto.dtbo"
DTB="/boot/dtb/otocam-merged.dtb"

# 1. Precheck vendor blob
echo "[1/6] Checking vendor blob..."
for f in "${VENDOR_DIR}/max9296.ko" "${VENDOR_DIR}/nv_imx390.ko" "${DTBO}"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: Missing $f. Install OTOCAM vendor package first." >&2
    exit 2
  fi
done

if [ ! -f "$DTB" ]; then
    echo "ERROR: Missing the merged dtb. Merge the file by yourself first."
    exit 2
fi

# 2. Remove stock kernel modules if present (override with vendor variants)
echo "[2/6] Removing stock max9295/max9296/nv_imx390 from /lib/modules..."
STOCK_DIR="/lib/modules/${KVER}/updates/drivers/media/i2c"
for m in max9295.ko max9296.ko nv_imx390.ko; do
  if [ -f "${STOCK_DIR}/${m}" ]; then
    rm -f "${STOCK_DIR}/${m}"
    echo "  removed stock module ${STOCK_DIR}/${m}"
  fi
done

# 3. Stage vendor .ko via symlinks into module tree
echo "[3/6] Symlinking vendor kmods into ${EXTRA_DIR}..."
sudo install -D -m 0644 "${VENDOR_DIR}/max9296.ko"  "${EXTRA_DIR}/max9296.ko"
sudo install -D -m 0644 "${VENDOR_DIR}/nv_imx390.ko" "${EXTRA_DIR}/nv_imx390.ko"
sudo depmod -a "${KVER}"

# 4. Install modules-load + modprobe configs
echo "[4/6] Installing /etc/systemd/system/otocam.service + /etc/modprobe.d/otocam.conf..."
sudo install -m 0644 "${TEMPLATES}/otocam.service" /etc/systemd/system/otocam.service
sudo install -m 0644 "${TEMPLATES}/otocam.modprobe.conf" /etc/modprobe.d/otocam.conf

# 5. Patch extlinux.conf (idempotent — grep before insert, backup first)
echo "[5/6] Patching ${EXTLINUX}..."
NEED_PATCH=0
grep -qF "$DTB" "$EXTLINUX"  || NEED_PATCH=1
grep -qF "$DTBO" "$EXTLINUX" || NEED_PATCH=1

if [ "$NEED_PATCH" -eq 1 ]; then
  cp -a "$EXTLINUX" "${EXTLINUX}.bak-$(date +%Y%m%d-%H%M%S)"
  # Insert FDT + OVERLAYS lines after first INITRD line.
  awk -v dtb="FDT $DTB" -v dtbo="OVERLAYS $DTBO" '
    BEGIN { inserted=0 }
    { print }
    !inserted && /^[[:space:]]*INITRD[[:space:]]/ {
      print dtb
      print dtbo
      inserted=1
    }
  ' "$EXTLINUX" > "${EXTLINUX}.new"
  mv "${EXTLINUX}.new" "$EXTLINUX"
  echo "  patched (backup at ${EXTLINUX}.bak-*)"
else
  echo "  already patched, skipping"
fi

# 6. Done
echo "[6/6] Done."
echo
echo "Reboot required for DTB overlay to take effect."
echo "After reboot, verify:"
echo "  lsmod | grep -E 'max9296|nv_imx390'"
echo "  ls /dev/video*"
