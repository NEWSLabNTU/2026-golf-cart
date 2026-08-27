# Known configuration defects

Things that are wrong in configuration rather than in hardware or code, and that
therefore stay wrong on every run until somebody edits a file. Separate from
[roadblocks.md](roadblocks.md), which records what is blocked; these are not
blocking anything, which is exactly why they have survived.

**Evidence**: play_launch bundles `2026-08-25_16-45-52` and
`2026-08-25_17-33-40`, two `just launch` runs on the Advantech. Both runs show
every item below, so none of it depends on the container-mode change being
tested that afternoon.

**Why it matters now**: 31.1% of all diagnostic reports in the observable run
were ERROR or STALE. Most of that is this list. Phase 4-O is building a mode
strip and an MRM timeline on top of the diagnostic graph, and a graph that is
permanently a third red trains everyone to ignore it.

**Read a config out of git, not out of a submodule working tree.** One entry
here was wrong for that reason and has moved to *Not defects* below. The
one-line guard is `git submodule status --recursive | grep '^+'`.

---

## 1. RViz asks for an MRM overlay plugin that does not exist — FIXED 2026-08-28

```
[ERROR] [rviz2]: PluginlibFactory: The plugin for class
'rviz_plugins/MrmSummaryOverlayDisplay' failed to load. Error: According to the
loaded plugin descriptions the class rviz_plugins/MrmSummaryOverlayDisplay with
base class type rviz_common::Display does not exist.
```

Once per run, both runs. The error scrolls past during startup and RViz carries
on without the display.

Consequence: **RViz has never shown MRM state on this machine.** The class is
not among the 60-odd declared types in this Autoware 1.5.0 install, so this is
not a load ordering problem, it is a config referring to something that was
removed or renamed upstream.

Relevant to phase 4-O directly. Part of the argument for building MRM
visualization into the web monitor was that RViz already covers it. It does not.

**Fixed** by removing the display from `golfcart.rviz`. It was `Enabled: false`,
so it never rendered and nothing is lost; all it did was fail loudly on every
startup. If an MRM overlay is wanted later the install does ship
`autoware_overlay_rviz_plugin/SignalDisplay` and
`autoware_string_stamped_rviz_plugin/StringStampedOverlayDisplay`.

The conclusion this defect supported still stands: **RViz has never shown MRM
state on this machine**, so phase 4-O cannot assume that coverage exists.

---

## 2. `topic_state_monitor_initialpose3d` has all-zero thresholds

Its published parameters:

```
error_rate        0.00 [Hz]
warn_rate         0.00 [Hz]
timeout           0.00 [s]
measured_rate     100000.00 [Hz]
status            NotReceived
```

Every threshold is zero, and it reports ERROR on 100% of its 3,219 reports.

A monitor with a zero timeout and a zero error rate cannot express a healthy
state. It is a graph leaf that is red by construction, which is worse than
absent: absent is visible, permanently red is background.

