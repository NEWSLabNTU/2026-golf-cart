# Phase 8 — LiDAR Drivers on the Orin

Adds `LIDAR_HOST` as a placement knob for the Velodyne VLP-32C (nebula) and
Seyond Falcon drivers, following the exact pattern the ZED camera already
uses: a config env var, read by the launch chain, gating a direct include from
the orin's side of `golfcart.launch.yaml` / `sensor_only.launch.yaml`.

**Status: Code complete, default unchanged (`LIDAR_HOST=master`). Blocked from
being turned on by network bandwidth — see "The bandwidth blocker" below,
which is the reason this is a placement knob and not a migration.**

Branch: `chore/lidar-on-orin`. Last updated: 2026-09-19.

---

## Why

`golfcart_sensor_kit_launch`'s sensing chain runs on the master only —
`golfcart_autoware.launch.xml` (and therefore `tier4_sensing_component`,
`sensing.launch.xml`, `lidar.launch.xml`) is gated on `is_master`. Both LiDAR
drivers have always launched there, cabled to dedicated master NICs
(`enP5p4s0` Velodyne, `enP5p5s0` Falcon — `net_monitor_master.param.yaml`).

The ZED X camera already proved a pattern for a sensor that instead runs on
the orin: `camera.launch.xml` is a single entry point, reached normally
through the master's sensing chain for the GMSL cameras, and reached a second,
shorter way — included directly from `golfcart.launch.yaml`'s `is_orin` group
— for the ZED. This phase applies the same pattern to the LiDAR drivers, so
that *if* the sensors are ever physically re-cabled to the orin, flipping one
config value is the only launch-side change needed.

It does not move anything today. `LIDAR_HOST` defaults to `master`, and
turning it on is blocked at the network layer regardless of what this branch
does — see below.

---

## What this branch does

**Only the drivers move.** Point cloud preprocessing and concatenation
(`pointcloud_preprocessor.launch.py`, the `pointcloud_container`) are
unconditional and stay on the master in both configurations, consuming the
drivers' topics over DDS wherever they were published. This was a decision
made before implementation, not a finding of this branch: preprocessing needs
the vehicle's CUDA/CPU pipeline and container infrastructure, which lives on
the master, and moving it would be a second, unrelated project.

- **`config/sensors.conf`**: new `LIDAR_HOST` (`master` default). Same
  mechanism as `IMU_SOURCE` / `CAMERA_MODEL` and for the same forced reason —
  documented in `config/README.md` — the installed tier4 sensing launch files
  between `golfcart.launch.yaml` and the sensor kit forward a fixed set of
  arguments and drop the rest, so an environment variable is the only channel
  that survives the trip from a launch argument's worth of configurability
  down to `lidar.launch.xml`.
- **`golfcart_sensor_kit_launch` submodule** (branch `chore/lidar-on-orin` on
  the fork, not yet on `main`):
  - New `lidar_driver.launch.xml` — the single entry point for both drivers,
    mirroring `camera.launch.xml`. Pushes an *absolute* `/sensing/lidar`
    namespace rather than the usual relative `lidar`, so the topic names come
    out identical (`/sensing/lidar/vlp32/...`, `/sensing/lidar/falcon/...`)
    whether it is reached from inside `lidar.launch.xml`'s own namespace push
    (the master path, still inside the `/sensing` push
    `tier4_sensing_launch` applies upstream) or with no enclosing push at all
    (a direct include from the orin, which never enters that chain).
  - `lidar.launch.xml` now reads `lidar_host` (default
    `$(env LIDAR_HOST master)`) and only includes `lidar_driver.launch.xml`
    when it equals `master`. The unconditional preprocessor include is
    untouched.
  - `sensing.launch.xml` gained a comment explaining the two-level gating:
    `launch_driver` is uniform across lidar/camera/imu/gnss (imposed by
    `tier4_sensing_component.launch.xml`, which only forwards that one flag),
    and `lidar.launch.xml`'s own `LIDAR_HOST` check is the finer gate that
    can turn off just the LiDAR pair on the master without touching the
    others.
  - TODO comments at the three places a physical move would need real
    addressing decisions this checkout cannot make: `VLP32.param.yaml`'s
    `host_ip` (the *driver host's* NIC address — not the sensor's, which is
    `sensor_ip` right next to it and does not change), `seyond.param.yaml`'s
    `lidar_ip`, and `seyond_start.py`'s `device_ip` default (the latter two
    are the *sensor's* address, which likewise does not change — what has to
    change is the physical cable and the local interface config, covered
    below).
