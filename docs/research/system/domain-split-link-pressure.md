# The master/orin link: one domain on the wire vs. a bridged link domain

**Date**: 2026-09-22. **Branch**: `perf/domain-split`.
**Status**: measured in simulation on a workstation; **not yet measured on the vehicle.**

## The problem as reported

Advantech (master) and orin share a 100 Mb/s segment. Under load the link
fills in bursts and has dropped outright. Both hosts ran one CycloneDDS domain
bound to the LAN interface (`config/cyclonedds/{master,orin}.xml` before this
branch), so every participant on either machine was on the wire.

## What that configuration puts on the wire, by construction

Three things, none of them the topics anyone chose to share:

1. **Discovery, O(participants × endpoints).** The master runs ~140 nodes and
   ~550 topics. Every participant that appears on the orin — the ZED driver,
   the recorder, every `ros2 topic list` — receives the master's whole
   endpoint set, and the master receives the orin's. Every restart of either
   side repeats it.
2. **Data the master never meant for the orin.** CycloneDDS 0.10 picks a
   writer's destination by coverage: the locator that reaches the most
   readers wins. A topic with two or more reader processes is reached by one
   multicast datagram or several unicast ones, so multicast wins, and a
   multicast datagram leaves the NIC whether or not anything on the far side
   subscribed. Autoware's sensing chain is exactly that shape: each
   intermediate cloud has several readers.
3. **Anything an operator touches.** `ros2 topic echo` of the ZED image on the
   master pulls the whole 5 MB/s stream across, because the topic is there
   to echo.

Domain ids on their own fix none of this: a domain is a port offset, and a
multicast datagram in domain 5 leaves the NIC exactly as one in domain 0 does.
What fixes it is **which interface each domain is bound to**.

## The split

`config/cyclonedds/master.xml` and `orin.xml` now hold two `<Domain>`
sections (CycloneDDS merges an `Id="any"` section with a specific one, and
expands `${VAR}` in the `Id` attribute; both verified with `Tracing
Category=config` before relying on them):

| domain | interface | who is in it |
|---|---|---|
| `0` (ROS_DOMAIN_ID unset) | `lo` | the whole stack, on both hosts, exactly as `loopback.xml` runs it single-machine |
| `${GOLFCART_LINK_DOMAIN_ID:-42}` | the LAN address | one `golfcart_domain_bridge` per host, and any CLI pointed at it |

`golfcart_domain_bridge` (`src/system/golfcart_domain_bridge`, ~300 lines of
rclcpp, two contexts in one process) copies the topics listed in
`config/link/topics.yaml` between the two domains as serialized bytes, in the
direction the file gives. The list today: the orin's IMU, `camera_info`,
`/diagnostics` and `/tf_static`, to the master; nothing back.
`golfcart.launch.yaml` starts it under `host:=master` and `host:=orin`.

So the wire carries: the listed topics, plus the discovery of two
participants. Nothing else *can* reach it.

## Measurement

`scripts/testing/link_sim/run.sh` (`just link sim baseline|split`). Two
network namespaces joined by a veth pair on the real addresses, so the real
profiles run unchanged; no root (unprivileged user namespace). Per-second
counters on the veth via `/proc/net/dev` (`scripts/check/link_pressure.sh`,
the same script to run on `enP5p3s0`), and a raw-socket sniffer that charges
every byte to a DDS domain and to multicast or unicast by destination port.

| side | runs |
|---|---|
| master | Autoware 1.5.0 `planning_simulator.launch.xml` (sample map, sample vehicle: 142 nodes, 552 topics — the discovery load); `fake_lidar.py`, one 1.2 MB PointCloud2 at 10 Hz with three reader processes (the byte load a planning sim lacks; ~12 MB/s offered); `probe.py`, the IMU consumer, instrumented |
| orin | `fake_zed.py`: IMU 100 Hz, `camera_info` 15 Hz, compressed image 15 Hz × 330 kB (~5 MB/s), `/diagnostics` 1 Hz, `/tf_static` latched — real names, real rates |
| both | `ros2 topic list --no-daemon` every 10 s (an operator's fresh participant); the master `ros2 topic echo`es the ZED image for 15 s once (an operator's mistake) |

40 s startup window, then 60 s steady with the 15 s echo carved out. Baseline
uses the pre-split profiles frozen in `scripts/testing/link_sim/baseline/`;
split uses what is checked in, plus the bridges reading the real
`config/link/topics.yaml`. Workstation: Ryzen 9 9950X, Ubuntu 22.04, ROS 2
Humble, CycloneDDS 0.10.5. Run twice each; the two baselines agreed to within
1 % on every mean, so one of each is archived in
[`data/link-sim/`](data/link-sim/).

## Results

Seen at the master's end of the veth. tx = master → orin, rx = orin → master.