It is also the same monitor that failed to load at all in the isolated run (see
play_launch issue #0023), so it has never worked in either sense.

---

## 3. Two nodes claim `/sensing/gnss/ublox` — FIXED 2026-08-28

```
[ERROR] duplicated_node_checker: Error: Duplicated nodes detected[/sensing/gnss/ublox]
```

1,131 reports in the observable run, 77 in the isolated one.

The Advantech launches `ublox_gps_node` for a device it does not have, and in
the observable run it died saying so:

```
terminate called after throwing an instance of 'std::runtime_error'
  what():  U-Blox: Could not open serial port :/dev/ublox-gps open: No such file or directory
```

The u-blox is on the Orin, because the oToCam overlay took the Advantech's USB
ports. The launch and recording configs were never updated to match, so both
hosts start the node and collide on the name.

Two distinct bugs in one symptom: the Advantech should not start it, and the
name collision would be a real hazard if both hosts ever did have a receiver.

**Fixed** by adding `gnss_receiver:=none`, defaulted from `GNSS_RECEIVER` in
`config/sensors.conf` (the same channel as `CAMERA_MODEL` and `IMU_SOURCE`,
since nothing forwards an unknown launch argument down the sensing chain).
Verified by resolving the launch: `ublox` gives 154 nodes with one
`ublox_gps_node`, `none` gives 153 with zero.

**Not yet applied on the vehicle.** The default is still `ublox` because
`config/sensors.conf` is shared between hosts; someone has to set
`GNSS_RECEIVER=none` on the Advantech, or gate it on `config/host`.

---

## 4. Autoware's `system_monitor` runs on stock x86 defaults

The repository ships no override for
`/opt/autoware/1.5.0/share/autoware_launch/config/system/system_monitor/*`, so
the stock parameters are what ran. They assume a desktop: every network
interface up, a `hdd_reader` daemon running, an NVML GPU, a CMOS battery.

| Monitor | Reports | Why |
|---|---|---|
| `net_monitor: Network Usage` | ERROR 100% | `devices: ["*"]` monitors every interface, and `l4tbr0` is `down`. One down interface makes the whole check ERROR forever. |
| `hdd_monitor` (4 checks) | ERROR "connect error" | `hdd_reader_socket_path: /tmp/hdd_reader.sock`; the daemon is not running. |
| `gpu_monitor` (5 checks) | ERROR "No message was set" | The check never produced a result. Tegra is not NVML. |
| `cpu_monitor: CPU Thermal Throttling` | ERROR "No message was set" | Same shape. |
| `voltage_monitor: CMOS Battery` | WARN "Battery Dead" | `cmos_battery_label: ""`; the Orin has no CMOS battery to read. |

Each is a one-line parameter fix or a decision not to launch that monitor. Left
as is, they are five permanently-red leaves feeding whatever aggregates them.

Note the one that is *not* on this list: `cpu_monitor: CPU Usage` was ERROR on
26.4% of reports before the optimization and 0.4% after. That monitor works and
was telling the truth.

---

## 5. `collision_detector` reports ERROR with no message

3,184 reports, all `[ERROR] No message was set`. The node is publishing a
diagnostic status it never filled in. Either it is misconfigured or it is
running without an input it requires. Not investigated.

---

## 6. `/adapi/node/vehicle_door` reports a door status forever

`The door status is unknown.`, ERROR on 99.8% of reports. The golf cart has no
doors. The AD API door interface should not be in the graph.

Same class, not yet examined: `/adapi/node/localization: state` and
`/adapi/node/routing: state`, both ERROR ~100%, with messages that are the bare
strings `1` and `0`.

---

## 7. The web monitor still lists `/diagnostics_agg` — FIXED 2026-08-28

`src/system/golfcart_system_monitor/config/monitor_topics.yaml:57`

```yaml
- [diagnostic_msgs/msg/DiagnosticArray, /diagnostics_agg, Aggregated Diagnostics, monitor_diagnostics, reliable]
```

Nothing publishes `/diagnostics_agg` in this stack, established three
independent ways during phase 4-O. Autoware uses
`autoware_diagnostic_graph_aggregator`, which publishes `DiagGraphStruct` and
`DiagGraphStatus`, not an aggregated `DiagnosticArray`. The row is a permanent
dead entry in the monitor's own table.

---

## 8. The sensor kit's analyzer config carries a comment that is wrong — FIXED 2026-08-28

`src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/diagnostic_aggregator/sensor_kit.param.yaml:3`

> It is written for the old `diagnostic_aggregator` package, which is not …

`diagnostic_aggregator` **is** installed, at
`/opt/ros/humble/share/diagnostic_aggregator`, with working `GenericAnalyzer`
and `AnalyzerGroup` plugins. The file is unused here because Autoware chose a
different aggregator, not because the package is missing.

**Fixed**: the comment now says that, and says what the old one claimed, because
the distinction decides whether the config could be revived.

---

## Not defects

Recorded so nobody re-investigates them:

- **`vehicle_interface/*` STALE, "frame never received"** and
  `vehicle_interface: active fault`. Correct. There is no CAN bus attached.
  These four leaves are the interface honestly reporting that the VCU is absent.
- **`gyro_odometer: gyro_odometer_status` ERROR**, "Twist msg has not been
  arrived yet.; IMU msg has not been arrived yet." Correct. The Xsens MTi is
  broken and `IMU_SOURCE=zed` needs the Orin.
- **`service_log_checker`**, "The vehicle is not stopped." Consequence of the
  above, not its own fault.
- **`net_monitor: Network Traffic`**, "No data monitored: greengrass". Stock
  `monitor_program: "greengrass"`, already documented as ignorable in CLAUDE.md.
- **`VLP32.param.yaml` differing between the vehicle and this repository.** An
  earlier revision of this file listed that as defect #1, on the strength of the
  vehicle running `udp_only: false` / `return_mode: SingleStrongest` where the
  repository appeared to hold `udp_only: true` / `return_mode: Dual`. It was
  wrong. The vehicle's version is committed, as `e41e16f fix(lidar): spell
  return_mode the way Nebula parses it`, and the parent has pinned it since
  `a7baa23`. What had gone stale was a **submodule working tree**: this checkout
  of `golfcart_sensor_kit_launch` sat at `76527d1`, one commit behind the pin,
  because `git submodule update` had not been run after a pull, and the file
  read out of it was the old one.

  Worth keeping because the failure mode is not obvious: `git status` in the
  parent says nothing when a submodule is checked out *behind* its pin at a
  commit that is still an ancestor, so the stale file looks authoritative. The
  check is

  ```bash
  git submodule status --recursive | grep '^+'
  ```

  which lists exactly the submodules whose checkout is not the pinned commit.
  Run it before concluding that a config file on a machine differs from git.

---

## Suggested order

**Done 2026-08-28**: #1 (RViz MRM plugin), #3 (u-blox, code landed, still needs
`GNSS_RECEIVER=none` set on the Advantech), #7 (`/diagnostics_agg` row), #8
(analyzer comment).

Remaining, in order:

1. **The five `system_monitor` parameters** (#4). The biggest remaining source
   of permanent red, and the most involved: the param paths are hardcoded in
   `autoware_launch/launch/components/tier4_system_component.launch.xml`, an
   installed file, so overriding them needs a local copy of that launch file the
   way `sample_bag_sensor_kit_launch` copies the nebula container. The device
   list for `net_monitor` is also machine-specific, so this wants verifying on
   the vehicle rather than guessing here.
2. `topic_state_monitor_initialpose3d` (#2), `collision_detector` (#5) and the
   AD API door (#6) need someone to decide what they should say, not just what
   number to put in them.
