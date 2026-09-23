# The master/orin link in ONE domain: multicast scope and monitor scope

**Status**: **all four vehicle cells measured plus an isolation run,
2026-09-23. Half the branch is proved; the link is still full.**

The corner — `spdp` plus the per-host monitor, which the simulation put at
228× — measures 12336.9 kB/s mean master → orin, against a one-domain baseline
of ~12100. But with the orin's stack stopped and nothing else changed, the same
configuration measures **676.1 kB/s**. So `AllowMulticast=spdp` does keep
local-reader traffic off the NIC, and the remaining ~11.7 MB/s is a real
subscriber on the orin that the source audit says should not exist. Do not
merge on the strength of the simulated table; the next step is two commands on
the orin, at the end of this section.

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

### Vehicle results — all four cells measured, 2026-09-23

Each cell is `just link cell <multicast> <monitor>`, which is the whole
procedure: both profiles set, `just launch-all`, both recorders started, 60 s
of NIC counters on both hosts at once, teardown, `spdp` restored.

| master → orin | shared monitor list | per-host + `/system/health` |
|---|---|---:|
| `AllowMulticast=default` | **11431.6 / 12633.0 kB/s** | **11236.1 / 12715.5 kB/s** |
| `AllowMulticast=spdp` | **12347.2 / 12425.6 kB/s** | **12336.9 / 12399.0 kB/s** |

| orin → master            | shared monitor list        | per-host + `/system/health` |
|--------------------------|----------------------------|-----------------------------|
| `AllowMulticast=default` | **9961.1 / 12382.5 kB/s**  | **10641.0 / 12380.3 kB/s**  |
| `AllowMulticast=spdp`    | **10596.4 / 12349.3 kB/s** | **10963.6 / 12359.3 kB/s**  |

Cells: `log/link_cells/default-shared_20260923-114136` and
`default-perhost_20260923-115959`. mean / peak over 60 s.

**The monitor fix alone does nothing, on the vehicle as in the simulation.**
Per-host scoping moves master → orin by 1.7 % (11431.6 → 11236.1 kB/s mean) and
moves orin → master the WRONG way by 6.8 % (9961.1 → 10641.0). On a link pinned
at its ceiling that is run-to-run noise, not an effect. Whatever fixes this
link, it is the multicast axis — and per the simulation, only both together.

The Velodyne is lossless in both cells: 1412 scans in 141.4 s and 1365 in
136.6 s, both 9.98 Hz against 10 Hz published. The storm is outbound; the
recorder is a local reader and never touches the wire.

**`spdp` alone is WORSE, not merely useless**
(`log/link_cells/spdp-shared_20260923-121039`). 12347.2 kB/s mean master →
orin, above both `default` cells, and the mechanism is not subtle: with the
shared monitor list the orin's copy genuinely subscribes to the master's three
clouds and three GMSL images, so a payload that was one multicast datagram
becomes one unicast copy per remote reader. Removing multicast without removing
the subscriptions multiplies the bytes.

**That cell also settles the missing-rx question.** The master's rx mean goes
from 95.6 and 341.2 kB/s in the `default` cells to 10634.2 kB/s here, against
the orin's own tx of 10596.4 — agreement to 0.4 %. Unicast is not subject to
IGMP snooping, so the 100× shortfall under `default` was multicast that never
reached the master's NIC, not an accounting error, and reading each direction
from the sending host's tx was the right call.

Instrument health in that cell, now that the control exists: the local control
topic `/sensing/lidar/vlp32/velodyne_points` held 10.00 Hz throughout
(9.975–10.034 over 21 windows), so CLI discovery is unaffected by the load and
an empty row means an empty topic. `/sensing/imu/imu_data` arrives but bursty,
13.2–128.6 Hz across the window against 100 Hz published — the ZED IMU crossing
a saturated link, which is exactly the jitter `gyro_odometer` time-syncs
against. `/localization/twist_estimator/twist_with_covariance` is silent
because the cart is stationary with no velocity source, not because of the
link; that row needs a moving vehicle and does not belong to this matrix.

**Read each direction from the SENDING host's own tx counter.** The master's rx
column disagrees with the orin's tx column by a factor of 100 — the orin's NIC
counted 597,666,196 B sent in the window, the master's counted 5,735,045 B
received — with zero errors and zero drops at both ends, 100 Mb/s full duplex
confirmed by ethtool on both. The lifetime counters carry the same ratio, so it
is not a one-off. The likely mechanism is IGMP snooping: under the storm the
master's own membership reports compete with 91 Mbit/s of outbound DDS, the
switch times the master's port out of the group, and orin → master multicast
stops being forwarded. Whatever the cause, a host's account of what it sent is
not in doubt, so that is the number this table carries.

