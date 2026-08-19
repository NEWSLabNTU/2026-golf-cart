# oToCam GMSL cameras — two problems worth reporting

Notes for the sensors section. Both are Advantech-side, both cost real effort,
and both are the kind of integration work that is invisible unless it is said
out loud.

## 1. Device tree overlay versus the USB ports

The cameras are Sony IMX390 behind a Maxim MAX9296 deserializer. Bringing them
up needs a vendor kernel module and a device tree overlay, shipped as a blob at
`/usr/local/bin/otocam/`:

```
max9296.ko
nv_imx390.ko
agxorin/oto.dtbo
```

**The conflict:** enabling the DT overlay makes the cameras work, and the USB
ports stop working. So the platform cannot simply be configured once — the
overlay is not free, it takes something else away.

We went through a workaround; the setup is now declarative rather than
vendor-script driven, in `scripts/hardware/otocam/`
([README](https://github.com/NEWSLabNTU/2026-golf-cart/blob/3a155a66754f980b1ed43f92c8a7dd5744345df9/scripts/hardware/otocam/README.md)):

- stock `max9295` / `max9296` / `nv_imx390` removed from `updates/`, vendor `.ko`
  symlinked into `extra/otocam/`, `depmod -a`
- `/etc/modules-load.d/otocam.conf` auto-loads at boot via
  `systemd-modules-load.service`
- `/etc/modprobe.d/otocam.conf` sets `options max9296 clk_en=1` and blacklists
  the stock variants
- `/boot/extlinux/extlinux.conf` patched with `FDT` + `OVERLAYS`, backup kept

**Fragility worth stating on the slide:** the `.ko` files are ABI-bound to kernel
`5.15.148-tegra`, so a kernel upgrade breaks the load, and a JetPack OTA can
reinstall the stock modules and silently undo it. `just otocam` re-applies.

## 2. Nothing on the accelerated path would take the camera's encoding

The cameras output **UYVY** — confirmed in the repo, not from memory: the
pipeline in `camera_{left,right,rear}.yaml` states
`video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1`.

Two separate problems followed:

- `gscam` does not know that input encoding.
- NVIDIA's DeepStream video convert does not support it either, so the
  accelerated conversion path was unavailable.

The fallback was the **CPU** `videoconvert` GStreamer element. It works, and it
drains the machine — a colour conversion per camera, three cameras, 1920×1280 at
30 fps. On a box already carrying three cameras and two LiDARs, that is exactly
the budget the multi-host split and the startup governor exist to protect.

**Workaround:** <https://github.com/newslabntu/gmslcam>, written to take the
camera's format without a CPU conversion stage.

## Status in this repo

**The gmslcam migration is planned, not done.** Present it as the intended fix,
not as the current state.

`camera_{left,right,rear}.yaml` carry a `gscam` pipeline (`v4l2src` → `nvvidconv`
→ `nvjpegenc`) and the sensor kit's `camera_model` offers `gscam | zedx | none`.
gmslcam is neither a submodule here nor checked out locally.

One detail to get right if it reaches a slide: the element named in the repo
pipeline is `nvvidconv`, while the element reported as not supporting UYVY is
DeepStream's video convert (`nvvideoconvert`). They are different elements with
different format support. Say "NVIDIA's accelerated converter" unless someone
can confirm which was tried.

## Why this belongs in the deck

It connects three things that otherwise look unrelated: the thermal photograph
(fan held against the cabinet), the CPU-load photograph (twelve cores at 100%),
and the decision to move the ZED to the Orin. A CPU colour-conversion stage per
camera is part of why that machine is at its limit.
