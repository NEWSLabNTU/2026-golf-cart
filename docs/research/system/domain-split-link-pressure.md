# The master/orin link: one domain on the wire vs. a bridged link domain

**Date**: 2026-09-22. **Branch**: `perf/domain-split`.
**Status**: measured with the real stack, both recorders and the real RViz in
a two-namespace simulation on a workstation, link shaped to 100 Mbit/s, three
operator situations, both directions. **Measured on the vehicle 2026-09-22**,
both hosts up, no recorder, RViz on the master: see *On the vehicle*.

## The problem as reported

Advantech (master) and orin share a 100 Mb/s segment. Under load the link
fills in bursts and has dropped outright. Both hosts ran one CycloneDDS
domain bound to the LAN interface (`config/cyclonedds/{master,orin}.xml`
before this branch), so every participant on either machine was on the wire.

## What that puts on the wire, by construction

1. **Discovery.** ~160 nodes and ~620 topics on the master. Every participant
   that appears on the orin — driver, recorder, every `ros2 topic list` —
   receives the master's whole endpoint set, and vice versa.
2. **Clouds the orin never asked for.** CycloneDDS 0.10 picks a writer's
   destination by coverage: one multicast datagram beats several unicast ones
   as soon as a topic has two reader *processes*. On the master every raw
   cloud has exactly two: the preprocessing container and the recorder
   (`config/recording/master_topics.txt` lists `velodyne_points` and
   `iv_points`). A multicast datagram leaves the NIC whether or not anything
   on the far side subscribed.
3. **Whatever an operator touches.** `ros2 topic echo` of the ZED image on
   the master pulls the whole stream across, because the topic is there.

Domain ids on their own change none of this; a domain is a port offset.
**Which interface each domain is bound to** is what matters.

## The split

Two `<Domain>` sections per profile (CycloneDDS merges `Id="any"` with the
specific one and expands `${VAR}` in the `Id`; both verified with `Tracing
Category=config`):

| domain | interface | who is in it |
|---|---|---|
| `50` master, `60` orin (`ROS_DOMAIN_ID`, exported by `scripts/env.sh` per role) | `lo` | the whole stack, exactly as `loopback.xml` runs it single-machine, on an id of its own |
| `10` (`${GOLFCART_LINK_DOMAIN_ID}`) | the LAN address | one `golfcart_domain_bridge` per host, and any CLI pointed at it |

`golfcart_domain_bridge` (`src/system/golfcart_domain_bridge`) copies the
topics in `config/link/topics.yaml` between the two domains as serialized
bytes. Today: the orin's IMU, its dynamic `/tf` (the `zed_imu_link` frame
the wrapper broadcasts at 100 Hz), `camera_info`, `/diagnostics`,
`/tf_static`; nothing back. The ZED image is deliberately not on it: at the
camera's rate it is 55 Mbit/s of the link (measured below), so it goes in
with a `max_hz` when someone wants it on the master. `golfcart.launch.yaml` starts it under
`host:=master` and `host:=orin`.

## The simulation, and what in it is real

`scripts/testing/link_sim/run.sh` (`just link sim baseline|split`). Two
network namespaces joined by a veth pair on the real addresses; no root
(unprivileged user namespace).

| piece | what runs | real? |
|---|---|---|
| master stack | `ros2 launch golfcart_launch golfcart.launch.yaml host:=master launch_sensing_driver:=false launch_vehicle_interface:=false use_cuda:=false pose_source:=ndt use_gnss:=false`: **158 nodes, 623 topics** | yes: Autoware 1.5.0 + this repo's launch, CPU NDT/preprocessing because this box has no colcon cargo extension for the Rust matcher; the DDS graph is the same |
| master recorder | `ros2 bag record` on `config/recording/master_topics.txt` | yes |
| orin recorder | `ros2 bag record` on `config/recording/orin_topics.txt` | yes |
| bridges (split only) | from the launch on the master; the binary on the orin | yes |
| drivers | `synthetic_sensors.py`: publishers on the real topic names | **no**: the bytes are synthetic. Sizes and rates are the device specs and cart measurements, each cited in that file's header |
| orin stack | driver + recorder only | partly: the orin runs no Autoware; its system monitor rows are synthetic |
| wire | veth, `tbf rate 100mbit burst 128kb limit 1mb` each way | shaped to the segment's negotiated rate; not an i226 behind a 4G router's switch |
| operator | `ros2 topic list` every 10 s on both hosts; one 15 s `ros2 topic echo` of the ZED image on the master | scripted |
| RViz (two of the three situations) | `rviz2 -d golfcart.rviz` on the master, on a private TurboVNC display, software GL | yes: the real RViz with the repo's config, a third reader of both raw clouds and a reader of ~140 topics |
| ZED view (one situation) | the same RViz with one more Image panel on the ZED's compressed topic, written as the file's three GMSL panels are | yes |

