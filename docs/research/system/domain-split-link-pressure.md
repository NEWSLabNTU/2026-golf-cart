# The master/orin link: one domain on the wire vs. a bridged link domain

**Date**: 2026-09-22. **Branch**: `perf/domain-split`.
**Status**: measured with the real stack in a two-namespace simulation on a
workstation, link shaped to 100 Mbit/s. **Not yet measured on the vehicle.**

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
| `0` (ROS_DOMAIN_ID unset) | `lo` | the whole stack, on both hosts, exactly as `loopback.xml` runs it single-machine |
| `${GOLFCART_LINK_DOMAIN_ID:-42}` | the LAN address | one `golfcart_domain_bridge` per host, and any CLI pointed at it |

`golfcart_domain_bridge` (`src/system/golfcart_domain_bridge`) copies the
topics in `config/link/topics.yaml` between the two domains as serialized
bytes. Today: the orin's IMU, its dynamic `/tf` (the `zed_imu_link` frame
the wrapper broadcasts at 100 Hz), `camera_info`, `/diagnostics`,
`/tf_static`; nothing back. `golfcart.launch.yaml` starts it under
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
9 9950X, Ubuntu 22.04, ROS 2 Humble, CycloneDDS 0.10.5. Runs archived in
[`data/link-sim/`](data/link-sim/).

## Results

tx = master → orin, rx = orin → master. Wire shaped to 100 Mbit/s = 12.5 MB/s.

| window | metric | one domain on the LAN | split | change |
|---|---|---:|---:|---:|
| steady | **tx mean** | **12 141 kB/s (97.1 Mbit/s — the ceiling)** | **1.9 kB/s** | −100 % |
| steady | tx peak second | 12 324 kB/s | 12.4 kB/s | −99.9 % |
| steady | tx packets/s | 9 229 | 5 | −99.9 % |
| steady | rx mean | 148.7 kB/s | 89.3 kB/s | −40 % |
| steady | rx peak second | 659.9 kB/s | 124.4 kB/s | −81 % |
| echo | rx mean | 6 635 kB/s (53 Mbit/s) | 88.6 kB/s | −98.7 % |
| whole run | tx bytes through the bucket | 1 872 MB | 0.32 MB | |
| whole run | **tx packets dropped by the bucket** | **161 840** | **0** | |

| at the real consumers on the master | one domain | split |
|---|---:|---:|
| `/sensing/imu/imu_data` (imu_corrector out) | 100.0 Hz | 99.7 Hz |
| `/localization/twist_estimator/twist_with_covariance` (gyro_odometer out) | **2.07 Hz** | **13.4 Hz** |

| the recorders (bag message counts, ~155 s) | one domain | split |
|---|---:|---:|
| master: `/sensing/lidar/vlp32/velodyne_points` | **634** | **1 550** |
| master: `/sensing/lidar/falcon/iv_points` | 634 | 1 550 |
| orin: ZED image | 5 191 | 5 250 |
| orin: ZED IMU | 17 254 | 17 421 |

| readers, discovery | one domain | split |
|---|---:|---:|
| readers of `velodyne_points` / `iv_points` (container + recorder) | 2 | 2 |
| nodes a fresh `ros2 node list` on the orin discovers | 159 | 3 (domain 0) / 2 (link) |

Where the baseline's master → orin bytes went (sniffer, whole run):

| class | bytes | share |
|---|---:|---:|
| domain 0, **multicast data** | 1 782 MB | 96.2 % |
| domain 0, unicast discovery | 64 MB | 3.5 % |
| domain 0, multicast discovery | 3.4 MB | 0.2 % |
| domain 0, unicast data (what the orin actually subscribed to) | 2.5 MB | 0.1 % |

After the split every byte on the wire is in domain 42, unicast: 13.7 MB of
data orin → master in 160 s (IMU, IMU `/tf`, `camera_info`, diagnostics),
0.5 MB of discovery both ways together.

## What this says

- **With the cart's own recorder running, the old profile saturates the
  link by itself.** Two readers of each raw cloud on the master, so
  CycloneDDS multicasts 27.5 MB/s of clouds out of the NIC; the 100 Mbit
  wire carries 12.1 of it and drops the rest, every second, with the orin
  subscribed to none of it. This is the cart's configuration on every
  recorded test drive.
- **The saturation reaches back into the master.** The recorder on the
  master, a *local* reader, got 634 of 1 550 scans. The writer's socket is
  backpressured by the full egress queue, the send fails, and a best-effort
  sample lost at the sender is lost for every reader. That is a real effect
  of a full transmit queue, not of the token bucket in particular; expect
  recordings on the cart to have gaps whenever the link was full.
- **The orin's data still arrives, degraded.** The IMU (reliable) is
  retransmitted through and reaches `imu_corrector` at 100 Hz either way,
  but gyro_odometer's twist fell from 13.4 Hz to 2.1 Hz on the saturated
  link: the `/tf` it needs for the transform arrives late or not at all.
- **The split removes all of it structurally.** Master → orin is 1.9 kB/s,
  zero drops, the orin sees 3 nodes instead of 159, and the ZED image is not
  there for an operator's echo to pull across (6.6 MB/s before). What does
  cross is exactly `topics.yaml`.
- **Running the real stack against the bridge found two bugs in my own
  list** that the earlier, synthetic-consumer version of this simulation
  could not: the IMU lane was best_effort while `imu_corrector` subscribes
  reliable (the bridge logged `requesting incompatible QoS` and the consumer
  would have got nothing), and the ZED's dynamic `/tf` was not listed at all
  (gyro_odometer would have dropped every sample, silently). Both fixed;
  both are in this run.

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

With the stack up and recording, old profiles then new:

```bash
just link pressure              # enP5p3s0, 60 s: tx mean at ~12 MB/s is the old world
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
