# OTOCAM GMSL Camera Setup

AGX Orin, kernel `5.15.148-tegra`. Sony IMX390 + Maxim MAX9296.

Two independent parts: the device tree (`dtb/`) and the kernel modules (`modules/`).

Vendor blob required at `/usr/local/bin/otocam/`: `max9296.ko`, `nv_imx390.ko`, `agxorin/oto.dtbo`.

> `setup-otocam.sh` and `templates/` are the old flow. Deprecated — its `FDT` path kills USB. Use this README.

## 1. Device tree

`dtb/merge-otocam-dtb.sh` merges `oto.dtbo` into the board DTB and verifies the result.

Base DTB must be `/boot/kernel_tegra234-p3737-0000+p3701-0005-nv.dtb`.
**Not** `/boot/dtb/kernel_...` — same filename, different file, missing the
`usb12_pwr_en` / `usb34_pwr_en` GPIO hogs. Boot that one and USB VBUS stays off:
`lsusb` empty, no keyboard, no external disk.

```bash
sudo ./dtb/merge-otocam-dtb.sh          # -> /boot/dtb/otocam-merged.dtb
```

Then edit `/boot/extlinux/extlinux.conf`. In the `LABEL primary` block only, after `INITRD`:

```
      FDT /boot/dtb/otocam-merged.dtb
```

Remove any existing `FDT` / `OVERLAYS` line in that block. Leave `LABEL primary-backup`
untouched — it is the fallback entry that still boots with working USB.

```bash
sudo reboot
```

Verify:

```bash
lsusb                                                    # hub + peripherals listed
ls /proc/device-tree/bus@0/i2c@3180000/ | grep max9296   # max9296_a@48
```

## 2. Kernel modules

Vendor `.ko` go in `updates/`, not `extra/` — `/etc/depmod.d/ubuntu.conf` sets
`search updates ubuntu built-in`, so `extra/` has no defined priority and stock
modules in `updates/` win.

```bash
KVER=$(uname -r)
sudo rm -f /lib/modules/$KVER/updates/drivers/media/i2c/{max9295,max9296,nv_imx390}.ko
sudo install -D -m 0644 /usr/local/bin/otocam/max9296.ko   /lib/modules/$KVER/updates/otocam/max9296.ko
sudo install -D -m 0644 /usr/local/bin/otocam/nv_imx390.ko /lib/modules/$KVER/updates/otocam/nv_imx390.ko
sudo depmod -a $KVER
```

Copy the config files:

| Source | Destination |
|---|---|
| `modules/otocam.modprobe.conf` | `/etc/modprobe.d/otocam.conf` |
| `modules/otocam.service` | `/etc/systemd/system/otocam.service` |

```bash
sudo install -m 0644 modules/otocam.modprobe.conf /etc/modprobe.d/otocam.conf
sudo install -m 0644 modules/otocam.service /etc/systemd/system/otocam.service
sudo systemctl daemon-reload
sudo systemctl enable --now otocam.service
```

Do **not** use `/etc/modules-load.d/`. It runs at `sysinit`, before the tegra camera
stack exists, and the probe fails permanently. `otocam.service` loads after udev settles;
the `blacklist` lines stop udev from autoloading `nv_imx390` early by modalias.

Verify:

```bash
lsmod | grep -E 'max9296|nv_imx390'
ls /dev/video*                          # 8 nodes
dmesg | grep -iE 'max9296|imx390'
```

## Notes

- `.ko` are ABI-bound to `5.15.148-tegra`. Kernel upgrade breaks them.
- JetPack OTA reinstalls stock `max9295.ko` / `max9296.ko` / `nv_imx390.ko` into `updates/drivers/media/i2c/`. Re-run the removal above.
- `max9296.ko` also carries the `max9295` / `ub953` / `ub960` aliases; one module drives serializer and deserializer.
- Do not run the vendor `/usr/local/bin/otocam/enable-otocamera.sh`. It appends `ubuntu ALL=(ALL) NOPASSWD:ALL` to `/etc/sudoers`. Call `gst-launch-1.0` directly instead.

## Uninstall

```bash
sudo systemctl disable --now otocam.service
sudo rm /etc/systemd/system/otocam.service /etc/modprobe.d/otocam.conf
sudo rm -rf /lib/modules/$(uname -r)/updates/otocam
sudo depmod -a
# remove the FDT line from /boot/extlinux/extlinux.conf
sudo reboot
```
