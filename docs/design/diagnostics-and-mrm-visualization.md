# System diagnostics, MRM and abnormality handling: what exists, what is visible

Study, not a plan. Everything below was read off the installed Autoware 1.5.0
tree and off `play_log/2026-08-18_14-42-44/`, a real 49-node run of this system.
Claims that could not be verified offline are marked **unverified** rather than
asserted.

The question behind it: an abnormality happens on the vehicle. Where does it
show up, and where does it not?

## 1. The chain, as it actually runs

Node names below are the ones that appeared in the 2026-08-18 run, so this is
what the golf cart launches, not what upstream documents.

```
 59 diag leaves                    graph: 120 units, 7 mode roots
      |                                        |
      v                                        v
/diagnostics  ------------->  aggregator_node  ------>  /diagnostics_graph/struct   (structure, once)
 DiagnosticArray              (autoware_diagnostic_        DiagGraphStruct
 69 distinct names             graph_aggregator)     ------>  /diagnostics_graph/status  (levels, 10 Hz)
 in the run                                                    DiagGraphStatus
                                                          |
                    +-------------------------------------+--------------------------+
                    |                                     |                          |
                    v                                     v                          v
             converter_node                       hazard_status_converter       logging_diag_graph
        (aggregator pkg, ns /system)                                            terminal log only,
                    |                                     |                     enable_terminal_log
                    v                                     v                     defaults FALSE
    /system/operation_mode/availability     /system/emergency/hazard_status      -> silent
    /system/command_mode/availability             HazardStatusStamped
                    |                        NO_FAULT / SAFE_FAULT /
                    v                        LATENT_FAULT / SINGLE_POINT_FAULT
              mrm_handler
                    |
      +-------------+---------------------------+
      v                                         v
/system/fail_safe/mrm_state          /system/mrm/{comfortable,emergency}_stop/operate
     MrmState                                   |
 state:    NORMAL / MRM_OPERATING /              v
           MRM_SUCCEEDED / MRM_FAILED     mrm_*_operator nodes
 behavior: NONE / EMERGENCY_STOP /               |
           COMFORTABLE_STOP / PULL_OVER          v
                                          control command
```

Sizes, counted from `autoware_launch/config/system/diagnostics/`: **120 units,
59 `type: diag` leaves, 7 mode roots** (`stop`, `autonomous`, `local`, `remote`,
`emergency_stop`, `comfortable_stop`, `pull_over`). Small enough to draw whole.

The graph is a DAG of AND/OR units over the leaves. A leaf going ERROR
propagates up and knocks out whichever *modes* depend on it. That propagation is
the entire point, and it is the part nothing currently shows.

## 2. `/diagnostics_agg` does not exist on this system

Three independent confirmations:

1. Nothing launches an aggregator node. `diagnostic_aggregator`, the classic ROS
   package that publishes `/diagnostics_agg`, is not in the Autoware 1.5.0
   overlay, and Autoware's own system launch never starts one.

   > **It is installed, though**, at `/opt/ros/humble/share/diagnostic_aggregator`,
   > with `libdiagnostic_aggregator_analyzers.so` beside it. An earlier note on
   > `golfcart_sensor_kit_launch/config/diagnostic_aggregator/sensor_kit.param.yaml`
   > says every `type:` in it "names a plugin that does not exist here". That is
   > wrong: `plugin_description.xml` declares `GenericAnalyzer`, `DiscardAnalyzer`,
   > `IgnoreAnalyzer` and `AnalyzerGroup`, and the config uses only the first and
   > last. The file is inert because no node loads it, not because the plugins are
   > missing. It could therefore be revived by launching an aggregator, where
   > "nonexistent plugin" would have meant rewriting it. That comment needs fixing
   > (it lives in a submodule, so it needs the submodule-pointer ceremony).
2. The graph aggregator publishes `tier4_system_msgs/DiagGraph{Struct,Status}`,
   not `DiagnosticArray`. Different types, different topics.
