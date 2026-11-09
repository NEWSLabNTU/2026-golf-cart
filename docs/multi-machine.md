# Multi-Machine Operation (master + orin)

How the golf cart stack runs across its two machines: the domain split, the link
bridge, the systemd units, time sync and the recording internals. For why it is
built this way, see [design/multi_machine_deployment.md](design/multi_machine_deployment.md).

For day-to-day use start with the user docs: [setup.md](setup.md) (install),
[operating.md](operating.md) (up/down, arguments, logs), [recording.md](recording.md)
and [hardware.md](hardware.md).

## The two hosts

| | address | interface | runs |
|---|---|---|---|
| master | `192.168.125.100` | `enP5p3s0` | the whole Autoware stack, plus the wired sensors (Velodyne, Falcon, GNSS, three GMSL cameras) |
| orin | `jetson@192.168.125.101` | `eno1` | the ZED X camera, and the CAN vehicle interface on `can0` |

Both sit on the shared 4G LAN, which negotiates **100 Mb/s**. Peripherals and addresses: [hardware.md](hardware.md). That is the reason
each host records to its own disk instead of streaming images across.

## What crosses the link

Only what `config/link/topics.yaml` lists. Under `host:=master` and
`host:=orin` the CycloneDDS profile binds the stack to its own domain on `lo`
(50 on the master, 60 on the orin; `scripts/env.sh` exports it as
`ROS_DOMAIN_ID`), so the stack on either machine cannot reach the wire; the
link domain (10, `GOLFCART_LINK_DOMAIN_ID`) is bound to the LAN address and holds exactly one participant per host, the
`link_bridge` node from `golfcart_domain_bridge`, which the launch starts. It
copies the listed topics across in the listed direction: the orin's IMU,
`camera_info`, `/diagnostics`, `/tf_static` and the vehicle interface's
`/vehicle/status/*` to the master; the six vehicle commands
(`/control/command/*`, `/vehicle/emergency_stop`) and the
`/control/control_mode_request` service to the orin.

### The vehicle interface is on the orin

The VCU's bus is wired to the orin's header (setup step `orin-can0`), so the
interface runs there: `golfcart.launch.yaml` has `vehicle_host`, default `orin`.
The master still runs tier4's `vehicle.launch.xml` for the vehicle description
and `robot_state_publisher`, just without the interface inside it; the orin
includes `vehicle_interface.launch.xml` directly. `vehicle_host:=master` puts it
back on the Advantech with nothing else to edit. Under `host:=all` the one
machine runs it whatever `vehicle_host` says.

What follows from that:

- **The orin needs `CAX_ADS_CAN.dbc`.** Without it `just build` skips the
  interface there and the cart has no velocity and cannot engage.
- **Driving needs the orin.** `just up` still treats a missing orin as
  non-fatal for the master, but with the bus on the orin a master alone has no
  vehicle interface. `GOLFCART_USE_ORIN=0` is for work that does not move the
  cart.
- **A link drop stops the cart.** Commands stop arriving and the interface's
  `control_timeout_ms` watchdog (500 ms) brakes. The orin's own watchdog stops
  its units about 42 s later.
- **Engage crosses the link as a service.** The bridge proxies
  `/control/control_mode_request`; if the orin side is down the request goes
  unanswered and Autoware's engage times out.
- `scripts/check/vehicle.sh` (and `just can vcu-status`) read the bus on the
  orin over ssh (`CAN_HOST=orin`, the default; `CAN_HOST=local` on the machine
  with the bus).

```bash
just link topics        # ros2 topic list in the link domain: what is on the wire
just link nodes         # should be the two bridges
just link hz /sensing/camera/zed/imu/data
just link pressure      # bytes and packets per second on enP5p3s0
```

Consequences worth knowing:

- A `ros2 topic list` on either host shows that host's stack domain, provided
  the shell sourced `scripts/env.sh` (direnv does; a bare fresh shell is in
  domain 0 and sees nothing). The
  orin's topics appear on the master under their own names, because the bridge
  republishes them there; they do not appear on the orin's `ros2 topic list`
  as anything special. To see the wire itself, `just link topics`.
- `ros2 topic echo` of an unlisted orin topic on the master shows nothing, and
  costs the link nothing. Before the split, echoing the ZED image pulled
  ~5 MB/s across; now the image is not there to echo. Add it to
  `topics.yaml` with a `max_hz` if a preview is wanted.
- Recording is unchanged: each host records its own stack domain.
- The two-machine profiles need `lo` to have the MULTICAST flag, as the
  loopback profile always did (`./setup.sh`, the multicast-lo step).

Why: before this, one domain bound to the LAN put every participant on the
wire, and with the recorder running every raw cloud had two readers on the
master, which is what makes CycloneDDS multicast it out of the NIC. In
simulation with the real stack and a 100 Mbit/s wire, that pinned the link at
its ceiling with the orin subscribed to none of it, dropped 160k packets in
160 s, and cost the master's *own* recorder 59 % of its LiDAR scans. The
split brings master → orin down to ~2 kB/s and orin → master to ~90 kB/s
(the listed topics), with zero drops. Measurements and method in
[research/system/domain-split-link-pressure.md](research/system/domain-split-link-pressure.md).

