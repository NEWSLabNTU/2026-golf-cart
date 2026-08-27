# Why NDT and RViz both see a partial point cloud

**Measured**: 2026-08-25, two `just launch` runs on the Advantech, from the
play_launch bundles `2026-08-25_16-45-52` (isolated) and `2026-08-25_17-33-40`
(observable). Both runs saw the same LiDAR behaviour, so nothing here is an
artifact of the container-mode change being tested that afternoon.

**Investigates**: the two rate observations left open in
[roadblocks.md](../../roadblocks.md#sensor-status-observed-2026-08-10), plus the
symptom that the point cloud is partially missing in RViz.

Answer up front: these are **two symptoms of one fault**. The original version of
this document called them unrelated; that was corrected on 2026-08-28 once the
cause was found. The Velodyne topic is published BEST_EFFORT, which both denies
a RELIABLE RViz display any data at all and costs the concatenator more than
half its scans.

| | Symptom | Cause | Confidence |
|---|---|---|---|
| **A** | RViz shows no Velodyne at all | a RELIABLE subscriber cannot match the BEST_EFFORT publisher, so it receives nothing | established |
| **B** | NDT gets ~4 Hz of cloud, half of it Falcon-only | the same BEST_EFFORT publisher, whose 1.38 MiB clouds fragment and are dropped without retransmission | established; a residual gap under load is still open |

Fixing A does nothing for B, but one change addresses both: the Velodyne
publisher's reliability.


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
   loaded `/mnt/external/2026-golf-cart/install/.../golfcart.rviz`, and nothing
   in the bundle pins that checkout to a commit. Confirm it before trusting the
   file above, with `git -C /mnt/external/2026-golf-cart status` on the machine.

   An earlier revision of this document offered `VLP32.param.yaml` as evidence
   that the vehicle's checkout diverges from git. That was wrong, and it is not
   evidence of anything: the vehicle's version of that file is committed as
   `e41e16f` and pinned since `a7baa23`. The divergence was in a **local
   submodule working tree** sitting one commit behind the pin, not on the
   vehicle. See the note in
   [known-config-defects.md](../../known-config-defects.md#not-defects).

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

Settled on 2026-08-28 against the NTU CSIE-1 bag, which carries
`/sensing/lidar/vlp32/velodyne_points` at a known **7.02 Hz** (3141 messages
over 447.5 s). The concatenator attempted **3.7 Hz**, so about two Velodyne
clouds were available per attempt and presence should have been near 100%. It
was ~50%.

So roughly half the Velodyne scans are lost **before** the synchroniser gets to
compare timestamps. Where, is section B's open question.

**Do not measure this with `ros2 topic hz`.** It is a Python node and drops
roughly three quarters of 300 KiB messages at 10 Hz. Demonstrated by playing a
bag with nothing else running: the C++ `ros2 bag record` received 288 of 288
scans while `ros2 topic hz` reported 2.1 Hz on the same topic in the same run.
An earlier revision of this document recommended exactly that command, and the
"~2 Hz" figures it produced were artifacts. Use `ros2 bag record` counts or the
nodes' own diagnostics.

### The window was the suspect, and it was wrong

**This section originally argued that the 200 ms `timeout_sec` was the binding
constraint, and recommended raising it. That was tested on 2026-08-28 and is
false.** The reasoning and the refutation are both kept, because the reasoning
was plausible and someone will otherwise re-derive it.

The matching config:

```yaml
timeout_sec: 0.2
publish_previous_but_late_pointcloud: false
matching_strategy:
  type: advanced
  lidar_timestamp_offsets: [0.0, 0.0]
  lidar_timestamp_noise_window: [0.1, 0.1]
```

The argument was: the node's own `Latency (s)` field put the Falcon at a median
509.7 ms and the Velodyne at 374.7 ms, a **135 ms differential** against a
200 ms budget, with p90 excursions past 500 ms on both sides. A coin flip per
window, which is what 47% looks like.

**The measurement.** Replayed against the NTU CSIE-1 merged bag, 75 s per run,
read from the concatenator's own diagnostics:

| `timeout_sec` | `noise_window` | attempts | **Velodyne present** | Falcon | all present |
|---|---|---|---|---|---|
| 0.2 | 0.1 | 277 | **54.2%** | 85.2% | 39.4% |
| 0.3 | 0.1 | 329 | **48.9%** | 90.0% | 38.9% |
| 0.4 | 0.1 | 285 | **48.4%** | 94.0% | 42.5% |
| 0.4 | 0.2 | 248 | **55.6%** | 92.7% | 48.4% |

Velodyne presence is flat across a 2x range of the parameter. What *did*
respond is the Falcon (85 to 94%) and all-inputs-present (39 to 48%), both
consistent with the timeout helping a genuinely *late* input arrive. The
Velodyne is not late; it is absent.

Two corrections fall out of that table.

**`timeout_sec` is not the fix.** Raising it costs up to 400 ms of added wait on
a moving vehicle and leaves the Velodyne where it was.

**The reported window is not the configured tolerance.** The
minimum-to-maximum reference timestamp span stayed pinned at 200 ms even at
`noise_window: 0.2`, with the config verified live through the symlinked
install. It reports the actual spread of what was collected, which two
independent sensors set themselves. On a kit whose LiDARs share a clock it
tracks the config and looks like a tolerance; here it does not.

### Where the Velodyne clouds actually go: transport, and it is the same fault as A

**Answered 2026-08-28.** They are dropped in transport, because the Velodyne
topic is published **BEST_EFFORT** while the Falcon's is **RELIABLE**, and each
Velodyne message is large enough to fragment.

The QoS recorded in the NTU bag, which is the QoS the drivers offered:

| topic | `reliability` | |
|---|---|---|
| `/sensing/lidar/vlp32/velodyne_points` | `2` | **BEST_EFFORT** |
| `/sensing/lidar/falcon/iv_points` | `1` | **RELIABLE** |

Play that bag into nothing but a `ros2 bag record`, no stack at all, over 67 s:

| transport | Velodyne delivered | Falcon |
|---|---|---|
| default FastDDS | 185 = **2.75 Hz** | 635 = 9.45 Hz |
| this repo's CycloneDDS profile | 416 = **6.16 Hz** | 636 = 9.42 Hz |

The bag carries the Velodyne at 7.02 Hz and the Falcon at 9.40 Hz. The Falcon
arrives complete under both transports. The Velodyne does not arrive complete
under either, and how much of it arrives depends entirely on the DDS
configuration. That is what a fragmented BEST_EFFORT sample looks like: one lost
fragment discards the whole cloud, and nothing retransmits.

Size is why it fragments. The Velodyne cloud is `PointXYZIRCAEDT`, 30 bytes per
point at 48342 points, so **1.38 MiB** per message, against a
`net.core.rmem_default` of 1 MiB. Note the kernel's UDP `RcvbufErrors` counter
does **not** move during this, so the loss is in DDS fragment reassembly rather
than socket overflow, and looking only at `/proc/net/snmp` will say everything
is fine.

**This is the same root cause as fault A.** The header table at the top of this
document called them unrelated. They are not. A BEST_EFFORT publisher is exactly
why a RELIABLE RViz display receives nothing at all, and it is also why the
concatenator receives less than half the scans. One property of one publisher,
two symptoms.

### What it does not explain, yet

Correct transport does not close the gap on its own. Re-running the full stack
with CycloneDDS rather than the default:

| | attempts | Velodyne present | Falcon | all present |
|---|---|---|---|---|
| default FastDDS | 277 | 54.2% | 85.2% | 39.4% |
| CycloneDDS profile | 368 | 45.4% | 88.9% | 34.2% |

Concatenation attempts rise (277 to 368) but Velodyne presence does not: 45.4%,
which is where the vehicle sat (47.2%). So a bare recorder gets 6.16 Hz while
the running stack gets 2.23 Hz of Velodyne into windows, and per-stage counting
shows preprocessing costs only ~12% of that (267 raw to 235 preprocessed).

The remaining loss is between "one subscriber on an otherwise idle machine" and
"this topic inside the running stack". Contention, subscriber queue depth, or
the executor. Not yet isolated.

### Methodology warning, learned the hard way

Every measurement in this document before 2026-08-28 was taken with
`RMW_IMPLEMENTATION` unset, which silently replaced the vehicle's CycloneDDS
configuration with default FastDDS. On this topic that is a 2.2x difference in
delivered messages. `scripts/env.sh` sets both `RMW_IMPLEMENTATION` and
`CYCLONEDDS_URI` for exactly this reason; a test harness that unsets them is not
testing the system.

Combined with the `ros2 topic hz` trap above: **two separate instrument errors,
both of which made the pipeline look worse than it is, and both of which were
invisible in the output.** Check the transport and the observer before believing
a rate.

### Still worth doing, independent of the above

1. **Set `lidar_timestamp_offsets`** to the measured skew rather than `[0.0,
   0.0]`. The two sensors are not synchronised to each other: `Use Sensor Time:
   0` means the Velodyne is stamped on host arrival, and nothing feeds PPS.
2. **Consider `publish_previous_but_late_pointcloud: true`** so a late scan is
   published rather than discarded. Trades freshness for coverage; whether NDT
   prefers that is a real question, not an obvious yes.

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
