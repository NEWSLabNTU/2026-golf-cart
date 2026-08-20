# Phase 2 - Camera image pipeline

Get the three GMSL cameras onto a wire format that is hardware-encoded at the
source, decodable by every consumer, and described by a contract that a Rust
node and a C++ node read the same way.

Extends [Phase 2 Track A](2-track-a.md), whose exit criterion in
[ROADMAP.md](../../ROADMAP.md#track-a--tier-iv-camera-setup) is "three cameras
stream images". They do. What is unfinished is the contract that says what the
bytes on those topics mean, which is what everything downstream has to agree on.

Feeds Phase 3 Track C: sub-phase D below migrates the ArUco detector, and
[3-indoor-d5](3-indoor-d5-detector.md) is where its current hand-rolled
transport lives.

Last updated: 2026-08-21. Blockers 1, 3 and 4 and the NVJPG capacity question
are answered, measured on an AGX Orin (JetPack 6.2, L4T R36.4.4, DeepStream 7.1)
with no cameras attached. Sub-phase B is decided: **gscam stays, gmslcam is
dropped**, and the capture path is a switchable profile. Sub-phase C is
implemented and tested against the C++ plugin's own bytes. Sub-phase D is
written but not compiled; see the note there.

What is left needs the vehicle: whether `nvv4l2camerasrc` binds to the oToCam
driver, and the end-to-end CPU delta. Both are one command on the box.

> Numbered Phase 4 when first written, which collided with ROADMAP.md's
> Phase 4 (Planning, Control & Safety). Renumbered 2026-08-20. Phase numbering
> follows ROADMAP.md, not the order documents were added; `0-migration.md`'s
> own `Phase #1`..`#11` scheme is deprecated and unrelated.

---

## The decision

**JPEG in `sensor_msgs/CompressedImage`, on `<base>/image_raw/compressed`.**
No raw `Image` topics between processes. No H.264/H.265.

Three constraints forced it, and they are worth keeping written down because
each one will look re-openable later:

1. **The DDS profiles cannot carry raw.** All three of `config/cyclonedds/*.xml`
   set `MaxMessageSize 65500B` and `WhcHigh 500kB`, with no shared memory or
   Iceoryx anywhere, loopback included. One `rgb8` frame at 1920x1280 is 7.37 MB:
   about 113 fragments against a 500 kB writer high-water mark. Three cameras of
   raw is 663 MB/s and roughly 10,000 datagrams a second. This is not a tuning
   problem, it is a different architecture.
2. **Every message must decode alone.** Bag seeking, late-joining subscribers,
   and single-frame loss recovery all depend on it. Inter-frame codecs give that
   up, which for a sensor feeding pose estimates is not a convenience trade.
3. **JPEG is hardware at both ends on Orin** (NVJPG encode, NVDEC/`nvjpegdec` or
   SIMD decode) and is understood by `cv::imdecode`, `image_transport`, RViz,
   rqt, Foxglove and rosbag tooling without anyone writing a decoder.

Quality 90, 4:2:0, roughly 250 to 400 kB per frame, about 9 MB/s per camera.

Not below 85 on the localization cameras: JPEG ringing at high-contrast marker
edges lands on the corners that subpixel refinement measures, and corner error
becomes pose error. Luma is not subsampled at 4:2:0 and the detector decodes
grayscale, so the chroma loss costs that path nothing.

---

## The contract

`CompressedImage.format` is the whole interface, and the message definition does
not specify it. The convention is whatever `compressed_image_transport` does.
Read out of the Humble sources, not recalled:

**Publisher**

```cpp
compressed.format  = message.encoding;        // "bgr8"
compressed.format += "; jpeg compressed ";
compressed.format += targetFormat;            // "bgr8" color, "mono8" mono
```

**Subscriber**, splitting on the first `;`

| input | behaviour |
|---|---|
| first field | copied **verbatim** into `Image.encoding` |
| second field contains `compressed bgr` | BGR to RGB/RGBA/BGRA conversion applied |
| second field contains `jpeg` + 16-bit encoding | `convertTo(CV_16U, 256)` |
| **no `;` at all** | guess by channel count: 1 to `mono8`, 3 to `bgr8`, else error |

**We emit `"bgr8; jpeg compressed bgr8"`.** The identity case: no conversion in
any subscriber, byte-identical to what a C++ `compressed` publisher produces from
a `bgr8` raw image, so Rust and C++ consumers cannot diverge.

Checked twice over, and the two checks found different things.

**Read out of the upstream sources** (`ros-perception/image_common` and
`ros-perception/image_transport_plugins`, both `humble`), which is where the
rules below come from:

| fact | source |
|---|---|
| publisher writes `encoding` + `"; jpeg compressed "` + `bgr8`/`mono8` | `compressed_publisher.cpp` |
| the target is `bgr8` when `enc::isColor(encoding)`, else `mono8` | same |
| `isColor` is exactly `{rgb8, bgr8, rgba8, bgra8, rgb16, bgr16, rgba16, bgra16}` | `sensor_msgs/image_encodings.hpp` |
| subscriber splits on the first `;`, copies field one into `Image.encoding` verbatim | `compressed_subscriber.cpp` |
| it reverts the colour order only for `isColor` encodings, keyed on the substring `compressed bgr` | same |
| **it decodes `IMREAD_UNCHANGED` by default** (`kDefaultMode = "unchanged"`), so the channel count comes from the payload and the target field never sizes the output | same |
| no `;` at all: guess by channel count, 1 to `mono8`, 3 to `bgr8` | same |
| `raw` subscribes to the base topic; every other transport to `base + "/" + name` | `raw_subscriber.hpp`, `simple_subscriber_plugin.hpp` |
| `camera_info` is the sibling of the base topic: drop the last element, append `camera_info` | `camera_common.cpp` |
| `CameraSubscriber` pairs them with an **exact-time** `TimeSynchronizer` | `camera_subscriber.cpp` |

The `IMREAD_UNCHANGED` row is the one worth stopping on, because the crate had
it wrong. The third field of the format string does not decide how many channels
you get -- the JPEG does. The field exists so the *revert* knows what the
publisher did. A format string that disagrees with its own payload,
`"mono8; jpeg compressed mono8"` carrying three channels, yields three channels
labelled `mono8` in C++, and now here too. Copying a publisher's bug is the
point: a Rust consumer that quietly disagreed with the C++ one about the same
bytes is exactly the failure this crate exists to prevent.

**And verified by running the plugin** and recording what it wrote, which is how
the strings below were obtained rather than recalled: `scripts/make_fixtures.py` in the crate publishes a known image
through `image_transport republish raw compressed` and commits the result. The
three strings it produced:

| source `Image.encoding` | `CompressedImage.format` |
|---|---|
| `bgr8` | `bgr8; jpeg compressed bgr8` |
| `rgb8` | `rgb8; jpeg compressed bgr8` |
| `mono8` | `mono8; jpeg compressed mono8` |

Three traps this encodes, all of which the crate must enforce:

- **The target field must be the literal `bgr8` for colour.** Not because the
  bytes are BGR, but because that substring is what the subscriber greps for to
  decide whether to swap channels. `"rgb8; jpeg compressed rgb8"` looks more
  honest and is silently wrong: no swap is applied, BGR pixels get labelled
  `rgb8`, and red and blue transpose with no warning.
- **The bare form is legal and we already produce it.** gscam writes plain
  `"jpeg"`. Every bag recorded so far contains it. The crate must implement the
  channel-count fallback or it cannot replay our own data.
- **The target field does not decide the channel order -- the first field does.**
  Row two of the table above is the case: an `rgb8` source produces
  `"rgb8; jpeg compressed bgr8"`, a BGR payload that a subscriber must hand back
  as RGB, because `Image.encoding` is about to say `rgb8`. A decoder that reads
  the target field and stops ("it says bgr8, so decode BGR") transposes red and
  blue on every frame from any publisher that was not fed BGR. The C++
  subscriber pays a `cvtColor` pass for this; libjpeg writes either order for
  free, so the crate asks for the right one instead.

---

## Blockers to clear before anything below is worth doing

| # | Blocker | Blocks | Status |
|---|---|---|---|
| 1 | **`camera_info` may never reach the detector.** `config/recording/master_topics.txt` stated "gscam publishes none for these". But gscam holds a `CameraInfo` publisher on `camera/camera_info`, uses `camera_info_manager`, `camera_info_url` is set in all three YAMLs, `camera_left_calibration.yaml` is a real calibration, and `camera.launch.xml` remaps it. Those could not all be true. | D, and every indoor run | **Answered 2026-08-20: gscam publishes it.** Run against three v4l2loopback devices with the same YAML shape and the same two remaps `camera.launch.xml` uses, gscam loaded the calibration from `camera_info_url` and published `camera_info` at 30 Hz alongside the image. The recording comment was wrong, and the three topics are now recorded. One `ros2 topic list` on the master is still worth doing, but the detector's intrinsics problem is blocker 2, not this. |
| 2 | **All three calibration files are one calibration copied three times.** Verified by diff on 2026-08-20: byte-identical apart from `camera_name`. The intrinsics are real, not placeholders, which makes this worse rather than better -- a plausible matrix on the wrong lens yields plausible poses that are wrong. Also `cx` is 712 on a 1920-wide image, about 248 px off centre. See [3-indoor-a](3-indoor-a-camera-calibration.md). | D | Confirmed, unfixed |
| 3 | **`nvv4l2camerasrc` binding to the oToCam driver is unverified.** It is verified by NVIDIA against their own V4L2 driver; oToCam is a vendor `nv_imx390.ko` behind a MAX9296. | A | **Half answered 2026-08-20.** The element is present and emits `UYVY` in `memory:NVMM`, which is what `nvvidconv` wants. Whether it binds to `nv_imx390` still needs a camera: it accepts only `V4L2_MEMORY_DMABUF` in importer role, and no loopback device can stand in. `scripts/check/camera_pipeline.sh` runs the test automatically when a `/dev/video*` exists. |
| 4 | **`nvjpegenc` NVMM sink caps unverified on this install.** Decides whether today's pipeline is hardware or a silent software fallback: the hardware JPEG encoder needs a dmabuf fd. | A | **Cleared 2026-08-20.** `nvjpegenc` lists `video/x-raw(memory:NVMM), format={I420, NV12}`, and the committed `nvvidconv ! NV12(NVMM) ! nvjpegenc` chain negotiates and runs. No silent software fallback. One thing the caps do say: `GRAY8` is accepted in **system memory only**, so encoding mono at the source -- the open question below -- would leave NVMM and hand the import copy back. |
| 5 | **`config/gscam.md` is stale on two counts.** It documents an `RGBA -> videoconvert -> RGB` pipeline with `image_encoding: rgb8` that is not what the YAMLs carry, and a `platform-3610000.usb-...` USB adapter rig that has been replaced by `platform-tegra-capture-vi-...`. It is the source of the "CPU conversion per camera" claim. | reading anything | Confirmed stale |

---

## Sub-phase A - capture path, zero copy to the encoder

The committed pipeline already has no CPU `videoconvert`:

```
v4l2src io-mode=4 ! video/x-raw,UYVY,1920x1280@30
  ! nvvidconv ! video/x-raw(memory:NVMM),NV12    [VIC]
  ! nvjpegenc quality=90                          [NVJPG]
```

The remaining CPU cost is one copy, at the front. `v4l2src` hands GStreamer a
system-memory buffer and `nvvidconv` must import it into NVMM: 4.92 MB per frame,
**147 MB/s per camera, 442 MB/s across three**, before any hardware runs.

Fix is the source element. NVIDIA's Jetson Linux guide gives this shape for
exactly this sensor class, and `nvvidconv` accepts UYVY in NVMM:

```
nvv4l2camerasrc device=<by-path> !
  'video/x-raw(memory:NVMM),format=UYVY,width=1920,height=1280,interlace-mode=progressive,framerate=30/1' !
  nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' !
  nvjpegenc quality=90
```

### NVJPG is one block and three cameras contend for it

Separate risk from the copy, and the one that can invalidate this plan rather
than merely slow it. Three streams at 1920x1280 and 30 fps is 90 frames a
second, **221 MP/s of JPEG encode on a single engine**. No authoritative encode
throughput figure for AGX Orin was found; the nearest data point is a forum
thread asking whether 14 ms to *decode* a 1080p JPEG is normal. If that order of
magnitude holds for encode, three cameras is at or past the limit.

The failure mode is not an error message. It is dropped frames, or a silent
software fallback that puts the load straight back on the CPU this phase exists
to unload.

`just sim cameras-bench` measures it. **It needs no cameras** -- the encoder does
not care where the pixels came from.

**Measured 2026-08-20, and the risk is not real.** AGX Orin, MAXN, 1920x1280
quality 90:

| | fps | MP/s | dropped |
|---|---|---|---|
| sustain, 1 live stream at 30 fps | 30.9 | 76 | 0 |
| sustain, 3 live streams at 30 fps | 87.9 | 216 | 0 |
| ceiling, 1 free-running process | 103 | 253 | -- |
| ceiling, 3 free-running processes | 365 | 899 | -- |

Three cameras is met with zero drops and **4.1x headroom**. Two things this
measurement had to be fixed to say, both of which had been reporting nonsense:

- The recipe measured wall-clock frames over a cold run, so a single stream came
  out *below* three streams -- NVJPG engine init inside the first seconds, not
  throughput. It now warms up and discards.
- A live source cannot exceed its own 30 fps, so the old run could only ever say
  "met", never how much room was left. Hence two blocks: `sustain` answers
  whether the cameras are kept up with, `ceiling` answers by how much. The
  per-process ceiling of ~103 fps is a per-process serialisation limit, not the
  hardware -- three processes get 3.5x that.

### What can be tested without cameras, and what cannot

`scripts/sim/cameras.sh` puts three v4l2loopback devices carrying UYVY at the
real geometry in front of the ROS stack. It covers the topic plumbing, the
format handling, the crate, the detector, bag replay and the appsink stall
behaviour, on any host. Exercised end to end on 2026-08-20: gscam ran on it, at
30 Hz, through the real `nvvidconv ! nvjpegenc` pipeline.

One bug in it had to be fixed first, and it is worth knowing because of how it
presents. The feeders passed `io-mode=rw` to `v4l2sink`, which reads as a
harmless choice and is not: the loopback node then never flips from OUTPUT to
CAPTURE and never advertises its format, so `v4l2-ctl --list-formats` comes back
empty and consumers die with `not-negotiated` -- or, through gscam, with
**"Failed to PAUSE stream, check your gstreamer configuration"**, which sends
you to look at the gscam config, the camera YAML and the encoder, none of which
are wrong.

**It cannot test the capture change above, on any machine.** v4l2loopback has no
dmabuf support -- not a version gap, the module exposes no dmabuf parameter and
the `.ko` contains no dmabuf code -- and `nvv4l2camerasrc` accepts only
`V4L2_MEMORY_DMABUF` in importer role. Verified 2026-08-20.

**Nor can an x86 box stand in.** `nvvidconv` and `nvv4l2camerasrc` are L4T-only
with no x86 build. DeepStream would supply `nvvideoconvert` on a dGPU, but its
sink caps there omit UYVY, which is our input format, and gst-plugins-bad's
`cudaconvert` omits it too (checked: I420, NV12, P010, RGBA and friends, no
4:2:2 at all). The memory types differ as well, `memory:CUDAMemory` against
`memory:NVMM`. Underneath that the architectures differ in the way that matters:
VIC and NVJPG are fixed-function blocks sharing physical memory with the CPU,
where a dGPU crosses PCIe both ways. A green result on x86 would not transfer.

So the split is: everything ROS-side anywhere, encoder caps and capacity on the
Advantech with no cameras, and only `nvv4l2camerasrc` plus the end-to-end CPU
delta needing real hardware.

Tasks:

- [x] Run `just sim cameras-bench`. Capacity answered above; the recipe itself
      was rewritten to stop reporting a startup artefact as a verdict.
- [x] Land the probe in `scripts/check/` so it is repeatable, not a one-off:
      `scripts/check/camera_pipeline.sh`. Records L4T and DeepStream versions,
      element availability, `nvjpegenc`/`nvvidconv`/`nvv4l2camerasrc` caps, runs
      the negotiation with `videotestsrc`, and -- when a `/dev/video*` exists --
      runs `v4l2src` and `nvv4l2camerasrc` against it and says which cleared.
- [ ] Run the probe on the Advantech **with the cameras attached**. That is the
      one remaining unknown: everything else in this sub-phase is now measured.
- [x] Make the capture path switchable without editing a tracked file:
      `camera_capture/<profile>.yaml`, selected by `CAMERA_CAPTURE_PROFILE`.
      Four profiles, one variable, and nothing downstream of the source element
      changes between them. See sub-phase B.
- [ ] On the vehicle, walk the ladder and set the winner:
      `CAMERA_CAPTURE_PROFILE=nvv4l2camerasrc`, falling back to `v4l2-dmabuf`
      then `v4l2-mmap`. `scripts/check/camera_pipeline.sh` does the walking.
- [ ] Rewrite `config/gscam.md` against what the YAMLs actually carry.

CPU, for the before number the acceptance criterion asks for. Three streams of
`videotestsrc ! nvvidconv ! NV12(NVMM) ! nvjpegenc` at 30 fps measured ~180% of
one core total, of which ~96% is `videotestsrc` itself generating UYVY. So the
encode-and-convert stage is roughly **0.85 of a core for three cameras** with a
system-memory source. That is the number `nvv4l2camerasrc` has to beat, and the
`v4l2src` import copy it removes is 147 MB/s per camera.

**DeepStream is deliberately not in this plan.** DeepStream 7.1 is installed
(`/opt/nvidia/deepstream/deepstream-7.1`, package `deepstream-7.1 7.1.0-1`) and
its `nvvideoconvert` is the element it contributes here -- verified on this
install to list `UYVY` in its NVMM sink caps, so it would work. It buys nothing: `nvvidconv` already does this conversion on the
same VIC hardware, and DeepStream's real asset is `nvstreammux` batching for
`nvinfer`, which this pipeline has no use for. Revisit when perception runs on
these cameras.

Acceptance: three cameras streaming, aggregate CPU for the capture-and-encode
stage measured before and after, both numbers written down.

---

## Sub-phase B - who publishes the format string

**Decided 2026-08-21: gscam stays, and gmslcam is dropped from this plan.**

gscam is an upstream deb and writes the bare `"jpeg"`. Confirmed live against
three v4l2loopback devices carrying UYVY at the real geometry, with the real
`nvvidconv ! NV12(NVMM) ! nvjpegenc quality=90` behind it:

```console
$ ros2 topic echo --field format /sensing/camera/left/image_raw/compressed --once
jpeg
$ ros2 topic hz /sensing/camera/left/image_raw/compressed
average rate: 30.017
```

And the crate reads it, which is the half that had to be proved:

```text
#0 format="jpeg" -> codec Jpeg, target None; decoded 1920x1280x1 mono8 in 6914 us
CameraInfo paired: 1920x1280, 12 distortion coefficients (rational_polynomial)
```

The earlier recommendation was "accept the bare form now, move to gmslcam when A
is settled". The move is now off the table, and the reasons it looked attractive
have each been dealt with in gscam instead:

| what gmslcam was for | how it stands now |
|---|---|
| we would own the publisher and emit the compound string | gmslcam's `compressed_format()` writes the bare `"jpeg"` too. The move did not buy the compound string; it bought the *option* to patch one. |
| `appsink max-buffers=2 drop=true`, the fix for gscam's stall | a `queue leaky=downstream max-size-buffers=2` at the tail of `gscam_config`, immediately before gscam's appsink. Same effect from the outside: a wedged sink costs frames instead of back-pressuring NVJPG and the camera. Verified running at 30 Hz. |
| it publishes `CameraInfo` | so does gscam, at frame rate. Blocker 1. |

So the bare form is the format this project publishes, permanently, and the
crate's channel-count fallback is not a compatibility shim for old bags: it is
the main path. That is fine. What the bare form costs is that the wire never
states channel order, and every consumer infers it from the channel count. For
JPEG out of `nvjpegenc` that inference is right, and the fixtures pin it.

If the compound string is ever wanted, the cheapest route is no longer a new
publisher: it is `image_transport`'s own `republish`, or a patch to gscam. Not
worth doing for its own sake.

### Capture profiles

The capture path is the one part of this pipeline that cannot be settled without
the vehicle, so it is now a **profile**, switched by environment variable at
deploy time with no edit to a tracked file:

```bash
CAMERA_CAPTURE_PROFILE=nvv4l2camerasrc just launch
```

`golfcart_sensor_kit_launch/config/camera_capture/`:

| profile | source | status |
|---|---|---|
| `v4l2-dmabuf` | `v4l2src io-mode=4` | **default**, what shipped before profiles |
| `nvv4l2camerasrc` | `nvv4l2camerasrc` | the zero-copy target, unverified against oToCam |
| `v4l2-mmap` | `v4l2src io-mode=2` | copies on purpose, to keep "camera dead" and "dmabuf dead" separable |
| `sim` | `v4l2src` on v4l2loopback | no hardware; pairs with `just sim cameras` |

`camera.launch.xml` loads `camera_<cam>.yaml` and then the profile, so the
profile supplies `gscam_config`. Each profile carries all three cameras keyed by
node name (`/**/camera_left:`), which is one file per profile rather than three.
The device paths moved into the profile; they used to be declared in
`camera.launch.xml` as `left_camera_device` and friends, read by nothing, while
the real paths sat inside the `gscam_config` strings.

Exercised end to end on an AGX Orin with no cameras attached, through the real
launch file:

```console
$ CAMERA_CAPTURE_PROFILE=sim ros2 launch golfcart_sensor_kit_launch camera.launch.xml camera_model:=gscam
left  30.008 Hz    right 30.019 Hz    rear  30.031 Hz
camera_info 29.978 Hz    format "jpeg"
```

**Three gscam nodes cost 29.2% of one core** in that configuration -- capture,
VIC, NVJPG and publish, for three 1920x1280 streams at 30 fps. That is the
"before" number sub-phase A's acceptance criterion asks for, taken with a
loopback source; a real V4L2 capture adds to the capture end and nothing else.

`scripts/check/camera_pipeline.sh` reads each profile's pipeline out of its YAML
and runs it: against the profile's own device when it exists, and otherwise
against a loopback device as a shape check, saying which it did. On the vehicle
it walks the ladder and names the profile to set.

Still true, and still worth not finding out the hard way: do not run `nvjpegenc`
and `nvv4l2h26xenc` in one process; there is a reported freeze on AGX Orin.

---

## Sub-phase C - the rclrs image transport crate

**Implemented.** `src/common/rclrs_image_transport/`, as two crates:

| crate | ROS deps | holds |
|---|---|---|
| `image_transport_codec` (`codec/`) | none | the format contract, decode, encode |
| `rclrs_image_transport` | rclrs, sensor_msgs, std_msgs | transport hints, image and camera subscriptions, `image_transport_echo` |

The split is not tidiness. The message crates do not exist on crates.io --
colcon-cargo-ros2 substitutes generated bindings through `[patch.crates-io]` at
build time -- so a crate that names them **cannot resolve a lock file outside an
ament workspace**, and cannot be tested with plain `cargo test`. Splitting the
contract out means the part that has to be exactly right is testable anywhere:

```console
cd src/common/rclrs_image_transport && cargo test --manifest-path codec/Cargo.toml
```

Still destined for **its own repository under NEWSLabNTU**, added back here as a
submodule. It is in-tree for now because nothing about it is golf-cart specific
except its current address, and moving it once it has settled costs a `git mv`
and a dependency line.

One thing consumers have to know: **the detector depends on it by path, not by
`"*"`.** colcon-cargo-ros2 generates `[patch.crates-io]` entries only for
interface packages, from their generated bindings. A plain Rust library package
gets no patch, so `"*"` resolves against the real crates.io and fails on a name
that is not there. `package.xml` still declares the dependency, which is what
orders the build.

### C1 - codec core

- [x] `format` parsing: compound form, bare form, and the channel-count
      fallback. Case sensitive and substring-matched, because the C++ subscriber
      greps rather than tokenises, and a Rust node that reads *more* formats than
      its C++ counterpart is a divergence waiting to be found in the field.
- [x] `format` construction, refusing to emit a colour target that is not the
      literal `bgr8`. `CompressedFormat::new` returns
      `FormatError::DishonestColourTarget` for anything else, and the two
      constructors a caller actually uses -- `jpeg_colour`, `jpeg_mono` -- cannot
      express the wrong thing at all.
- [x] Channel-order revert, the trap added to the contract section above.
- [x] Decode via `turbojpeg` (libjpeg-turbo), with grayscale and DCT-scaled
      decode at 1/2, 1/4, 1/8.
- [x] Encode path, for fixtures and tests. Not on the vehicle's critical path.
- [x] PNG and TIFF parsed and refused by name; 16-bit and four-channel colour
      likewise, rather than silently returning three 8-bit channels under a
      label that promises otherwise.

**The performance rationale written here originally does not survive
measurement, and is worth correcting rather than deleting.** One 1920x1280
quality-90 frame on this AGX Orin:

| path | ms |
|---|---|
| `turbojpeg` gray, full | 5.3 |
| `turbojpeg` BGR, full | 9.1 |
| `turbojpeg` gray, 1/2 | 3.1 |
| `turbojpeg` gray, 1/4 | 2.9 |
| OpenCV `imdecode(IMREAD_GRAYSCALE)` | 4.9 |
| OpenCV `imdecode(IMREAD_COLOR)` | 12.6 |

OpenCV's `IMREAD_GRAYSCALE` already decodes grayscale directly -- it is not
"a full colour decode thrown away", and it is if anything a shade faster than
turbojpeg. OpenCV even exposes `IMREAD_REDUCED_GRAYSCALE_2` at 3.3 ms. So the
crate does not buy decode speed. What it buys, and what the claim should have
been:

- the format contract, which `imdecode` knows nothing about;
- one fewer OpenCV feature to link (`imgcodecs` is gone from the detector);
- scaled decode expressed as a parameter rather than a different call;
- and a decode path that does not require OpenCV at all, which matters for the
  next Rust node that needs images and does not otherwise want it.

`turbojpeg-sys` builds libjpeg-turbo from source and links it statically -- the
system has `libturbojpeg.so.0` and no `-dev` package -- so the build is the same
on every host rather than depending on what apt happens to carry.

### C2 - the subscriber API

- [x] Transport-hint indirection: `Transport::from_hint("raw"|"compressed")`,
      topic naming `<base>/<transport>`, one call that subscribes to whichever.
      A node changes transport by parameter and its code does not move.
- [x] `subscribe_camera`, the `CameraSubscriber` equivalent: time-syncs
      `<base>/camera_info` against the image and hands the callback both. Two
      policies, because the C++ one has only the strict half: `InfoPolicy::Latest`
      (default -- correct for a fixed camera, and it survives a driver that
      publishes intrinsics once at startup) and `InfoPolicy::ExactStamp`
      (matches C++ `CameraSubscriber`, and silently drops frames otherwise).
- [x] `Frame` carries the parsed source format and the decode time, so a node
      can log what a topic is actually publishing without anyone running
      `ros2 topic echo --field format`.

### C3 - scope boundaries, written down so they are not re-litigated

- **No H.264/H.265 in `CompressedImage`.** If video codecs are wanted later the
  ecosystem answer is `ffmpeg_image_transport`, which uses its own
  `FFMPEGPacket` message precisely because `CompressedImage` is the wrong
  container. (Note it is **not** installed on this box -- the plugins present are
  `compressed`, `compressedDepth`, `raw`, `theora`.)
- **`compressedDepth` is a separate transport**, with a binary header prefixed to
  a PNG payload. If depth images appear it needs its own path, not a `format`
  string variant.
- **PNG and TIFF**: parse and reject with a clear message. Done.

### Acceptance - met

Round-trip tests against fixtures produced by the **C++**
`compressed_image_transport`, both directions, plus the bare `"jpeg"` case.
19 tests, all green: 11 unit tests on the contract, 8 integration tests reading
bytes the C++ plugin wrote.

Run live as well, which is the half a fixture cannot cover -- C++ publisher, ROS
graph, Rust subscriber:

```console
ros2 run image_transport republish raw compressed \
  --ros-args -r in:=/probe/image_raw -r out/compressed:=/probe/out/image_raw/compressed
ros2 run rclrs_image_transport image_transport_echo \
  --ros-args -p base_topic:=/probe/out/image_raw -p with_camera_info:=true
```

```text
#0 format="bgr8; jpeg compressed bgr8" -> codec Jpeg, target Some(Colour);
   decoded 1920x1280x1 mono8 in 4632 us
CameraInfo paired: 1920x1280, 5 distortion coefficients (plumb_bob)
```

`image_transport_echo` is a keeper, not scaffolding: it is the tool that answers
"what is on this camera topic, can we decode it, and how long does it take"
against a real camera, and it is what will settle blocker 1 on the master.

---

## Sub-phase D - migrate the ArUco detector

**Written, not yet compiled.** Blocker 1 still stands and is unrelated to the
code change.

- [x] Replaced the hand-rolled `CompressedImage` subscription and the
      `imdecode(IMREAD_GRAYSCALE)` call with `subscribe_image`. Both transports
      now go through one call and one code path; `image_to_mat` and
      `compressed_to_mat` are gone, and what is left is `as_gray_mat`, which
      borrows the decoded buffer into a `Mat` without copying.
- [x] Grayscale decode path (`Target::Mono`), so a colour JPEG never has its
      chroma reconstructed.
- [x] `use_compressed: bool` became `image_transport: "raw"|"compressed"`, the
      spelling `image_transport` uses. Default unchanged in behaviour.
- [x] Dropped the `opencv` `imgcodecs` feature.
- [ ] Evaluate scaled decode for detection with full-res corner refinement.
      Available (`Scale::Half` and friends) and deliberately not switched on:
      it trades corner precision for CPU, corner precision is pose accuracy, and
      that is a measurement, not a default.

**A bug found on the way, fixed here.** `aruco_detector.launch.xml` remapped
`~/input/image` only. ROS 2 remapping matches a whole topic name, so it does not
carry `~/input/image/compressed` with it -- a detector launched through that file
on its default transport subscribed to its own private
`<node>/input/image/compressed` and sat silent forever, looking exactly like a
camera that sees nothing. Both remaps are now present.
(`aruco_localization.launch.xml`, which is what the indoor runs use, already
remapped the compressed topic and was never affected.)

**Not compiled on the development Orin, and this is not a soft "untested".** The
package needs OpenCV's `aruco` contrib module; the L4T OpenCV 4.8.0 on this box
has no contrib modules at all, so `golfcart_aruco_detector` cannot build here
regardless of these edits. It has to be built on a machine that has them before
this box is ticked. `rclrs_image_transport` itself does build here, cleanly, and
its `image_transport_echo` binary exercises the same API the detector now calls.

Acceptance: detection rate and pose residuals unchanged against a recorded bag,
CPU down. Unchanged is the bar; this is a refactor, not a tuning opportunity.

---

## Sub-phase E - verification

- [x] **The bare form reads, off a real gscam publisher.** `image_transport_echo`
      against gscam on three synthetic devices, hardware-encoded JPEG at 30 Hz,
      decoded to `mono8` in ~5.8 ms a frame. That is the same code path a bag
      replay takes, and it is also a test (`gscams_bare_form_survives_a_real_payload`).
- [ ] Existing bags replay through the new consumers. The fallback is proved;
      what is not is that a specific recorded bag plays back through the
      migrated detector. Needs a bag and a machine that can build the detector.
- [x] **A C++ subscriber reads what we publish.** `image_transport republish
      compressed raw` against a live gscam topic on the sim profile produced
      `bgr8` 1920x1280 raw images at 22 Hz (the republisher's own decode rate,
      not ours). That exercises the same channel-count fallback our Rust crate
      takes, from the C++ side, on our own bare `"jpeg"` -- a stronger check
      than looking at `rqt_image_view`, and one that runs without a display.
- [ ] RViz displays all three cameras. Cosmetic next to the line above; needs a
      display, so it belongs on the vehicle.
- [ ] Aggregate CPU on the master, before and after the whole phase, under three
      cameras plus both LiDARs. This phase exists because that number is at its
      ceiling; it is the only end-to-end measure of whether it worked.

---

## Open questions

- **Grayscale JPEG at the source.** The only current consumer decodes to
  grayscale, so encoding mono would cut bytes and both encode and decode cost by
  roughly a third, and the format string becomes
  `"mono8; jpeg compressed mono8"`. The cost is that bags stop being colour,
  which matters for human review and any future perception. A real trade, and a
  per-camera one: the ArUco cameras and a future front camera need not agree.

  **One new fact against it**, from the probe: `nvjpegenc` accepts `GRAY8` in
  **system memory only** -- its NVMM sink caps are `{I420, NV12}`. So a mono
  JPEG at the source would have to leave NVMM and hand back the very import copy
  sub-phase A exists to remove. Measured decode saving on the other end is
  smaller than the original estimate too: 5.3 ms grayscale against 9.1 ms
  colour, and the detector already decodes grayscale from a colour JPEG. This
  looks like a trade that no longer pays.
- **UYVY is 4:2:2 and NV12 is 4:2:0.** Half the vertical chroma is discarded
  before JPEG sees it, unavoidably, on the NVJPG path. Irrelevant to grayscale
  consumers. Worth knowing before anyone builds a colour-critical feature on
  these cameras.
- **Which host runs future camera consumers.** Everything above assumes cameras
  and consumers share the Advantech, which is true today. A cross-host consumer
  changes nothing about the format but makes the bandwidth argument load-bearing
  rather than incidental.
- **When a second consumer appears**, the answer is not a second decode. It is
  one decode-and-fan-out component per camera inside a container, raw
  intra-process to everything in it. Compressed across process boundaries, raw
  only inside one. Not worth building at N=1.