## Daily operation

The commands (`just up`, `just up @name`, `just logs`, `just down`) and the
argument files are in [operating.md](operating.md). What happens underneath:

Arguments reach each unit through `.golfcart-launch.args` in that host's
checkout (gitignored). `just up` expands `@name` arg files once on the master,
prints the list, and runs the private `_up-local` recipe here and on the orin
with it; `_up-local` rewrites the file on **every** start, empty when there are
no arguments, so a flag never outlives the start that asked for it (the old
`GOLFCART_LAUNCH_ARGS` in the user manager's environment did, until something
cleared it). `launch_unit_exec.sh` reads the file and adds `host:=`,
`master_ip:=` and `link_topics:=` through `scripts/launch/args.py`, which logs
the final list to the journal. A hand-run `systemctl --user restart` reuses the
last file.

`just down` deliberately leaves recording alone — that is `just record stop`.

### Letting the cart move

There is no software TX switch. The vehicle interface always transmits on `can0`,
because the VCU reports velocity and steering only while it hears the rolling
counter in our frames — a listen-only interface left the stack blind. The cart's
power switch is the master enable, and the interface's `control_timeout_ms`
watchdog brakes when commands stop arriving.

Single-machine operation is untouched:

```bash
just run                     # host:= from config/host, nothing remote, foreground
GOLFCART_USE_ORIN=0 just up   # master alone, without touching the orin
```

`just run` derives `host:=` from the `config/host` marker — `master` and
`orin` narrow the profile and add `master_ip:=` / `link_topics:=`, no marker
(loopback) keeps `host:=all`. It used to
pass nothing and take the `all` default, which put the `is_orin` group in scope
on the Advantech: that group includes `camera.launch.xml` with
`camera_model:=zedx` unconditionally, so a machine with no ZED and no ZED SDK
(`just build` skips the ZED packages without one) died before any node started
with `Package 'zed_wrapper' not found`. An explicit `host:=` in the arguments
still wins.

## Recording

The commands are in [recording.md](recording.md). The internals:

Recording is independent of the launch. Start it whenever you want, with the
stack up, down, or half-up. A session is one ID, `YYYYmmdd_HHMMSS[_NAME]`,
generated once on the master by `just record start` and handed to both hosts,
so the two halves are paired by name rather than by nearby timestamps.

```bash
just record start [SCOPE] [NAME]   # master first, then the orin over on_orin.sh
just record status                 # both hosts: session, files, growth per second
just record stop [merge=on]        # both finalize; prints the collect command
just record collect [ID] [merge=on]
```

How a host records: `just record _up-local ID SCOPE` (what `start` runs on each
host) checks free space (`session.py preflight`), writes `.golfcart-record.args`
(gitignored, `id=` and `scope=`, rewritten on every start, the same pattern as
`.golfcart-launch.args`) and restarts `golfcart-record.service`. The unit runs
`scripts/recording/record_unit_exec.sh`, which sources `scripts/env.sh` for the
role's DDS profile and execs the session runner, `scripts/recording/session.py
run --unit`. The runner starts every recorder of the scope as a child in its own
process group (`ros2 bag record`, one `candump -L` per CAN bus, one `tshark`
per NIC), checks at 2 s which ones died at start (no permission, interface gone),
and writes `recordings/<id>/<role>/session.yaml`.

Stopping: the unit has `KillMode=control-group` and `KillSignal=SIGINT`, so
systemd delivers SIGINT to every recorder at once; the runner does not forward a
second one (a second SIGINT during bag finalization is what must not happen),
waits for each to exit (escalating to SIGTERM and SIGKILL only after a grace:
270 s for the bag, inside `TimeoutStopSec=300`), and rewrites `session.yaml`
with exit codes, sizes, packet counts and the bag's topic count. In the
foreground (`just bag record`, `just can record`) the runner forwards exactly one
SIGINT to each recorder on Ctrl-C.

Scopes are `config/recording/scopes.yaml`; a scope names topic classes, and the
classes, with each host's topics, are `config/recording/topics.yaml`. Edit that
rather than any script (docs/recording.md, "Topic classes"). The split is deliberate: both LiDARs are
cabled to the master at ~30 MB/s each, and only the ZED's *compressed* stream is
small enough to cross the shared 100 Mb/s LAN, so each host records its own
sensors locally.

`just record collect` rsyncs the orin's `recordings/<id>/orin/` into the same
path on the master. The transport is `scripts/recording/orin_rsh.sh`, which
makes `on_orin.sh` rsync's remote shell, so it uses the same key, BatchMode and
checkout path as every other remote command. It refuses while the orin's half
is still recording, resumes partial files, and finishes with a size check of
every file against the orin's own listing. `merge=on` runs `bag_merge.sh` on
`master/bag` and `orin/bag` into `recordings/<id>/merged/`.
`GOLFCART_ON_ORIN` replaces `on_orin.sh` in all of the record recipes, which is
how the two-host flow is tested against a second local checkout.

Recording used to be part of the launch (`record:=true`), and that argument no
longer exists. Two reasons it moved out. You could not start or stop a recording
without restarting the whole stack; and as a play_launch child, every
multi-gigabyte bag stopped from the foreground came out with a 0-byte
`metadata.yaml` (see docs/roadblocks.md). Outside that process tree, play_launch's
shutdown cannot reach the recorder at all.

Before sessions (2026-11-09) the unit wrote `$GOLFCART_BAG_DIR/<role>_<ts>`,
`record stop` fetched and merged in the background into `merged_<ts>`, pairing
the orin bag by nearest timestamp. Those bags are still where they were; `just
record collect master_<ts>` still runs the old pairing collector
(`scripts/multi_machine/record_collect.sh`) for them.

## Time sync

The two hosts record separate bags, so their clocks have to agree before a LiDAR
sweep can be lined up against a camera frame. Left alone, each host tracks
internet NTP pools over 4G independently, with error bounds of 150–430 ms — two
bags could be half a second apart with nothing to reveal it.

The master therefore serves time and the orin follows it:

```bash
./setup.sh --only chrony-master   # on the master
./setup.sh --only chrony-orin     # on the orin
```

`./setup.sh --role master|orin` selects these for you (see [setup.md](setup.md)).

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

**PTP:** the master also runs `ptp4l` on `enP5p5s0` and `phc2sys -s CLOCK_REALTIME -c enP5p5s0` (setup step `linuxptp`), pushing the
system clock out to the Falcon LiDAR's NIC. Chrony disciplines `CLOCK_REALTIME`,
so the two compose — chrony sets the system clock, phc2sys propagates it to the
LiDAR. Do not reverse phc2sys's direction while chrony is running.

## Collecting the bags

Each host records to its own disk, so a session leaves two halves on two
machines. `just record collect` brings the orin's half over (see *Recording*).
For bags from before sessions, fetch by hand:

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
just bag replay                                    # newest session (merged, else master), then legacy bags
just bag replay 20261109_142501_campus-loop        # a session by id
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
./scripts/multi_machine/on_orin.sh just _up-local
./scripts/multi_machine/on_orin.sh just record down
./scripts/multi_machine/on_orin.sh just service host-status
./scripts/multi_machine/on_orin.sh systemctl --user is-active golfcart-record.service
```

