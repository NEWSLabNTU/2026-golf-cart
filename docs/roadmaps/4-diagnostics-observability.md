# Phase 4-O: abnormality observability

Belongs to **Phase 4, Track A (MRM & Safety Review)** in [ROADMAP.md](../../ROADMAP.md).

It is the missing prerequisite for that track's item 3, "Sensor failure handling:
test system behavior when individual sensors drop out. Ensure MRM activates
correctly." That claim cannot be verified today. The graph that decides whether a
mode is available has no runtime view of any kind, so "MRM activated correctly"
and "MRM activated for the wrong reason" look identical from outside.

Background, with the evidence for every claim:
[docs/design/diagnostics-and-mrm-visualization.md](../design/diagnostics-and-mrm-visualization.md).
The generic ROS half of the work lives in play_launch as
`docs/roadmap/phase-62-diagnostics-observability.md`.

## Where the blind spot is

The chain runs `/diagnostics` (69 leaves) into `aggregator_node`, which computes a
graph of **120 units over 59 diag leaves with 7 mode roots**, and publishes it.
Three consumers read it: the availability converter, the hazard status converter,
and a terminal logger that is launched with `enable_terminal_log: false` and
therefore prints nothing.

MRM state and operation mode are visible, in RViz: `AutowareStatePanel` ships in
`tier4_state_rviz_plugin`, is declared in `autoware_launch/rviz/autoware.rviz`,
and that is exactly the config `golfcart_autoware.launch.xml:46` launches. So
they are on screen for whoever is watching RViz, which during a drive is nobody.

The **graph** has no visualizer at all. All 19 `*_rviz_plugin` packages in
Autoware 1.5.0 were checked and none reference diagnostics. Upstream's only
readers are that silent terminal logger and an offline `tree` CLI. On a stock
install, "which leaf just made autonomous mode unavailable" has no runtime
answer.

## O-A: ground truth on the vehicle

**Blocks O-C and O-D. One session, no code.**

Everything below was determined from an x86 workstation against the installed
Autoware tree and a recorded run. Four things need confirming on the real
vehicle before anything is built.

| Check | Why it blocks |
|---|---|
| `ros2 topic info -v /api/system/diagnostics/struct` | is it `transient_local`? |
| `ros2 topic info -v /api/system/diagnostics/status`, plus `ros2 topic hz` on both | confirms the adapi nodes are live on the vehicle, not only in the 2026-08-18 planning-sim run |
| `ros2 topic list \| grep diagnostics_agg` | closes the "never published here" finding empirically instead of by inference |
| Decide: rosbridge or rclpy (see below) | structural, and it changes what O-C builds |

**Why `transient_local` decides the design.** `struct` and `status` are separate
messages joined by array index. `DiagLinkStruct` carries `parent` and `child` as
indices into the struct's `nodes` array, and `DiagNodeStatus` has no path field
at all. A subscriber holding only `status` has a list of levels it cannot name.

If `struct` is `volatile`, a monitor that starts after the aggregator receives
status forever and can never interpret it, and O-C and O-D both need a
restart-detection path built on the `id` field, which changes when the graph is
rebuilt. **That work is not scoped here**, because whether it is needed is
exactly what this check answers.

**Subscribe the AD API, not the internal topics.**

| Topic or service | Type (`autoware_adapi_v1_msgs`) | Purpose |
|---|---|---|
| `/api/system/diagnostics/struct` | `DiagGraphStruct` | nodes, leaves, links |
| `/api/system/diagnostics/status` | `DiagGraphStatus` | levels, index-parallel to struct |
| `/api/system/diagnostics/reset` | `ResetDiagGraph` | clear latched levels |
| `/api/fail_safe/mrm_state` | `MrmState` | which MRM is running, and its outcome |
| `/api/fail_safe/list_mrm_description` | `ListMrmDescription` | human-readable behaviour names |
| `/api/operation_mode/state` | `OperationModeState` | current mode, permitted transitions |

Three reasons over the internal `/diagnostics_graph/*`:

1. `autoware_adapi_v1_msgs` is version-committed. `tier4_system_msgs` is not.
2. The payloads are the same. `autoware_adapi_v1_msgs/DiagNodeStatus` differs
   from the `tier4_system_msgs` one by a single comment line, checked with `diff`.
3. `MrmState.behavior`'s enum is marked **deprecated in the message file itself**,
   pointing at the description API. `ListMrmDescription` returns
   `{behavior, name, description}`, so a UI renders "Comfortable Stop" from the
   system rather than from a hardcoded table that goes stale on the next upgrade.

`autoware_default_adapi`'s `diagnostics`, `fail_safe`, `mrm_request` and
`operation_mode` composable nodes all appear in the 2026-08-18 run's `load_node/`
records, so these are live. `hazard_status` has no API equivalent and stays at
`/system/emergency/hazard_status`, as does `/system/operation_mode/availability`,
which is the per-mode availability `OperationModeState` does not break out.

**The structural decision.** `golfcart_system_monitor` today is a rclpy node
holding subscriptions behind a hardcoded type map, with Flask serving JSON. Every
new topic costs a subscription, a type-map entry and a serialiser, and that type
map is why the GNSS entries were silently skipped at load for so long.

`rosbridge_server` is already installed in `/opt/ros/humble`. Over it, the browser
subscribes by topic name and the Python side contributes nothing per-type.

