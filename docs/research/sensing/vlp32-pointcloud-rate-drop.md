# Why `/sensing/lidar/vlp32/pointcloud` records at 9.5 Hz

**Measured**: 2026-09-24 on the Advantech, `just launch-all` (both hosts,
`pointcloud_backend:=cuda`, TX off), recorded with `just record start` for 20 s:
bag `master_20260924_122343`. Live probes against the same running stack
followed.

**Investigates**: in that bag, `/sensing/lidar/vlp32/pointcloud` held 155
messages, 9.54 Hz, against 167 for the raw `velodyne_points`, 10.00 Hz.

Answer up front: **nothing in the pipeline loses a scan.** The preprocessor and
the concatenator pass every VLP scan, and a lightweight live subscriber receives
every `vlp32/pointcloud` message. The loss is **at the recorder**, on that one
topic. Why the recorder drops it and not the other clouds is open.

A first reading of the same data blamed the concatenator's `timeout_sec`. That
reading was wrong, and it is kept below (under *The explanation that was wrong*)
because the numbers behind it look convincing.

| Claim | Evidence | Confidence |
|---|---|---|
| Preprocessor loses nothing | `velodyne_points` 10.010 Hz in, `pointcloud_before_sync` 10.007 Hz out | established |
| Concatenator pairs almost every scan | its diagnostics: both inputs present in 200 of 201 concatenations | established |
| `vlp32/pointcloud` reaches a light subscriber intact | 229 received, 229 `pointcloud_before_sync` inputs over the same 22.8 s | established |
| The bag lost 7 of 161 mid-stream scans on this topic only | stamp gaps: 7 on `vlp32/pointcloud`, 0 on `velodyne_points`, `velodyne_packets`, `falcon/iv_points` | established |
| Why the recorder drops this topic | — | **open** |

---

## What the topic is

`/sensing/lidar/vlp32/pointcloud` is **not** the preprocessor's output. It is
published by `/sensing/lidar/concatenate_data`, the CUDA concatenator, as its
per-LiDAR synchronized copy:

```yaml
# golfcart_sensor_kit_launch/config/concatenate_and_time_sync_node.param.yaml
publish_synchronized_pointcloud: true
keep_input_frame_in_synchronized_pointcloud: true
synchronized_pointcloud_postfix: pointcloud
```

The preprocessor publishes `pointcloud_before_sync`. So the chain is
`velodyne_points` → CUDA preprocessor → `pointcloud_before_sync` → concatenator
→ `concatenated/pointcloud` plus `vlp32/pointcloud` and `falcon/pointcloud`. The
two synchronized copies keep their own sensor's frame and stamp, not the
concatenated stamp.

## Stage by stage

Live, all stages measured at once:

| Stage | Rate | Source |
|---|---|---|
| `vlp32/velodyne_points` (driver) | 10.010 Hz | `ros2 topic hz` |
| `vlp32/pointcloud_before_sync` (preprocessor) | 10.007 Hz | `ros2 topic hz` |
| `falcon/iv_points` (driver) | 10.010 Hz | `ros2 topic hz` |
| concatenations | 10.26 Hz, 234 in 22.8 s | concatenator diagnostics |
| `concatenated/pointcloud` received | 234 of 234 | `raw=True` subscriber |
| `vlp32/pointcloud` received | 229, same count as its input | `raw=True` subscriber |

The concatenator runs slightly **above** 10 Hz. It publishes a handful of
single-sensor frames on top of the paired ones: the diagnostics showed one
concatenation in 201 without the Falcon and one without the VLP. That is about
1 %, and it is not the loss this note is about.

## Where the loss is: the recorder, one topic

Header-stamp gaps in the bag, at a 100 ms period:

| Topic | Messages | Missing stamps |
|---|---|---|
| `vlp32/velodyne_points` | 167 | 0 |
| `vlp32/velodyne_packets` | 167 | 0 |
| `falcon/iv_points` | 166 | 0 |
| `vlp32/pointcloud` | 155 | **7** |

The missing ones are spread through the run (raw indices 37, 51, 102, 110, 127,
129, 152), not bunched at start or stop. Five more fall at the bag's edges,
where the recorder is still subscribing or already stopping; those are normal.

What is different about this topic, for whoever picks the open question up:

- **Its publisher bursts.** The concatenator publishes `concatenated/pointcloud`
  (about 2.2 MB), `falcon/pointcloud` (1.5 MB) and `vlp32/pointcloud` (0.8 MB)
  from one process at essentially the same instant. The recorder subscribes to
  the middle-sized one. Each driver cloud, by contrast, is published alone.
- **The machine was saturated.** Load average about 57 on 12 cores, 33 % of CPU
  time in the kernel. The recorder shares that CPU with everything else.
- **The DDS buffers are not small.** `config/cyclonedds/master.xml` already sets
  16 MB receive and send socket buffers, and `net.core.rmem_max` allows them. So
  a plain socket overflow is not the obvious answer.

