# config/ — the single source of truth

Everything that differs between machines, deployments or recording sessions lives
here. Nothing in `scripts/` hardcodes any of it; each script reads these files, so
changing a value here changes it for every consumer on both hosts.

| File | Format | What it decides |
|---|---|---|
| `host` | one word (`master` or `orin`) | which machine this checkout is on. Selects the DDS profile. **Gitignored** — it is a property of the machine, not the branch |
| `multi_machine.conf` | shell assignments | the other host's `user@addr`, its repo path, the ssh key, the master's IP |
| `sensors.conf` | shell assignments | which IMU and camera driver the sensor kit uses (`IMU_SOURCE`, `CAMERA_MODEL`), and which host runs the LiDAR drivers (`LIDAR_HOST`) |
| `vehicle.conf` | shell assignments | whether the vehicle interface may transmit on CAN (`GOLFCART_TX_ENABLED`) |
| `ntrip.param.yaml` | ROS 2 parameter YAML | the NTRIP caster account for RTK corrections. **Gitignored**, it is a secret; start from `ntrip.param.yaml.example`. Exported as `NTRIP_PARAM_FILE`, read only with `use_ntrip:=true` |
| `runtime.conf` | shell assignments | how play_launch runs composable nodes (`GOLFCART_CONTAINER_MODE`), which middleware this host uses (`GOLFCART_RMW`), and the three ROS domain ids: master stack 50, orin stack 60, wire 10 |
| `recording/master_topics.txt`<br>`recording/orin_topics.txt` | one topic per line, `#` comments | what each host records |
| `link/topics.yaml` | YAML | what crosses the master/orin wire, in which direction, with what QoS. One file, read by both hosts' bridges |
| `cyclonedds/{master,orin,loopback}.xml` | CycloneDDS XML | DDS network profiles, one per role. `master` and `orin` bind the stack domain (50 / 60) to `lo` and only the link domain (10) to the LAN |
| `zenoh/{master,orin}-session.json5` | Zenoh JSON5 | Zenoh session profiles, used only when `GOLFCART_RMW=zenoh`. **Generated** — see [`zenoh/README.md`](zenoh/README.md) |

Formats are deliberately unlike each other: the topic lists are edited by hand and
diffed per line, so a flat list beats YAML; `multi_machine.conf` is sourced by
shell scripts, so it is shell; the DDS profiles are XML because CycloneDDS reads
them directly and we do not want to generate them.

## Setting the host marker

```bash
echo master > config/host      # or: orin
just service doctor                    # confirms what resolved, and from where
```

Precedence, highest first: `GOLFCART_ENV_ROLE` (how the systemd units state their
role), then an exported `GOLFCART_DDS_PROFILE`, then this file, then `loopback`.
A marker naming a profile with no `cyclonedds/<name>.xml` is reported loudly and
falls back to `loopback` — silently running the wrong profile is the failure this
machinery exists to prevent.

The older location `.golfcart-host` in the repo root is still read when
`config/host` is absent, so an existing checkout keeps working after a pull.

## Changing the other host

`multi_machine.conf` keys take their value from the `GOLFCART_`-prefixed
environment variable of the same name when it is set, so an override still wins
for one shell or one unit:

```sh
ORIN_SSH="${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}"
```

`ORIN_WORKSPACE` accepts `~/path` or an absolute path; the tilde is expanded by
the *remote* shell, since this machine's `$HOME` is the wrong answer.

## Changing the IMU or camera

`sensors.conf` holds `IMU_SOURCE` and `CAMERA_MODEL`. They are **environment
variables, not launch arguments**, and that is forced rather than chosen:
`golfcart.launch.yaml`'s `imu_source:=` reaches `golfcart_autoware.launch.xml`,
but the path onwards runs through two installed Autoware files that forward a
fixed set of arguments and drop the rest. So `just launch "imu_source:=zed"`
looks like it works and does nothing; `IMU_SOURCE=zed` is what the sensor kit
actually reads.

Currently `IMU_SOURCE=zed` — the ZED X's built-in IMU, published by the orin —
because the Xsens MTi is broken.

## Moving the LiDAR drivers

`sensors.conf` also holds `LIDAR_HOST` — `master` (default) or `orin` — naming
which host runs the Velodyne VLP-32C (nebula) and Seyond Falcon drivers. Same
environment-variable mechanism as `IMU_SOURCE` for the same forced reason: the
launch argument path from `golfcart.launch.yaml` down to `lidar.launch.xml`
runs through the same installed tier4 files.