Driver sizes, from `synthetic_sensors.py`:

| source | size × rate | from |
|---|---:|---|
| VLP-32C `velodyne_points` | 60 000 pts × 32 B = 1.92 MB × 10 Hz | 600 000 pts/s single return (datasheet), `PointXYZIRCAEDT` (Nebula); cart bags show 48 700 pts indoors |
| Falcon `iv_points` | 51 743 pts × 16 B = 828 kB × 10 Hz | measured over 3 677 frames of a cart bag (where-the-orin-cpu-goes.md) |
| 3 × GMSL `image_raw/compressed` | 300 kB × 30 Hz each | 1920×1280 @ 30 (config), 250–400 kB at q90 (2-camera-image-pipeline.md) |
| ZED `image/compressed` | 220 kB × 30 Hz | HD1200 @ 30 (zedx.yaml); 295 MB / 45 s orin bag (multi_machine_deployment.md) |
| ZED IMU, IMU `/tf` | 100 Hz | `sensors_pub_rate: 100`, `publish_imu_tf: true` |

Measured at the master's end of the veth: per-second counters
(`scripts/check/link_pressure.sh`, the same script for `enP5p3s0`), the
tbf's own drop counter, and a raw-socket sniffer charging every byte to a
domain and to multicast/unicast by destination port. Rates at the **real
consumers** (`imu_corrector`'s output, `gyro_odometer`'s twist) with
`ros2 topic hz` on small topics only; a `hz` on a cloud would be a second
reader and change the thing measured. Bag message counts from the recorders.

70 s startup, 90 s steady with the 15 s echo carved out. Workstation: Ryzen
9 9950X, Ubuntu 22.04, ROS 2 Humble, CycloneDDS 0.10.5. Domains as
configured: master stack 50, orin stack 60, link 10; the baseline runs both
hosts in domain 0 as the cart did. Runs archived in
[`data/link-sim/`](data/link-sim/), one directory each, `matrix.md` across
them.

## Results

Six runs: three operator situations, each under the old profile (one domain
on the LAN, no bridge) and the split. Every run: real stack, both recorders,
wire shaped to 100 Mbit/s = 12.5 MB/s each way, 70 s startup then a 90 s
steady window. All numbers are the steady window unless marked. "worst s" is
the worst single second. Every cell is read from a file under
[`data/link-sim/`](data/link-sim/), by `scripts/testing/link_sim/matrix.py`.

| situation | readers of each raw cloud on the master |
|---|---:|
| **record**: stack + `just record start` | 2 (preprocessing container, recorder) |
| **RViz + record**: plus `rviz2 -d golfcart.rviz` on the master, the real one | 3 |
| **RViz + ZED view + record**: RViz also shows the ZED image (in the split, the image lane is added to `topics.yaml` at full rate so there is something to show) | 3 |

### Both directions

| run | master → orin mean | worst s | dropped | orin → master mean | worst s | dropped |
|---|---:|---:|---:|---:|---:|---:|
| record, one domain | **12.10 MB/s (96.8 Mbit/s)** | 12.43 MB/s | 137 358 pkts | 150 kB/s (1.2 Mbit/s) | 533 kB/s | 0 |
| record, split | **1.9 kB/s** | 10 kB/s | 0 | 89 kB/s (0.7 Mbit/s) | 115 kB/s | 0 |
| RViz + record, one domain | **12.53 MB/s (100.3 Mbit/s)** | 12.54 MB/s | 156 205 pkts | 158 kB/s (1.3 Mbit/s) | 754 kB/s | 0 |
| RViz + record, split | **1.9 kB/s** | 10 kB/s | 0 | 89 kB/s (0.7 Mbit/s) | 115 kB/s | 0 |
| RViz + ZED view + record, one domain | **12.53 MB/s (100.3 Mbit/s)** | 12.62 MB/s | 143 138 pkts | **6.93 MB/s (55.5 Mbit/s)** | 7.39 MB/s | 0 |
| RViz + ZED view + record, split | **1.9 kB/s** | 10 kB/s | 0 | **6.87 MB/s (55.0 Mbit/s)** | 7.01 MB/s | 0 |

