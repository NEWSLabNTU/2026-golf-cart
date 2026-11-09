# Recording

A recording **session** captures ROS bags and raw packets (CAN frames, Ethernet
packets) on both machines at once, under one session ID. Each machine writes to
its own disk; afterwards one command copies the orin's half to the master.

Recording is separate from the stack: start and stop it at any time, with the
stack up or down. `just down` does not stop a recording.

## Start, check, stop, collect

Run these on the **master**, in the repository directory.

```bash
just record start                  # scope drive (default), both machines
just record start raw              # another scope
just record start all campus-loop  # scope and a name: 20261109_142501_campus-loop
just record status                 # both machines: session, each file and how fast it grows
just record stop                   # both machines close their files
just record collect                # copy the orin's half of the newest session here
just record list                   # sessions on this machine
```

`start` prints the session ID and, for each machine, every file it is writing
(or why one was skipped). `stop` returns once every file is closed, then prints
the `collect` command for that session.

`collect` is safe to re-run: it resumes an interrupted copy, then checks every
file's size against the orin's. It never deletes anything on the orin.
`just record collect <ID> merge=on` also merges the two bags into one
(`recordings/<ID>/merged/`). `just record stop merge=on` does both after stopping.

If the orin cannot be reached, the master still records, and `start` says so and
exits non-zero.

## Scopes

A scope says what a session records: which topic classes (below) go into the
ROS bag, which CAN buses, which Ethernet captures.

| scope | ROS | CAN | Ethernet (pcapng) |
|---|---|---|---|
| `drive` (default) | first-hand + `sensing_derived`, `diagnostics`, `vehicle_cmd`, `localization` | every bus | none |
| `localize` | same as `drive` (the name from before topic classes) | every bus | none |
| `autonomy` | `drive` + `planning`, `control`, `perception` | every bus | none |
| `all` | every topic (`ros2 bag record -a`) | every bus | sensor NICs + cart LAN |
| `raw` | none | every bus | sensor NICs + cart LAN |
| `can` | none | every bus | none |
| `ros` | the first-hand classes only | none | none |

`drive` records everything it did before topic classes, plus the localization
outputs: the NDT pose and its scores (NVTL, transform probability, iterations,
execution time), the EKF pose and twist, the initialization state and the board
pose. They are a few kB/s.

Interfaces per machine:

| machine | CAN | Ethernet |
|---|---|---|
| master | `can0`, `can1` | `enP5p4s0` (VLP-32C), `enP5p5s0` (Seyond Falcon), `enP5p3s0` (cart LAN) |
| orin | `can0` (the VCU bus) | `eno1` (cart LAN) |

The cart-LAN captures leave out ssh (`not tcp port 22`). An interface that is
missing or down at start is skipped and noted; the rest of the session still
records. `just record scopes` shows what each scope records on this machine.

The scopes live in [config/recording/scopes.yaml](../config/recording/scopes.yaml).

## Topic classes

Every recorded topic is in one class, in
[config/recording/topics.yaml](../config/recording/topics.yaml). Each class is
**first-hand** or **computed**:

- **first-hand**: a driver or a person produced it: sensor output, the vehicle's
  own reports. A replay plays it into the stack.
- **computed**: a node of our stack computed it from other topics. Recorded so
  you can look at what the stack did; a replay into a running stack leaves it
  out, because the stack computes it again (see "Replaying a bag" below).

| class | kind | master | orin | what |
|---|---|---|---|---|
| `lidar` | first-hand | 3 | 0 | VLP-32C points and packets, Falcon points |
| `camera` | first-hand | 6 | 6 | GMSL compressed images and camera_info; ZED X image, H.264, health |
| `imu` | first-hand | 1 | 1 | Xsens raw (broken, listed anyway); ZED X IMU |
| `gnss` | first-hand | 4 | 0 | u-blox fix, NMEA, RTCM status, NTRIP corrections |
| `vehicle` | first-hand | 8 | 0 | `/vehicle/status/*`, the driver's e-stop |
| `tf` | first-hand | 2 | 1 | `/tf` (master), `/tf_static` |
| `sensing_derived` | computed | 4 | 0 | the concatenator's synchronized VLP-32C cloud, gnss_poser's pose |
| `diagnostics` | computed | 1 | 0 | `/diagnostics` |
| `vehicle_cmd` | computed | 5 | 0 | `/control/command/*`, what the gate sends the vehicle |
| `localization` | computed | 15 | 0 | NDT pose and scores, EKF, twist, initialization, board pose |
| `planning` | computed | 2 | 0 | route, trajectory |
| `control` | computed | 3 | 0 | the controller's command, operation mode |
| `perception` | computed | 3 | 0 | objects, occupancy grid, obstacle cloud |

