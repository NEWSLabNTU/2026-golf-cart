# Multi-Machine Deployment: Master + Orin Architecture

**Status**: Design approved (2026-08-05); amended 2026-08-07 — see *Amendments*
**Builds on**: commit `f405a3b` — `feat(launch): add host argument for multi-machine deployment`

> **Partly superseded (2026-08-14).** The rationale here still holds — why the
> hosts split the way they do, why each records locally, why play_launch is
> stopped with SIGINT. The *mechanism* sections do not: per-host units
> (`golfcart-orin.service`), the `orin_remote.sh` orchestrator with its EXIT trap,
> and recording as a launch entry have all been replaced. See
> [orin_provisioning_implementation_plan.md](orin_provisioning_implementation_plan.md)
> §4 for what exists now, and [../multi-machine.md](../multi-machine.md) for how
> to operate it. Treat file names and lifecycle tables below as historical.

## Amendments

**2026-08-10 — step 5 findings from first bring-up.**

- **play_launch ignores SIGTERM.** systemd's default stop left the unit in
  `deactivating` for the full `TimeoutStopSec`, then SIGKILLed the cgroup and
  marked it `failed (Result: timeout)`. A SIGKILLed `ros2 bag` never writes
  `metadata.yaml`, so every recording would have been lost on shutdown. The unit
  now sets `KillSignal=SIGINT`, the path play_launch actually handles; stops are
  clean and `Result=success`.
- **The ZED SDK silently breaks DDS.** It ships
  `/etc/sysctl.d/60-zed-buffers.conf` with `net.core.rmem_max=1048576`, which
  sorts *after* our old `10-cyclone-max.conf` and undercuts it. Our profiles set
  `SocketReceiveBufferSize min="10MB"`, a hard minimum, so CycloneDDS refused to
  create a domain at all — with every profile, loopback included. The setup
  script now writes `99-cyclonedds-max.conf` and deletes the `10-` file. Any host
  that gets the ZED SDK installed later must re-run it.
- **Watchdog timing is ~42s, not 30s.** Each cycle costs the ping timeout (2s)
  plus the interval (5s), so six misses take `6 * 7 = 42s`. Still inside §6 item
  6's "~30–45s" window, but the arithmetic in §2 is wrong.
- **`set -u` cannot wrap ROS setup files.** They read unbound variables by
  design (`AMENT_TRACE_SETUP_FILES`), which aborted the unit before it launched.

Verified on hardware: `orin_remote.sh start` brings both units up, ZED topics and
data reach the master, `stop` leaves both units inactive with no orphan processes,
the watchdog fires when the master is unreachable, and `record:=true` produced a
45s bag on the orin's local disk — 8397 messages, 295 MB, finalized cleanly.

**2026-08-07 — §5's risk gate FAILED: play_launch does not replay `executable:` entries.**
Tested against play_launch 0.5.1 with a launch file holding two `executable:`
actions (`sleep 45`, and a `touch` of a marker file):

- Plain `ros2 launch` runs both, so the YAML is valid.
- Under play_launch, step 1 (dump) **runs** them — the marker appears — and then
  **waits for them to exit**: `sleep 45` held the dump for the full 45 s.
- The resulting `record.json` has keys `container`, `file_data`,
  `lifecycle_node`, `load_node`, `node` and nothing for `ExecuteProcess`. All
  five lists were empty.
- Step 2 (replay) reported `Spawning 0 nodes (0 pure nodes, 0 containers,
  0 composable nodes)`.

So an `executable:` entry runs exactly once, in the wrong phase, unsupervised,
and never appears in the replay the user actually interacts with. A long-lived
one — `ros2 bag record`, or `orin_remote.sh` holding an ssh session — blocks the
dump indefinitely, so the stack would never reach replay at all. This kills the
recorder and orchestrator design in §2 and §3 as written.

The fallback works: a `node:` entry (`demo_nodes_cpp talker`) dumps without being
executed and replays as `Spawning 1 nodes (1 pure nodes, …)`. dump_launch
evidently intercepts `Node` actions to record their command lines while letting
`ExecuteProcess` run for real.