3. There *is* a back-converter, `autoware_diagnostic_graph_utils/converter_node`,
   which turns the graph into a `DiagnosticArray`. It is not launched by
   `tier4_system_launch/system.launch.xml` (only `logging.launch.xml` ships in
   that package), and its output topic is `/diagnostics_array` anyway, not
   `/diagnostics_agg`. Topic name read out of
   `libautoware_diagnostic_graph_utils_tools.so`.

The running node called `converter_node` in the 2026-08-18 log is a **different
node of the same name** from the aggregator package, remapped into `/system`,
and it emits operation-mode availability, not diagnostics.

Two configs are wrong because of this, both in the "monitoring a phantom" family
already documented for the Velodyne topic:

| File | Entry | Effect |
|---|---|---|
| `golfcart_system_monitor/config/monitor_topics.yaml:57` | `/diagnostics_agg` | permanent NO DATA row. **Still there** |
| `play_launch` `default_diagnostics_topics()` | `/diagnostics_agg` | subscription that never fires. Fixed in `adee4f6` |

Neither is harmful. Both are noise that reads as a fault.

## 3. What an operator can see today

| Signal | Visible where | Gap |
|---|---|---|
| `/diagnostics` leaves | play_launch web UI, flat table | no structure, no history |
| MRM state | **RViz**, `AutowareStatePanel` | present but instantaneous; no history |
| operation mode | **RViz**, `AutowareStatePanel` | ditto |
| graph structure + propagation | **nowhere** | see below |
| `hazard_status` | nowhere | not subscribed by anything we run |
| mode *availability* per mode | nowhere | consumed by `mrm_handler`, never displayed |

`AutowareStatePanel` ships in `tier4_state_rviz_plugin`, is declared in
`autoware_launch/rviz/autoware.rviz`, and that is exactly the config
`golfcart_autoware.launch.xml:46` launches. Reading its subscriptions out of
`libtier4_state_rviz_plugin.so`, it takes `/api/fail_safe/mrm_state`,
`/api/fail_safe/list_mrm_description`, `/api/operation_mode/state`,
`/api/localization/initialization_state`, `/api/motion/state` and
`/api/routing/state`. So MRM is not invisible today. It is visible to whoever is
looking at RViz, which on this vehicle is nobody once the run starts.

The **graph** is the part with no visualizer, and that is not an oversight of
ours. I checked all 19 `*_rviz_plugin` packages in Autoware 1.5.0: **none
reference diagnostics.** The only readers upstream ships are `logging_node`
(terminal, off by default) and an offline `tree` CLI. So on a stock install the
question "which leaf just made autonomous mode unavailable" has no runtime
answer.

That is the gap worth filling, and it is squarely Autoware-specific.

## 4. Four defects in play_launch's generic diagnostics, fixed

These are `DiagnosticArray` bugs, nothing to do with Autoware, so they belonged
upstream. All four are fixed in play_launch `a7c2da7`, `adee4f6` and `adf6516`
(2026-08-20), along with the dead `/diagnostics_agg` default from section 2.
Kept here because the reasoning is the reasoning for the Autoware-side design
too, and because three of the four were only visible from this vehicle's data.

Ordered by how much they cost.

### 4.1 Unbounded history, never read

`DiagnosticRegistry::update` does `history.push(status)` on every accepted
message. `get_history` has **zero callers** and carries `#[allow(dead_code)]`.

The 2026-08-18 run wrote **405,480** rows to `diagnostics.csv`. The same
405,480 `DiagnosticStatus` values, each with a `String` hardware_id, a `String`
name, a `String` message and a `HashMap<String,String>` of values, were also
retained in RAM for the life of the process. On a multi-hour drive this grows
without bound.

The CSV is already the durable record. **Fixed:** the `Vec` is gone, and with it
the `tokio::Mutex` that guarded it, so `update` is no longer async: the
callers were awaiting a lock taken solely to push onto a vector nobody read.

### 4.2 Debounce swallows level transitions

`diagnostic_monitor.rs` keys debounce on `hardware_id/name` and applies it
*before* the registry update. Default `debounce_ms` is 100.

Autoware diagnostics publish at 10 Hz, exactly 100 ms apart. A leaf that goes
OK -> ERROR -> OK inside one debounce window is invisible to the registry *and*
absent from the CSV. Transient faults are precisely the ones worth catching.