**The orin has the same disease as the master.** 9961 kB/s leaving the orin is
not the monitor's cross-subscriptions alone; its own local readers are enough to
put the ZED image on the wire. Both fixes are needed on both hosts, which the
simulation predicted and this confirms.

Alongside, from the same cell:

| what                                              | result                                                                                                                                                                                                      |
|---------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Velodyne scans kept                               | 1412 in 141.4 s = 9.98 Hz — **no loss**. The storm is outbound; the master's recorder is a local reader and never sees the wire.                                                                            |
| readers on `/sensing/lidar/vlp32/velodyne_points` | 3 subscriber processes: `golfcart_system_monitor`, `rosbag2_recorder`, `vlp32_cuda_pointcloud_preprocessor_node` — exactly the "two or more reader processes" that makes Cyclone pick the multicast locator |
| `gyro_odometer` / `imu_corrector` rates           | **not obtained** — see below                                                                                                                                                                                |
| multicast groups on the NIC                       | `239.255.0.1 users 132` on `enP5p3s0`, and nothing else                                                                                                                                                     |
| localization converges                            | not applicable; the cart was stationary with no map loaded                                                                                                                                                  |

### Two instrument problems this cell exposed

**`just link groups` cannot discriminate, and the check as written is wrong.**
CycloneDDS uses 239.255.0.1 for SPDP *and* for user data by default, so "any
239.255.0.x DATA group means a profile did not take" describes a signal that
never appears: under `default` the data simply goes to the SPDP group, with the
join count rising (132 users here). The instrument that does work is the reader
census — `ros2 topic info -v`, which names every subscriber and its host, and is
a graph query so it adds no reader to the topic it reports on.

**`ros2 topic hz` returned nothing for either small topic**, and as written the
cell cannot tell "the link starved them" from "the CLI could not discover under
load". Both readings are plausible at 91 Mbit/s. Needs a control — a topic known
to be publishing locally — before either row can be believed.

The orin's `just link groups` also timed out mid-storm. Like the NIC sample, it
has to be collected into the orin's own `log/` during the cell and fetched after
teardown; an ssh opened while the wire is full is not an instrument.

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

## The corner cell FAILED on the vehicle, 2026-09-23

`log/link_cells/spdp-perhost_20260923-121720`: **12336.9 kB/s mean**, 12399.0
peak, master → orin, with 10963.6 kB/s coming back. The configuration the whole
branch exists to produce is indistinguishable from doing nothing.

For scale, the committed baseline of the *earlier* domain-split experiment
(`docs/research/system/data/link-sim/baseline_record/summary.md`, one domain,
`AllowMulticast` default) is 12100.0 kB/s steady. Every vehicle cell, including
the corner, sits on that number:

| run | steady master → orin |
|---|---:|
| old sim baseline, one domain, default | 12100.0 kB/s |
| vehicle `default` + shared | 11431.6 |
| vehicle `default` + per-host | 11236.1 |
| vehicle `spdp` + shared | 12347.2 |
| **vehicle `spdp` + per-host** | **12336.9** |

The simulation predicted 801 MB → 3.5 MB for this cell. It did not happen.

**The cell is not contaminated.** Its `run.log` opens with `launch inactive` on
both hosts and both ros2 daemons stopped, and the copied profiles in the cell
directory show `spdp` on both machines before launch. The units load that
profile through `launch_unit_exec.sh`, which sets `GOLFCART_ENV_ROLE=master` and
**aborts** if the resolved profile is not the host's own, so a silently wrong
transport is not possible either.

### What the audit rules out

The monitor half of the branch was read line by line after the failure, and it
is correct:

- every one of the 21 rows in `monitor_topics.yaml` carries the sixth field:
  16 `master`, 3 `orin` (the ZED image, its `camera_info`, its IMU), `/rosout`
  and `/diagnostics` as `any`. No row falls back to `any` by accident.
- the host test in `_setup_subscriptions` runs **before** `_create_subscription`,
  so a foreign row creates no subscription at all rather than being filtered at
  report time — the only version that saves anything.
- the node creates exactly **one** publisher, `/system/health`. It does not
  publish `/diagnostics`; that row is watched, and Autoware's own
  `system_monitor` publishes it on both hosts.
- `/system/health` carries metadata only: per watched topic, `display_name`,
  `type`, `rate_hz`, `count`, plus OK / `STALE` / `NO DATA`. No sample contents.
  One topic name shared by both hosts, not one per watched topic: the master's
  summary is 16 statuses once a second, the orin's is 3.

### Every subscription that legitimately crosses, and what it costs