Master → orin under the old profile is the link ceiling in all three
situations, and it is the ceiling with the orin subscribed to none of it.
The sniffer's account of the RViz + ZED view baseline, whole run: 1 846 MB
domain-0 multicast clouds master → orin (95.8 %), 75 MB discovery; orin →
master 1 045 MB multicast ZED image (RViz on the master and the recorder on
the orin: two readers, so multicast), 9.6 MB discovery.

### What each direction is made of, after the split

Master → orin: nothing is listed, so the 1.9 kB/s is the bridges' discovery
and AckNacks. `master_to_orin: []`.

Orin → master, per lane, from the bridge's own counters (payload; the wire
adds RTPS/UDP/IP), RViz + ZED view run:

| lane | msgs in 160 s | payload |
|---|---:|---:|
| `/sensing/camera/zed/imu/data` 100 Hz | 16 737 | 34.7 kB/s |
| `/tf` (`zed_imu_link`) 100 Hz | 16 737 | 13.0 kB/s |
| `/sensing/camera/zed/rgb/color/rect/camera_info` 30 Hz | 5 095 | 10.7 kB/s |
| `/diagnostics` 1 Hz | 169 | 1.4 kB/s |
| `/tf_static` | 1 | 0 |
| **subtotal, the checked-in list** | | **~60 kB/s payload, 89 kB/s on the wire** |
| `/sensing/camera/zed/rgb/color/rect/image/compressed` 30 Hz, only when listed | 5 095 | **7 008 kB/s** |

So: the ZED image at the ZED's rate is **55 Mbit/s of a 100 Mbit/s link**,
before and after the split alike. The split does not make an image cheap; it
makes carrying it a line someone wrote, with a `max_hz` beside it. At
`max_hz: 5` the same panel costs ~9 Mbit/s; at 2 Hz, ~3.7. Without the line,
opening the panel on the master shows nothing and costs nothing.

### At the real consumers, and in the recordings

| run | Velodyne scans kept by the master's recorder (of ~1 560) | gyro_odometer twist | imu_corrector |
|---|---:|---:|---:|
| record, one domain | **625** | **2.0 Hz** | 100.0 Hz |
| record, split | 1 558 | 14.2 Hz | 100.0 Hz |
| RViz + record, one domain | **495** | **1.6 Hz** | 100.0 Hz |
| RViz + record, split | 1 561 | 13.0 Hz | 99.9 Hz |
| RViz + ZED view + record, one domain | **490** | **1.6 Hz** | 99.0 Hz |
| RViz + ZED view + record, split | 1 561 | 13.7 Hz | 97.1 Hz |

The master's recorder is a local reader; it lost 60–69 % of the LiDAR scans
under the old profile. The writer's socket is backpressured by the full
egress queue, the send fails, and a best-effort sample lost at the sender is
lost for every reader. Opening RViz made it worse (495 of 1 561), because a
third reader adds nothing to the multicast decision but does add a local
consumer competing for the same stalled writer.

The IMU (reliable) is retransmitted through in every run and reaches
`imu_corrector` at ~100 Hz; but gyro_odometer, which also needs the IMU's
`/tf`, fell to 1.6–2.0 Hz whenever the wire was full. With the ZED image
listed at full rate in the split, imu_corrector dropped to 97 Hz: 55 Mbit/s
of image on a 100 Mbit/s link is already costing the IMU samples.

### Discovery

A fresh `ros2 node list` on the orin under the old profile discovers 159
nodes and 624 topics; under the split, 3 nodes and 9 topics in its own
domain and 2 nodes in the link domain.

## What this says

- **With the cart's own recorder running, the old profile saturates the
  link by itself, in the direction the orin never asked for.** Two readers
  of each raw cloud on the master, so CycloneDDS multicasts 27.5 MB/s of
  clouds out of the NIC; the 100 Mbit wire carries 12.1–12.5 MB/s of it and
  drops 140–156k packets per 160 s. This is the cart's configuration on every
  recorded test drive. Opening RViz changes nothing about it: the wire was
  already full.
- **The saturation reaches back into the master.** Its own recorder kept
  40 % of the LiDAR scans without RViz, 31 % with. Expect the cart's
  recordings to have gaps wherever the link was full.
- **Orin → master is what the operator makes it.** With the checked-in list
  it is ~90 kB/s on the wire. Viewing the ZED image on the master is
  55 Mbit/s at the camera's 30 Hz, old profile or split; the split only
  turns that from an accident (a panel opened) into a line in `topics.yaml`
  with a rate cap next to it, and makes an unlisted panel cost nothing.
- **The split removes the master → orin leg structurally**: 1.9 kB/s, zero
  drops, and the orin discovers 3 nodes instead of 159. Nothing on either
  host can reach the wire except through the bridge's list.
