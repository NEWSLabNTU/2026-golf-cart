# Recording

Each machine records its own sensors to its own disk. Recording is separate from
the stack: start and stop it at any time, with the stack up or down.

## Before you record

**1. Check free disk.** The master's own disk is small and nearly full. Bags must
go to the external SSD.

```bash
source scripts/env.sh; echo "$GOLFCART_BAG_DIR"   # should be /mnt/external/rosbags
df -h "$GOLFCART_BAG_DIR"
```

If it says `~/rosbags`, the SSD is not mounted. Mount it first. Recording runs at
15 to 30 MB/s, so the master's own disk fills in minutes.

**2. Make sure the vehicle interface is running.** Localization needs the speed
report, so a bag without it cannot be replayed usefully. The interface runs on
the orin as part of `just up`. Check that the speed report is arriving:

```bash
ros2 topic hz /vehicle/status/velocity_status
```

The cart does not need to be in AUTO for this, but it must be powered on.

## Start and stop

```bash
just record start    # both machines start recording
just record status   # is each machine recording?
just record stop     # both stop; the orin's bag is copied over and merged
```

`just record stop` returns once both bags are closed. Copying and merging then
runs in the background and prints where its log is. The result is one bag on the
master, `merged_<timestamp>`.

To stop without merging, and merge later:

```bash
just record stop merge=off
just record collect                           # the newest session
just record collect master_20260924_124734    # a given session
```

`just down` does not stop a recording.

## Where bags land

One directory per run, named `<machine>_<YYYYmmdd_HHMMSS>`:

| machine | directory |
|---|---|
| master | `/mnt/external/rosbags` when the SSD is mounted, else `~/rosbags` |
| orin | `~/rosbags` |

The merged bag is `merged_<timestamp>` next to the master's bag. It is about the
size of both inputs together.

## Copying and merging by hand

For bags that `just record stop` did not merge:

```bash
just bag fetch-orin                      # copy all new orin bags to the master
just bag fetch-orin "--latest"           # only the newest
just bag fetch-orin "--list"             # list what is on the orin
just bag merge "master_20260814_152605 orin_20260814_152603"
just bag merge "-o /mnt/external/rosbags/session1 <bag> <bag>"
```

Fetching never deletes from the orin. Delete the originals there yourself once
you have checked the copies. Do not fetch while driving: it fills the link.

## Looking at a bag

```bash
just bag replay                                # newest merged (or master) bag, with RViz
just bag replay merged_20260810_1230 "rate:=2.0"
just bag replay "" "start_offset:=40.0"        # skip the first 40 s
just bag play                                  # plain ros2 bag play of the newest bag
ros2 bag info <bag directory>                  # what is in it
```

A merged bag starts with about 35 s of orin-only data, because the orin starts
first. Use `start_offset:=40.0` if master topics look silent at the start.

## Recording in a terminal (one machine)

To record this machine only, in the foreground (Ctrl-C stops and closes the bag):

```bash
just bag record                  # $GOLFCART_BAG_DIR/master_<ts>
just bag record campus_loop      # $GOLFCART_BAG_DIR/master_<ts>_campus_loop
```

## What is recorded

The topic lists are plain text, one topic per line:

```
config/recording/master_topics.txt
config/recording/orin_topics.txt
```

Only sensor and driver output is recorded. Computed topics are left out, because
replay recomputes them. A broken sensor's topic stays on the list and records
zero messages, so the bag shows it was expected and silent.

More detail (time sync, checking a merged bag, damaged bags):
[multi-machine.md](multi-machine.md#recording).
