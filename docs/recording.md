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

| scope | ROS | CAN | Ethernet (pcapng) |
|---|---|---|---|
| `drive` (default) | the topic lists | every bus | none |
| `all` | every topic (`ros2 bag record -a`) | every bus | sensor NICs + cart LAN |
| `localize` | the topic lists + localization outputs (NDT pose and scores, EKF, `/tf`; `localize_topics.txt`), master only | every bus | none |
| `raw` | none | every bus | sensor NICs + cart LAN |
| `can` | none | every bus | none |
| `ros` | the topic lists | none | none |

Interfaces per machine:

| machine | CAN | Ethernet |
|---|---|---|
| master | `can0`, `can1` | `enP5p4s0` (VLP-32C), `enP5p5s0` (Seyond Falcon), `enP5p3s0` (cart LAN) |
| orin | `can0` (the VCU bus) | `eno1` (cart LAN) |

The cart-LAN captures leave out ssh (`not tcp port 22`). An interface that is
missing or down at start is skipped and noted; the rest of the session still
records. `just record scopes` shows what each scope records on this machine.

The scopes live in [config/recording/scopes.yaml](../config/recording/scopes.yaml).
The topic lists are
[config/recording/master_topics.txt](../config/recording/master_topics.txt) and
[orin_topics.txt](../config/recording/orin_topics.txt): sensor and driver output
only, because replay recomputes the rest. A broken sensor's topic stays on the
list and records zero messages, which shows it was expected and silent.

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
just bag play                   # newest session bag (merged first)
just bag play <ID>
just bag replay <ID> "start_offset:=40.0"      # with RViz
```

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
just bag record              # scope ros: recordings/<ts>/<machine>/bag
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
