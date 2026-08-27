# Why NDT and RViz both see a partial point cloud

**Measured**: 2026-08-25, two `just launch` runs on the Advantech, from the
play_launch bundles `2026-08-25_16-45-52` (isolated) and `2026-08-25_17-33-40`
(observable). Both runs saw the same LiDAR behaviour, so nothing here is an
artifact of the container-mode change being tested that afternoon.

**Investigates**: the two rate observations left open in
[roadblocks.md](../../roadblocks.md#sensor-status-observed-2026-08-10), plus the
symptom that the point cloud is partially missing in RViz.

Answer up front: **two faults on one topic.** A is a QoS mismatch that denies
RViz any data. B is a TF transform failure inside the concatenator that discards
clouds which arrived perfectly intact. An intermediate revision of this document
briefly claimed a single shared cause; that was wrong and is corrected below.

| | Symptom | Cause | Confidence |
|---|---|---|---|
| **A** | RViz shows no Velodyne at all | a RELIABLE subscriber cannot match the BEST_EFFORT publisher, so it receives nothing | established |
| **B** | NDT gets ~4 Hz of cloud, half of it Falcon-only | the concatenator cannot transform the cloud into `base_link` and discards it; everything upstream is lossless | established; the reason the lookup fails is open |

Fixing A does nothing for B. They share a topic, not a cause.


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

### Where the Velodyne clouds actually go: the concatenator's TF transform

**Answered 2026-08-28.** They arrive intact and are then discarded inside the
concatenator, because it cannot transform them into `base_link`:

```
[WARN] [sensing.lidar.concatenate_data]:
transformed_raw_points[/sensing/lidar/vlp32/pointcloud_before_sync] is nullptr,
skipping pointcloud publish.
```

`transformed_raw_points` is the cloud after transformation into `output_frame`.
A null pointer there means the lookup failed and the whole publish is skipped.

**The counts identify it.** On the 2026-08-25 vehicle run the concatenator made
2210 attempts with the Velodyne present in 1043, so **1167 without it**, against
**1186** nullptr warnings for that topic. Those are the same event. For the
Falcon the same run logged only 153, a 7.8:1 asymmetry against the Velodyne.

**Nothing upstream is losing anything.** Per-stage counting over 67.9 s of NTU
CSIE-1 replay, on the repo's CycloneDDS profile:

| stage | count |
|---|---|
| `vlp32/velodyne_points` | 419 |
| `vlp32/self_cropped/pointcloud_ex` | 419 |
| `vlp32/rectified/pointcloud_ex` | 419 |
| `vlp32/pointcloud_before_sync` | 419 |

419 over 67.9 s is 6.17 Hz, exactly the rate the bag holds in that segment
(431 messages in its first 70 s). The driver, the crop box, the distortion
corrector and the ring outlier filter are collectively lossless. The clouds are
delivered and then thrown away at the last step.

**Two earlier explanations are dead.** The matching window was tested and ruled
out (table above). Transport was tested and ruled out: on the repo's CycloneDDS
profile 416 of 431 arrive, 96.5%. Forcing the publisher RELIABLE via
`ros2 bag play --qos-profile-overrides-path` changed nothing, because there was
nothing left to recover.

Transport is worth one caveat rather than a finding. Under **default FastDDS**
the same replay delivers only 185 of 431, 43%, because the topic is BEST_EFFORT
and a `PointXYZIRCAEDT` cloud at 48342 points is 1.38 MiB, so it fragments and
one lost fragment discards the sample. The repo's CycloneDDS profile already
handles this, and the vehicle uses it. It matters only if someone runs this
stack without `scripts/env.sh`.

### Why the transform fails: still open

Not the frame names, which was the obvious guess and is wrong: the sensor kit
URDF publishes links named `velodyne` and `seyond`, matching `frame_id` in
`VLP32.param.yaml` and `seyond.param.yaml`. The calibration YAML's `vlp32c` and
`falcon` are entry names the xacro maps onto those links, not frames.

What to probe next, in order:

1. **Whether the failure is time-bounded.** `is_motion_compensated: true` makes
   the lookup time-dependent, so a cloud stamped outside the TF buffer's range
   fails while a static lookup would succeed. `VLP32.param.yaml` runs with
   `Use Sensor Time: 0`, so the Velodyne is stamped on host arrival while the
   Seyond is not, which is a mechanism for exactly this asymmetry.
2. **Whether `tf_static` is complete when the failures happen**, and whether
   they cluster at startup or continue throughout.
3. **`/tf` publishers for the same frame.** CLAUDE.md already records the Xsens
   driver broadcasting `world -> imu_link` while the URDF publishes
   `sensor_kit_base_link -> imu_link`; a second parent for a LiDAR frame would
   produce intermittent lookup failures of exactly this shape.

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
