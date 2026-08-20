# Phase 4 - Camera image pipeline (master)

Get the three GMSL cameras onto a wire format that is hardware-encoded at the
source, decodable by every consumer, and described by a contract that a Rust
node and a C++ node read the same way.

Last updated: 2026-08-20 (decision made, nothing implemented)

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

Two traps this encodes, both of which the crate must enforce:

- **The target field must be the literal `bgr8` for colour.** Not because the
  bytes are BGR, but because that substring is what the subscriber greps for to
  decide whether to swap channels. `"rgb8; jpeg compressed rgb8"` looks more
  honest and is silently wrong: no swap is applied, BGR pixels get labelled
  `rgb8`, and red and blue transpose with no warning.
- **The bare form is legal and we already produce it.** gscam writes plain
  `"jpeg"`. Every bag recorded so far contains it. The crate must implement the
  channel-count fallback or it cannot replay our own data.

---

## Blockers to clear before anything below is worth doing

| # | Blocker | Blocks | Status |
|---|---|---|---|
| 1 | **`camera_info` may never reach the detector.** `config/recording/master_topics.txt` states "gscam publishes none for these". But gscam holds a `CameraInfo` publisher on `camera/camera_info`, uses `camera_info_manager`, `camera_info_url` is set in all three YAMLs, `camera_left_calibration.yaml` is a real calibration, and `camera.launch.xml` remaps it. Those cannot all be true. The detector blocks until `CameraInfo` arrives and logs "images arriving but no CameraInfo yet". If the recording comment is right, ArUco detection has **never had intrinsics**. | D, and every indoor run | **Unverified.** One `ros2 topic list` on the master settles it. |
| 2 | **All three calibration files are one calibration copied three times.** Verified by diff on 2026-08-20: byte-identical apart from `camera_name`. The intrinsics are real, not placeholders, which makes this worse rather than better -- a plausible matrix on the wrong lens yields plausible poses that are wrong. Also `cx` is 712 on a 1920-wide image, about 248 px off centre. See [3-indoor-a](3-indoor-a-camera-calibration.md). | D | Confirmed, unfixed |
| 3 | **`nvv4l2camerasrc` binding to the oToCam driver is unverified.** It is verified by NVIDIA against their own V4L2 driver; oToCam is a vendor `nv_imx390.ko` behind a MAX9296. | A | `scripts/check/` probe drafted, not run |
| 4 | **`nvjpegenc` NVMM sink caps unverified on this install.** Decides whether today's pipeline is hardware or a silent software fallback: the hardware JPEG encoder needs a dmabuf fd. | A | Same probe |
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

Tasks:

- [ ] Run the probe on the Advantech. Records JetPack and DeepStream versions,
      element availability, `nvjpegenc` and `nvvidconv` caps, and benchmarks
      `v4l2src` against `nvv4l2camerasrc` on all three cameras at once.
- [ ] If B negotiates, change `gscam_config` in the three `camera_*.yaml`. One
      line each, no new package, isolates the variable.
- [ ] Land the probe in `scripts/check/` so it is repeatable, not a one-off.
- [ ] Rewrite `config/gscam.md` against what the YAMLs actually carry.

**DeepStream is deliberately not in this plan.** DeepStream 7.1 ships with
JetPack 6.2 and its `nvvideoconvert` does document UYVY sink caps on Jetson, so
it would work. It buys nothing: `nvvidconv` already does this conversion on the
same VIC hardware, and DeepStream's real asset is `nvstreammux` batching for
`nvinfer`, which this pipeline has no use for. Revisit when perception runs on
these cameras.

Acceptance: three cameras streaming, aggregate CPU for the capture-and-encode
stage measured before and after, both numbers written down.

---

## Sub-phase B - who publishes the format string

gscam is an upstream deb and writes the bare `"jpeg"`. We cannot change that
without forking it. So B is a fork in the road, not a task list:

| option | cost | consequence |
|---|---|---|
| **Accept the bare form** | zero | The crate's fallback carries it. Works, but the wire never says whether pixels are BGR or RGB, and every consumer guesses by channel count. |
| **Move to gmslcam** with `codec: jpeg` | port + validate | We own the publisher and emit the compound string. Also picks up `appsink max-buffers=2 drop=true`, which is the documented fix for gscam's permanent stall. |

