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
graph of **63 nodes over 41 diag leaves with 7 mode roots**, and publishes it
(measured live, see O-A).
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

## O-A: ground truth

**Status: the blocking question is ANSWERED. O-C and O-D are unblocked.**

`scripts/check/diag_graph_qos.sh` brings up the aggregator and the AD API
diagnostics node, reports the QoS of all four topics, and proves whether a
late-joining subscriber can read the graph.

It needs no vehicle, no sensors and no map. QoS is declared by the publisher's
code, so the same binaries give the same answer anywhere. Run it with `--attach`
against a live stack to confirm the launch does not override anything.

### Result, 2026-08-21, Autoware 1.5.0

| Topic | Reliability | Durability |
|---|---|---|
| `/diagnostics_graph/struct` | RELIABLE | **TRANSIENT_LOCAL** |
| `/diagnostics_graph/status` | RELIABLE | VOLATILE |
| `/api/system/diagnostics/struct` | RELIABLE | **TRANSIENT_LOCAL** |
| `/api/system/diagnostics/status` | **BEST_EFFORT** | VOLATILE |

Late join confirmed live: a subscriber created long after the graph was
published received it, `63 nodes, 41 leaves, 80 links, 7 mode roots`.

**Why this was the blocking question.** `struct` and `status` are separate
messages joined by array index. `DiagLinkStruct` carries `parent` and `child` as
indices into the struct's `nodes` array, and `DiagNodeStatus` has no path field
at all, so a subscriber holding only `status` has a list of levels it cannot
name. Had `struct` been `volatile`, a monitor starting after Autoware could
never have interpreted anything, and O-C and O-D would each have needed a
restart-detection path built on the graph `id`.

It is `transient_local`, so **no such path is needed for late join**. The `id`
still matters for one narrower case: the aggregator restarting mid-session
rebuilds the graph and changes `id`, and a monitor holding the old struct would
index into a stale array. Compare `id` on every status and re-fetch when it
changes. That is a handful of lines, not a sub-phase.

### The trap this exposed, which is now the bigger risk

**The two API topics do not share a QoS profile.** `struct` is RELIABLE, `status`
is BEST_EFFORT. A subscriber that applies one profile to both silently receives
nothing on one of them: a RELIABLE subscriber cannot match a BEST_EFFORT
publisher. Verified in the probe, which subscribes `status` RELIABLE on purpose
and gets nothing.

Worse for anyone porting code: the internal and API topics **disagree with each
other**. `/diagnostics_graph/status` is RELIABLE, `/api/system/diagnostics/status`
is BEST_EFFORT. Code developed against the internal topic and then repointed at
the API goes dead with no error.

This is the same failure documented in `monitor_topics.yaml` for the ZED, where
subscribing best-effort to a reliable publisher reported a live camera as dead.
Whatever O-C is built on must take the QoS per topic, not per subscription
group, and there must be a test that fails when they are swapped.

### Still open in O-A

| Check | Why it still needs the vehicle |
|---|---|
| `--attach` run against the full stack | confirms no launch-level QoS override, and that the adapi nodes are live on the Orin rather than only in a workstation probe |
| `ros2 topic list \| grep diagnostics_agg` | closes the "never published here" finding empirically instead of by inference |
| ~~Decide: rosbridge or rclpy~~ | **Done, see O-A2.** rosbridge, measured rather than argued |

### Correction to an earlier figure

This document and the design doc both said "120 units, 59 leaves", counted by
grepping `- path:` out of the graph YAML files. The **live** graph is 63 nodes,
41 leaves and 80 links. The static count double-counted: the YAML files define
units across several files that the aggregator resolves and dedupes, and `path:`
also appears on leaf entries. Use the live numbers. They come from the struct
message itself, which is what a UI will actually render.

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

## O-A2: the structural decision, rosbridge or rclpy

**Decided 2026-08-21: rosbridge, for the graph views. Measured, not assumed.**

`golfcart_system_monitor` today is a rclpy node holding subscriptions behind a
hardcoded type map, with Flask serving JSON. Every new topic costs a
subscription, a type-map entry and a serialiser, and that type map is why the
GNSS entries were silently skipped at load for so long. `rosbridge_server` 2.0.6
is already installed in `/opt/ros/humble`.

The measurement below was made with the aggregator, the AD API diagnostics node
and rosbridge running locally, and a websocket client counting what arrived.

### The finding that decides it: rosbridge negotiates QoS per topic

O-A established that these two topics disagree on QoS, and that a subscriber
applying one profile to both silently gets nothing on one. That is a trap a
hand-written rclpy subscriber walks into, and it is the exact trap that already
cost this project a working ZED camera reading as dead.