Resolution: recorders take option 1, the orchestrator takes option 2. The
recorders belong in the play_launch UI and need supervised teardown so the bag
finalizes; the orchestrator is not a ROS node and should not pretend to be, and
its ssh-hold semantics fit a shell EXIT trap in the `just launch-master` recipe.

Options as considered:

1. Wrap each script as a package executable so it enters as a `node:` entry.
   Caveat: replay spawns nodes with ROS arguments appended, so a shell script
   must tolerate a trailing `--ros-args …`.
2. Start them outside play_launch, from the `just launch-master` recipe, with a
   shell EXIT trap for teardown. Loses play_launch's supervision and web UI.
3. systemd user units on both hosts, started and stopped around the launch.
   Consistent with the orin side, which already needs a unit for §2's lifecycle.

**2026-08-07 — the inter-machine link is the existing wired LAN, not the WiFi AP.**
The master has no wireless radio: no `wlan*` device, no wireless PCI or USB
device, `rfkill` lists no radios, and `cfg80211` is loaded with no driver above
it. The M.2 Key-E slot is empty, so the AP described below cannot be raised on
this machine.

Both hosts are instead on the existing 4G LAN, which already carries SSH between
them:

| | address | interface |
|---|---|---|
| master | `192.168.125.100` | `enP5p3s0` |
| orin (`jetson@`) | `192.168.125.101` | — |

Consequences for the design below, which assumed `192.168.13.1/.2` over WiFi:

- Everywhere `192.168.13.1` / `192.168.13.2` appears, read `192.168.125.100` /
  `192.168.125.101`. That covers §2's watchdog ping target, §3's DDS profiles,
  and §4's provisioning.
- `AllowMulticast` stays `default` rather than dropping to `spdp`: multicast is
  reliable on switched Ethernet. The unicast `<Peers>` entries are kept as a
  discovery fallback.
- §3's bandwidth rule stands and is now the binding constraint: `enP5p3s0`
  negotiates **100 Mb/s** and the segment is shared with the 4G router and other
  devices. Full-rate ZED image topics must not cross it; they are recorded on the
  orin's local disk.
