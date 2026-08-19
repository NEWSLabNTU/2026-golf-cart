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

**Do not attach the GNSS move to this.** It is tempting and it is wrong: the
u-blox lives on the Orin because the Advantech ran out of USB *ports*, not because
the overlay disabled them. See `notes-usb-ports.md`. Keep the two separate on the
slides — one is a device-tree conflict, the other is a plain port count, and
merging them makes a claim the team has not made.

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

## 2. A format conversion with no GPU element to do it

The chain, stated as the problem actually is:

1. The cameras emit **UYVY** at 1920x1280, 30 fps. Sourced, not recalled:
   `camera_{left,right,rear}.yaml` state
   `video/x-raw,format=UYVY,width=1920,height=1280,framerate=30/1`.
2. The consuming nodes want **RGB or JPEG**.
3. So a conversion has to happen somewhere.
4. gscam does that conversion through GStreamer, and **no GPU element was found
   that takes UYVY in and gives RGB or JPEG out**.
5. The fallback is the **CPU** `videoconvert` element — one colour conversion
   per camera, three cameras, 1920x1280 at 30 fps.

That CPU stage is the reportable cost. On a box already carrying three cameras
and two LiDARs it is part of why the machine sits at its limit, which is the
same limit the fan photograph, the twelve-cores-at-100% photograph, the ZED move
to the Orin and the startup governor are all responses to.

**Workaround:** <https://github.com/newslabntu/gmslcam>, to remove that stage.

### What the sources say, so the slide claims only what holds

Checked because a narrower claim was heading for a slide:

- **gscam is not the limitation, and the deck should not say it is.** Its ROS 2
  source accepts `rgb8`, `mono8`, `yuv422` and `jpeg`, and `yuv422` sets caps
  `video/x-raw, format=UYVY` exactly. It will happily *carry* UYVY — it just
  publishes it unconverted, which is no use to a consumer wanting RGB or JPEG.
  gscam is the thing that needs a GStreamer element to convert; it is not the
  thing refusing the format.

- **DeepStream `nvvideoconvert` documents UYVY on Jetson** (sink caps: NV12,
  I420, P010_10LE, BGRx, RGBA, GRAY8, RGB, BGR, BGR10A2_LE, UYVP, **UYVY**,
  YUY2, YVYU, Y42B, I420_12LE, GRAY16_LE, BGRA64_LE; the dGPU list omits it, but
  this is a Jetson). So "DeepStream does not support UYVY" is not supportable
  from the docs.

- Our pipeline uses **`nvvidconv`**, the L4T converter, *not* `nvvideoconvert`.
  Different plugin, different caps.

**`nvvidconv` was tried** — confirmed by the team, 2026-08-19. So it is the
element that can be named, rather than DeepStream's `nvvideoconvert`, which was
never in the pipeline.

### One thing that does not add up, and should be settled before the slide

The committed pipeline in `camera_{left,right,rear}.yaml` is

```
v4l2src ! video/x-raw,format=UYVY,1920x1280@30 ! nvvidconv !
video/x-raw(memory:NVMM),format=NV12 ! nvjpegenc quality=90
```

with `image_encoding: "jpeg"`. That is `nvvidconv` taking UYVY and handing NV12
to a hardware JPEG encoder — **no CPU `videoconvert` anywhere in it**. So the
repo does not corroborate "the conversion runs on CPU, once per camera".

Both statements came from the team, so one is narrower than it reads. The likely
resolutions, in order of plausibility:

1. This pipeline is the one that was *tried* and did not work, and the CPU
   `videoconvert` path is what actually runs — the config here would then be
   stale.
2. `nvvidconv` handles UYVY→NV12→JPEG, and the CPU cost is elsewhere in the
   chain (gscam's own handling, or the RGB path a consumer needs rather than the
   JPEG one).

**Safe wording either way:** "the cameras emit UYVY, the consumers want RGB or
JPEG, we tried `nvvidconv`, and the conversion still costs us CPU per camera —
`gmslcam` is the fix." That holds under both resolutions. Do not put a specific
element count or a specific CPU figure on the slide until one of them is
confirmed.

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