- **`golfcart.launch.yaml` / `sensor_only.launch.yaml`** (parent repo): new
  `is_orin_lidar` `<let>`, `True` only when `is_orin` and
  `LIDAR_HOST=orin`. A new group, gated on it, includes
  `lidar_driver.launch.xml` directly — the same shorter path
  `camera.launch.xml`'s `zedx` branch already takes, for the same reason: the
  sensing subtree it would otherwise hang off is master-only.
- **`config/recording/{master,orin}_topics.txt`**: recording follows the
  driver. The three LiDAR topics stay live in `master_topics.txt` (today's
  default) with a comment naming the rule; the same three topics were added to
  `orin_topics.txt`, commented out, with the mirror-image comment. These are
  static files, not templated by `LIDAR_HOST` — switching it means editing
  both files by hand, same as the code comments say.
- **`net_monitor_{master,orin}.param.yaml`**: TODO comments only. The device
  lists are static and describe *this machine's* interfaces; `LIDAR_HOST`
  does not move `enP5p4s0`/`enP5p5s0` out of the master's list; a real
  recable would need its own edit to both files, naming the orin's actual
  interface from `ip -br link` at the time, not a guessed name.
- **`scripts/check/vehicle.sh`**: `LIDAR_HOST` config var; `check_velodyne` /
  `check_seyond` now route their ping/interface/UDP-sniff probes over ssh to
  the orin when it is set to `orin`, the same way `check_zedx` already does,
  via a `lidar_remote` array threaded through `iface_for_ip`, `count_udp`,
  `port_free_udp` and `tcp_open`.
- **`scripts/check/run.sh`**: comment only — this script has no ssh-routing
  concept and its phase 2 starts real ROS nodes and RViz locally, so if
  `LIDAR_HOST=orin` the right move is to run the script on the orin, not to
  add remote routing here.
- **Docs**: `docs/multi-machine.md`, `config/README.md`,
  `docs/design/multi_machine_deployment.md` (reopens the "Orin payload"
  decision that reverted an earlier `falcon-on-orin` draft — see below),
  `docs/design/orin_provisioning_implementation_plan.md` (new §9, provisioning
  steps as TODO).

---

## What this branch deliberately does NOT do

- **Does not touch physical network scripts with guessed values.**
  `scripts/hardware/lidar-network/*` (MAC-bound `.nmconnection` templates) and
  `setup/files/linuxptp/*` (`ptp4l.conf`, and unit files that hardcode
  `enP5p5s0`) are untouched. Fabricating a MAC address or an interface name
  for hardware this checkout cannot see would be worse than leaving a TODO —
  it would look authoritative and be wrong. See "Still needed" below for
  exactly what those changes are.
- **Does not change `setup/golfcart_setup/registry.py`.** The
  `hardware-config` step (`registry.py:349-380`) always targets *this*
  machine's `setup-lidar-network.sh` and CAN setup with no per-host
  parameter; the `linuxptp` step installs the master's hardcoded
  `enP5p5s0` unit unconditionally. Both need real design work — which
  machine gets which profile, whether the orin needs its own `ptp4l` unit
  alongside the master's rather than instead of it — not a blind edit.
- **Does not move preprocessing or concatenation.** See "What this branch
  does" above.
- **Does not turn `LIDAR_HOST=orin` on anywhere.** It is a knob, not a
  migration. See below.

---

## The bandwidth blocker

**`LIDAR_HOST=orin` cannot be turned on today, independent of any code
change.** The master↔orin link is a shared, switched **100 Mb/s** LAN
(`docs/multi-machine.md`, confirmed by `net_monitor_master.param.yaml`'s
`enP5p3s0` comment). Each raw LiDAR runs at roughly **30 MB/s** —
`config/recording/master_topics.txt`'s own comment gives this figure for
both `/sensing/lidar/vlp32/velodyne_points` and
`/sensing/lidar/falcon/iv_points`. Two LiDARs is therefore ~60 MB/s, or
**~480 Mb/s**, against a 100 Mb/s link — not a tight fit, roughly 5x over
capacity, and that is before accounting for the ZED's own already-recorded
~40 Mbit/s compressed stream and everything else the two hosts already
exchange (DDS discovery/liveliness traffic, ssh, chrony, watchdog pings).