- **Running the real consumers against the bridge found two errors in my
  own list** that a synthetic-consumer simulation could not: the IMU lane
  was best_effort while `imu_corrector` subscribes reliable (the bridge
  logged `requesting incompatible QoS`; the consumer would have received
  nothing), and the ZED's dynamic `/tf` was not listed (gyro_odometer would
  have dropped every sample, silently). Both fixed; both are in these runs.

## What this does not say

- Anything about the link **disconnecting**. DDS cannot take an interface
  down. A flapping `igc` link under load is a NIC, cable, EEE/ASPM or
  4G-router-port problem (`dmesg | grep -i 'link is'`,
  `ethtool --show-eee enP5p3s0`, and why a 2.5 GbE NIC negotiates 100 Mb).
  The split removes the load that triggers it, not the fault.
- The exact numbers on the cart: the drivers are synthetic (sizes are the
  specs; the real Velodyne frame is smaller indoors), the orin runs no
  Autoware here, CUDA preprocessing may change the reader topology of the
  intermediate clouds, RViz on the master adds readers this run did not
  have. Every one of those changes the magnitude, none the mechanism.
- CPU.

## On the vehicle

**Measured 2026-09-22**, Advantech and orin on the real 100 Mb/s segment,
`just launch-all` (both units, `launch_perception:=false` on the first run,
perception on the second), RViz on the master via `just tool rviz`, no
recorder. `scripts/check/link_pressure.sh` on the master's `enP5p3s0`.

| situation | tx mean | tx peak | rx mean | rx peak |
|---|---:|---:|---:|---:|
| old profiles, master alone, 2026-09-21 (`scripts/env.sh` header) | ~12 MB/s | at the 12.5 MB/s ceiling | | |
| split, master alone, 150 s | 12.9 kB/s | 95.6 kB/s | 0.6 kB/s | 5.5 kB/s |
| split, both up, 60 s | 15.7 kB/s | 98.0 kB/s | 128.9 kB/s | 148.3 kB/s |

Both up is 1.2 Mbit/s at the worst second, ~1% of the link, and the rx is the
payload: ZED IMU and its `/tf` at 100 Hz plus `camera_info` at 30 Hz.

What crosses, with the rates seen on the master in domain 50 against the
orin's own domain 60:

| topic | orin, d60 | master, d50 |
|---|---:|---:|
| `/sensing/camera/zed/imu/data` | 100.2 Hz | 100.1 Hz |
| `/tf` (`zed_imu_link`) | 101.3 Hz | 98.3 Hz |
| `/sensing/camera/zed/rgb/color/rect/camera_info` | 30 Hz | 29.0 Hz |

`ros2 topic list` in domain 10 from either host shows exactly the five topics
in `config/link/topics.yaml` plus `/rosout` and `/parameter_events`. The
LiDARs, the three GMSL cameras and the other ~600 master topics never appear
on the wire; the master's own stack is unaffected (166 nodes, VLP-32C 10 Hz,
cameras 30 Hz with `camera_info`).

Two failures on the way that were not the split, both recorded in
`docs/roadblocks.md`: the Advantech's installed units still carried
`Requires=iox-roudi.service` from before the iceoryx removal, and the orin's
`net.core.wmem_max` was 212992 so CycloneDDS refused the 16 MB
`SocketSendBufferSize` that `c228d87` added and created no participant at all
(`rmw_create_node: failed to create domain`). Neither host had had its setup
steps re-run after those two commits. The second one hides well: the unit is
`active`, every node dies in its first second, and the symptom is "no data".

Still to do with the stack up and recording:

```bash
just link nodes                 # exactly two bridges
ros2 topic hz /sensing/imu/imu_data
ros2 topic hz /localization/twist_estimator/twist_with_covariance
ros2 bag info <bag> | grep velodyne_points   # scans recorded vs scans expected
```

## Alternatives weighed

- `ros2/domain_bridge`: would do; not in the workspace, no per-topic rate
  cap. Switch if the bridge grows.
- CycloneDDS multi-interface (`lo` + NIC) in one domain: discovery still
  fans out, and whether the same-host locator choice keeps clouds off the
  NIC is exactly what cannot be verified from here.
- Zenoh with a router allow-list: same effect; `GOLFCART_RMW=zenoh` has
  never brought Autoware up (`config/zenoh/README.md`).
- The 1 Gb/s interlink (`scripts/hardware/network/setup-interlink.sh`):
  raises the ceiling above the 27.5 MB/s offered; composes with this, and
  is the cheapest test of whether the disconnects are load or NIC.
