# The master/orin link in ONE domain: multicast scope and monitor scope

**Status**: simulated on a workstation, **not yet measured on the vehicle**.
The vehicle table below is deliberately empty; filling it is the next job.

**Branch**: `perf/spdp-multicast`. **Date**: 2026-09-23.

## Why this exists

`perf/domain-split` solved the link pressure by putting each host's stack in
its own DDS domain and bridging a named list of topics across. It worked —
148 kB/s peak on the vehicle — but every cross-host topic paid a bridge hop:
an extra copy, an extra scheduling boundary, extra jitter, on exactly the
topics `gyro_odometer` time-syncs against. That branch is reverted.

**Hard constraint on this branch: ONE domain.** No bridge, no second domain.

## What actually fills the link, and it is two separate things

Both have to be fixed. Neither does anything on its own, which is the single
most important result here and the one that is easy to get wrong.

### 1. Multicast sent for purely LOCAL readers (master → orin)

CycloneDDS picks a writer's destination by coverage: once a topic has two or
more reader **processes**, one multicast datagram beats several unicast ones.
The interface these profiles bind is the LAN NIC, so that datagram leaves the
machine whether or not anything on the far side wants it. On the master every
raw cloud has two readers before anyone touches anything — the preprocessing
container and the recorder — and opening RViz makes three.

This is why the vehicle measured ~12 MB/s on 2026-09-21 with the **master
alone** and the orin subscribed to nothing.

Fix: `<AllowMulticast>spdp</AllowMulticast>` in
`config/cyclonedds/{master,orin}.xml`. Multicast then carries SPDP participant
announcements only; data and SEDP go unicast to each matched reader, and a
local reader's locator is this host's own address, which the kernel routes over
`lo`.

### 2. Subscriptions the other host genuinely made (both directions)

`golfcart_system_monitor` is gated on `launch_web_monitor`
(`golfcart.launch.yaml:547-558`), which has **no host condition**, so it runs
on both machines — and it read one shared `monitor_topics.yaml`. Its entries
become real `create_subscription` calls, so:

- the **orin's** copy subscribed to the master's three point clouds and three
  GMSL images
- the **master's** copy subscribed to the ZED image (220 kB × 30 Hz = 6.6 MB/s,
  over half the link, for a liveness indicator)

`AllowMulticast` cannot help with these: they are real remote readers, so
`spdp` just sends them a unicast copy instead of a multicast one.

Fix: `golfcart_system_monitor` gains a sixth `host` field per topic
(`master|orin|any`), a `monitor_host` parameter, and a 1 Hz `/system/health`
`DiagnosticArray` (`hardware_id` = hostname, one `DiagnosticStatus` per locally
watched topic with `rate_hz` / `count`). Each host watches only what it
publishes and learns the rest from that summary. `/diagnostics` stays the
standard channel; `/system/health` is the extension, kept separate so a
per-topic rate table never enters Autoware's fault graph.

### What was ruled out

- **RViz** is not the cause and cannot be the fix. `golfcart.rviz` has 71
  enabled display subscriptions plus RViz's own `/tf` and `/tf_static`, and
  **no ZED topic** — its three Image panels are the master's own GMSL cameras.
  RViz is a third *local* reader; it pulls nothing across the link. It is also
  not running under `just launch-all` at all (`launch_unit_exec.sh:80` passes
  `rviz:=false`; RViz is `just tool rviz`).
- **CycloneDDS `<Partitioning>`**, the only per-topic transport allowlist
  Cyclone offers, is **compiled out** of `ros-humble-cyclonedds 0.10.5`:
  ```
  config: //CycloneDDS/Domain/Partitioning: NetworkPartition: unknown element
  ```
  `IgnoredPartitions` fails identically; the same config without the
  `<Partitioning>` block is accepted. There is no transport-level per-topic
  allowlist available in this binary.

## Simulated result (workstation, `scripts/testing/link_sim` flow model)

One DDS domain throughout. 100 Mbit/s veth, 20 s startup + 45 s steady.
Bytes are the whole run, master → orin, from a raw-socket sniffer.

| master → orin | shared monitor list | per-host + `/system/health` |
|---|---:|---:|
| `AllowMulticast=default` | 801,318,676 B | 801,408,324 B |
| `AllowMulticast=spdp` | 801,085,848 B | **3,513,644 B** |

orin → master, same runs: 441,066,760 B → **2,662,076 B**.

Read the table as: **only the corner works.** `spdp` alone is a 0.03 % change.
The monitor fix alone is a 0.01 % change. Together, 228×.

Combined ≈95 kB/s, against the three-domain bridge's 129 kB/s mean on the
vehicle — so one domain reaches the split's result without the hop.