This is exactly the reasoning `docs/design/multi_machine_deployment.md`'s
decision table already recorded once: an earlier draft put the Falcon on the
orin, and the "Orin payload" decision reverted it, choosing the ZED
specifically because only its *compressed* stream (~5 MB/s) fits the link at
all. This branch does not relitigate that decision — it reopens the row to
note that the option now exists as a config value, gated by the same
constraint that reverted the draft, not by another ad-hoc attempt.

**A dedicated 1 Gb/s interlink already exists in the repo and is unused.**
`scripts/hardware/network/setup-interlink.sh` installs NetworkManager
profiles for a direct Ethernet link at `192.168.13.1/.2` over a free NIC
(`enP5p6s0` on the master), and `config/cyclonedds/master.xml` documents it
in a comment: "currently unused — switching to it means changing the
addresses below and in orin.xml, nothing else." At 1 Gb/s, ~480 Mb/s of raw
LiDAR traffic fits with headroom; at 100 Mb/s it does not, by a wide margin.

**Precondition for turning `LIDAR_HOST=orin` on for real:** the interlink (or
an equivalent dedicated, high-bandwidth path) has to actually be carrying
inter-host DDS traffic before raw point clouds can cross it — today it is
installed but not switched to. Until then, `LIDAR_HOST=orin` will start
cleanly (the launch and recording sides both work) and then saturate the
100 Mb/s LAN the moment real point cloud traffic starts flowing, degrading or
starving everything else that shares it, including the vehicle's own control
loop if it shares the same segment.

---

## Still needed (physical / system, tracked here as TODO)

Roughly in the order a real move would hit them:

1. **Switch DDS onto the interlink** (or confirm an equivalent link), and
   re-measure that it actually carries the expected throughput under load —
   `config/cyclonedds/{master,orin}.xml` addresses, `scripts/hardware/network/setup-interlink.sh`.
2. **Physically re-cable** the chosen LiDAR(s) from the master's
   `enP5p4s0`/`enP5p5s0` to NIC(s) on the orin.
3. **New MAC-bound `.nmconnection` templates** for the orin's LiDAR-side
   interface(s) in `scripts/hardware/lidar-network/templates/`, from the
   orin's real hardware MACs — not derived from the master's templates.
4. **`setup/golfcart_setup/registry.py`** per-host gating for the
   `hardware-config` step (`registry.py:349-380`), so provisioning installs
   the right NIC profiles on the right machine instead of always this one.
5. **PTP**: a second `ptp4l.service`/`phc2sys.service` pair for the orin's
   own LiDAR-side interface — `setup/files/linuxptp/*` currently hardcodes
   `enP5p5s0`, which is a master-only interface name and would need to be
   parameterized or duplicated, not edited in place, since the master may
   still need PTP for whatever stays on it.
6. **`net_monitor_{master,orin}.param.yaml`** device lists, updated from each
   machine's own `ip -br link` once the physical change has actually
   happened — not before, and not guessed.
7. **Re-verify recording bandwidth end to end**: confirm the chosen link
   sustains both LiDARs' combined rate continuously (not just briefly) before
   trusting a bag recorded over it, and re-run the topic-list audit in
   `docs/multi-machine.md` against the new namespace/host split.

None of these are started by this branch. `docs/design/orin_provisioning_implementation_plan.md`
§9 cross-references items 3–4 in that document's own numbering scheme.

---

## How to verify (once hardware exists)

Nothing here is verifiable in a checkout with no ROS, no Autoware and no
hardware — which is how this branch was written. Once on real hardware:

```bash
LIDAR_HOST=orin just launch                    # single machine: still runs everything here
LIDAR_HOST=orin just launch-all                # two machines: drivers move to the orin
just service host-status                       # confirm effective LIDAR_HOST on each host
ros2 topic hz /sensing/lidar/vlp32/velodyne_points   # from the master, over DDS
LIDAR_HOST=orin scripts/check/vehicle.sh velodyne seyond   # routed checks, see script header
```

And the thing to actually watch: `ros2 topic hz` on both raw LiDAR topics
from the master while the stack is under normal load, to see whether the
interlink holds the advertised rate or the shared LAN visibly degrades
everything else.
