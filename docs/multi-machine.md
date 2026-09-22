# Multi-Machine Operation (master + orin)

How to run the golf cart stack across its two machines. For why it is built this
way, see [design/multi_machine_deployment.md](design/multi_machine_deployment.md).

## The two hosts

| | address | interface | runs |
|---|---|---|---|
| master | `192.168.125.100` | `enP5p3s0` | the whole Autoware stack, plus the wired sensors (Velodyne, Falcon, GNSS, IMU, USB cameras) |
| orin | `jetson@192.168.125.101` | `eno1` | the ZED X camera only |

Both sit on the shared 4G LAN, which negotiates **100 Mb/s**. That is the reason
each host records to its own disk instead of streaming images across.

## Daily operation

Everything runs from the master:

```bash
just launch-all    # both hosts: this stack + the orin's ZED, over ssh
just logs          # follow this host's log
just stop-all      # stop both hosts
```

Both hosts run under systemd now, so `launch-all` **returns immediately** and
nothing occupies a terminal. Closing your ssh session no longer stops the cart;
`just stop-all` is the stop verb, and there is no Ctrl-C to press.

`stop-all` deliberately leaves recording alone — that is `just record stop`.

### Letting the cart move

`launch-all` starts with CAN TX off: the vehicle interface listens, so
`/vehicle/status/*` and `/diagnostics` fill in, but nothing it publishes can move
the cart. Turn TX on with the `tx=` token:

```bash
just launch-all tx=on     # ⚠️  real frames on can0 — the cart can move
just service host-status          # shows "can tx  ENABLED" and where that came from
just service status       # the same, for both hosts
```

TX applies to the **master only**. `launch-all` strips the token before calling
the orin's `launch-up`, since the orin has no CAN bus and
`golfcart.launch.yaml` gates the vehicle group on `is_master`.

It is per invocation, not a setting: a `launch-all` without `tx=` clears it, and
so does `stop-all`. `config/vehicle.conf` holds the resting default and is the
place to change it for a machine — see [config/README.md](../config/README.md).

`tx=` is not a launch argument and cannot be one; the installed
`tier4_vehicle_launch/vehicle.launch.xml` forwards a fixed set of arguments to
our `vehicle_interface.launch.xml` and drops the rest, so `scripts/tx_switch.sh`
pulls the token out and the environment carries it the rest of the way.

Single-machine operation is untouched:

```bash
just launch                         # host:= from config/host, nothing remote
GOLFCART_USE_ORIN=0 just launch-all   # master alone, without touching the orin
```

`just launch` derives `host:=` from the `config/host` marker — `master` and
`orin` narrow the profile, no marker (loopback) keeps `host:=all`. It used to
pass nothing and take the `all` default, which put the `is_orin` group in scope
on the Advantech: that group includes `camera.launch.xml` with
`camera_model:=zedx` unconditionally, so a machine with no ZED and no ZED SDK
(`just build` skips the ZED packages without one) died before any node started
with `Package 'zed_wrapper' not found`. An explicit `host:=` in the arguments
still wins.

## Recording

Recording is independent of the launch. Start it whenever you want, with the
stack up, down, or half-up:

```bash
just record start     # both hosts begin recording to their own local disk
just record status
just record stop      # both finalize their bags
```

Bags land in `$GOLFCART_BAG_DIR/master_<ts>` and `.../orin_<ts>` on their
respective machines — the external SSD (`/mnt/external/rosbags`) when mounted,
otherwise `~/rosbags`.

What each host records is a plain list, one topic per line:

```
config/recording/master_topics.txt
config/recording/orin_topics.txt
```

Edit those rather than any script. The split is deliberate: both LiDARs are
cabled to the master at ~30 MB/s each, and only the ZED's *compressed* stream is
small enough to cross the shared 100 Mb/s LAN, so each host records its own
sensors locally.

Recording used to be part of the launch (`record:=true`), and that argument no
longer exists. Two reasons it moved out. You could not start or stop a recording
without restarting the whole stack; and as a play_launch child, every
multi-gigabyte bag stopped from the foreground came out with a 0-byte
`metadata.yaml` (see docs/roadblocks.md). Outside that process tree, play_launch's
shutdown cannot reach the recorder at all.

If the orin is unreachable, the master still records — the failure is reported
and `just record start` exits non-zero.

## Time sync

The two hosts record separate bags, so their clocks have to agree before a LiDAR
sweep can be lined up against a camera frame. Left alone, each host tracks
internet NTP pools over 4G independently, with error bounds of 150–430 ms — two
bags could be half a second apart with nothing to reveal it.