| window | metric | one domain on the LAN | split | change |
|---|---|---:|---:|---:|
| steady | **tx mean** | **13 466 kB/s (108 Mbit/s)** | **2.2 kB/s** | −100 % |
| steady | tx peak second | 18 640 kB/s (149 Mbit/s) | 12.4 kB/s | −99.9 % |
| steady | tx packets/s | 10 495 | 6 | −99.9 % |
| steady | rx mean | 103.7 kB/s | 55.0 kB/s | −47 % |
| steady | rx peak second | 475.8 kB/s | 78.9 kB/s | −83 % |
| startup | tx peak second | 28 281 kB/s (226 Mbit/s) | 31.6 kB/s | −99.9 % |
| startup | tx total, 40 s | 536 MB | 87 kB | |
| echo | rx mean | 4 939 kB/s (39.5 Mbit/s) | 53.9 kB/s | −98.9 % |

| data path, at the master | one domain | split |
|---|---:|---:|
| IMU rate | 99.7 Hz | 99.8 Hz |
| IMU latency, mean | 0.119 ms | 0.165 ms |
| IMU latency, p99 | 0.309 ms | 0.423 ms |
| orin `/diagnostics` received in 100 s | 100 | 99 |
| `/tf_static` frames | 32 | 32 |

| what a fresh `ros2 node list` on the orin discovers | one domain | split |
|---|---:|---:|
| nodes | 142 | 2 (domain 0) / 2 (link) |
| topics | 552 | 7 / 6 |

Where the baseline's bytes went, by the sniffer (whole 100 s run,
master → orin):

| class | bytes | share |
|---|---:|---:|
| domain 0, **multicast data** | 1 253 MB | 94.5 % |
| domain 0, unicast discovery | 67 MB | 5.1 % |
| domain 0, multicast discovery | 3.1 MB | 0.2 % |
| domain 0, unicast data (the orin's real subscriptions) | 1.3 MB | 0.1 % |

After the split every byte on the wire is in domain 42: 5.4 MB of unicast
data orin → master in 100 s (the IMU, `camera_info`, diagnostics), 0.3 MB of
discovery in both directions together, nothing multicast but SPDP.

## What this says

- **The master was offering the link 13.5 MB/s that nobody on the orin had
  asked for**, 94 % of it domain-0 multicast data: one synthetic LiDAR
  topic with three local readers, fanned out of the NIC. On a 100 Mb/s
  segment that alone is over capacity before a single wanted byte moves. The
  real master runs two LiDARs through a preprocessing chain with more readers
  per stage than this; the real number is larger, and it is the thing to
  measure first on the cart.
- **Startup is a 226 Mbit/s second**, and every `ros2 topic list` on the orin
  is a fresh SEDP exchange with 142 nodes. The split makes the orin's fresh
  participant see 2 nodes.
- **The accidental image echo cost 5 MB/s before and costs nothing after**,
  because the topic is no longer where an echo can find it. Bringing it
  across is now a deliberate line in `topics.yaml`, with a rate cap.
- **The data path is intact**: 100 Hz IMU through two bridges at +0.05 ms
  mean, +0.1 ms p99. Diagnostics and static TF arrive.
- Reliability is unchanged in what remains: the bridge publishes with the QoS
  in the list, so `/diagnostics` and `/tf_static` stay reliable and the IMU
  stays best-effort, which is what their consumers expect.

## What this does not say

The veth has no 100 Mb/s ceiling and drops nothing, so it measures what the
stacks *offer* the link, not what a saturated i226 does with it. That is the
right instrument for the question the split answers. It is silent on:

- the link **disconnecting**. DDS cannot take an interface down. A flapping
  `igc` link under load is a NIC, cable, EEE/ASPM or 4G-router-port problem
  (`dmesg | grep -i 'link is'`, `ethtool --show-eee enP5p3s0`, and why a
  2.5 GbE NIC negotiates 100 Mb at all). The split removes the load that
  triggers it, not the fault.
- the real master's numbers. Two LiDARs, CUDA preprocessing, cameras: the
  offered load is different, almost certainly larger.
- CPU. Cyclone's discovery cost on the orin also drops (2 remote
  participants instead of 142), but that was not measured here.

## On the vehicle

Before merging to the cart, with the stack up and the orin idle, then up:

```bash
just link pressure              # enP5p3s0, 60 s: tx mean and peak are the numbers
just link nodes                 # exactly two bridges
just link hz /sensing/camera/zed/imu/data
ros2 topic hz /sensing/camera/zed/imu/data   # the same, arrived in domain 0
```

Expect tx to fall from whatever it is now to tens of kB/s, and the IMU to
hold 100 Hz. If a master consumer of an orin topic goes quiet, the topic is
missing from `config/link/topics.yaml`; the bridge logs every lane it opened
and every one it could not.

## Alternatives weighed

- **`ros2/domain_bridge`**: would do the same job; not in the workspace, and
  lacks the per-topic rate cap. Switch if the bridge grows.
- **CycloneDDS multi-interface (`lo` + NIC) in one domain**: halves the
  problem at best; discovery still fans out, and whether the same-host
  locator choice keeps data off the NIC is exactly the thing nobody can
  verify here.
- **Zenoh with a router allow-list**: same effect, but `GOLFCART_RMW=zenoh`
  has never brought Autoware up (`config/zenoh/README.md`).
- **The 1 Gb/s interlink** (`scripts/hardware/network/setup-interlink.sh`):
  ten times the ceiling and no shared segment. Orthogonal; composes with
  this, and is the cheapest test of whether the disconnects are load or NIC.