`just record scopes` prints this table from the file, then every scope's
classes and topic count on each machine. Each machine records its own half of
a class: the LiDARs and the GMSL cameras are cabled to the master, the ZED X to
the orin, and nothing large crosses the link.

A broken sensor's topic stays listed and records zero messages, which shows it
was expected and silent.

**To add a topic**, put it under its class in `topics.yaml`, on the machine that
has it (`master:`, `orin:`, or `both:`). **To add a class**, add a key with
`kind:` and `description:`; then name it in a scope's `ros:` list in
`scopes.yaml`. A new first-hand class joins every scope that lists
`first-hand` without further edits. Check the names against a running stack:

```bash
ros2 topic list > /tmp/live.txt
python3 scripts/recording/session.py topics --role master \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

`session.yaml` records, for the bag, which classes were asked for and how many
topics each had on that machine.

## Before you record

**Free disk.** `start` prints the free space on each machine. Below 20 GB it
refuses scope `all` and warns for the others. Rough rates on the master: the
Falcon capture alone is about 9 MB/s and the VLP-32C capture about 2 MB/s; a
`drive` bag is 15 to 30 MB/s.

**Vehicle interface.** Localization replays need the speed report, so the
vehicle interface (on the orin, part of `just up`) should run while you record:

```bash
ros2 topic hz /vehicle/status/velocity_status
```

**Packet capture without root.** `raw` and `all` capture with `tshark`, which
needs no root once the user is in the `wireshark` group. `./setup.sh --status`
shows a TODO with the fix if this machine cannot. Without it, the Ethernet
captures are skipped and the rest records.

## Where files land

On each machine, inside the repository (gitignored, untouched by `just clean`):

```
recordings/<ID>/
  master/                 written on the master
    bag/                  ROS bag (ros2 bag, sqlite3)
    can0.log, can1.log    CAN frames, candump -L format
    enP5p4s0.pcapng ...   Ethernet packets
    session.yaml          what ran and how it ended
    log/                  each recorder's stderr
  orin/                   on the orin; on the master after collect
  merged/                 after collect merge=on
```

`<ID>` is `YYYYmmdd_HHMMSS`, plus `_<name>` if you gave one. Both machines use the
same ID. On the master the repository is on the external SSD.

`session.yaml` records the ID, scope, machine, git commit (and whether the tree
was dirty), the launch arguments in use, the chrony clock offset at start and
stop, start and stop times, and for each recorder its status, exit code, file
size and, for captures, packet counts. A recorder that was skipped or failed
says why.

## Opening the files

**pcapng** (Ethernet): open in Wireshark, or on the command line:

```bash
capinfos recordings/<ID>/master/enP5p4s0.pcapng      # packet count, duration
tshark -r recordings/<ID>/master/enP5p4s0.pcapng | head
```

**CAN logs** (`candump -L`): replay onto the virtual bus, or decode.

```bash
just can play                                  # newest non-empty log, onto vcan0
just can play recordings/<ID>/orin/can0.log
canplayer -I recordings/<ID>/orin/can0.log vcan0=can0
cantools decode src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc \
    < recordings/<ID>/orin/can0.log