The master therefore serves time and the orin follows it:

```bash
# On the master:
cd setup && just chrony-master

# On the orin:
cd setup && just chrony-orin
```

Verify from the orin — the master should be the selected source (`^*`):

```bash
chronyc sources     # ^* 192.168.125.100 ... +12us
chronyc tracking    # Reference ID : C0A87D64 (192.168.125.100)
```

Measured after setup: **+12 µs** last sample, 2.8 µs system time offset, 327 µs
RMS. Expect the RMS to fall further once chrony has been locked for more than a
few minutes.

Two deliberate choices in the config:

- The master carries `local stratum 10`, so it keeps serving from its own clock
  when the 4G uplink is down — which on a vehicle is most of the time, and
  exactly when recordings happen. Without it chronyd refuses to answer clients
  while unsynchronised, and the hosts drift apart at the worst moment.
- The orin *prefers* the master rather than dropping its own pools, so an
  unreachable master degrades to coarse internet time instead of no time at all.

`chronyc clients` on the master needs root; checking the orin's `^*` selection is
the easier confirmation that the master is answering.

**PTP:** the master also runs `phc2sys -s CLOCK_REALTIME -c enP5p5s0`, pushing the
system clock out to the Falcon LiDAR's NIC. Chrony disciplines `CLOCK_REALTIME`,
so the two compose — chrony sets the system clock, phc2sys propagates it to the
LiDAR. Do not reverse phc2sys's direction while chrony is running.

## Collecting the bags

Each host records to its own disk, so a session leaves two bags on two machines.
Bring the orin's side over afterwards:

```bash
just bag fetch-orin              # everything not already here
just bag fetch-orin "--latest"   # only the newest
just bag fetch-orin "--list"     # show what is on the orin, copy nothing
just bag fetch-orin "orin_20260810_112836"   # one by name
```

Nothing is deleted from the orin — re-running is safe and resumes a partial
transfer. Delete the originals there yourself once you have checked the copies.

Expect roughly 11 MB/s, which saturates the 100 Mb/s link: a 45s ZED recording is
~300 MB and takes ~26s to pull. Do not fetch while a run is in progress.

Every fetched bag is checked afterwards — total size against the orin's copy, and
a SQLite `quick_check` on each `.db3`. This is not paranoia: a fetch that ran
while the destination filesystem was full produced a bag that `ros2 bag info`
reported as perfectly healthy, because info reads `metadata.yaml` and never opens
the database. The corruption only appeared later, during a merge.

## Merging the two hosts' bags into one

```bash
just bag merge "master_20260810_123019 orin_20260810_122949"
just bag merge "-o /mnt/external/rosbags/session1 <bag> <bag>"
```

Bare names are resolved under `GOLFCART_BAG_DIR`; paths work too. The inputs are
left untouched. Messages interleave by timestamp, which is only meaningful
because chrony holds the two clocks within tens of microseconds — see *Time
sync*. Without that the halves would be stitched together wrong, and nothing in
the output would say so.

The merged bag is roughly the sum of its inputs, so it needs real space: a 2.3 GB
master bag plus a 334 MB orin bag gives 3.5 GB. The script refuses to start if
the destination cannot hold the result, because filling a disk mid-write is what
corrupts bags in the first place.

Under the hood this is `ros2 bag convert` with repeated `-i` arguments. Note the
explicit `sqlite3` storage id per input: bags recovered with `ros2 bag reindex`
carry an empty `storage_id` in their metadata, and convert will not infer it.

### Replaying with RViz

```bash
just bag replay                                    # newest merged bag, or newest master bag
just bag replay "" "start_offset:=40.0"            # skip the orin-only opening
just bag replay merged_20260810_1230 "rate:=2.0 play_args:=--loop"
```

Brings up the bag player, `robot_state_publisher` and RViz together. The fused
cloud and the ZED image are on by default; the two raw LiDAR clouds are off,
since drawing them alongside the fused cloud triples the point count for no extra
information — enable them to eyeball the extrinsics.

Two things this launch does that a bare `rviz2` cannot:

- **It rebuilds the TF tree from the vehicle description.** The bag's own
  `tf_static` is unusable: only two or three messages are recorded, and rosbag2
  does not republish them with the transient-local QoS subscribers expect, so
  nothing receives them. Without a TF tree RViz cannot place clouds stamped in
  `velodyne` or `seyond` at all. Rebuilding also means the view reflects current
  calibration rather than whatever was installed the day the bag was made.