Untested: a recording with the synchronized outputs turned off, or with a lighter
stack (see *CPU* below), would show whether the drop follows the burst or the
load.

## The explanation that was wrong

Read from the bag and from `ros2 topic hz` alone, the data told a consistent
story:

- `ros2 topic hz` put `vlp32/pointcloud` at 9.34 Hz, `falcon/pointcloud` at
  9.28 Hz and `concatenated/pointcloud` at 10.245 Hz. That looks like the
  concatenator failing to pair scans and publishing each alone.
- From the bag's receive times, the Falcon arrived a median 36 ms after the
  preprocessed VLP, with a tail near 100 ms. The concatenator waits
  `timeout_sec: 0.05` for the second scan, and the comment above that parameter
  asks for exactly this measurement: *"it assumes the two sensors arrive within
  50 ms of each other. Measure that offset on the cart and raise this if it is
  larger."*

So the conclusion was: pairs split when the Falcon is late, so raise
`timeout_sec` to about 0.08. The concatenator's own diagnostics refute it: 200
of 201 concatenations contained both sensors. Two things misled:

- **`ros2 topic hz` is not a rate meter for large clouds on a loaded host.** It
  is Python and decodes every message, so it falls behind and drops messages
  itself. It read 9.34 Hz on a topic a `raw=True` subscriber received at full
  rate. The 10.245 Hz on `concatenated/pointcloud` was real; the other two
  readings were the tool.
- **Arrival times taken from the bag are the recorder's receive times.** The
  recorder is on the same saturated CPU, so the gap between two topics'
  receive times measures the recorder as much as the sensors. That estimate
  predicted about 30 % of pairs splitting; the diagnostics show about 1 %.

`timeout_sec` stays at 0.05. The 2026-08-28 sweep in
[lidar-pipeline-starvation.md](lidar-pipeline-starvation.md#the-window-was-the-suspect-and-it-was-wrong)
already showed that raising it adds waiting on a moving vehicle without fixing
the Velodyne, under a different fault.

## Measured along the way

These numbers are sound, whatever the drop turns out to be.

**Timing**

| Quantity | p50 | p95 | max |
|---|---|---|---|
| Preprocessor `processing_time_ms` | 17.5 ms | 60.9 ms | 80.5 ms |
| Preprocessor `latency_ms`, stamp to output | 124.1 ms | 184.5 ms | 211.3 ms |
| Concatenator pipeline latency, VLP input | 194.4 ms | 266.1 ms | 383.2 ms |
| Falcon stamp minus nearest VLP stamp | 12.1 ms | 17.2 ms (p5 −19.3) | — |

Two readings of that table:

- A CUDA preprocess with a 60 ms p95 is waiting for CPU, not computing. On a
  quiet host it should take single-digit milliseconds.
- The two LiDARs are free-running but stay within ±25 ms of each other, well
  inside the matcher's `lidar_timestamp_noise_window: [0.1, 0.1]`.

**CPU**, same stack: all 12 cores about 80 % busy, a third of it kernel time;
GPU 46–67 % busy but clocked at 305 MHz. The two biggest user-space consumers
were not the stack:

- `golfcart_system_monitor` (Python, 56 % CPU) subscribes to both raw clouds,
  the concatenated cloud and all three cameras, about 96 MB/s. It decodes every
  message fully (a plain `create_subscription`, not `raw=True`) only to count
  its rate.
- RViz (57 % CPU) pulls the raw Falcon and VLP clouds and all three cameras,
  about 75 MB/s.

**Traffic nobody reads**: `vlp32/pointcloud` and `falcon/pointcloud` together
are about 20 MB/s of publishing whose only reader is the recorder.

## What to do with it

1. **Stop recording `vlp32/pointcloud`.** It is derived output of the
   concatenator, which the recording list's own rule says not to record. A
   logging-simulation replay regenerates it. It is 120 MB per 20 s in this bag,
   and it is the one topic the recorder drops. The raw cloud that replay
   actually needs recorded without a gap.
2. **Consider `publish_synchronized_pointcloud: false`** to drop the 20 MB/s of
   copies, if nothing depends on the per-LiDAR debug output.
3. **Take the load off**: rate counting without decoding in
   `golfcart_system_monitor`, and RViz off or with its raw displays disabled
   when not looking. That is the likeliest lever on the preprocessor's p95.
4. **Measure cloud rates with the concatenator's diagnostics or a `raw=True`
   subscriber**, not `ros2 topic hz`.

## How it was measured

- **Bag**: header stamps read straight from each message's CDR bytes (int32
  seconds and uint32 nanoseconds after the 4-byte encapsulation header) in the
  bag's sqlite `messages` table, matched between topics by exact stamp.
- **Concatenator diagnostics**: the `concatenate_data` status on
  `/diagnostics`: the `Concatenated: <topic>` flags and the `Concatenated
  pointcloud timestamp` field, over 20–25 s.
- **Delivery check**: an rclpy node with `raw=True` subscriptions at
  `qos_profile_sensor_data`, pulling the stamp from the raw bytes, so it does no
  decoding and keeps up.