Point cloud preprocessing and concatenation are **not** governed by this — they
always run on the master and consume the drivers' topics over DDS, wherever
`LIDAR_HOST` put the drivers.

`LIDAR_HOST=orin` is a placement knob, not a switch to flip today: each raw
LiDAR is ~30 MB/s (~240 Mb/s for both), and the master↔orin link is a shared
100 Mb/s LAN — it cannot carry them. See
[docs/roadmaps/8-lidar-on-orin.md](../docs/roadmaps/8-lidar-on-orin.md) for the
full accounting and what has to move first (network profiles, PTP).

## Turning CAN TX on

`vehicle.conf` holds `GOLFCART_TX_ENABLED`. With it `false` — the default — the
vehicle interface only listens: `/vehicle/status/*` and `/diagnostics` fill in
normally and nothing we publish can move the cart.

It is an environment variable for the same forced reason as `IMU_SOURCE`: the
one installed Autoware file in between,
`tier4_vehicle_launch/vehicle.launch.xml`, forwards exactly `vehicle_id`,
`raw_vehicle_cmd_converter_param_path` and `initial_engage_state` to our
`vehicle_interface.launch.xml` and drops the rest. `just launch
"tx_enabled:=true"` looks like it works and does nothing.

Use the `tx=` token instead — the justfile strips it out of the launch
arguments and puts it in the environment:

```bash
just launch tx=on          # single machine, foreground
just launch-up tx=on       # this host, via systemd
just launch-all tx=on      # both hosts; TX applies to the master only
```

⚠️  `tx=on` puts real frames on `can0` and the cart can be commanded into motion.

`launch-all` splits the token off and forwards only the remaining launch
arguments to the orin. CAN is the master's alone — the orin has no bus, and
`golfcart.launch.yaml` gates the vehicle group on `is_master` — so the orin's
`launch-up` runs without `tx=` and therefore clears `GOLFCART_TX_ENABLED` in its
own user manager rather than inheriting a value from an earlier run.

`just service host-status` (and `just service status`, which runs it on both hosts)
prints the effective setting next to the unit states, and names where it came
from: `unit-env` when `launch-up` set it for this run, `config/vehicle.conf`
when nothing is set.

TX is deliberately **not sticky**. `launch-up` writes it into the user manager's
environment for that invocation only: an invocation that does not say `tx=`
clears it, and `launch-down` clears it too. Editing `vehicle.conf` changes the
resting default for the machine and does make it apply to every launch, which is
why the file is the wrong place to switch it on for one test.

`just vehicle interface tx=on` is a different path — it bypasses Autoware
entirely and passes `tx_enabled:=` as a real launch argument.

## Changing what is recorded

Record **first-hand driver output**. Topics a node computed from other topics —
the concatenated cloud, the corrected IMU — are commented out in the lists, since
replay is a logging simulation: the single-machine stack runs with drivers
disabled against the merged bag and recomputes them, using today's parameters
rather than the ones frozen at record time.

A topic that is expected but dead stays listed and records zero messages, on
purpose. `/sensing/imu/xsens/imu_raw` is the current example. An empty topic in a
bag says "this device was expected and was silent"; an absent one says nothing,
and months later nobody can tell which it was.

Edit the topic lists — not any script. Audit them against a running stack:

```bash
ros2 topic list > /tmp/live.txt
grep -vE '^\s*(#|$)' config/recording/master_topics.txt | tr -d ' ' \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

A stale entry records zero messages while still appearing in `ros2 bag info`,
which reads as "the sensor was quiet" rather than "the name is wrong".

## What crosses the link

`link/topics.yaml`. Under the `master` and `orin` profiles the stack runs in
ROS domain 0 bound to `lo`, so nothing in it can reach the wire; only the link
domain (`GOLFCART_LINK_DOMAIN_ID` in `runtime.conf`, 10) is on the LAN, and its
only participant per host is `golfcart_domain_bridge`, which copies the topics
in this file across in the direction the file gives them. The wire therefore
carries exactly this list plus the discovery traffic of two participants, and
nothing an operator's `ros2 topic echo` on either host can add to it.

Add a topic by adding an entry (name, `pkg/msg/Type`, QoS, optional `max_hz`);
the type support has to exist on both hosts. Never list one topic in both
directions: the bridge refuses to start, because the alternative is an echo
loop. `just link topics` shows the wire; `just link pressure` measures it.
Before this split the wire carried every raw cloud the master's recorder
read, as multicast, whether or not the orin wanted it: the link at its
100 Mbit/s ceiling in simulation with the real stack, and the master's own
recorder losing more than half its scans to the backpressure:
[docs/research/system/domain-split-link-pressure.md](../docs/research/system/domain-split-link-pressure.md).

## Choosing the container mode

`runtime.conf` holds `GOLFCART_CONTAINER_MODE`, which every `play_launch`
invocation in this repo passes through as `--container-mode`. Three values:

| mode | processes | DDS participants | a node segfaults |
|---|---|---|---|
| `observable` (default here) | one per container | one per container | takes its container's ~6 nodes with it |
| `isolated` (play_launch's own default) | one per composable node | **one per node** | takes only itself down, and play_launch names it |
| `stock` | one per container | one per container | as `observable`, but no ComponentEvents, so the web UI cannot list nodes |

The default is `observable` rather than play_launch's `isolated` because
`isolated` is what pinned all 12 cores on the Advantech. Measured with
`just profile report` and `just profile perf` on the full stack:

    isolated:  84 composable nodes ran as 84 extra processes
               -> 149 DDS participants -> 1036 CycloneDDS threads
               -> 3739 threads on 12 cores, loadavg 276
               -> ~76% of all CPU samples inside Cyclone's own threads
                  (tev / recv / recvMC / recvUC / gc / dq.*),
                  with Autoware's real work under 10%

Discovery, heartbeat and liveliness traffic grows with the square of the
participant count, which is why the per-node mode is not a linear cost.

`isolated` still earns its keep while you are chasing a crash, because it tells
you *which* node died instead of which container. Turn it on for that run only:

```bash
GOLFCART_CONTAINER_MODE=isolated just launch
```

Like every other key here, an already-set value wins, so that override needs no
edit to the file and does not persist into the next launch.

**There is no per-container setting.** In play_launch 0.9.0 `--container-mode`
is global, and the `-c/--config` RuntimeConfig schema (`monitoring`,
`composable_node_loading`, `container_readiness`, `diagnostics`, `interception`,
`startup`, `processes`) has no equivalent key, so isolating one suspect
container while the rest stay composed is not expressible today. It needs an
upstream change to play_launch.

## Choosing the middleware

`GOLFCART_RMW` in `runtime.conf` selects `cyclonedds` (the deployed default) or
`zenoh`. It is a per-host setting and **both machines must agree**: the two share
no wire protocol, so a mismatched pair does not fail — each host comes up cleanly
and never sees the other's topics.

Switching it is not sufficient on its own. The ros2 daemon binds its middleware
when it starts and its port does not depend on the RMW, so a leftover daemon
answers every graph query from an empty world. `scripts/rmw/ensure.sh` handles
that on every launch; by hand it is `just rmw daemon-stop`.

Under `zenoh` there is no extra daemon: peers discover each other by multicast
scouting and link directly, the same shape as the CycloneDDS setup. What must
hold instead is that the interface carrying this host's LAN address has the
`MULTICAST` flag — without it every node starts, publishes and is discovered by
nobody. Full reasoning, the topology, and what is not yet measured:
[`zenoh/README.md`](zenoh/README.md).

```bash
just rmw status         # what this host is actually on
just service host-status   # and whether the other host agrees
```

## Shared memory (Iceoryx) — removed

Removed on 2026-09-02, along with `config/iceoryx/roudi.toml`,
`scripts/iceoryx/`, the `iox-roudi.service` unit, the setup step, and the guards
in `scripts/env.sh` and the justfile.

It never worked here. iceoryx caps publisher ports at `IOX_MAX_PUBLISHERS = 512`
and that is a **compile-time** constant: `iceoryx_posh_deployment.hpp` is
autogenerated and says so, and `roudi.toml` sized mempools and nothing else.
Cyclone registers a publisher port per writer even for types it cannot loan, so
a stack this size exhausts the pool regardless of message type, and the failure
is a hard abort at participant creation rather than a fallback to the network
transport:

```
[Warning]: ICEORYX error! PORT_POOL__PUBLISHERLIST_OVERFLOW
[ Error ]: ICEORYX error! EXPECTS_ENSURES_FAILED
```

Bringing it back is a source rebuild of iceoryx with a raised limit, not a config
change, so nothing in the repo pretends otherwise any more. The three CycloneDDS
profiles carry a comment saying what would be involved.