- **It decompresses the ZED stream.** Only the compressed image is recorded, and
  RViz's Image display did not subscribe to it via its transport hint — the
  compressed topic showed zero subscribers with the display enabled.
  `image_transport republish` decodes it onto `/replay/zed/image` instead.

### Checking a merged bag by hand

```bash
ros2 bag play /mnt/external/rosbags/merged_<ts> --clock --start-offset 40
```

**Use `--start-offset`.** The orin starts recording before the master finishes
its ~45s launch dump, so a merged bag opens with roughly 35 seconds of orin-only
data. Playing from the beginning and checking a master topic reports it silent,
which looks like a broken merge and is not one. Skip past the gap and both hosts
appear together.

Then confirm messages from each side, and that they share a time base:

```bash
ros2 topic echo /sensing/lidar/vlp32/velodyne_points --no-daemon --once   # master
ros2 topic echo /sensing/camera/zed/imu/data --no-daemon --once          # orin
```

Both header stamps should fall inside the bag's own start/end range from
`ros2 bag info`. A merged bag whose halves sit in different epochs means the
clocks were not synced when it was recorded — see *Time sync*.

To drive the orin by hand:

Both machines carry the same repository, so there is no separate remote-control
vocabulary to learn: you run the same recipe over there.

```bash
./scripts/multi_machine/on_orin.sh just launch-up
./scripts/multi_machine/on_orin.sh just record down
./scripts/multi_machine/on_orin.sh just service host-status
./scripts/multi_machine/on_orin.sh systemctl --user is-active golfcart-record.service
```

`on_orin.sh` is the entire remote layer: it knows how to log in and which
directory to start in, and nothing else. Anything you can run by hand on the orin
runs from here unchanged, and the exit status is the remote command's, so the
caller decides what a failure means.

The per-host recipes are symmetric — `launch-up`, `launch-down`, `record-up`,
`record-down`, `host-status` act only on the machine they run on. The two-host
verbs (`launch-all`, `stop-all`, `record-start`, `record-stop`) are just
each one run locally and then over there.

## What stops the orin, and when

| Failure | What stops it | How long |
|---|---|---|
| `just stop-all` | it runs `just launch-down` on the orin over ssh, then stops the local unit | immediate |
| Master unit stopped or crashed, network up | nothing stops the orin until someone runs `stop-all`; otherwise the watchdog | ~42s |
| Network cut, or master powered off | the orin's own watchdog stops **every** `golfcart-*` unit locally | ~42s |

`KillMode=control-group` in the unit is what makes the no-orphan guarantee hold —
it kills everything play_launch spawned, not just the main process.

The watchdog (`golfcart-watchdog.service`) is independent of the units it guards.
It has to be: recording can run while the launch is down, so a watchdog scoped to
the launch unit would be absent exactly when a recording needs stopping. It starts
alongside the first remote start, stops everything on master loss, and exits once
no `golfcart-*` unit is left — so it never pings on a machine being used alone.

One consequence to know: a master reboot during a long recording ends that
recording after ~42 s. One timeout is used for both units deliberately — an
interrupted recording can be recovered, a full disk cannot.

The orin is never enabled at boot. It is started on demand, because an orin that
launches its ZED with no master to talk to is just a warm camera.

## One-time provisioning

Once per machine, from its own checkout:

Most of it is driven from the master:

```bash
# On the master:
echo master > config/host              # picks the DDS profile; gitignored
just service install master               # units + lingering (sudo)
just service ssh-setup                            # dedicated key, copied to the orin
just service install-orin                 # runs the orin's own installer over ssh

# On the orin, once (its own checkout, its own clock and buffers):
echo orin > config/host
./setup/scripts/configure-cyclonedds-sysctl.sh
(cd setup && just chrony-orin)            # follow the master's clock
just build

# Back on the master:
(cd setup && just chrony-master)          # serve time to the orin
```

`just service install` writes a drop-in per unit carrying the resolved repo path
and this machine's role, so the checkout does not have to live at
`~/2026-golf-cart`. `just service remove <role>` undoes it, on whichever host you run it.

`just service install-orin` logs in and runs that same installer from the orin's
own checkout, so the drop-in it writes points at the orin's path. It is the one
command here that may prompt — it runs before key-based ssh necessarily exists,
and enabling lingering needs the orin's sudo. Everything else uses
`BatchMode=yes` and fails rather than asking.

Where the orin's checkout lives is `ORIN_WORKSPACE` in
`config/multi_machine.conf`; it accepts `~/path` or an absolute path, and the
tilde is expanded by the orin's shell, not the master's.

