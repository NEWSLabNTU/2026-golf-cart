# OTOCAM GMSL Camera Setup

Persistent boot-time setup for OTOCAM GMSL cameras (Sony IMX390 + Maxim MAX9296 deserializer) on AGX Orin (JetPack 6.0, kernel `5.15.148-tegra`).

Replaces vendor-supplied scripts (`insmod-otocam.sh`, `set_otocam_agxorin_64g.sh`) with declarative system config. Modules auto-load at boot via `systemd-modules-load.service`; DTB overlay applied via extlinux.

## Prerequisites

Vendor blob installed at `/usr/local/bin/otocam/`:

```
/usr/local/bin/otocam/
├── max9296.ko
├── nv_imx390.ko
└── agxorin/
    └── oto.dtbo
```

Kernel must be `5.15.148-tegra` (`.ko` ABI bound).

## Run

```bash
sudo ./setup-otocam.sh
sudo reboot
```

Or via just:

```bash
just otocam
sudo reboot
```

## What it does

1. Verify vendor blob present.
2. Remove stock `max9295.ko`, `max9296.ko`, `nv_imx390.ko` from `/lib/modules/<ver>/updates/drivers/media/i2c/`.
3. Symlink vendor `.ko` into `/lib/modules/<ver>/extra/otocam/`. Run `depmod -a`.
4. Install `/etc/modules-load.d/otocam.conf` (auto-load `max9296`, `nv_imx390`).
5. Install `/etc/modprobe.d/otocam.conf` (`options max9296 clk_en=1`, blacklist stock variants).
6. Patch `/boot/extlinux/extlinux.conf` — add `FDT` + `OVERLAYS` lines after first `INITRD`. Backup saved to `extlinux.conf.bak-<timestamp>`.

## Verify after reboot

```bash
lsmod | grep -E 'max9296|nv_imx390'
ls /dev/video*
```

## Risks

- `.ko` ABI bound to kernel `5.15.148-tegra`. Kernel upgrade breaks load; rebuild vendor `.ko` against new headers.
- JetPack OTA may reinstall stock `max9295.ko`/`max9296.ko`/`nv_imx390.ko`; re-run `setup-otocam.sh` to clear.
- `extlinux.conf` patcher inserts after first `INITRD` line. If file structure changes, verify by hand.

## Uninstall (manual)

```bash
sudo rm /etc/modules-load.d/otocam.conf /etc/modprobe.d/otocam.conf
sudo rm -rf /lib/modules/$(uname -r)/extra/otocam
sudo depmod -a
# Restore extlinux from backup:
sudo cp /boot/extlinux/extlinux.conf.bak-<timestamp> /boot/extlinux/extlinux.conf
sudo reboot
```