`on_orin.sh` is the entire remote layer: it knows how to log in and which
directory to start in, and nothing else. Anything you can run by hand on the orin
runs from here unchanged, and the exit status is the remote command's, so the
caller decides what a failure means.

The per-host recipes are symmetric — `_up-local`, `_down-local` (private, hidden
from `just --list`), `record up`, `record down`, `service host-status` act only on
the machine they run on. The two-host verbs (`up`, `down`, `record start`,
`record stop`) are just each one run locally and then over there.

## What stops the orin, and when

| Failure | What stops it | How long |
|---|---|---|
| `just down` | it runs `just _down-local` on the orin over ssh, then stops the local unit | immediate |
| Master unit stopped or crashed, network up | nothing stops the orin until someone runs `just down`; otherwise the watchdog | ~42s |
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

The procedure is in [setup.md](setup.md): `./setup.sh --role master|orin` on each
machine (its `host-services` step installs the units and lingering), then
`just service pair` once on the master. The pieces it is made of, for when one
needs redoing by hand:

```bash
just service install master   # or orin: units + lingering (sudo), this host
just service ssh-setup        # dedicated key, copied to the orin
just service install-orin     # runs the orin's own installer over ssh
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

## Troubleshooting

**`rmw_create_node: failed to create domain`, and `failed to increase socket
receive buffer size`.** The ZED SDK installs
`/etc/sysctl.d/60-zed-buffers.conf` with `net.core.rmem_max=1048576`, which sorts
after and undercuts our setting. Our DDS profiles require a 10 MB minimum, so
CycloneDDS refuses to start at all — on every profile, loopback included. Re-run
`./setup.sh --rerun cyclonedds-sysctl`, which writes
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
| `GOLFCART_BAG_DIR` | `/mnt/external/rosbags` if mounted, else `~/rosbags` | where bags from before sessions are; new recordings go to `recordings/` |
| `GOLFCART_ON_ORIN` | `scripts/multi_machine/on_orin.sh` | the record recipes' way to the orin (tests point it at a stub) |
| `GOLFCART_WORKSPACE` | `~/2026-golf-cart` | workspace the units launch from; set by the installer's drop-in |

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
python3 scripts/recording/session.py topics --role master \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

Same with `--role orin`, run on the orin.

This caught the Velodyne being under `vlp32/` rather than `top/`, the GNSS being
the Xsens MTi rather than a u-blox, and the USB cameras publishing no
`camera_info` at all.

## Two bags whose timestamps do not line up

Check `chronyc tracking` on the orin. If `Reference ID` is anything other than
`192.168.125.100`, it has fallen back to the internet pools and the two bags may
be hundreds of milliseconds apart. Causes, in order of likelihood: the master's
chrony is not running, `/etc/chrony/conf.d/golfcart-master.conf` is missing there,
or the LAN was down when the orin last polled. Re-running
`./setup.sh --rerun chrony-orin` on the orin forces a re-select.