Check either machine at any time:

```bash
just service doctor           # this host
just service doctor-orin      # the same diagnostic, over ssh
```

Key-based ssh is required, not optional: the orchestrator runs non-interactively
and cannot answer a password prompt.

`just service ssh-setup` installs a **dedicated** key at `~/.ssh/golfcart_orin`, never
touching your own `id_*` keys, and every script passes it explicitly with
`ssh -i`. That explicitness is the point: ssh only tries the default names by
itself, so a differently-named key is invisible to it unless an agent happens to
hold one. That is how the previous key (`~/.ssh/golfcart_slave`, held by the
desktop keyring) worked by hand and failed under systemd, which has no agent:

```
$ env -u SSH_AUTH_SOCK ssh -o BatchMode=yes jetson@192.168.125.101 hostname
jetson@192.168.125.101: Permission denied (publickey,password).
```

`ssh-setup` verifies agentless afterwards for the same reason — a running agent
can make the check pass while every unit still fails.

> **Upgrading an existing machine.** The per-host units were replaced by a single
> `golfcart-launch.service` plus `golfcart-record.service`, and the old
> `orin_unit_exec.sh` / `master_unit_exec.sh` are gone. A machine provisioned
> before that has units pointing at deleted scripts and will fail at start. Re-run
> `just service install <role>` after pulling.

## Which DDS profile a terminal gets

Each machine binds a different CycloneDDS profile, so a shell on the wrong one
sees an empty graph while the stack is plainly running. The profile comes from
`config/host` — one word, `master` or `orin`, gitignored because it is a
property of the machine and not of the branch.

```bash
echo master > config/host    # then re-enter the directory, or: source scripts/env.sh
just service doctor                     # what got resolved, and from where
```

Precedence: an explicit `GOLFCART_DDS_PROFILE` wins, then the marker, then
`loopback`. A marker naming a profile with no `config/cyclonedds/<name>.xml` is
reported loudly rather than silently ignored.

Shells without direnv get the same environment from `source scripts/env.sh`.

A running `ros2` daemon keeps whatever DDS context it started with, so changing
the profile does not reach it — `just service doctor` says so when one is running.

## What crosses the link, and why it is not the sensors

Both hosts are in one ROS domain, bound to the LAN address, and see each
other's whole graph. What keeps the 100 Mb/s segment from filling is
`<AllowMulticast>spdp</AllowMulticast>` in `config/cyclonedds/{master,orin}.xml`.

CycloneDDS switches a writer to the multicast locator once a topic has two or
more reader **processes**, and the bound interface is the LAN NIC, so that one
datagram leaves the machine whether or not the other host wants it. On the
master every raw cloud has two readers before anyone touches anything —
preprocessing and the recorder — and RViz makes three. Under `spdp` multicast
carries participant discovery only; sample data goes unicast to each matched
reader, and a reader on this host has this host's address, so the kernel
routes it over `lo`.

**How much this is worth has not been measured.** Measure it on the vehicle
with `just link pressure` under each setting. Do not quote the workstation
simulation: its runs had the orin idle and the master on CPU NDT, neither of
which is what `just launch-all` does.

**And it is not sufficient on its own.** `golfcart_system_monitor` is gated on
`launch_web_monitor` with no host condition
(`golfcart.launch.yaml:547-558`), so it also runs on the orin, and
`golfcart_system_monitor/config/monitor_topics.yaml` makes it a real
`create_subscription` on the master's three point clouds and three GMSL
images. That makes the orin a genuine remote reader: `spdp` turns one
multicast datagram into one unicast copy per remote reader and the bytes
still cross the link. Give the monitor a per-host topic list, or gate it on
the host, before expecting the multicast setting to help.

Inspecting it:

```bash
just link topics          # topics with their publisher and subscriber counts
just link pressure        # bytes/s on enP5p3s0 (eno1 on the orin)
just link groups          # multicast groups joined, per interface
just link sim baseline    # reproduce the old behaviour, no root, no vehicle
just link sim spdp        # and the current one
```

The part this does **not** solve: one domain means a subscription anywhere
fetches the topic across the link, at the publisher's rate. There is no
allowlist and no rate cap; `max_hz` belonged to the bridge that was reverted.
Record images on the orin's local disk (`config/recording/orin_topics.txt`)
rather than pulling them to the master.

The checked-in `golfcart.rviz` is not the culprit here: it has 71 enabled
display subscriptions and **no ZED topic** — its three Image panels are the
master's own GMSL cameras. The unconditional cross-link readers are the two
`golfcart_system_monitor` instances described above.

