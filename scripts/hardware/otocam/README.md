# OTOCAM GMSL Camera Setup

AGX Orin, kernel `5.15.148-tegra`. Sony IMX390 + Maxim MAX9296.

Two independent parts: the device tree (`dtb/`) and the kernel modules (`modules/`).

Vendor blob required at `/usr/local/bin/otocam/`: `max9296.ko`, `nv_imx390.ko`, `agxorin/oto.dtbo`.


> files in `templates/` are the old flow. Deprecated — its `FDT` path kills USB. Use this README.
> `setup-otocam.sh` is updated but not tested.

## 1. Device tree

`dtb/merge-otocam-dtb.sh` merges `oto.dtbo` into the board DTB and verifies the result.

Base DTB must be `/boot/kernel_tegra234-p3737-0000+p3701-0005-nv.dtb`.
**Not** `/boot/dtb/kernel_...` — same filename, different file, missing the
`usb12_pwr_en` / `usb34_pwr_en` GPIO hogs. Boot that one and USB VBUS stays off:
`lsusb` empty, no keyboard, no external disk.

```bash
sudo ./dtb/merge-otocam-dtb.sh          # -> /boot/dtb/otocam-merged.dtb
```

### Edit Bootloader
Then edit `/boot/extlinux/extlinux.conf`. 
In the `LABEL primary` block only, after `INITRD`:

```
      FDT /boot/dtb/otocam-merged.dtb
      OVERLAYS /usr/local/bin/otocam/agxorin/oto.dtbo
```

Remove any existing `FDT` / `OVERLAYS` line in that block.

#### Backup (rescue for you)
Leave `LABEL primary-backup` untouched — it is the fallback entry (spam 1 on boot). 

#### Verify

```bash
reboot
```
and then after the reboot, check your keyboard with numlock or capslock 
to see if it is functional.

```bash
lsusb                                                    # hub + peripherals listed
ls /proc/device-tree/bus@0/i2c@3180000/ | grep max9296   # max9296_a@48
```

#### Bailout

If you find you cannot use your keyboard or mouse, use the methods below:
1. Connect the Advantech with Orin or other computer via the LAN. 
   Use SSH with `sudo poweroff` to shut the machine down.
2. Hold on the power button of the machine, poweroff it.
3. Remove the power plug, only do this when you can see the login screen.

After that, spam 1 on boot to get into the backup profile.

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