**Fixed:** `update` reports whether the level changed, and a change bypasses the
debounce. Rate-limit the boring repeats, never the transitions. The hardware-id
filter also moved ahead of the debounce, so a filtered-out diagnostic leaves no
bookkeeping behind for a key that is never recorded.

### 4.3 Nothing ages a diagnostic out

In all 405,480 rows there were **zero STALE and zero WARNING**. Every single
row was OK or ERROR. `DiagnosticLevel::Stale` is only ever set from a publisher
declaring level 3 itself.

So when a diagnostic publisher dies, its last status sits in the registry
forever, reading OK. A node crashing looks identical to a node that is fine.
**Fixed:** `diagnostics.stale_after_ms` (default 30 s, `0` disables) ages an
entry that stops updating. The threshold had to be configurable because publish
rates differ by two orders of magnitude across a real system, and the default is
loose for the same reason.

Ageing is applied on read rather than by a sweeping task, so there is no window
in which the stored value and the reported value disagree. The consequence
matters for the UI: a diagnostic going stale raises no change event, because
silence cannot announce itself.

### 4.4 Poll, not push

`DiagnosticsView.js` does `setInterval(fetchDiags, 5000)`. play_launch already
has an SSE layer (`/api/state/updates`, `/api/metrics/system`), so the machinery
exists. Worst case an ERROR is 5 seconds stale on screen, and the level filter
re-fetches nothing in between.

Under 4.2 and 4.3 the poll is also the *only* reason short faults sometimes show
at all: they linger in the registry until overwritten.

**Fixed:** `/api/diagnostics/stream` pushes the whole table on every level change
and once a second otherwise. The 1 Hz tick is not belt-and-braces. It is the
only thing that surfaces 4.3, since a publisher going silent generates no event
by construction. `/api/diagnostics/{list,counts}` stay for scripts.

## 5. Where each piece belongs

The split the project already wants, made explicit:

**play_launch stays ROS-generic.** Its diagnostics feature is defined entirely
over `diagnostic_msgs/DiagnosticArray`, which every ROS 2 system has. Section 4
is all in scope. Nothing in section 1 below the aggregator is: `tier4_system_msgs`
would drag an Autoware message dependency into a launcher meant for any ROS user,
and the DAG semantics are Autoware's, not ROS's.

One exception was worth taking, and is taken: **`/diagnostics_agg` is out of the
default topic list**, with the list still configurable. It is dead on Autoware
and on any system that has not deliberately launched the classic aggregator.
`/diagnostics` alone is the honest default.

**golfcart_system_monitor becomes the Autoware-aware view.** It already
subscribes `DiagnosticArray` and serves a web UI, and it is already
config-driven through `monitor_topics.yaml`. What it needs is a second data
source, gated by config so a non-Autoware variant simply does not enable it:

**Subscribe the AD API, not the internal topics.** Autoware exposes all of this
a second time on its versioned public interface, and that is what an external
tool is meant to use:

| Topic / service | Type (`autoware_adapi_v1_msgs`) | Purpose |
|---|---|---|
| `/api/system/diagnostics/struct` | `DiagGraphStruct` | nodes, leaves, links. Structure only |
| `/api/system/diagnostics/status` | `DiagGraphStatus` | levels per node/leaf, index-parallel to struct |
| `/api/system/diagnostics/reset` | `ResetDiagGraph` | clear latched levels |
| `/api/fail_safe/mrm_state` | `MrmState` | which MRM is running and whether it succeeded |
| `/api/fail_safe/list_mrm_description` | `ListMrmDescription` | **human-readable** MRM names, see below |
| `/api/operation_mode/state` | `OperationModeState` | current mode and what it may change to |

The internal `/diagnostics_graph/*` and `/system/fail_safe/mrm_state` remain as
a fallback. Three reasons to prefer the API:

- `autoware_adapi_v1_msgs` is version-committed; `tier4_system_msgs` is not.
- the payloads are the same. `DiagNodeStatus` differs between the two packages
  by one comment line and nothing else, checked with `diff`.
