# Why NDT and RViz both see a partial point cloud

**Measured**: 2026-08-25, two `just launch` runs on the Advantech, from the
play_launch bundles `2026-08-25_16-45-52` (isolated) and `2026-08-25_17-33-40`
(observable). Both runs saw the same LiDAR behaviour, so nothing here is an
artifact of the container-mode change being tested that afternoon.

**Investigates**: the two rate observations left open in
[roadblocks.md](../../roadblocks.md#sensor-status-observed-2026-08-10), plus the
symptom that the point cloud is partially missing in RViz.

Answer up front: these are **two unrelated faults** that happen to produce the
same complaint.

| | Symptom | Cause | Confidence |
|---|---|---|---|
| **A** | RViz shows no Velodyne at all | a RELIABLE subscriber cannot match the BEST_EFFORT publisher, so it receives nothing | established |
| **B** | NDT gets ~4 Hz of cloud, half of it Falcon-only | the concatenator's 200 ms window rejects most Velodyne scans | strong, one measurement short of proof |

Fixing A does nothing for B and vice versa.

---

## A. The Velodyne display is empty, not sparse

The driver says so directly, three times in the observable run:

```
[WARN] [sensing.lidar.vlp32.velodyne_ros_wrapper_node]: New subscription
discovered on topic '/sensing/lidar/vlp32/velodyne_points', requesting
incompatible QoS. No messages will be sent to it.
Last incompatible policy: RELIABILITY_QOS_POLICY
```

"No messages will be sent to it" is literal. A RELIABLE subscriber cannot match
a BEST_EFFORT publisher: DDS treats the subscriber's request as a demand the
publisher cannot honour, so the two never connect. This is not degradation, it
is silence, and nothing else in the system reports it. The same trap was
recorded in phase 4-O when the diagnostic-graph status topic turned out to be
BEST_EFFORT.

Timing places the blame:

| t (run-relative) | event |
|---|---|
| +7.2 s | driver starts, warning #1 |
| +114.3 s | rviz2 starts (`Stereo is NOT SUPPORTED`, OpenGL 4.6) |
| +114.8 s | warning #2 |
| +143.1 s | warning #3 |

Warnings 2 and 3 bracket RViz coming up and a display being switched on shortly
after. The isolated run shows one such warning and no RViz warning, consistent
with RViz not having been opened in it.

**The committed config is not obviously at fault.** All three LiDAR displays in
`src/launcher/golfcart_launch/rviz/golfcart.rviz` already ask for Best Effort:

```yaml
Reliability Policy: Best Effort
Value: /sensing/lidar/vlp32/velodyne_points
```

Two things can still produce the warning, and they need different fixes:

1. **A display added by hand at runtime.** rviz2's Add-display dialog defaults
   to RELIABLE, so any display created in the GUI rather than loaded from the
   file starts out unable to receive from any BEST_EFFORT sensor topic. It looks
   broken and the GUI says nothing. Fix per display, in the Topic > Reliability
   Policy dropdown.
2. **The vehicle running a different config from the one in git.** The run
   loaded `/mnt/external/2026-golf-cart/install/.../golfcart.rviz`. That
   checkout is known to differ from the repository elsewhere: its
   `VLP32.param.yaml` has `udp_only: false` and a `return_mode` comment block
   that exist in no commit on `origin/2026-golf`. See
   [known-config-defects.md](../../known-config-defects.md).

**Check first, it costs nothing:**

```bash
ros2 topic info -v /sensing/lidar/vlp32/velodyne_points
```

That prints every endpoint with its QoS. The RELIABLE one is the culprit, and
the node name tells you which of the two cases you are in. Warning #1 arrives
before RViz exists, so at least one non-RViz subscriber is also affected: find
out which, because if it is anything on the localization path it belongs in
section B instead.

---

## B. The concatenator throws most Velodyne scans away

`debug_mode: true` in `concatenate_and_time_sync_node.param.yaml` makes the node
publish per-input diagnostics, so this is measured rather than inferred. Per
concatenation attempt it reports whether each input was present.

|  | isolated run | observable run |
|---|---|---|
| concatenation attempts | 760 over 321 s = **2.37 Hz** | 2210 over 535 s = **4.13 Hz** |
| Falcon present | 649 = **85.4%** | 2112 = **95.6%** |
| **Velodyne present** | 381 = **50.1%** | 1043 = **47.2%** |
| all inputs present | 270 = 35.5% | 945 = 42.8% |

The Velodyne lands in fewer than half the windows, and the number barely moved
between runs even though the machine went from 90% CPU to 74% and the Falcon
improved from 85% to 96%. Whatever is rejecting Velodyne scans is specific to
the Velodyne path and is not general system load.

### The number that decides it

The Velodyne raw topic was measured at **8.6 Hz** on 2026-08-10 (1290 messages
in a 150 s bag, roadblocks.md). This run's concatenator saw a Velodyne scan
**1.95 times a second**. If both hold in the same run, then roughly **three out
of four Velodyne scans are published and then discarded by the synchroniser**,
which makes this a matching problem, not a sensor rate problem.

That is the one measurement missing. The two figures come from different runs,
so confirm them together:

```bash
ros2 topic hz /sensing/lidar/vlp32/velodyne_points \
              /sensing/lidar/falcon/iv_points \
              /sensing/lidar/concatenated/pointcloud
```

- Velodyne ≈ 8-10 Hz → matching problem, go to the window analysis below.
- Velodyne ≈ 2 Hz → sensor or decoder problem, go to the deadline section.

Both may be partly true. The two paths are not exclusive.

### Why the window is the suspect

The matching config:

```yaml
timeout_sec: 0.2
publish_previous_but_late_pointcloud: false
matching_strategy:
  type: advanced
  lidar_timestamp_offsets: [0.0, 0.0]
  lidar_timestamp_noise_window: [0.1, 0.1]
```

The observed window between the reported minimum and maximum reference
timestamp is a median of exactly **0.200 s** in both runs, so `timeout_sec` is
the binding constraint.

Against that 200 ms budget, here is how late each input actually arrives
relative to its own timestamp, from the node's own `Latency (s)` field:

| | isolated: median / p90 | observable: median / p90 |
|---|---|---|
| Falcon | 540.8 / 808.2 ms | 509.7 / 591.3 ms |
| Velodyne | 244.9 / 456.8 ms | 374.7 / 521.8 ms |
| **differential** | **296 ms** | **135 ms** |

Two things follow.

**Both LiDARs arrive later than the entire window is wide.** That alone is
survivable, because the collector opens on the first arrival and measures the
timeout from there, so a common delay cancels.

**What does not cancel is the differential, and it sits right at the threshold.**
135 ms of mean skew against a 200 ms timeout, with p90 excursions above 500 ms
on both sides, is a coin flip per window. A coin flip per window is exactly the
47% we measure. This is the most economical explanation of the number, and it
predicts the one thing a rate problem would not: that the Falcon, which usually
opens the collector, is present 96% of the time while the input being waited on
is present 47%.

`publish_previous_but_late_pointcloud: false` then decides what happens to the
loser: the late scan is **dropped**, not published behind the others.

### Things to try, cheapest first

1. **Raise `timeout_sec` to 0.3 or 0.4** and re-measure the present-percentages.
   One-line change, and the diagnostic already reports the answer. If Velodyne
   presence jumps, the diagnosis is confirmed and the remaining question is what
   the added latency costs NDT.
2. **Set `lidar_timestamp_offsets`** to the measured skew rather than `[0.0,
   0.0]`. The two sensors are not synchronised to each other: `Use Sensor Time:
   0` means the Velodyne is stamped on host arrival, and nothing feeds PPS. A
   fixed offset is what this field is for, and it is more honest than widening
   the timeout.
3. **Consider `publish_previous_but_late_pointcloud: true`** so a late scan is
   published rather than discarded. Trades freshness for coverage; whether NDT
   prefers that is a real question, not an obvious yes.
4. Only then look at the sensor.

### The sensor side, for completeness

Both drivers are complaining, continuously, in both runs.

**Velodyne**: `Missed pointcloud output deadline` appears 60 times in the
isolated run and 96 in the observable one. Normalised that is 0.187/s and
0.180/s: essentially identical, and close enough to one per 5 s throttle window
to mean it is firing on effectively every window rather than occasionally. The
decoder is not assembling a full rotation in time, continuously, and has been
since before the optimization.

**Falcon**: the Seyond SDK logs `drop data in deliver stage` **24,670 times
(77/s)** in the isolated run and **37,701 times (70/s)** in the observable one.
That is inside the vendor driver, upstream of ROS entirely. It did not improve
when the machine got 15 points of CPU back, which argues for a driver-internal
queue rather than starvation.

Neither NIC is saturated: the Velodyne link carries 15.69 Mbit/s against a
100 Mbit/s capacity, and the Falcon link 65.86 Mbit/s against 1000. The
Velodyne figure matches a VLP-32C's fixed ~1507 packets/s exactly, so **the
packets are reaching the NIC at full rate**. Whatever is lost is lost between
the NIC and the decoder, which points at the UDP socket buffer or at scheduling
of the driver's read thread, not at the network.

That said, the buffer tuning in the same session cut UDP receive-buffer
overflows from 14,148/s to 983/s without moving the Velodyne presence figure at
all, so socket buffer size is unlikely to be the whole story.

---

## What this costs NDT

The concatenated cloud reaches NDT at **~4 Hz**, and **53% of those clouds
contain only the Falcon**. NDT is configured for a 10 Hz input.

Separately, NDT's own `sensor_points_delay_time_sec` has a median of **0.51 s**.
At 5 m/s that is 2.5 m of travel between the scan being taken and the match
being computed. Neither run had localization active
(`is_activated: False` throughout on both `ndt_scan_matcher` and
`ekf_localizer`, and `map -> base_link` never received), so that delay was never
under load. It will not improve when it is.

The optimization did make one real difference here. Normalised per second, the
concatenator went from dropping clouds to publishing degraded ones:

| | isolated | observable | |
|---|---|---|---|
| dropped, missing topics and stale timestamp | 8.16/s | 2.09/s | -74% |
| dropped, stale timestamp | 1.57/s | 0.47/s | -70% |
| published but incomplete | 7.10/s | 21.55/s | +203% |

A dropped cloud gives NDT nothing. An incomplete one gives it a Falcon-only
scan. The second is better, and it is why the raw ERROR count went up while the
pipeline got healthier.