- `ROS_DOMAIN_ID` stays unset, as §3 says — but the reasoning there ("private AP,
  pinned peers") no longer holds on a shared LAN. Any other ROS 2 machine joining
  this network merges into the graph. Set a domain id on both hosts if that
  becomes a problem.
- Time sync: chrony as designed. PTP hardware timestamping is available on these
  i226 NICs, but the shared segment and its router make the sub-µs result
  unreliable, so it buys little over chrony's ~ms here.
- The WiFi client side of §4 (`setup-wifi-client.sh`,
  `golfcart-client.nmconnection.in`) is not needed and was never written.
  `setup-wifi-ap.sh` and `templates/golfcart-ap.nmconnection.in` are left in the
  tree unused, live again only if a radio is fitted.

**Upgrade path.** `scripts/hardware/network/setup-interlink.sh` installs a
dedicated 1 Gb/s link on `192.168.13.1/.2` over the master's free `enP5p6s0` NIC
and the orin's spare port. It is written and unused. Running it removes the
100 Mb/s ceiling and the shared-segment caveats above; the only code change
needed is the pair of addresses in `config/cyclonedds/{master,orin}.xml`.

**Goal**: Run the golf cart stack across two machines with one command:

1. The **master** (AGX Orin on the cart) runs the full Autoware stack and its wired
   sensors; launching it with `host:=master` automatically launches the **orin**
   (slave Jetson) with `host:=orin`.
2. Killing the master's processes kills the related orin processes — **no orphans**,
   even on network cut or master hard power-off.
3. Recording runs on both hosts simultaneously: sensor topics on the master,
   camera (ZED) topics on the orin — each written to **local** disk.

---

## 1. Background

Commit `f405a3b` added a `host` launch argument (`master|orin|all`, default `all`) to
`golfcart.launch.yaml`. `is_master` gates the entire Autoware stack; `is_orin` gates a
lifted-out `falcon.launch.xml` (the Seyond driver was extracted from the sensor kit
because `tier4_sensing_component` does not forward custom arguments). This proved the
gating mechanism, but nothing actually connects two machines:

- `cyclonedds.xml` pins DDS to **loopback** (`name="lo"`, `autodetermine="false"`),
  so `host:=master` and `host:=orin` on two boxes form two isolated ROS graphs.
- No orchestration: `just launch-orin` must be run by hand on the second box, and
  killing the master leaves the orin side running.
- `scripts/rosbag/record_outdoor.sh` has a stale, single-host topic list
  (no falcon topics; camera entries use `front` while the kit publishes `left/right/rear`).

Decisions taken for this design:

| Decision | Choice |
|---|---|
| Lifecycle mechanism | SSH + systemd user unit + ping watchdog |
| Inter-machine network | Existing GolfCart WiFi AP (master `192.168.13.1/24`, orin static `192.168.13.2`) |
| Orin payload | **ZED camera** (falcon-on-orin was a draft test → falcon returns to master, whose NIC config `172.168.1.x/enP5p5s0` it uses) |
| Recording trigger | Launch argument: `just launch-master record:=true` |
| Time sync | chrony over the AP (PTP has no HW timestamping on WiFi) |

**2026-09 (`chore/lidar-on-orin`) reopens the "Orin payload" row above.** That
decision reverted a draft test; this branch reintroduces the *option* as a
config placement knob (`LIDAR_HOST` in `config/sensors.conf`, default still
`master`, so nothing here actually changes today) rather than another draft
test, and only for the driver processes - preprocessing and concatenation stay
on the master unconditionally either way. The reason the original attempt
didn't stick still applies at the network layer: this design's own WiFi AP has
even less headroom than the switched 100 Mb/s LAN that replaced it (see
`docs/multi-machine.md`), and a raw LiDAR at ~30 MB/s does not fit either one.
See [docs/roadmaps/8-lidar-on-orin.md](../roadmaps/8-lidar-on-orin.md) for the
accounting and what would have to change before `LIDAR_HOST=orin` is real.

## 2. Architecture

```
┌─ master (cart AGX Orin, AP 192.168.13.1) ─────────────┐
│ play_launch ── golfcart.launch.yaml host:=master      │
│   ├─ golfcart_autoware.launch.xml (full stack)        │
│   ├─ falcon.launch.xml   (Seyond, 172.168.1.x wired)  │
│   ├─ record_master.sh    (if record:=true)            │
│   └─ orin_remote.sh      (if use_orin:=true)          │
│        │ ssh: systemctl --user restart golfcart-orin  │
│        │ hold: journalctl -f   (EXIT trap → stop)     │
└────────┼──────────────────────────────────────────────┘
         │ GolfCart WiFi AP ── DDS (CycloneDDS, spdp-multicast
         │ 192.168.13.0/24     only, unicast data, pinned peers)
┌────────┼─ orin (slave Jetson, client 192.168.13.2) ───┐
│ systemd user units (cgroup kill ⇒ no orphans)         │
│   golfcart-orin.service                               │
│     └─ play_launch ── golfcart.launch.yaml host:=orin │
│          ├─ camera.launch.xml camera_model:=zedx      │
│          │    (/sensing/camera/zed/...)               │
│          └─ record_orin.sh  (if record:=true, local)  │
│   golfcart-orin-watchdog.service (PartOf=main unit)   │
│     └─ ping 192.168.13.1; 6 misses ⇒ stop main unit   │
└───────────────────────────────────────────────────────┘
```

### Lifecycle coverage (why no orphans)

| Failure | What stops the orin side |
|---|---|
| Master launch stopped normally (Ctrl-C, play_launch stop) | `orin_remote.sh` EXIT trap → `ssh systemctl --user stop golfcart-orin` |
| Master stack killed (`kill -9 play_launch`) while network up | play_launch's process group dies → orin_remote's foreground ssh dies → trap still runs in the surviving shell; if not, watchdog catches it |
| Network cut / AP down / master hard power-off | Orin watchdog pings fail 6×5 s → `systemctl --user stop` locally |
| Any of the above | systemd default `KillMode=control-group` kills everything play_launch spawned on the orin |

The watchdog is **ping-based**, not a ROS heartbeat: the two mechanisms above already
cover both "master dead, network up" (SSH stop) and "network dead" (ping fail); a DDS
heartbeat would add complexity without covering a new failure mode.

### DDS over the WiFi AP

Per-host CycloneDDS profiles in `config/cyclonedds/`:

- `loopback.xml` — byte-for-byte the current root `cyclonedds.xml`; default profile,
  keeps single-box `just launch` behaviour identical.
- `master.xml` / `orin.xml` — bind by **address** (`192.168.13.1` / `192.168.13.2`,
  robust to differing wlan interface names), `<AllowMulticast>spdp</AllowMulticast>`
  (WiFi multicast is unreliable; data goes unicast), unicast `<Peers>` pinned to the
  other host as discovery fallback, `<ParticipantIndex>auto</ParticipantIndex>` with a
  raised `MaxAutoParticipantIndex` (Autoware = many processes), enlarged socket
  receive buffers.

Selection: `.envrc` exports `CYCLONEDDS_URI` from `GOLFCART_DDS_PROFILE`
(default `loopback`); `just launch-master` / `just launch-orin` override the URI
explicitly so they work without direnv. `ROS_DOMAIN_ID` stays unset on both hosts
(private AP, pinned peers).

**Bandwidth rule**: full-rate ZED image topics must never cross the WiFi. They are
recorded locally on the orin; only low-rate topics (camera_info, diagnostics, any
downsampled streams) should be subscribed cross-host.

### Recording

`record:=true` adds per-host recorder processes *inside* the launch, so they are
supervised and die with the stack:

- Master: `scripts/rosbag/record_master.sh` → `rosbags/master_<ts>` —
  Velodyne + falcon + GNSS + IMU + vehicle status + `/diagnostics` + `/tf` + `/tf_static`.
- Orin: `scripts/rosbag/record_orin.sh` → `rosbags/orin_<ts>` (orin-local disk) —
  ZED `rgb/image_rect_color/compressed`, `rgb/camera_info`, `imu/data`, `/tf_static`
  (depth off by default — enable deliberately, it is very large).

Both scripts `exec ros2 bag record …` so SIGTERM reaches the recorder directly and
bags finalize cleanly. `just bag fetch-orin` rsyncs orin bags to the master over the AP.
chrony (master = stratum-10 server on the AP, orin = client) keeps the two bags'
timestamps aligned to ~ms.

## 3. Components

| Component | Path | Role |
|---|---|---|
| Launch gating | `src/launcher/golfcart_launch/launch/golfcart.launch.yaml` | `host`/`record`/`use_orin` args; falcon under `is_master`; ZED under `is_orin`; recorder + orchestrator executables |
| ZED launch | `golfcart_sensor_kit_launch/launch/{camera,zed}.launch.xml` | reached from the `is_orin` group with `camera_model:=zedx`; absolute `sensing/camera` namespaces; builds the container itself rather than including `zed_camera.launch.py`. See [zed_camera_integration.md](zed_camera_integration.md) |
| ZED driver | `src/sensor_component/external/zed-ros2-wrapper` (submodule) | NEWSLabNTU zed-ros2-wrapper; build-skipped when `/usr/local/zed` absent |
| DDS profiles | `config/cyclonedds/{loopback,master,orin}.xml` | see above |
| Orchestrator | `scripts/multi_machine/orin_remote.sh` | master-side; ssh start/hold/stop of the orin unit, 60 s reachability retry, EXIT trap |
| Unit exec | `scripts/multi_machine/orin_unit_exec.sh` | orin-side; replicates `.envrc` env (systemd has no direnv), execs play_launch `host:=orin` |
| Watchdog | `scripts/multi_machine/orin_watchdog.sh` | orin-side; ping master, stop unit after ~30 s unreachable |
| systemd units | `setup/files/systemd/golfcart-orin{,-watchdog}.service` | user units; no `[Install]` — started on demand by master; watchdog `PartOf=` main unit |
| Recorders | `scripts/rosbag/{record_master,record_orin}.sh` | per-host topic lists |
| Provisioning | `setup/scripts/{install-orin-host,install-zed-sdk,install-chrony-timesync}.sh` + `setup/justfile` recipes | orin one-time setup: units, linger, ZED SDK, chrony |
| WiFi client | `scripts/hardware/network/{setup-wifi-client.sh,templates/golfcart-client.nmconnection.in}` | orin joins GolfCart-AP with static `192.168.13.2` |

## 4. Usage (target state)

```bash
# One-time orin provisioning (on the orin):
#   checkout + build, then:
cd setup && just zed-sdk orin-host chrony-orin
../scripts/hardware/network/setup-wifi-client.sh GolfCart-AP-<MAC6>
# On the master: ssh-copy-id to the orin; add ~/.ssh/config Host golfcart-orin.

# Daily operation (on the master only):
just launch-master                  # starts master stack + orin ZED remotely
just launch-master record:=true     # + recording on both hosts
# Ctrl-C / stop  → orin unit stopped over ssh; watchdog covers hard failures.

just bag fetch-orin                 # pull orin bags over the AP

# Single-box workflows are unchanged:
just launch                         # host:=all, loopback DDS, no remote anything
```

## 5. Implementation order

1. DDS profiles + `.envrc`/justfile plumbing (single-box testable).
2. Launch args + falcon move + **risk gate**: confirm play_launch 0.5.x runs
   `executable:` YAML entries (test with a trivial `sleep`; fallback = wrap scripts
   as `ros2 run` entry points).
3. Recording scripts (testable single-box: `just launch ARGS="record:=true"`).
4. ZED: submodule, sensor-kit `zed.launch.xml`, build gating, SDK setup script (needs orin hardware).
5. Lifecycle units + orchestrator + watchdog + provisioning scripts.
6. Docs (`docs/multi-machine.md` usage guide) + CLAUDE.md corrections.

## 6. Verification checklist

1. **Single-box regression**: `just launch` unchanged; `CYCLONEDDS_URI` → `loopback.xml`, content identical to the old root file.
2. **Host guard**: `just launch ARGS="host:=bogus"` errors instead of silently launching nothing.
3. **Recorder supervision**: single-box `record:=true` → recorder visible in play_launch UI; stop finalizes the bag; no orphan `ros2 bag` process.
4. **DDS over AP**: `ros2 topic list` on master shows `/sensing/camera/zed/...`; `ros2 topic hz .../rgb/camera_info` works cross-host; wlan throughput stays low.
5. **Remote lifecycle**: `just launch-master` → orin unit + watchdog active; Ctrl-C on master → both inactive, no ZED/play_launch processes left on orin.
6. **Watchdog**: `kill -9` master play_launch or AP off → orin units stop within ~30–45 s.
7. **Recording end-to-end**: two bags (`master_<ts>`, `orin_<ts>`) with overlapping time ranges; `chronyc tracking` offset < 10 ms; `just bag fetch-orin` retrieves.
8. **Degradation**: orin powered off → `orin_remote` retries 60 s, errors out; master stack unaffected.

## 7. Open items

- Confirm the actual ZED unit model (`zedx` / `zedxm` / `zed2i`) — sets `camera_model`.
- Confirm falcon topic names for `record_master.sh` (`/sensing/lidar/falcon/iv_points`) with `ros2 topic list`.
- ZED extrinsics: restore the commented-out entry in the sensor kit's `sensor_kit_calibration.yaml` once calibrated (separate task).
- Verify WiFi AP bandwidth headroom with `iftop` during a full run; if discovery over the AP proves flaky, revisit with a dedicated wired link.