That is a different monitor, not a bigger one. Take the decision here, before
O-C, because taking it afterwards means building O-C twice. Either way the
`monitor_topics.yaml` liveness table should survive: it answers "is this device
publishing at all", which the graph does not.

## O-B: play_launch, generic ROS

**No dependency on O-A. Runs in parallel.**

Tracked in play_launch, not here: `docs/roadmap/phase-62-diagnostics-observability.md`.

- W1, four registry and transport defects: **done**, `a7c2da7` / `adee4f6` / `adf6516`
- W2, diagnostics badges on the node cards
- W3, level-transition strip over time

Nothing there takes an Autoware message dependency, which is the test for
anything proposed on that end.

## O-C: mode availability strip

**Needs O-A. Build this first of the three vehicle views. If only one thing gets
built, this is it.**

Seven chips, one per mode root (`stop`, `autonomous`, `local`, `remote`,
`emergency_stop`, `comfortable_stop`, `pull_over`), each available or not.

This is the one-glance answer and the cheapest of the three: the aggregator
already computes it and already publishes it. An operator needs to know
autonomous became unavailable immediately, without reading 59 rows to work it
out.

Acceptance:

- a leaf forced to ERROR turns the right chip red within one second
- the chip set is read from `struct`, not hardcoded, so a graph change does not
  silently drop a mode from the display
- the display distinguishes "mode unavailable" from "no data yet", which are
  different and must not both render as red

## O-D: the failing path, not the fault tree

**Needs O-C's struct handling.**

When a mode goes unavailable, show the path from that mode root down to the leaf
that caused it. Rendering all 120 units is a wall of green that hides the one red
line through it, so collapse to the failing path by default and expand on demand.

`is_dependent` on `DiagNodeStatus` distinguishes a node that failed from one that
merely inherited a failure, so the originating leaf is identifiable rather than
guessed. `latch_level` records the worst level seen, so a fault that has already
cleared is still attributable.

Acceptance:

- with two simultaneous injected faults, both originating leaves are named
- no inherited node is ever reported as a cause
- a fault that clears before the operator looks is still attributable, via
  `latch_level`

## O-E: MRM timeline

**Needs O-A only, not O-C.**

`MrmState` is a state machine, and what matters after an incident is the
sequence: when availability dropped, when `mrm_handler` reacted, which operator
ran, whether it reached `MRM_SUCCEEDED`. A strip chart of `mrm_state` beside
`hazard_status.level` answers post-run questions that no instantaneous view can,
including the ones RViz's `AutowareStatePanel` cannot, since it shows only the
present value.

Acceptance:

- replaying an injected fault shows availability drop, handler reaction,
  operator, outcome, in order and with timestamps
- behaviours are labelled from `ListMrmDescription`, never from a hardcoded enum

## O-F: fault injection and acceptance

**`autoware_dummy_diag_publisher` already runs in every launch** and can force any
leaf to a chosen level. It is configured from
`config/system/diagnostics/dummy_diag_publisher.param.yaml`.

This means every view above is testable on a parked vehicle, or on a bench with
no vehicle at all, without waiting for a real fault.

Acceptance for the phase as a whole: one forced leaf, and O-C, O-D, O-E and
RViz's `AutowareStatePanel` all agree on what happened.

This harness is worth building **even if none of O-C through O-E is built**,
because Phase 4 Track A item 3 needs it regardless. Testing sensor-dropout
behaviour by unplugging sensors is slower, less repeatable, and cannot produce a
LATENT_FAULT on demand.

## Cleanups, unblocked, any time

- `golfcart_system_monitor/config/monitor_topics.yaml:57` lists
  `/diagnostics_agg`, which is never published on this system. Permanent NO DATA
  row that reads as a fault. Same family as the un-namespaced Velodyne topic.
- `golfcart_sensor_kit_launch/config/diagnostic_aggregator/sensor_kit.param.yaml`
  carries a comment claiming every `type:` in it "names a plugin that does not
  exist here". **That is wrong.** `diagnostic_aggregator` is installed at
  `/opt/ros/humble/share/diagnostic_aggregator`, and its `plugin_description.xml`
  declares `GenericAnalyzer` and `AnalyzerGroup`, the only two the config uses.
  The file is inert because no node loads it, not because the plugins are
  missing, which means it is revivable rather than needing a rewrite. Fixing the
  comment needs the submodule pointer ceremony.
- `logging_diag_graph` runs in every launch with `enable_terminal_log: false`. A
  node doing nothing. Enable it or drop it.
- `golfcart_system_monitor` is commented out of `golfcart.launch.yaml:316`. Only
  `sensor_only.launch.yaml` and `logging_simulation.launch.yaml` launch it, so
  nothing built here is reachable from the normal launch until that is settled.
  Decide before O-C, not after.

## Critical path

```
O-A (ground truth + structural decision)
 |
 +--> O-C (availability strip) --> O-D (failing path)
 |
 +--> O-E (MRM timeline)

O-B (play_launch)  runs in parallel, no dependency
O-F (fault injection)  needed by all, buildable immediately
```

## Honest caveats

- **O-A is genuinely blocking.** If `struct` is `volatile`, O-C and O-D both grow
  a restart-detection path that is not scoped in this document.
- **The structural call is a rewrite, not an increment.** Deferring it past O-C
  means building O-C twice.
- Every finding here was read off an x86 workstation and a recorded planning-sim
  run. The vehicle is an AGX Orin running the same stack against real sensors.
  Nothing in the chain should differ, and that is an expectation rather than a
  measurement until O-A is done.