rosbridge does not have the bug available. `rosbridge_library/internal/subscribers.py`
calls `get_publishers_info_by_topic` and derives the profile from the publishers:
default volatile plus best-effort, promote to transient-local plus reliable when
every publisher is transient-local, demote to best-effort when any publisher is
best-effort. It re-derives on each new client subscription.

So the QoS question that would have to be got right by hand, per topic, and kept
right through every Autoware upgrade, is answered by construction.

### Measured, clean run

| | struct | status |
|---|---|---|
| rate | once | **10.0 Hz**, matching the aggregator's `rate: 10.0` |
| size on the wire | 8,684 B | 7,125 B |
| bandwidth | negligible | **69.7 KiB/s** |

**Total 70 KiB/s** for the whole graph feed. Trivial on localhost or LAN.

Both startup orders were tested and both work:

- Autoware first, then rosbridge, then the browser: struct and status both arrive.
- Browser subscribes **5 s before Autoware starts**: struct and status both still
  arrive. This was the case I expected to fail, because rosbridge negotiates QoS
  at subscribe time and the publisher does not exist yet. It does not fail,
  because volatile-against-transient-local and best-effort-against-reliable are
  both compatible pairings, so the subscription matches when the publisher
  appears.

`subscribe` also takes `throttle_rate`, `queue_length` and `compression`, so
server-side throttling for a UI that does not need 10 Hz is one field, not code.

Reproduce with `scripts/check/rosbridge_graph_feed.sh --order`.

Note the JSON cost: 7,125 B/msg on the wire for a status message describing 63
nodes and 41 leaves is roughly four times the binary form. It does not matter at
70 KiB/s on one link, and it would matter if this were ever fanned out to many
clients or run across the master-to-orin link. Throttle first, reach for
`compression` second.

> Caveat on the numbers, because two separate bugs inflated them before the
> table above was trustworthy. A first measurement read **173 Hz and 1.2 MiB/s**:
> that was four orphaned aggregators from earlier runs publishing at once, and
> `ros2 run` forks the node, so killing the PID it returns leaves the node alive.
> A second read **49.7 Hz** because the teardown between the two startup-order
> cases silently matched nothing, and the same stack ran through both (visible
> in the results as a repeated graph `id`).
>
> The fix is `set -m` plus `kill -- -$!`: with job control on, each background
> job gets its own process group whose ID equals `$!`. `setsid` is the wrong
> tool and was the second bug, because it forks when already a group leader, so
> the session ID is the grandchild's PID rather than `$!`.
>
> The script now warns when an aggregator or bridge is already running, and both
> cases show distinct graph `id`s. Anyone repeating this: if the rate is not
> 10 Hz, something stale is publishing.

### What this does not decide

**The liveness table stays rclpy.** `monitor_topics.yaml` answers "is this device
publishing at all", which the graph does not and cannot: a sensor that never
starts produces no diagnostic, so it has no node in the graph to be red. That
table is also where the hardcoded type map lives, so it keeps the maintenance
cost it always had. It is not made worse by this decision, and rewriting it is
not part of O-C.

So the monitor becomes two things sharing a page: a rosbridge-fed graph view, and
the existing rclpy liveness view. That is more moving parts than either option
alone, and it is still right, because the two answer different questions and the
graph half is the one with the QoS hazard.

**Deployment cost.** rosbridge is another process to launch and supervise, and it
is one more thing that can be down when the operator needs the page. Whatever
launches it must sit beside the monitor, and the page must say "bridge down"
rather than "no faults" when the websocket fails. That distinction is an
acceptance criterion for O-C, not a detail.

## O-B: play_launch, generic ROS

**No dependency on O-A. Runs in parallel.**

Tracked in play_launch, not here: `docs/roadmap/phase-62-diagnostics-observability.md`.

- W1, four registry and transport defects: **done**, `a7c2da7` / `adee4f6` / `adf6516`
- W2, diagnostics badges on the node cards
- W3, level-transition strip over time

Nothing there takes an Autoware message dependency, which is the test for
anything proposed on that end.

## O-C: mode availability strip

**Status: DONE, 2026-08-21.** `golfcart_system_monitor` `acfeaa7`.

Seven chips, one per mode root, above the existing liveness cards. The page
reads the graph from rosbridge directly; the monitor node gains no subscription
and does not proxy it, for the QoS reason in O-A2.

### What it does

The chip set is read from `struct`, never a hardcoded seven, so a graph that
gains or loses a mode is followed rather than silently misreported.