```

`vcan0` must exist first (`sudo ./scripts/can/up-vcan0.sh vcan0`). The DBC is
proprietary and only on the machines it was copied to.

**Bags**:

```bash
ros2 bag info recordings/<ID>/master/bag
just bag play                   # newest session bag (merged first), into a running stack
just bag play <ID>
just bag play <ID> computed=on  # every topic, as recorded
just bag replay <ID> "start_offset:=40.0"      # with RViz, every topic
```

## Replaying a bag

A replay into a running stack (a logging simulation: `just sim logging`, the
`ntu-test` and `indoor-test` sequences) leaves out what the stack computes
itself. Otherwise each such topic would have two publishers, the bag's and the
stack's, and the stack's results would be mixed with the recorded ones.

`just bag play`, `just bag play-ntu`, `just ntu-test bag`, `just indoor-test bag`
and `scripts/testing/board_check.sh` all play through
`scripts/recording/play.py`, which leaves out:

- every topic of a computed class;
- every topic in no class that matches `replay.stack_patterns` in `topics.yaml`.
  A bag of scope `all` is mostly the stack's own topics (`/planning/...`,
  `/api/...`, the preprocessed clouds); these are left out the same way.
  An unclassified topic that matches none (a driver's extra output) plays.

`/tf` is a special case. On the master it carries the ZED's IMU frame, which the
logging simulation needs and does not publish, and the stack's own
`map -> base_link` (EKF) and `map -> ndt_base_link` (NDT), which it does. Before
topic classes it replayed whole, so the replayed stack had two
`map -> base_link` publishers. Now `play.py` plays `/tf` under another name and
republishes it without the transforms listed in `replay.tf_computed`.
`/tf_static` replays as recorded.

ROS 2 Humble's `ros2 bag play` can only include topics (`--topics`), not exclude
them, so `play.py` builds the include list from the bag's `metadata.yaml`. A
bag with nothing to leave out plays exactly as before. See what it would do:

```bash
python3 scripts/recording/play.py --dry-run recordings/<ID>/master/bag
```

`computed=on` (`just bag play`), `--computed` (`play.py`) or
`GOLFCART_REPLAY_COMPUTED=on` (the other wrappers) plays everything. `just bag
replay` always plays everything: it runs only RViz, so the recorded
localization is the only one there is.

## A recording for a vendor bug report

To send Turing Drive (or a LiDAR vendor) what happened on the wire:

```bash
just record start can vcu-steer-fault   # or: raw, to add the Ethernet captures
# reproduce the problem
just record stop
just record collect                     # brings the orin's CAN log over
```

Then send, from `recordings/<ID>/`:

- `orin/can0.log`: the VCU bus (the vehicle interface runs on the orin);
- `orin/session.yaml` and `master/session.yaml`: when, which commit, clock offset;
- for `raw`, the relevant `master/*.pcapng` (for example `enP5p5s0.pcapng` for the Falcon).

Do not send the DBC: it is the vendor's own file.

## Recording on one machine, in a terminal

These record this machine only, in the foreground; Ctrl-C stops and closes the
files. They write the same session layout.

```bash
just bag record              # scope ros (first-hand classes): recordings/<ts>/<machine>/bag
just bag record campus_loop  # with a name
just can record              # scope can, every bus
just can record can0         # one bus
just record up raw           # this machine only, as a background service; stop: just record down
```

## Deleting recordings

**This deletes every session on both machines and cannot be undone.** Collect
and copy off anything you want to keep first.

```bash
just record nuke                 # both machines
just record nuke host=master     # one machine only (also: host=orin)
```

It lists every session on each machine with its size, then asks you to type
`nuke`. Anything else deletes nothing. It always asks; there is no flag to skip
the question, and it refuses to run without a terminal. It also refuses while
either machine is recording, and when the orin cannot be reached (unless you
give `host=master`). Only `recordings/` is deleted: older bags in
`$GOLFCART_BAG_DIR` and `rosbags/can/` are not touched.

## Older recordings

Bags recorded before sessions (`master_<ts>`, `orin_<ts>`, `merged_<ts>`) stay in
`$GOLFCART_BAG_DIR` (`/mnt/external/rosbags` on the master), and CAN logs in
`rosbags/can/`. `just bag play`, `just bag replay`, `just bag merge` and
`just can play` still take them by path or name; with no argument they look in
`recordings/` first. `just record collect master_<ts>` and `just bag fetch-orin`
still handle old orin bags.

More detail (time sync, the systemd unit, checking a merged bag):
[multi-machine.md](multi-machine.md#recording).