- `MrmState.behavior`'s enum is marked **deprecated in the message file itself**,
  pointing at the description API. `ListMrmDescription` returns `{behavior, name,
  description}`, so a UI can render "Comfortable Stop" from the system rather
  than from a hardcoded enum table that goes stale on the next upgrade.

These are live on this vehicle: `autoware_default_adapi`'s `diagnostics`,
`fail_safe`, `mrm_request` and `operation_mode` composable nodes all appear in
the 2026-08-18 run's `load_node/` records.

`hazard_status` has no API equivalent and stays internal at
`/system/emergency/hazard_status` (`HazardStatusStamped`), as does
`/system/operation_mode/availability`, which is the per-mode availability the
API's `OperationModeState` does not break out.

Note `struct` and `status` are **separate messages joined by array index**:
`DiagLinkStruct` carries `parent`/`child` as indices into the struct's `nodes`
array, and `DiagNodeStatus` has no path field at all. The UI must hold the
struct and index into it. If the struct is not `transient_local`, a late-joining
monitor gets status it cannot interpret until the aggregator restarts.

> **Unverified, and it decides the design.** Whether the struct topic is
> published `transient_local` could not be determined offline, because the binaries are
> stripped and no bag containing it exists here. Check on the vehicle with
> `ros2 topic info -v /api/system/diagnostics/struct` before building anything
> that assumes late-join works. If it is `volatile`, the monitor needs a
> restart-detection path (the `id` field on both messages exists for exactly
> this: it changes when the graph is rebuilt).

## 6. What ROS and Autoware already give us

Surveyed before proposing anything, because half of "we should build X" turns out
to be "X exists and nobody launches it".

### Installed and usable today

| Tool | Where | What it does | Verdict |
|---|---|---|---|
| `rqt_robot_monitor` | `/opt/ros/humble` | tree view of `/diagnostics_agg`, grouped by analyzer | **needs an aggregator**, which nothing launches |
| `rqt_runtime_monitor` | `/opt/ros/humble` | flat list of raw `/diagnostics`, KV inspector | works now, but it is a desktop Qt app |
| `diagnostic_aggregator` | `/opt/ros/humble` | the classic analyzer-tree aggregator | installed, not launched, config already written (§2) |
| `rqt_console` | `/opt/ros/humble` | `/rosout` with severity filter | complements diagnostics; unused here |
| `rosbridge_server` | `/opt/ros/humble` | ROS over WebSocket, JSON | **a browser can subscribe ROS directly** |
| `AutowareStatePanel` | `tier4_state_rviz_plugin` | operation mode, MRM state, routing, localization init | already in our RViz config (§3) |
| `logging_node` | `autoware_diagnostic_graph_utils` | prints the graph as a tree to a terminal | launched, `enable_terminal_log: false` |
| `tree` | `autoware_diagnostic_graph_aggregator` | offline dump of a graph YAML | design-time, not runtime |
| `dump_node` | `autoware_diagnostic_graph_utils` | live graph dump | not launched; the closest thing to what we want |
| `dummy_diag_publisher` | `autoware_dummy_diag_publisher` | **injects synthetic faults** | launched already; the fault-injection path for testing |

Two of these change the plan.

**`rosbridge_server` means the system monitor need not proxy ROS at all.** Its
current design (a rclpy node holding subscriptions, Flask serving JSON) has to
add a subscription, a type mapping and a serialiser for every new topic, which is
exactly why `monitor_topics.yaml` carries a hardcoded type map that silently
skips anything unlisted. Over rosbridge the browser subscribes by topic name and
the server contributes nothing per-type.

**`dummy_diag_publisher` is already running** and can force any leaf to a chosen
level. Every view proposed below can be exercised against a parked vehicle, or
none at all, without waiting for a real fault.

### Deliberately not proposed

- **Foxglove.** Not installed, and its diagnostics panel reads `DiagnosticArray`,
  so it would show the same flat leaves with none of the graph. Its value here
  would be layout, not information.
- **A new RViz plugin for the graph.** RViz is the right home for anything
  spatial and the wrong home for a 120-node DAG, and it is not running during a
  normal drive on this vehicle.
- **Reviving `diagnostic_aggregator`** to feed `rqt_robot_monitor`. It would
  produce a second, differently-shaped aggregation next to Autoware's, from a
  config nobody maintains. Two disagreeing trees is worse than one missing view.

