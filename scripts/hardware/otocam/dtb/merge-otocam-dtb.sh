#!/usr/bin/env bash
# Merge the OTOCAM GMSL overlay into the board DTB and verify the result.
#
# Why: the vendor script points extlinux FDT at
# /boot/dtb/kernel_tegra234-p3737-0000+p3701-0005-nv.dtb, which is the stock
# generic DTB and lacks the carrier-board usb12_pwr_en / usb34_pwr_en GPIO hogs.
# Booting it leaves USB VBUS off, so lsusb reports nothing. The correct base is
# /boot/kernel_tegra234-p3737-0000+p3701-0005-nv.dtb.
#
# Output is a single pre-merged DTB, so boot does not depend on UEFI overlay
# handling. Writes nothing outside OUT; extlinux.conf is edited by hand.

set -euo pipefail

BASE="${BASE:-/boot/kernel_tegra234-p3737-0000+p3701-0005-nv.dtb}"
DTBO="${DTBO:-/usr/local/bin/otocam/agxorin/oto.dtbo}"
OUT="${OUT:-/boot/dtb/otocam-merged.dtb}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v fdtoverlay >/dev/null || die "fdtoverlay missing. apt install device-tree-compiler"
command -v dtc        >/dev/null || die "dtc missing. apt install device-tree-compiler"

[ -f "$BASE" ] || die "base DTB not found: $BASE"
[ -f "$DTBO" ] || die "overlay not found: $DTBO"

dts() { dtc -I dtb -O dts "$1" 2>/dev/null; }

# Guard: refuse a base DTB without the USB power-enable hogs.
echo "[1/4] Checking base DTB ${BASE}..."
BASE_DTS="$(dts "$BASE")"
for hog in usb12_pwr_en usb34_pwr_en; do
  grep -q "$hog" <<<"$BASE_DTS" \
    || die "base DTB has no ${hog} GPIO hog — booting it kills USB. Wrong base DTB."
done
grep -q '__symbols__' <<<"$BASE_DTS" || die "base DTB has no __symbols__ — overlay cannot resolve fixups."

echo "[2/4] Merging ${DTBO}..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
fdtoverlay -i "$BASE" -o "$TMP" "$DTBO" || die "fdtoverlay failed"

echo "[3/4] Verifying merged DTB..."
OUT_DTS="$(dts "$TMP")" || die "merged DTB does not parse"
for node in usb12_pwr_en usb34_pwr_en max9296_a@48 imx390@10 imx390@17; do
  grep -q "$node" <<<"$OUT_DTS" || die "merged DTB missing ${node}"
done

echo "[4/4] Installing ${OUT}..."
[ -f "$OUT" ] && cp -a "$OUT" "${OUT}.bak-$(date +%Y%m%d-%H%M%S)"
install -m 0644 "$TMP" "$OUT"

echo "OK: ${OUT}"
echo "Next: add 'FDT ${OUT}' to the LABEL primary block of /boot/extlinux/extlinux.conf, then reboot."