Health of the local pipeline in the final configuration: `master_preprocess`
542 Velodyne / 568 Falcon scans in 45 s (~8.5 Hz against 10 Hz published); both
monitors receiving `diagnostics=112 health=112`.

### What is synthetic, so nobody over-reads it

- **Payload bytes.** Topology, topic names, message sizes, rates and QoS are
  the real ones; the bytes inside are filler. Routing does not depend on them.
- **Socket buffers are 208 kB, not the deployed 16 MB.** The workstation's
  `net.core.wmem_max` is 212992 and cannot be raised without root, and
  CycloneDDS treats an unmet `SocketSendBufferSize min` as fatal to the domain.
  The value is **identical across all five runs**, so the comparison holds, but
  absolute magnitudes are not the vehicle's.
- **It is a flow model, not Autoware.** Node counts differ; the DDS graph that
  decides routing does not.

## TODO: measure on the vehicle

Four cells, same two axes. `just link pressure` on the master's `enP5p3s0`
(`eno1` on the orin) during a steady period with both hosts up.

### Vehicle results — TO BE FILLED

| master → orin | shared monitor list | per-host + `/system/health` |
|---|---|---|
| `AllowMulticast=default` | TODO mean / peak kB/s | TODO mean / peak kB/s |
| `AllowMulticast=spdp` | TODO mean / peak kB/s | TODO mean / peak kB/s |

| orin → master | shared monitor list | per-host + `/system/health` |
|---|---|---|
| `AllowMulticast=default` | TODO | TODO |
| `AllowMulticast=spdp` | TODO | TODO |

Alongside each cell, record:

| what | how | why |
|---|---|---|
| TODO Velodyne scans kept | `ros2 bag info <bag> \| grep velodyne_points` | the master's own recorder lost scans to backpressure under the old profile |
| TODO `gyro_odometer` rate | `ros2 topic hz /localization/twist_estimator/twist_with_covariance` | it needs the ZED IMU *and* its `/tf`; it fell to ~2 Hz whenever the wire was full |
| TODO `imu_corrector` rate | `ros2 topic hz /sensing/imu/imu_data` | reliable, so it survives longest — a drop here means the link is badly gone |
| TODO multicast groups on the NIC | `just link groups` | under `spdp` the only DDS group on the LAN NIC should be SPDP, 239.255.0.1 |
| TODO NDT / localization still converges | RViz or `/localization/kinematic_state` | the point of the exercise |

### How to switch each axis

**Multicast axis** — `config/cyclonedds/{master,orin}.xml`, one element:
```xml
<AllowMulticast>spdp</AllowMulticast>   <!-- or: default -->
```
Both hosts must match. Re-launch after editing; a running `ros2` daemon keeps
its old profile.

**Monitor axis** — `monitor_host` reaches the node from
`golfcart.launch.yaml`, which passes its own `host`. To get the OLD behaviour
back for the control cell, override it:
```bash
just launch-all "monitor_host:=any"
```
`any` makes every instance watch every row, which is what the shared list did.
The per-host behaviour is the default once `host:=master` / `host:=orin`.

### Order to run them

Run the two `default` cells first and stop if the link is already saturated —
that reproduces the known 2026-09-21 state and confirms the instrument. Then
the two `spdp` cells. The interesting comparison is the diagonal: if either
single change appears to fix it on the vehicle, the simulation is wrong about
the mechanism and that is worth knowing.

## Reproducing the simulation

The flow model is not committed (it lives outside the tree). What is committed
is `scripts/testing/link_sim/`, which runs the REAL stack and needs
`net.core.wmem_max` ≥ 16 MB to create a domain at all:

```bash
just link sim baseline      # AllowMulticast default
just link sim spdp          # AllowMulticast spdp
just link pressure          # on the vehicle, enP5p3s0
just link groups            # which multicast groups are joined, per interface
```

`run.sh` derives BOTH profiles from `config/cyclonedds/*.xml` with one element
rewritten, and writes `profiles.diff` to prove the one-line delta; the frozen
copies under `baseline/` predate the `SocketSendBufferSize` commit and would
have credited `AllowMulticast` with that fix as well.

## Open questions

- Does the orin's `golfcart_system_monitor` actually need `/diagnostics` from
  the master, or only its own? It is `any` today, so both hosts watch their own
  copy — cheap either way, but unverified as a design choice.
- `/system/health` has no consumer in the web UI yet. The node stores peer rows
  keyed by `hardware_id`; rendering them is not done.
- The ZED IMU stays cross-subscribed on purpose (100 Hz of `sensor_msgs/Imu`,
  tens of kB/s, and `imu_corrector` reads it anyway). Worth confirming on the
  vehicle that it is as cheap as assumed.
