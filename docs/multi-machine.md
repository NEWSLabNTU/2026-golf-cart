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
just launch-master                  # master stack + the orin's ZED, started over ssh
just launch-master "record:=true"   # the same, with both hosts recording locally
```

Stopping the master (Ctrl-C, or play_launch's stop button) stops the orin too.
Bags land in `~/rosbags/master_<ts>` and `~/rosbags/orin_<ts>` on their respective
machines; override the directory with `GOLFCART_BAG_DIR`.

Single-machine operation is untouched:

```bash
just launch                         # host:=all, loopback DDS, nothing remote
GOLFCART_USE_ORIN=0 just launch-master   # master alone, without touching the orin
```

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
just bag-fetch-orin              # everything not already here
just bag-fetch-orin "--latest"   # only the newest
just bag-fetch-orin "--list"     # show what is on the orin, copy nothing
just bag-fetch-orin "orin_20260810_112836"   # one by name
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
just bag-merge "master_20260810_123019 orin_20260810_122949"
just bag-merge "-o /mnt/external/rosbags/session1 <bag> <bag>"
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
just bag-replay                                    # newest merged bag, or newest master bag
just bag-replay "" "start_offset:=40.0"            # skip the orin-only opening
just bag-replay merged_20260810_1230 "rate:=2.0 play_args:=--loop"
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

```bash
./scripts/multi_machine/orin_remote.sh start [true|false]   # the argument enables recording
./scripts/multi_machine/orin_remote.sh status
./scripts/multi_machine/orin_remote.sh stop
```

## What stops the orin, and when

| Failure | What stops it | How long |
|---|---|---|
| Master stopped normally | `launch-master`'s EXIT trap runs `orin_remote.sh stop` over ssh | immediate |
| Master killed, network up | the same trap, if the shell survives; otherwise the watchdog | immediate, or ~42s |
| Network cut, or master powered off | the orin's own watchdog stops the unit locally | ~42s |

`KillMode=control-group` in the unit is what makes the no-orphan guarantee hold —
it kills everything play_launch spawned, not just the main process.

The orin is never enabled at boot. It is started on demand, because an orin that
launches its ZED with no master to talk to is just a warm camera.

## One-time provisioning of the orin

```bash
# On the orin:
cd ~/2026-golf-cart
./setup/scripts/install-orin-host.sh      # systemd user units + lingering
./setup/scripts/configure-cyclonedds-sysctl.sh
(cd setup && just chrony-orin)            # follow the master's clock
colcon build --base-paths src --symlink-install \
    --cmake-args -DCMAKE_BUILD_TYPE=Release

# On the master, once:
ssh-copy-id jetson@192.168.125.101
(cd setup && just chrony-master)          # serve time to the orin
```

Key-based ssh is required, not optional: the orchestrator runs non-interactively
and cannot answer a password prompt.

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

**Nothing is discovered between the hosts.** Check the profile actually in use —
`launch-master` and `launch-orin` set `CYCLONEDDS_URI` themselves, but a plain
shell falls back to `.envrc`, which defaults to `loopback`. Set
`GOLFCART_DDS_PROFILE=master` (or `orin`) for manual work.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GOLFCART_DDS_PROFILE` | `loopback` | which `config/cyclonedds/<name>.xml` `.envrc` exports |
| `GOLFCART_USE_ORIN` | `1` | set to `0` to run the master without the orin |
| `GOLFCART_ORIN_SSH` | `jetson@192.168.125.101` | ssh destination for the orin |
| `GOLFCART_ORIN_WAIT` | `60` | seconds to wait for the orin before giving up |
| `GOLFCART_MASTER_IP` | `192.168.125.100` | what the orin's watchdog pings |
| `GOLFCART_BAG_DIR` | `~/rosbags` | where each host writes its bags |
| `GOLFCART_WORKSPACE` | `~/2026-golf-cart` | workspace the orin's unit launches from |

## A master bag with an empty metadata.yaml

Large master-side bags can lose their metadata on shutdown: the `.db3` is
complete but `metadata.yaml` is 0 bytes, and `ros2 bag info` reports
`invalid node; first invalid key: "version"`. Observed with a 2.2 GB bag - the
recorder is killed before it finishes writing. Recover in place:

```bash
rm -f <bag>/metadata.yaml
ros2 bag reindex <bag>
```

The reindexed bag is complete; nothing is lost but the original metadata.

The orin side does not have this problem: its recorder is stopped by systemd with
`KillSignal=SIGINT` and `TimeoutStopSec=30`, which gives it time to finalize. The
master's recorder is stopped by play_launch, whose grace period is shorter than a
multi-gigabyte flush needs. Check `metadata.yaml` is non-empty after any long
master recording.

## Checking the recorded topic list is still right

Topic names drift as the sensor kit changes, and a stale entry records zero
messages while still appearing in `ros2 bag info` - which reads as "the sensor was
quiet", not "the name is wrong". Audit against a running stack:

```bash
ros2 topic list > /tmp/live.txt
grep -oE '^  /[a-z0-9_/]+' src/launcher/golfcart_launch/scripts/record_master.sh \
  | tr -d ' ' \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

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