Recommendation is **accept the bare form now, move to gmslcam when A is
settled**. The crate has to implement the fallback either way, so nothing is
wasted, and A's measurement is cleaner with one variable changing at a time.

Note for the gmslcam move: **its default codec is `h265`**, which `imdecode`
cannot read and which would break the ArUco detector and every recorded bag.
`codec: jpeg` is supported (`nvjpegenc` + `jpegparse`) and is not the default.

Also do not run `nvjpegenc` and `nvv4l2h26xenc` in one process; there is a
reported freeze on AGX Orin.

---

## Sub-phase C - the rclrs image transport crate

Home: **its own repository under NEWSLabNTU**, added here as a submodule, the
same shape as `gmslcam`. It is general rclrs toolchain, not golf-cart code, and
the stated aim is to complete that toolchain.

The reason this crate has to exist at all: `image_transport` is a C++ pluginlib
system. rclrs cannot join it, and it has no intra-process comms either. So the
Rust side must own both the codec and the camera-info pairing.

### C1 - codec core

- [ ] `format` parsing: compound form, bare form, and the channel-count fallback,
      matching the C++ subscriber's behaviour exactly.
- [ ] `format` construction, refusing to emit a colour target that is not the
      literal `bgr8`. Make the silently-swapped-channels case a compile-time or
      constructor-time error, not a runtime surprise.
- [ ] Decode via `turbojpeg` (libjpeg-turbo). Chosen over OpenCV and the
      pure-Rust decoders for two capabilities the C++ `image_transport` does not
      expose:
      - **grayscale decode** that skips chroma reconstruction entirely, which is
        what the ArUco detector wants and today pays a full colour decode to
        throw away;
      - **DCT-scaled decode** at 1/2, 1/4, 1/8 for a fraction of full cost.
        Half-res detect then full-res refine is a standard marker trick and this
        makes it nearly free.
- [ ] Encode path, for completeness and for tests. Not on the vehicle's critical
      path: the camera encodes in hardware.

`zune-jpeg` is the fallback if a C dependency becomes unacceptable. It is fast
and pure Rust but has no scaled decode, which gives up the main reason for the
choice.

### C2 - the subscriber API

- [ ] Transport-hint indirection, so a node picks `raw` or `compressed` without
      its own code changing. This is the part of the convention worth copying.
- [ ] A `CameraSubscriber` equivalent: time-syncs `<base>/camera_info` against
      the image and hands the callback both. **This is what the ArUco detector
      hand-rolls today.**
- [ ] Topic naming `<base>/<transport>`, matching `image_raw/compressed`.

### C3 - scope boundaries, written down so they are not re-litigated

- **No H.264/H.265 in `CompressedImage`.** If video codecs are wanted later the
  ecosystem answer is `ffmpeg_image_transport`, already installed on our Humble,
  which uses its own `FFMPEGPacket` message precisely because `CompressedImage`
  is the wrong container.
- **`compressedDepth` is a separate transport**, with a binary header prefixed to
  a PNG payload. If depth images appear it needs its own path, not a `format`
  string variant.
- **PNG and TIFF**: parse and reject with a clear message. Do not implement.

Acceptance: round-trip tests against fixtures produced by the **C++**
`compressed_image_transport`, both directions, plus a fixture carrying gscam's
bare `"jpeg"`. A Rust publisher must be readable by a C++ subscriber and vice
versa, or the crate has not done its job.

---

## Sub-phase D - migrate the ArUco detector

Blocked on C2 and on blocker 1.

- [ ] Replace the hand-rolled `CompressedImage` subscription and the
      `imdecode(IMREAD_GRAYSCALE)` call with the crate's camera subscriber.
- [ ] Take the grayscale decode path rather than decoding colour and discarding
      it.
- [ ] Evaluate scaled decode for detection with full-res corner refinement.
      Measure before adopting: it trades corner precision for CPU, and corner
      precision is pose accuracy here.
- [ ] Drop the `opencv` `imgcodecs` feature if nothing else needs it.

Acceptance: detection rate and pose residuals unchanged against a recorded bag,
CPU down. Unchanged is the bar; this is a refactor, not a tuning opportunity.

---

## Sub-phase E - verification

- [ ] Existing bags replay through the new consumers. This is what the bare-form
      fallback is for, and it should be a test, not a hope.
- [ ] `rqt_image_view` and RViz still display all three cameras. If a C++ tool
      cannot read what we publish, the contract is wrong regardless of what the
      tests say.
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
