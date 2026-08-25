# config/ — the single source of truth

Everything that differs between machines, deployments or recording sessions lives
here. Nothing in `scripts/` hardcodes any of it; each script reads these files, so
changing a value here changes it for every consumer on both hosts.

| File | Format | What it decides |
|---|---|---|
| `host` | one word (`master` or `orin`) | which machine this checkout is on. Selects the DDS profile. **Gitignored** — it is a property of the machine, not the branch |
| `multi_machine.conf` | shell assignments | the other host's `user@addr`, its repo path, the ssh key, the master's IP |
| `sensors.conf` | shell assignments | which IMU and camera driver the sensor kit uses (`IMU_SOURCE`, `CAMERA_MODEL`) |
| `vehicle.conf` | shell assignments | whether the vehicle interface may transmit on CAN (`GOLFCART_TX_ENABLED`) |
| `runtime.conf` | shell assignments | how play_launch runs composable nodes (`GOLFCART_CONTAINER_MODE`) |
| `recording/master_topics.txt`<br>`recording/orin_topics.txt` | one topic per line, `#` comments | what each host records |
| `cyclonedds/{master,orin,loopback}.xml` | CycloneDDS XML | DDS network profiles, one per role |
| `iceoryx/roudi.toml` | TOML | RouDi shared-memory pool sizes for the CycloneDDS zero-copy transport |

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

## Shared memory (Iceoryx) — installed, disabled

All three DDS profiles set `<SharedMemory><Enable>false</Enable>`. It was
enabled, tried against the full stack, and turned back off. Two findings, either
disqualifying on its own.

**It does not fit.** The first full launch died with:

```
[Warning]: Out of publisher ports! ... Event: ros_discovery_info
[Warning]: ICEORYX error! PORT_POOL__PUBLISHERLIST_OVERFLOW
[ Error ]: ICEORYX error! EXPECTS_ENSURES_FAILED
terminate called without an active exception
```

iceoryx caps publisher ports at `IOX_MAX_PUBLISHERS = 512`, and that is a
**compile-time** constant — `iceoryx_posh_deployment.hpp` is autogenerated and
says the only way to change it is rebuilding with `-DIOX_MAX_PUBLISHERS=N`.
`roudi.toml` sizes mempools and nothing else. And the failure is a hard abort,
not a fallback to UDP: the node calls `terminate`.

**Ports are spent on writers that can never benefit.** Every overflow named the
same service — `ros_discovery_info`, type
`rmw_dds_common::msg::dds_::ParticipantEntitiesInfo_`. That type is full of
strings, so it is not loanable and gains nothing from shared memory, yet Cyclone
still registers an iceoryx publisher port for it. Consumption scales with the
total DDS writer count; the benefit reaches only fixed-size types.

And the benefit was already near zero. Measured with `can_loan_messages()`,
RouDi up and SHM on:

| type | loanable |
|---|---|
| `sensor_msgs/PointCloud2` | no |
| `sensor_msgs/Image` | no |
| `sensor_msgs/Imu` | no |
| `geometry_msgs/Twist` | **yes** |
| `std_msgs/UInt64` | **yes** |

Any message carrying a `std_msgs/Header` is excluded, because `frame_id` is a
string — that is every sensor and perception topic on this vehicle.

### What is still installed

`./setup.sh iceoryx` installs the runtime and `just service install` installs
`iox-roudi.service`, so re-enabling is a config change rather than a
provisioning job. RouDi is not started by default and the launch units carry
`Wants=`/`After=`, not `Requires=` — a RouDi failure must not take down a stack
that is not using it.

### Re-enabling

1. Rebuild iceoryx from source with a raised `IOX_MAX_PUBLISHERS` (and
   `IOX_MAX_SUBSCRIBERS`), sized above this stack's total DDS writer count.
2. Flip `<Enable>` to true in all three profiles.
3. `systemctl --user start iox-roudi.service`, and change `Wants=` back to
   `Requires=` in the two launch units.

The guards follow the config automatically — `scripts/iceoryx/ensure_roudi.sh`
and `scripts/env.sh` both grep the resolved profile for the enabled form of the
tag, and demand RouDi only when they find it. For that reason, never write the
enabled form of that tag inside a comment in those files.

With SHM off and RouDi down, participant creation is immediate; with SHM on and
RouDi absent it hangs forever with no message, which is what those guards exist
to prevent.