Three states that are easy to collapse into one, and must not be:

| State | Renders as | Why it is distinct |
|---|---|---|
| unknown | outlined chip, "awaiting status" | struct known, nothing has reported yet. A monitor started before Autoware must not show red |
| bridge down | chips blanked, note in words | a page that cannot reach the bridge must never look like a page reporting no faults |
| stalled | "no status for Ns" | bridge up, aggregator dead. The chips would otherwise sit there looking healthy |

`latch_level` is surfaced as an underline, so a mode that faulted earlier is
still attributable after it clears.

An aggregator restart rebuilds the graph with a new `id`. The strip compares the
`id` on every status and re-subscribes to `struct` when it changes, which is what
makes rosbridge re-deliver the latched message. This is the narrow case O-A left
open, and it is a few lines as predicted.

### Acceptance, met

| Criterion | Result |
|---|---|
| a leaf forced to ERROR turns the right chip red within 1 s | **0.70 s** measured |
| the chip set is read from `struct`, not hardcoded | asserted in the render test |
| unavailable is distinguished from no-data-yet | asserted |
| bridge down is distinguished from no faults | asserted |

Two tests, neither needing a vehicle:

- `golfcart_system_monitor/test/mode_strip_render_test.js` drives the **shipped**
  page JavaScript against a graph fixture captured from a live aggregator, with a
  stub DOM and WebSocket. 11 checks. `node test/mode_strip_render_test.js`.
- `scripts/check/mode_strip_test.sh` runs it live: publishes all 41 leaves
  healthy, forces `autonomous_emergency_braking: aeb_emergency_stop` to ERROR,
  and confirms `autonomous`, `pull_over` and `comfortable_stop` go red while
  `local`, `remote`, `stop` and `emergency_stop` stay green. Selectivity is the
  point: a strip that reddens everything proves nothing.

### Traps recorded while building it

The fixture keeps the real node ordering deliberately. `struct` and `status` join
by array index and `DiagNodeStatus` has no path field, so an off-by-one mislabels
every chip and still looks plausible. Renumbering the fixture retires the only
test that can catch it.

The live test initially reported an all-ERROR baseline. That was the test's own
fault, not the system's: it interleaved `rclpy.spin_once` with the websocket
drain on one thread, so `/diagnostics` stopped while sampling and the aggregator
aged every leaf out. It was measuring its own starvation. rclpy now spins on its
own thread, and the test fails loudly if the baseline is not healthy rather than
reporting a false pass.

### Not done here

No browser screenshot: the Chrome extension is not connected in this
environment. Layout and colour contrast are unverified by eye. The render test
covers structure and class names, which is what regressions actually break, but
someone should still look at it on the vehicle.

## O-D: the failing path, not the fault tree

**Status: DONE, 2026-08-21.** `golfcart_system_monitor` `36b3f81`.

When a mode goes unavailable the strip names the **leaf** that caused it, with
the chain of graph units behind an expander. Collapsed by default: the graph has
63 nodes and rendering all of them is a wall of green that hides the one red line
through it.

### Two assumptions in this document were wrong, and probing found it

**`is_dependent` is not the inherited-failure marker.** This document said to use
it to distinguish a node that failed from one that merely inherited a failure. It
reads **false on every node in this graph**, including nodes plainly inheriting
their level from a child. Attribution is structural instead: walk down from the
mode root through units that are themselves bad, and report the diag **leaves**
that are bad. A leaf is an origin; a unit above it has only inherited. A test
asserts that no `/autoware/...` unit path is ever reported as a cause.

**`latch_level` does not latch here.** `grep -rn latch` over
`autoware_launch/config/system/diagnostics/` returns nothing, so no unit in the
graph is configured to latch and the field stays 0 even while a node sits at
ERROR. The acceptance criterion "a fault that clears is still attributable via
`latch_level`" was therefore unsatisfiable as written.

Retention is now client side: the page keeps the worst level seen per mode since
load, with the causes recorded alongside it, and dims a mode that has recovered.
That delivers what the criterion was after. O-C's latched underline is kept as
defensive code but is currently dead against this graph, and should be left alone
rather than "cleaned up": a future graph that does configure latching will use it.

### Two more facts worth knowing before extending this

- **`DiagNodeStruct` in the AD API carries only `path`.** The internal
  `tier4_system_msgs` version also has `type` (`and`, `or`, `short-circuit-and`).
  The API drops it, so this view cannot show why a unit failed, only which leaf
  did. Switching to the internal topic to recover `type` would mean giving up the
  version-committed interface, which is not worth it for a label.
