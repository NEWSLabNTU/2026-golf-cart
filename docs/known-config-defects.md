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

---

## 1. The vehicle checkout is not in git

The run loaded `/mnt/external/2026-golf-cart/install/...`, and that checkout's
`VLP32.param.yaml` differs from every commit on `origin/2026-golf`:

| | in git (`6a3f9b1`) | running on the vehicle |
|---|---|---|
| `udp_only` | `true` | `false` |
| `return_mode` | `Dual` | `SingleStrongest` |
| comments | no `return_mode` spelling section | has one, about `return_mode_from_string()` vs `return_mode_from_string_velodyne()` |

The vehicle's version is the better one. It is also the one nobody else has, and
it is the file that decides the LiDAR's frame rate and point count. Commit it.

This makes every other item here provisional: what is in the repository is not
necessarily what produced these logs. Check the vehicle before concluding that
any config below is untouched.

---

## 2. RViz asks for an MRM overlay plugin that does not exist

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

Fix: either drop the display from `golfcart.rviz`, or find what replaced it. The
install does ship `autoware_overlay_rviz_plugin/SignalDisplay` and
`autoware_string_stamped_rviz_plugin/StringStampedOverlayDisplay`.

---

## 3. `topic_state_monitor_initialpose3d` has all-zero thresholds

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

## 4. Two nodes claim `/sensing/gnss/ublox`

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

---

## 5. Autoware's `system_monitor` runs on stock x86 defaults

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

## 6. `collision_detector` reports ERROR with no message

3,184 reports, all `[ERROR] No message was set`. The node is publishing a
diagnostic status it never filled in. Either it is misconfigured or it is
running without an input it requires. Not investigated.

---

## 7. `/adapi/node/vehicle_door` reports a door status forever

`The door status is unknown.`, ERROR on 99.8% of reports. The golf cart has no
doors. The AD API door interface should not be in the graph.

Same class, not yet examined: `/adapi/node/localization: state` and
`/adapi/node/routing: state`, both ERROR ~100%, with messages that are the bare
strings `1` and `0`.

---

## 8. The web monitor still lists `/diagnostics_agg`

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

## 9. The sensor kit's analyzer config carries a comment that is wrong

`src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/diagnostic_aggregator/sensor_kit.param.yaml:3`

> It is written for the old `diagnostic_aggregator` package, which is not …

`diagnostic_aggregator` **is** installed, at
`/opt/ros/humble/share/diagnostic_aggregator`, with working `GenericAnalyzer`
and `AnalyzerGroup` plugins. The file is unused here because Autoware chose a
different aggregator, not because the package is missing. Fixing the comment
needs the submodule ceremony, so it has been deferred twice.

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

---

## Suggested order

1. **Commit the vehicle's checkout** (#1). Everything else is unverifiable until
   the file on the machine and the file in git are the same file.
2. **The five `system_monitor` parameters** (#5) and the `/diagnostics_agg` row
   (#8). Cheapest, and together they remove most of the permanent red.
3. **The RViz MRM plugin** (#2), because phase 4-O has been reasoning about MRM
   visualization on the assumption that it works.
4. **The u-blox split** (#4), which is a launch-config change on both hosts.
5. `topic_state_monitor_initialpose3d` (#3), `collision_detector` (#6) and the
   AD API door (#7) need someone to decide what they should say, not just what
   number to put in them.