## 7. What to build, and on which end

The flat table play_launch has is right for "what is broken". It is useless for
"what does that break", which is the question a graph answers and a list cannot.

### play_launch: keep it about processes and `DiagnosticArray`

Two additions, both generic ROS, both cheap now that the registry pushes:

**P1. Diagnostics on the node cards.** play_launch already knows every node it
spawned and already has a `/diagnostics` feed keyed by `hardware_id/name`. It
does not join them. A badge on each node card, carrying the worst level among that
node's diagnostics, turns the diagnostics table from a separate screen into an
annotation on the thing an operator is already looking at. The join is a heuristic
(`hardware_id` is free text) and must be presented as one, with an unmatched
bucket rather than a guess.

**P2. A level-transition strip.** The registry now sees transitions rather than
swallowing them (§4.2). A per-diagnostic sparkline of level over time answers
"was it flapping or did it fail once", which neither the current table nor the CSV
answers without a spreadsheet. Bounded ring buffer, explicitly sized: the point
of §4.1 was that an unbounded one is how this went wrong before.

Nothing above needs an Autoware message. That is the test for anything proposed
on this end.

### golfcart_system_monitor: the Autoware views

Three, in value order:

**A1. Mode availability strip.** Seven mode roots, each a chip: available or not.
The one-glance answer, and the cheapest of the three, because the aggregator already
computes it and publishes it. An operator needs to know autonomous went
unavailable immediately, without reading 59 rows. Build this first; if only one
thing gets built, this is it.

**A2. Fault path, not fault tree.** When a mode goes unavailable, show the path
from that mode root down to the leaf that caused it. Rendering all 120 units is a
wall of green that hides the one red line through it, so collapse to the failing
path by default and expand on demand. `is_dependent` on `DiagNodeStatus`
distinguishes a node that failed from one that merely inherited a failure, so the
originating leaf is identifiable rather than guessed.

**A3. MRM timeline.** `MrmState` is a state machine, and what matters after an
incident is the sequence: when availability dropped, when `mrm_handler` reacted,
which operator ran, whether it reached `MRM_SUCCEEDED`. A strip chart of
`mrm_state` beside `hazard_status.level` answers post-run questions no
instantaneous view can. Label the behaviours from `ListMrmDescription`, not from
a hardcoded enum. The enum is deprecated in the message file.

`latch_level` on `DiagNodeStatus` is worth surfacing in all three: it records the
worst level seen, so a fault that has already cleared is still attributable. The
graph therefore retains transitions that a naive sampler loses, the same problem
as §4.2, already solved on the Autoware side.

### The structural question to settle first

The current monitor is a rclpy node with a hardcoded type map, plus Flask. Every
topic above costs a subscription, a type-map entry and a serialiser, and the type
map is why GNSS entries were silently skipped for so long. With `rosbridge_server`
already installed, the browser can subscribe `/api/system/diagnostics/*` directly
and the Python side contributes nothing per-type.

That is a different monitor, not a bigger one, so it is a decision to take before
building A1 rather than after. The `monitor_topics.yaml` liveness table is a
genuine feature and should survive either way. It answers "is this device
publishing", which the graph does not.

## 8. Loose ends found on the way

- `golfcart_system_monitor` is **commented out** of `golfcart.launch.yaml:316`.
  Only `sensor_only.launch.yaml` and `logging_simulation.launch.yaml` launch it.
  Whatever gets built here is not reachable from the normal launch until that is
  decided one way or the other.
- `logging_diag_graph` runs in every launch with `enable_terminal_log` defaulting
  to `false`. It is a node doing nothing. Either turn it on or drop it.
- The 2026-08-18 run shows 12 distinct `topic_state_monitor_*` leaves at ERROR
  for the whole run. That is `autoware_component_state_monitor` reporting absent
  topics, and it is expected in a planning sim. Worth knowing before reading any
  ERROR count as a fault.
- `play_log/*/diagnostics.csv` is a ready-made replay corpus: 405,480 rows, 69
  names, real timing. Any staleness or transition-detection rule can be tested
  against it offline, with no vehicle.