- **Anonymous inline `and`/`or` units have an empty path.** They are real nodes in
  `struct.nodes` with `path: ""`, and are skipped in the displayed chain rather
  than rendered as blank rows.

### Acceptance, met

| Criterion | Result |
|---|---|
| with two simultaneous faults, both originating leaves are named | asserted, faults under different subtrees |
| no inherited node is ever reported as a cause | asserted structurally, not via `is_dependent` |
| a fault that clears is still attributable | met by client-side retention, not `latch_level` |

The render test is now 19 checks. The O-D ones fault a **named leaf** and
propagate the level up through the fixture's real `links`, rather than setting
mode levels directly, so the traversal itself is under test rather than assumed.

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

## O-F: fault injection

**Status: DONE, 2026-08-21.** `scripts/check/diag_inject.py`, wrapped as
`just diag`.

Forces any diagnostic leaf to any level, so the whole fault path can be
exercised on a bench. This is what ROADMAP Phase 4 Track A item 3 needs whether
or not any view gets built: unplugging a sensor is slower, less repeatable, and
cannot produce a WARN-then-ERROR sequence or a timed recovery on demand.

```
just diag list                                   # leaf names, from the RUNNING graph
just diag inject 'aeb_emergency_stop=ERROR'      # hold it faulted until Ctrl-C
just diag inject-cycle 'ndt_scan_matcher=ERROR'  # fault at 5 s, recover at 20 s
just diag qos                                    # the O-A checks
just diag strip-test                             # the O-C acceptance test
```

### Why not `autoware_dummy_diag_publisher`

Autoware ships one and it is the right tool when the names are known ahead of
time. It reads a `required_diags` list **at startup**, so a leaf that is not in
that config cannot be faulted at runtime. Its config here was one of the 145
files deleted in the A1 sweep, and `launch_dummy_diag_publisher` defaults to
false in `golfcart_autoware.launch.xml` anyway.

`diag_inject.py` reads the leaf names out of the **live graph** instead, so it
always matches whatever the aggregator actually loaded, including the ArUco
variant, and it needs no config to maintain.

### Conflicts are refused, not warned about

The injector publishes `/diagnostics` under the real leaves' names. With a real
publisher also running, both write the same name and the aggregator takes
whichever arrived last, so the levels flap and the result means nothing. The
tool counts other publishers and **exits** rather than producing a quietly
meaningless run. `--allow-conflict` overrides it, with a warning.

That guard needed two attempts. The first counted publishers after creating its
own and filtered by node name, and since two copies of the tool are both called
`diag_inject`, each filtered the other out as itself and the guard never fired.
It now counts before publishing, so anything found is genuinely someone else.

### Verified

Injecting `aeb_emergency_stop=ERROR` with a timed clear drove the real graph
through the full cycle, read back off the mode roots:

| | autonomous | pull_over | comfortable_stop | others |
|---|---|---|---|---|
| while faulted | ERROR | ERROR | ERROR | OK |
| after clear | OK | OK | OK | OK |

Substring matching resolves `aeb_emergency_stop` to
`autonomous_emergency_braking: aeb_emergency_stop`, and an unmatched pattern is
an error naming `--list` rather than a silent no-op.

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
O-A  (QoS ground truth)          DONE, struct is transient_local
O-A2 (rosbridge or rclpy)        DONE, rosbridge for the graph views
 |
 +--> O-C (availability strip)  DONE --> O-D (failing path)  DONE
 |
 +--> O-E (MRM timeline)

O-B (play_launch)      runs in parallel, no dependency
O-F (fault injection)  DONE, and O-E can now be driven from it offline

O-C is unblocked. The only vehicle-dependent item left is confirming the QoS
against the live stack with `diag_graph_qos.sh --attach`, which is confirmation
rather than discovery.
```

## Honest caveats

- ~~**O-A is genuinely blocking.**~~ Answered: `struct` is `transient_local`, so
  no restart-detection path is needed for late join.
- ~~**The structural call is a rewrite, not an increment.**~~ Answered in O-A2,
  and smaller than feared: the graph views go on rosbridge, the existing rclpy
  liveness table stays as it is. Nothing is rewritten.
- **The monitor becomes two data paths on one page.** That is more moving parts
  than either option alone, and rosbridge is one more process that can be down.
  The page must distinguish "bridge down" from "no faults".
- Every finding here was read off an x86 workstation and a recorded planning-sim
  run. The vehicle is an AGX Orin running the same stack against real sensors.
  Nothing in the chain should differ, and that is an expectation rather than a
  measurement until O-A is done.