## Troubleshooting

**`rmw_create_node: failed to create domain`, and `failed to increase socket
receive buffer size`.** The ZED SDK installs
`/etc/sysctl.d/60-zed-buffers.conf` with `net.core.rmem_max=1048576`, which sorts
after and undercuts our setting. Our DDS profiles require a 10 MB minimum, so
CycloneDDS refuses to start at all — on every profile, loopback included. Re-run
`./setup/scripts/configure-cyclonedds-sysctl.sh`, which writes
`99-cyclonedds-max.conf`. Re-run it any time the SDK is reinstalled.

**`InvalidHandle: cannot use Destroyable because destruction was requested`.**
A `ros2` daemon started under a different `CYCLONEDDS_URI` is still running. Run
`ros2 daemon stop`, or pass `--no-daemon` (note `ros2 topic hz` does not accept
it).

**The orin's unit fails with `libexec directory ... does not exist`.** Its
workspace has not been rebuilt since the recorders were added. Run `colcon build`
there.

**`git pull` on the orin fails with "correct access rights".** Its remote is
`git@github.com:...` and a non-interactive ssh session carries no agent. Pull
from an interactive shell on the orin.

**Nothing is discovered between the hosts.** Run `just service doctor` — it prints the
profile that resolved, where it came from, and whether the current shell is
carrying a different `CYCLONEDDS_URI` than the one the marker now selects. The
usual cause is a missing `config/host`, or a shell entered before it existed.

## Environment variables

Most of these now have a home in a file, and the variable is only an override.

| Variable | Default | Meaning |
|---|---|---|
| `GOLFCART_DDS_PROFILE` | from `config/host`, else `loopback` | which `config/cyclonedds/<name>.xml` is used |
| `GOLFCART_HOST` | from `config/host` | this machine's role; units get it from their drop-in |
| `GOLFCART_USE_ORIN` | `1` | set to `0` to run the master without the orin |
| `GOLFCART_ORIN_SSH` | `config/multi_machine.conf` | ssh destination for the orin |
| `GOLFCART_ORIN_WAIT` | `60` | seconds to wait for the orin before giving up |
| `GOLFCART_MASTER_IP` | `config/multi_machine.conf` | what the orin's watchdog pings |
| `GOLFCART_BAG_DIR` | `/mnt/external/rosbags` if mounted, else `~/rosbags` | where each host writes its bags |
| `GOLFCART_WORKSPACE` | `~/2026-golf-cart` | workspace the units launch from; set by the installer's drop-in |
| `GOLFCART_LAUNCH_ARGS` | *(empty)* | extra launch arguments for the launch unit |
| `GOLFCART_TX_ENABLED` | `false` (`config/vehicle.conf`) | may the vehicle interface transmit on CAN; set per invocation by `just launch-up tx=on`, cleared by `launch-down` |

## A bag with an empty metadata.yaml

Largely historical: recording no longer runs inside play_launch's process tree,
which is where this came from. If you meet it on an old bag, recovery is lossless:

```bash
rm -f <bag>/metadata.yaml
ros2 bag reindex <bag>
```

The full measurement — two 3 GB bags differing only in how they were stopped — is
in docs/roadblocks.md. Bag size was never the variable, and the mechanism behind
it was never identified; taking the recorder out of that process tree sidesteps it
rather than explaining it.

## Checking the recorded topic list is still right

Topic names drift as the sensor kit changes, and a stale entry records zero
messages while still appearing in `ros2 bag info` - which reads as "the sensor was
quiet", not "the name is wrong". Audit against a running stack:

```bash
ros2 topic list > /tmp/live.txt
grep -vE '^\s*(#|$)' config/recording/master_topics.txt \
  | tr -d ' ' \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

Same for `config/recording/orin_topics.txt`, run on the orin.

This caught the Velodyne being under `vlp32/` rather than `top/`, the GNSS being
the Xsens MTi rather than a u-blox, and the USB cameras publishing no
`camera_info` at all.

## Two bags whose timestamps do not line up

Check `chronyc tracking` on the orin. If `Reference ID` is anything other than
`192.168.125.100`, it has fallen back to the internet pools and the two bags may
be hundreds of milliseconds apart. Causes, in order of likelihood: the master's
chrony is not running, `/etc/chrony/conf.d/golfcart-master.conf` is missing there,
or the LAN was down when the orin last polled. Re-running
`cd setup && just chrony-orin` on the orin forces a re-select.