| subscriber             | remote topic                                             | scale                     |
|------------------------|----------------------------------------------------------|---------------------------|
| master `imu_corrector` | `/sensing/camera/zed/imu/data` (`IMU_SOURCE=zed`)        | 100 Hz × ~300 B ≈ 30 kB/s |
| master `gyro_odometer` | the ZED driver's dynamic `/tf`                           | small                     |
| master recorder        | `/tf`, `/tf_static`, `/diagnostics` (both hosts publish) | small                     |
| both monitors          | `/diagnostics`, `/rosout`, `/system/health`              | ~1 Hz                     |

Both recording lists are otherwise host-local: the master records its own
clouds, GMSL images and vehicle status; the orin records four ZED topics and
`/tf_static`. Nothing in this table is within two orders of magnitude of
12 MB/s.

### The three candidates, and which survived

1. **`AllowMulticast=spdp` does not stop data leaving the NIC for purely LOCAL
   readers.** **DISPROVED** — see the isolation run below.
2. **A subscriber that no config records.** `rosbridge` runs on both hosts
   (`launch_rosbridge` defaults true) and creates subscriptions *on client
   request*, so a browser tab on either host's web UI pulls topics across the
   link invisibly to any file review. **Struck**: the operator confirms no
   browser was open during any cell.
3. **Something on the orin genuinely subscribes to the master's sensor data**,
   despite `monitor_host:=orin`. **The one left standing.**

### The isolation run settles the transport, 2026-09-23

`log/link_cells/spdp-perhost_20260923-125011`, run as
`GOLFCART_USE_ORIN=0 just link cell spdp perhost`: the master launches alone,
nothing runs on the orin, everything else identical.

| configuration | master tx mean |
|---|---:|
| `spdp` + per-host, orin up | 12336.9 kB/s |
| **`spdp` + per-host, orin stack DOWN** | **676.1 kB/s** |

**18× lower with nothing on the far side, so `AllowMulticast=spdp` works.** It
does keep a cloud with three local reader processes off the LAN NIC — which is
precisely what the 2026-09-21 storm was, and precisely what this branch set out
to fix. The transport half of the design is sound and stays.

It follows that the missing ~11.7 MB/s is a **real remote reader on the orin**.
That is candidate 3, and it contradicts the source audit above: with
`monitor_host:=orin` the monitor creates no subscription for a `master` row,
and nothing else in either recording list or launch file asks for a master
cloud. One of those two readings is wrong, and only the running system can say
which.

**The next measurement is two commands, on the orin, with both stacks up:**

```bash
ros2 param get /golfcart_system_monitor monitor_host   # did the param arrive?
ros2 node info /golfcart_system_monitor                # what does it subscribe to?
```

If `monitor_host` is not `orin`, the parameter never reached the node and the
bug is in launch plumbing, not in the monitor. If it is `orin` and the master's
clouds are still in its subscription list, the filter does not do what the code
reads like. If that node is clean, the subscriber is something else on the orin
and every topic needs a census from the orin's side.

Two smaller facts from the same run, recorded so they are not rediscovered:

- **676 kB/s mean with 5.2 MB/s peaks still leaves the master** when the orin
  runs nothing at all. Discovery accounts for some of it; `just record start`
  is not gated on `GOLFCART_USE_ORIN`, so the orin's recorder came up and
  subscribes `/tf_static` from the master. Small against 12 MB/s, but it is not
  zero and nobody has accounted for all of it.
- **Teardown took one second here**, against the 4+ minutes it hung in the
  corner cell. `GOLFCART_USE_ORIN=0` removes the orin ssh from `stop-all`,
  which localises that hang to the remote `just launch-down`, not to the
  network.

Note that the spdp simulation's raw logs are **not in the repository** — commit
`283f741` added 195 lines of prose and no data, and the model itself lives
outside the tree — so its table cannot be audited from here. Only the older
domain-split runs under `docs/research/system/data/link-sim/` are committed.
Whatever the outcome, a claim that cannot be re-derived should not have been
recorded as a result.

### Where this stands

The branch is **half proved and half open**. `spdp` demonstrably keeps
local-reader traffic off the wire; the per-host monitor demonstrably does not
empty the link, because something on the orin is still reading the master's
sensors. Merging now would ship a transport fix whose benefit is entirely
masked by that reader, so the two commands above come first.

## Open questions

- Does the orin's `golfcart_system_monitor` actually need `/diagnostics` from
  the master, or only its own? It is `any` today, so both hosts watch their own
  copy — cheap either way, but unverified as a design choice.
- `/system/health` has no consumer in the web UI yet. The node stores peer rows
  keyed by `hardware_id`; rendering them is not done.
- The ZED IMU stays cross-subscribed on purpose (100 Hz of `sensor_msgs/Imu`,
  tens of kB/s, and `imu_corrector` reads it anyway). Worth confirming on the
  vehicle that it is as cheap as assumed.
