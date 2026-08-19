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

## 2. The camera encoding and the conversion stage

The cameras output **UYVY** at 1920x1280, 30 fps — sourced, not recalled:
`camera_{left,right,rear}.yaml` state
`video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1`.

**What the documentation actually says.** Checked because the claim was going on
a slide, and it does not survive contact with the sources as stated:

- **gscam does support UYVY.** Its ROS 2 source accepts four `image_encoding`
  values — `rgb8`, `mono8`, `yuv422`, `jpeg` — and `yuv422` sets caps
  `video/x-raw, format=UYVY` exactly. Anything else is a fatal
  "Unsupported image encoding". The same strings are in the installed
  `libgscam.so`.

- **DeepStream `nvvideoconvert` lists UYVY on Jetson.** Its documented Jetson
  sink-pad caps are NV12, I420, P010_10LE, BGRx, RGBA, GRAY8, RGB, BGR,
  BGR10A2_LE, UYVP, **UYVY**, YUY2, YVYU, Y42B, I420_12LE, GRAY16_LE,
  BGRA64_LE. (The dGPU list omits UYVY — but this is a Jetson.)

**So the blocker was something more specific than "neither supports UYVY", and
the deck should not say that.** Candidates worth one test each on the vehicle:

- The element in our pipeline is **`nvvidconv`** — the L4T converter — not
  DeepStream's `nvvideoconvert`. Different plugin, different caps. This is the
  most likely culprit and the easiest to check: `gst-inspect-1.0 nvvidconv`
  on the Advantech.
- gscam's `yuv422` mode publishes UYVY *unconverted*; the moment a
  JPEG/NV12 output is wanted, a conversion element is needed regardless, and
  that is where the CPU `videoconvert` crept in.
- A version difference between the installed L4T/DeepStream and the documented
  one.

**What is not in doubt:** a CPU `videoconvert` stage per camera was in use, three
cameras at 1920x1280x30 is real load, and `gmslcam` was written to remove it.
The *cost* is the reportable fact; the exact plugin that refused the format
needs one command to pin down.

## Status in this repo

**The gmslcam migration is planned, not done.** Present it as the intended fix,
not as the current state.

`camera_{left,right,rear}.yaml` carry a `gscam` pipeline (`v4l2src` → `nvvidconv`
→ `nvjpegenc`) and the sensor kit's `camera_model` offers `gscam | zedx | none`.
gmslcam is neither a submodule here nor checked out locally.

Our pipeline is `v4l2src → (UYVY) → nvvidconv → NV12(NVMM) → nvjpegenc`, with
`image_encoding: "jpeg"`. Note what that means: gscam is being used in JPEG
mode with a hand-written pipeline doing the conversion, rather than in its
built-in `yuv422` mode. That is consistent with "the built-in path did not give
us what we needed" — but it is not the same claim as "gscam does not know
UYVY".

## Why this belongs in the deck

It connects three things that otherwise look unrelated: the thermal photograph
(fan held against the cabinet), the CPU-load photograph (twelve cores at 100%),
and the decision to move the ZED to the Orin. A CPU colour-conversion stage per
camera is part of why that machine is at its limit.
