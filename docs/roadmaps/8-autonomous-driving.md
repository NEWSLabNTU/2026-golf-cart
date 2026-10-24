# Phase 8: first autonomous drive, indoors

Take the cart from "NDT tracks in the basement" to "Autoware drives it along a
route there and stops", supervised, at crawl speed. The site is the Ming-Da
basement, whose map is `data/basement-indoor/` (GLIM point cloud, anchored to
the retroreflective board, `Local` projector). Cold start is the board
initializer from [Phase 7](7-reflective-board-cold-start.md).

Started 2026-09-29 from a four-part gap audit (vehicle interface, map and
planning, localization, system layer). Every item below cites what the audit
found; the audit itself is not a separate document.

**The VCU is at the vendor for repair** (noted 2026-09-08 in
`scripts/check/vehicle.sh`, still away 2026-09-29). Nothing on the cart can be
driven, and no velocity, steering or control-mode report exists, until it is
back. Everything marked *desk* is done without it; everything marked *vehicle*
waits.

## Exit criteria

The phase is done when, on the cart in the basement:

1. The stack comes up from **one documented command**, localizes from the board,
   and `/autoware/modes/autonomous` reports available with the cart stopped.
2. A route set through the AD API along a drivable lanelet is followed at
   **no more than 1.0 m/s**, and the cart stops at the goal within 0.5 m.
3. A driver e-stop press stops the cart and **stays** stopped until released,
   regardless of what Autoware publishes.
4. An injected MRM (a localization or sensor leaf forced to ERROR) stops the cart.
5. Every run above is recorded, and the bag replays through
   `logging_simulation` with the same route.

## The engage sequence, as the code allows it

Written down here because nothing else does, and two READMEs contradict each
other on it (`control_test/README.md:136-139` says the control-mode service
engages; the vehicle interface README says it cannot).

Corrected 2026-10-22, on the cart: the mode is the dashboard's alone, entered
and left with the brake pedal held and the AUTO button. Nothing over CAN moves
the VCU either way; Autoware reads the mode the VCU reports.

1. `just launch-drive-mingda` (or `just launch-all ...`). The interface always
   transmits since fc54edb; there is no `tx=on`. Its frames carry the rolling
   counter without which the VCU reports all zeros (`just can vcu-status` shows
   both sides).
2. Localize (board), set a route.
3. **Driver holds the brake and presses the dashboard AUTO button.** The
   interface's control-mode service only acknowledges, both ways
   (golfcart_vehicle_launch 960a2be): AUTONOMOUS succeeds once the VCU reports
   all four subsystems autonomous, MANUAL once it no longer does. Autoware is
   still in STOP here, so `stop_hold_acceleration` (-1.5 m/s2) goes out.
4. `/api/operation_mode/change_to_autonomous`.
5. To finish: `/api/operation_mode/change_to_stop`, then brake + AUTO button on
   the dashboard to leave AUTO.

Any subsystem switched back to manual breaks unanimity and the interface goes
idle: that is the driver override.

## Track E: engage is refused today

Each of these alone keeps `/autoware/modes/autonomous` unavailable.

### E1: cuda_ndt's diagnostic name does not match the graph (desk)

The graph matches a `diag` unit on `"<node>: <name>"`
(`autoware_diagnostic_graph_aggregator`, `config/loader.cpp:168`), which is what
Autoware's `DiagnosticsInterface` publishes. `cuda_ndt_matcher` published the bare
`scan_matching_status`, so `/autoware/localization/scan_matching_status` never
received anything under the default `pose_source:=cuda_ndt`. Side effect:
`scripts/localization/check_ndt_activated.py` filters on `ndt_scan_matcher` in the
name, so it silently ignored cuda_ndt too.

**Done when:** every status cuda_ndt publishes is `"<node name>: <category>"`
with the node name as `hardware_id`, pinned by a unit test.

### E2: `map_path` cannot be set from the command line (desk)

`golfcart.launch.yaml` passes `map_path: ./data/COSS-map-planning` as a fixed
include value and never declares it, while its own header documents
`just launch "... map_path:=./data/basement-indoor"`.

**Done when:** `map_path` is a declared argument defaulting to the COSS map, and
the documented override reaches the map loaders (checked in play_launch's dump).

### E3: the diagnostic graph this cart actually needs (desk, decision)

Non-ArUco runs load upstream `autoware-main.yaml` unchanged. Two of its leaves
cannot pass here:

- `/autoware/perception` needs `/perception/obstacle_segmentation/pointcloud`,
  which nothing publishes with the default `launch_perception:=false`.
- `/autoware/localization/accuracy` is the localization error monitor's 1.5 m
  ellipse, which `docs/guides/mrm_configuration.md` says caused false MRM stops on
  COSS. The guide also says it is disabled; the repo copy that disables it
  (`config/system/diagnostics/localization.yaml`) is loaded by nothing.

The perception leaf is not a config problem to be hidden: without it there is no
obstacle source at all (see M4). The decision is which of these the first run
uses, and it belongs in a golfcart graph file that says so, not in an unloaded
copy.

**Done when:** a golfcart graph is loaded for NDT runs, each leaf it drops or
relaxes has a comment giving the reason, and `just diag list` on a replay shows
`/autoware/modes/autonomous` available once localized.

### E4: one command for an autonomous-capable stack (desk)

Today it is `just launch-all` plus an unwritten set: `pose_initializer:=board`,
`use_gnss:=false`, a map (E2), perception or not (E3, M4), a speed cap (S4).

**Done when:** one recipe or preset brings it up for the basement, and CLAUDE.md
names it.

### E5: operator procedure (desk)

The engage sequence above, the pre-drive checks, where the physical e-stop is and
how it is tested, and what the driver does when the cart does something
unexpected. `docs/guides/control_testing.md` is referenced by the MRM guide and
does not exist.

**Done when:** the procedure exists and both READMEs agree with it.

## Track S: safety

### S1: a driver e-stop can be cleared by Autoware (desk)

The interface's `emergency_stop` (Bool, driver button) and `emergency_cmd`
(Autoware MRM) wrote the same flag. `vehicle_cmd_gate` publishes `emergency_cmd`
with `emergency=false` on every control cycle
(`vehicle_cmd_gate.cpp:622-627`, universe 0.48.0), so a driver press lasted at most
one cycle.

**Done when:** the two sources are independent flags, the effective e-stop is
their OR, and a unit test shows a driver press surviving `emergency=false`.

### S2: small negative accelerations cut the motor (desk)

Any negative commanded acceleration becomes `Target_Deceleration > 0`, which the
interface treats as "cut motor torque". Autoware's longitudinal PID dithers around
zero at cruise, so the motor would toggle.

**Done when:** a deadband parameter keeps the motor on for small negative
commands, with unit tests either side of it.

### S3: the VCU does not brake below 1.2 m/s2 (vehicle)

ROOTS brakes in stages at 1.2, 1.8 and 2.8 m/s2 and does nothing below. Ordinary
planner stops (-0.3 to -0.8), the comfortable-stop MRM (-1.0) and stop-hold (-1.5,
stage 1 only) either coast or brake weakly. Remapping small decelerations up to a
stage is plausible but changes how every stop feels, so it is decided on the cart.

**Done when:** a stop from 1.0 m/s is measured with and without a remap, and the
chosen mapping is a documented parameter.

### S4: a first-run speed cap (desk)

Planning runs stock `max_vel` 4.17 m/s; the only cart-side caps are the
interface's 5.0 m/s and an optional 2 m/s in the route TUI.

**Done when:** the basement bring-up (E4) caps planning at 1.0 m/s and the
interface at 1.5 m/s, and both are visible in the launch.

### S5: MRM reaches the VCU (desk in simulation, then vehicle)

Wired by topic name (`emergency_cmd` into the interface's safety brake at
3.0 m/s2 plus `Veh_Estop`) and never exercised end to end.

**Done when:** in the planning simulator an injected fault drives `mrm_state` to
MRM_OPERATING and the command reaching the interface is an emergency stop; then
the same on the cart (exit criterion 4).

**Desk half done 2026-10-24: `just sim-mrm-check`** (`scripts/testing/sim_mrm_check.py`),
against `just sim-drive-basement ./data/mingda-basement`. It runs the real
vehicle interface on vcan0 with `mock_vcu --auto`, inputs wired as on the cart
and reports kept private (the simulator owns `/vehicle/status/*`), drives the
straight lane, and at 0.8 m/s sets `ndt_scan_matcher: scan_matching_status` to
Error through the simulator's `dummy_diag_publisher`. Timeline, from the
injection, consistent over seven runs:

| +s | |
|---|---|
| 0.13-0.18 | `mrm_state` MRM_OPERATING, behaviour EMERGENCY_STOP |
| 0.15-0.20 | `/control/command/emergency_cmd` true; interface logs "MRM emergency_cmd ENGAGED" |
| 0.15-0.21 | CAN 0x68 `Target_Deceleration` 3.0 m/s2 and 0x43F `Veh_Estop` 1 |
| 1.82-1.86 | `control_cmd` acceleration reaches -2.0 |
| 1.90-1.95 | simulated cart stopped; MRM_SUCCEEDED |

Setting the leaf back to OK clears `emergency_cmd` and `Veh_Estop` within
0.24 s. The perception pointcloud leaf gives the same timeline. Control run:
with the interface's `emergency_cmd` input unwired, every ROS link passes and
the check fails at the CAN link, so it does see a broken chain.

What it showed:

- **A faulted leaf gives EMERGENCY_STOP, not the comfortable stop**, although
  `mrm_handler` has `use_comfortable_stop: true`. Upstream's
  `/autoware/modes/comfortable_stop` needs the same subtrees as autonomous, so
  a leaf fault takes both down; only an external `/adapi/mrm_request` would
  pick the comfortable stop. That matters here: `vehicle_cmd_gate` raises
  `emergency_cmd` only for EMERGENCY_STOP, and a comfortable stop would reach
  the cart only as a -1.0 m/s2 planner deceleration, which the VCU does not
  brake for (S3). The check fails on any other behaviour.
- **On the cart the interface's brake leads, not Autoware's.** The emergency
  operator ramps with jerk -1.5 m/s3 and is at -2.0 only after 1.8 s; the
  interface sends its fixed 3.0 m/s2 (VCU stage 2.8) and `Veh_Estop` within
  about 0.05 s of `emergency_cmd`. The simulated stop (1.9 s from 0.8 m/s)
  follows Autoware's ramp, so it overstates the cart's stopping time.
- **The cart drives on by itself once the fault clears.** With
  `use_emergency_holding: false` (upstream default) the MRM returns to NORMAL,
  the operation mode is still AUTONOMOUS with the route set, and the simulated
  cart resumed towards the goal. Whether a transient fault should instead hold
  the cart until the driver re-engages is a decision for the first runs, not
  changed here.

Not covered: the master/orin link (`emergency_cmd` crosses it on the cart; a
dropped link brakes through `control_timeout_ms` instead), the VCU itself, and
the golfcart launch's own graph (the simulator loads upstream
`autoware-main.yaml`; with `launch_perception:=false` the perception subtree
is removed from autonomous and comfortable stop alike, so the conclusion
holds).

### S6: the MRM guide describes a config that does not run (desk)

`docs/guides/mrm_configuration.md` points at deleted repo configs and says the
accuracy check and comfortable stop are disabled. Neither is.

**Done when:** the guide describes what E3 loads.

## Track M: map and planning

### M1: a drivable lanelet in the basement (desk)

`data/basement-indoor/lanelet2_map.osm` is byte-identical to `board_polygon.osm`:
the board and nothing else. No route can exist.

It must be authored in the same board-anchored `Local` frame with
`local_x`/`local_y`/`ele` tags; a georeferenced block would put it somewhere else
with no warning. The map's z origin may be biased up to about 0.2 m and there is a
ramp (Phase 7 notes), so `ele` needs care. Add `format_version` while there.

**Done when:** a lanelet covering the aisle the cart will drive loads without
warnings and a route can be set along it in RViz.

**Tools, 2026-09-29.** `scripts/map/pcd_floor_plan.py` draws the map top-down
(obstacles 0.3 to 2.0 m above a per-cell floor, so the ramp stays floor) with a
metre grid and the board at the origin. `scripts/map/centerline_to_lanelet.py`
turns a list of map-frame points into connected road lanelets beside the board
polygon, and warns when a corner is tighter than the cart's 5.7 m minimum
radius. Both have tests; the lanelet tests load the output the way Autoware does
and route over it.

**Route, 2026-10-05: the clockwise aisle ring.** `data/basement-indoor/route_loop_cw.yaml`
is the NDT-tracked path of the 2026-09-24 clockwise lap (L1), decimated to
0.5 m, smoothed and closed; `lanelet2_map.osm` is generated from it beside the
board polygon: 15 one-way lanelets of about 5 m, 2.4 m wide, 4 km/h, the last
leading into the first, no load errors. It follows a line a person drove, so
the geometry is drivable by construction; it is not a surveyed lane.

**Found on the way: Autoware loads Local-frame lanelets backwards unless the
bounds are stored reversed.** `LocalProjector` puts every point at (0, 0) during
the load and restores `local_x`/`local_y` only afterwards; lanelet2's
`geometry::align()` then sees zero signed distance and inverts both bounds of
every lanelet. A lanelet written in the direction of travel therefore loads
pointing the other way with its bounds on the wrong sides. The tool writes both
bounds reversed, which comes out right under that loader and under a normal one.
Evidence: read from `lanelet2_map_loader_node.cpp` and lanelet2's `align()`, and
reproduced with lanelet2's Python loader under the same degenerate projection;
not yet seen in a running Autoware, which M2's planning simulator will show.
If it holds, any Local map authored in travel order, Vector Map Builder's
included, meets the same trap.

### M2: a planning-simulator scenario on the basement map (desk)

No indoor planning scenario exists; `launch-sim-planning`'s map has no PCD and
the ArUco planning sim was never run.

**Done when:** `just` has a recipe that brings up the planning simulator on the
basement map, sets a route, engages, and reaches the goal. This is where E1-E3,
S4, S5 and M1 are proven together before the cart.

**2026-09-29: the mechanism works.** `just sim-drive-basement MAP=<dir>` plus
`scripts/testing/sim_route_check.py`. Against a scratch copy of the basement map
with a straight test lane along x = 7.5 m (built by `centerline_to_lanelet.py`,
not a chosen route), the golf-cart model drove from (7.5, -11) to (7.5, 6):
first metre forward, peak 1.18 m/s against the lanelets' 4 km/h limit, arrived
0.09 m from the goal. The reverse request was refused, as a one-way lane should
be. Two findings on the way:

- **`allow_goal_modification` must be off in the basement.** With it on, the
  goal planner searches for a pull-over spot, finds no road shoulder, and holds a
  stop at distance 0 forever: route set, engaged, speed 0. The route TUI sets it
  on; the checker defaults it off.
- **The goal's footprint must fit in the lanelet.** A goal 2 m before the lane's
  end was refused ("Goal's footprint exceeds lane").

**2026-10-05, on the real basement map and route:** from the board spot,
three corners round the ring to the east side, the golf-cart model arrived
0.07 m from the goal at up to 1.18 m/s. But it got round the corners by
saturating: steering sat at the 0.349 rad limit for 31% of moving time, and the
cart ran up to 0.81 m off the centreline (p95 0.61 m), outward at the corners.
See V3: the corners were driven at 3.3 to 4.1 m radius, and Autoware's model of
the cart cannot turn tighter than 5.66 m.

Still open for M2 proper: the golfcart launch's own pieces, which the stock
planning simulator does not load (E1, E3, S4, S5).

### M3: planning parameters for a slow cart indoors (desk)

Everything is stock `autoware_launch`: `stop_margin` 5.0 m (large in a garage
aisle), lane change, avoidance, crosswalk, intersection and traffic-light modules
all on.

**Done when:** a golfcart planning preset exists with the reasons for each change,
exercised in M2.

**Done on the desk 2026-10-24: `planning_preset:=slow_indoor`**
(golfcart_launch `config/planning/preset/`, read by our copy of
`tier4_planning_component.launch.xml`, pinned by `test_planning_preset.py`;
each change carries its reason in the files). Upstream's component can choose
modules by preset but hardcodes every parameter path, hence the copy.

- Off: static obstacle avoidance (it swerves round parked cars, and the top
  aisle leaves 0.28 m a side), lane change both ways, avoidance by lane change,
  and the crosswalk, walkway, traffic light, virtual traffic light,
  intersection, blind spot, detection area and no-stopping-area modules (the
  maps have none of their elements; traffic light would stop for an UNKNOWN
  light with recognition off). `stop_line` stays.
- obstacle_stop and road_user_stop margins 5.0/3.0/3.0 -> 2.0/1.5/1.5 m;
  `max_vel` 4.17 -> 1.5 m/s, the interface's ceiling (S4).

The drive recipes and `just sim-drive-basement` use it; the planning simulator
goes through `planning_sim.launch.xml` (upstream's, with our planning
component). Planning sim on the Ming-Da map, stock vs slow_indoor: the straight
lane and two loop laps arrive alike (0.07-0.10 m, 1.19 m/s, 214 vs 215 s). In
the lane, a box stops the cart 4.25 -> 1.86 m short, a pedestrian 5.06 ->
2.08 m; a car 0.4 m into the lane went from "never starts" to "stops 1.85 m
short, no swerve"; a car 0.1 m outside the lane causes no stop under either.
`just sim-mrm-check` passes under it. The 2.0 m margin assumes the cart's
coasting through decelerations below 1.2 m/s2 (S3); re-check on the cart. Not
in the preset, deliberately: obstacle_stop's raw-pointcloud check
(`obstacle_filtering.check_inside.pointcloud: false`), which would stop for the
boxes CenterPoint misses (M4) at the risk of phantom stops.

### M4: an obstacle source (desk, then vehicle)

With perception off there is none: objects are an empty publisher and the
pointcloud obstacle stop is disabled upstream. Either `lidar_only` perception
(CenterPoint, never run on this cart) or a pointcloud-based stop.

**Done when:** a box placed in the aisle of a replay stops the planned trajectory.

**Decided 2026-10-23: CenterPoint tiny only.** `lidar_only` now sets
`lidar_detection_model:=centerpoint/centerpoint_tiny` and turns off clustering
and the analytics publisher (our perception launch copy; see the preset
README). In lidar mode the tracker never read clustering anyway. So objects are
CenterPoint's road classes and a box is not one: the done-when above becomes a
person (or a car) in the aisle, and boxes stay with the driver.

**Desk half done 2026-10-24 (workstation).** The CenterPoint tiny engine builds
in 51 s on the RTX 5090 (`build_only:=true model_name:=centerpoint_tiny`) and
loads. Both 2026-09-24 loops replayed on the Ming-Da map with
`launch_perception:=true` and the lidar_only values:
`/perception/object_recognition/objects` at 9.4-9.7 Hz. CenterPoint saw only
CARs parked in the bays beside the ring, in 10-15 % of frames; **closest
detection 7.4 m (median 15 m), and cars 3-4 m off the lane were never
detected**. The obstacle-pointcloud validator drops about half, because a car
that is in the survey map has lost its points to compare-map. **Neither bag has
a person**: no PEDESTRIAN class, and no person-sized cluster in the
map-filtered cloud moved 1.5 m. Pipeline latency, scan stamp to tracked
objects, 218 ms mean (p95 245, including the 50 ms concatenator wait for the
absent Falcon).

Stop half, planning simulator: a dummy pedestrian placed 9 m ahead of the cart
at 1 m/s stops it through obstacle_stop, at rest 7.5 m from the object centre
with stock margins (`stop_margin` 5.0); deleting it lets the route finish. With
the pedestrian there before engage, the cart does not start.

Workstation load, reference only: perception about 25-30 % of one core,
+4 GB RSS (mostly the TensorRT/CUDA runtime in pointcloud_container), +1.2 GB
GPU memory; that memory matters on the Orin's shared RAM.

Open, on the cart: build the engine on the master; record a person walking the
aisle and standing in the lane at 3, 5, 8 and 12 m; measure pedestrian recall
against range, watching for the under-7 m blind spot seen on cars; the master's
load; rerun the stop check under M3's preset.

### M5: basement poses for the route TUI (desk, after M1)

`scripts/testing/drive/poses.json` holds COSS-era poses.

### M6: drive a closed loop as chained goals (desk)

One route round the Ming-Da loop fails: with the goal just behind the start,
behavior_path_planner's drivable area collapses (left bound cut to 2 points) and
path_optimizer stops the cart "outside drivable area". The planning sim drove
two laps as three goals a lap, sent by a scratch script (`loop_legs.py`: next
goal when the previous one reports ARRIVED). Goals at a lanelet boundary or in
the 1.5 m stretch past the hanging board are refused ("Goal's footprint exceeds
lane!"), so the goal poses are part of the map, not free choices.

**Done when:** the loop's goal poses live beside the map
(`data/mingda-basement/`), a tested script or `just` recipe drives N laps
through the AD API in the planning sim, and the route TUI or the procedure in
`control_testing.md` uses the same goals on the cart.

**Done on the desk 2026-10-24.** Goals in `data/mingda-basement/loop_goals_cw.yaml`
(start plus three goals at s = 1.0 / 22.5 / 57.1 / 77.3 m of the 79.3 m loop:
on the centreline, at least 1 m from a lanelet seam, the whole cart on 2.5 m of
lane). `scripts/testing/sim_loop_drive.py` (`just sim-drive-mingda-loop`, then
`just sim-loop-drive --laps 2`) checks them against the lane offline, then
drives N laps through the AD API, 33 tests. Two laps, stock limits: 6/6 legs
ARRIVED within 0.10 m, 1.19 m/s, footprint at least 0.117 m from every obstacle
cell. **Autoware drops to STOP on every ARRIVED**, so each leg is engaged again.
The route TUI reads the same file (`just tool tui --poses
data/mingda-basement/loop_goals_cw.yaml`, goal modification off) and
`control_testing.md` has the per-leg procedure.

**The pause in the top aisle, found 2026-10-24.** Every lap, stock or
slow_indoor, noise or none, the planned speed dropped to 0 for about 1 s near
(14, 22.8) and the cart halted for up to 0.6 s. It is path_optimizer's
outside-drivable-area check (`insertZeroVelocityOutsideDrivableArea`), which
publishes no planning or velocity factor and logs nothing; its only trace is
the "outside drivable area" virtual wall. The zero is absent from
`path_smoother/path` and first appears in `path_optimizer/trajectory`. The MPT
point nearest ego (0.36 m behind it) had its rear-left corner 3.3 cm past the
left bound beside the hanging board, and `vehicle_stop_margin_outside_drivable_area`
is 0.0, so v = 0 lands at ego; the optimizer clears it in ~0.3 s and the
smoother re-accelerates from 0. The simulated cart itself stays 0.095 m
inside there. Root: 1.5 m of lane for a 1.215 m cart through the S-bend after
the board, where the elastic band (clearance 0.1) sits 0.08-0.20 m off centre.
The same check briefly stops it at (16.2-16.7, 22.2-22.4), the turn onto the
east side.

Fix, slow_indoor only: BPP `dynamic_expansion.ego.extra_width` 0.0 -> 0.1
(`config/planning/slow_indoor/drivable_area_expansion.param.yaml`), which widens
the bound only where the footprint meets it on a curve (+0.05 m beside the
board). Fresh launch, 3 laps: 0 stops at ego (baseline 19 per 2 laps), leg-2
minimum 0.42 m/s (the slow-down into the 2 km/h zone), 9/9 legs within
0.10 m. Footprint to the nearest obstacle cell 0.078 m (baseline 0.067-0.077;
`extra_width` 0.2 also fixes it but gives 0.039 m, hence 0.1). Did not work:
MPT `soft_collision_free_weight` x100; elastic-band clearance 0.05 or 0.02
(deadlocks at (16.1, 22.5): the turn works only because the band cuts the
corner); BPP bound offsets. Caveats: the front-left corner overshoots the map
lane at the east turn (x 16.1) by 0.25-0.30 m (baseline 0.15-0.22; no obstacle
within 0.2 m); the stock preset still pauses; and the board clearance by this
method is ~0.07 m, below the 0.12 m in `route_loop_cw.yaml`'s header. The real
fix is lane geometry (M7 refit, widening the north edge past the board) after
4d's tape walk.

### M7: the loop-lane fit as repo tooling (desk)

The 2026-10-23 refit of `route_loop_cw.yaml` (6a35f04) came from scratch
scripts: an obstacle grid from the PCD (0.1 m cells, >= 3 points, band
0.25-2.13 m), a bounded least-squares corridor fit (lateral offsets along the
normals, curvature penalty reweighted to a >= 3.8 m radius, per-stretch widths
and margins, a body band at the board), and a clearance check of the built
lanelets against the grid. Every number in the YAML header comes from them; 4d
(the cart's real width and height) will need the fit rerun.

**Done when:** the three live under `scripts/map/` with tests beside
`test_centerline_to_lanelet.py`, take the vehicle dimensions from
`vehicle_info.param.yaml` as the lanelet builder now does, and reproduce the
committed lane and its header numbers.

**Done 2026-10-24.** `scripts/map/obstacle_grid.py` (PCD plus
`data/mingda-basement/obstacle_edits.yaml`: band, removals and additions, each
with its reason), `fit_lane_corridor.py` (`centre`, the 2026-10-22 fit;
`refine`, the 2026-10-23 bounded least squares, configured by
`data/mingda-basement/loop_fit.yaml`) and `check_lane_clearance.py` (cells
inside the lane, exact edge-to-cell distance, narrow stretch, speed zones,
radius against the vehicle), 28 tests on synthetic aisles. The body comes from
`vehicle_info.param.yaml` (`vehicle_body()` beside `vehicle_geometry()`), so 4d
is a rerun. From the full SLAM cloud moved by the two anchors, `refine` on the
2026-10-22 lane reproduces `route_loop_cw.yaml` and `lanelet2_map_loop.osm`
byte for byte; the check gives 0 cells inside, nearest 0.124 m to the board's
cell (the header's 0.13 m was centre distance minus half a cell), 1.5 m
narrowest over 11.1 m, radius 3.80 against 3.60 m. **It needs the full cloud**:
the tracked 0.30 m one has about one point per 0.1 m cell, and its grid (582
cells against 12,917) lets a refit put a cell inside the lane. `refine` needs
`python3 -s` on the workstation (user-site numpy 2 breaks apt's scipy). The
planning-simulator numbers in the header still need the simulator.

### M8: planning sim with realistic localization error (desk)

The planning sim localizes perfectly, so its 0.11 m minimum clearance on the
loop assumes a perfect pose. The replays measured NDT scatter (8.8 cm p95
against the full map on the 0.30 m map) but nothing injects it.

**Done when:** the loop is driven in the planning sim with pose noise and lag
drawn from the replay's distribution (and the 22 deg steering cap, V3), and the
minimum clearance and goal error are reported against the noise-free run.

**Done on the desk 2026-10-24 (tooling in scratch, not the repo).** The
simulator's pose is moved aside and `localization_sim_mode:=pose_twist_estimator`
runs the real gyro_odometer and EKF, fed by a 10 Hz NDT stand-in that replays
the 0.30 m replay's body-frame error against the full map (8.8 cm p95, along
1.0 +- 2.8 cm, lateral -2.4 +- 2.2 cm, correlated over 8-9 s) with its 0.10 s
lag. Steering capped at 0.384 rad and 0.13 rad/s in a scratch overlay; committed
limits untouched. Two laps each:

| run | arrival error max | min clearance |
|---|---|---|
| perfect pose, stock limits | 0.099 m | 0.117 m |
| perfect pose, 22 deg cap | 0.106 m | 0.110 m |
| cap, EKF, replay noise, three draws | 0.083 / 0.074 / 0.059 m | 0.088 / 0.097 / 0.110 m |
| stress: twice the noise, 0.3 s lag, 1 s pose dropout every 20 m | 0.153 m | 0.092 m |

Every leg ARRIVED. The EKF pose was 7.7-9.5 cm p95 from the truth (lateral
4.8-6.6 cm). The pinch is always the front-left corner at the hanging board;
the draws cost at most 2.2 cm of it, but a lateral error at p95 lined up with
the pinch would leave about 4 cm. Not modelled: the left steering report of 0,
wheel-speed scale error, the Orin's latency; the "error" is the difference of
two NDT runs, not ground truth.

### M9: steering limits and controller settings for the cart we have (desk, after decision)

Phase 9 decisions 4 and 4a: `max_steer_angle` 0.52 -> 0.38 rad in
`vehicle_info.param.yaml`, the simulator model, the keyboard recipe and the
interface clamp together; and before any left turn, the MPC/PID
steer-convergence holds off, since the left report reads 0.

**Done when:** the team has decided, all four places hold the same limit (a test
reads them), and the loop sim reruns clean on the result.

## Track L: localization under the cart's own motion

No recorded run fuses velocity and IMU with NDT. The Phase 7 replay bag had one
topic.

### L1: analyse the 2026-09-24 indoor loops (desk, done for NDT)

Two hand-driven loops, clockwise (134 s) and counter-clockwise (166 s), on the
NAS under `dataset/2026-09-24 indoor-experiment/raw_rosbags`. **They carry no
wheel speed**: `velocity_status`, steering and gear hold 0 messages because the
VCU was already away. They have both LiDARs, the ZED IMU at about 100 Hz and
TF. So they measure NDT alone, from the board cold start, through a moving
drive; EKF fusion still waits on a VCU day.

Replayed 2026-10-02 with `just indoor-test` on the raw VLP-32 cloud only
(extracted to `rosbags/basement/loop_*`, 2.0 and 2.5 GB), events recorded and
summarised by `scripts/rosbag/indoor_loop_report.py`:

| | clockwise | counter-clockwise |
|---|---|---|
| poses, span, rate | 1305 over 130.5 s, 9.99 Hz | 1617 over 161.8 s, 9.99 Hz |
| path, median speed | 78.3 m, 0.61 m/s | 84.2 m, 0.54 m/s |
| implied jumps over 3 m/s | 0 | 0 |
| NVTL min / p5 / median | 2.28 / 2.34 / 2.45 | 1.87 / 2.31 / 2.43 |
| below the 1.3 gate | 0 | 0 |
| iterations median, at the 30 cap | 2, 0 | 2, 2 |
| execution median / p99 | 1.89 / 4.65 ms | 1.84 / 4.87 ms |
| gaps over 0.3 s | 3, longest 1.05 s | 3, longest 1.00 s |

The two loops cover the same ring of aisles around the central block,
independently: each clockwise pose lies a median 0.43 m (p95 1.05 m, max 1.60 m)
from the counter-clockwise path. That is two drivers' lines, not an error bound,
but it rules out a drifting or jumping track. **The ring is the route
candidate for M1**: `log/indoor-test/loop_cw_path.csv`.

Three findings:

- **Cold start races the map (fixed in the replay, open on the cart).** Board
  detection fires about 1 s after playback; the first run's two align calls
  failed with `No map loaded`, because the map loader's service did not exist
  yet and the map reached the matcher 8.6 s later. The cart left the board after
  two detections, so the loop was never tracked. The replay now waits for the
  latched map and the matcher's target before resuming. **On the cart the same
  race happens if the driver is parked at the board while the stack boots**:
  five detections a second apart all fail and the initializer stops for good.
  The initializer must not spend its attempt budget before the matcher has a
  map (new item L8).
- **A ~1 s localization stall at every dynamic map update (new item L9).** The
  gaps are not in the bags; they line up exactly with cuda_ndt's map updates,
  every 20 m travelled (two back to back, then one about 63 s later). The basement
  map is ONE 4-million-point tile, so each update drops and reloads the whole
  map (`+1 tiles, -1 tiles, took 217.8ms`) and the executor stalls. With wheel
  speed the EKF dead-reckons across it; it is still a defect.
- **Align asked for no tiles.** Before initialization the matcher is
  deactivated and nothing requested map tiles around the align pose. Align now
  requests them when it finds no map, so a retry can succeed; it cannot help
  while the loader service itself is not up.

### L2: EKF parameters (desk)

`ekf_localizer.param.yaml` is tuned for AR tag plus VSLAM: twist gate off
(`twist_gate_dist: 10000`), reduced process noise, `show_debug_info: true`.

**Done when:** it is back to the upstream baseline with each remaining deviation
justified, and L1's replay shows no regression.

### L3: NDT gate against the input cuda_ndt actually gets (desk)

cuda_ndt loads the repo's NVTL gate (1.3, derived at NTU with 2000 points,
`min_z` -1) while `cuda_localization.launch.xml` hardcodes its own preprocessing
(5000 points, `min_z` -30).

**Deliberately not switched yet (2026-09-29).** The mechanism is a copy of what
`autoware_localization.launch.xml` already takes: three preprocessing path
arguments. But the one run that worked indoors, the 2026-09-12 basement replay,
used exactly the submodule's own 5000 points and `min_z` -30. Pointing cuda_ndt
at the repo's 2000 / -1 would make the gate consistent with its derivation and
the input inconsistent with the only evidence. Both numbers move together, from
L1's data.

**Done when:** the repo's preprocessing reaches cuda_ndt, and the gate is
re-derived from L1's distribution on that input.

### L8: the board initializer must wait for the matcher's map (desk)

See L1. **Done when:** a cart parked at the board through boot initializes on
its own, i.e. failures before the matcher has a map do not consume
`max_attempts`, checked by a replay that resumes before the map is up.

**Done at the desk 2026-10-23** (reflective_pose_detector a83b3f8). The
initializer watches the matcher's `debug/loaded_pointcloud_map` and counts a
failed attempt only if that map had been seen when the call went out
(`ignore_failures_before_map`, default on). The aligns still go out, since
cuda_ndt's align is what requests the tiles.

The replay check as written could not show the race on the workstation. With
`INDOOR_SIM_MAP_WAIT=off` the conductor resumes as soon as
`/localization/initialize` exists, but the map reached the matcher 0.5 s after
start (3,995,308 points; 63,115 on the Ming-Da map) and the service ~30 s
later, so there was no window. On 2026-10-02 the map arrived 8.6 s after
playback. Both replays initialized on attempt 1/5. They also showed that the
new subscription connects to cuda_ndt's real (volatile) publisher. The race
itself is replayed over real ROS transport in the submodule's
`test_initializer_boot_race.py`: poses at 5 Hz, a service that fails until the
map is out at 2 s. With the fix it initializes after 10 free failures; the
control with counting on fails for good at 5/5. On the cart, the stationary
rehearsal (Phase 9 item 16) is the remaining check.

### L9: split the basement map into tiles (desk)

See L1. Autoware's pointcloud divider, or an equivalent, so a map update loads
the tiles near the cart instead of the whole map. **Done when:** a loop replay
shows no pose gap over 0.3 s.

**Not needed (2026-10-24).** The L1 gaps do not reproduce with cuda_ndt as
built now. 1x replays:

| map | loop | NDT poses | longest gap | gaps > 0.3 s | NVTL min / median |
|---|---|---|---|---|---|
| basement-indoor, 4.0 M points | cw | 1296 over 129.6 s | 0.20 s | 0 | 1.84 / 2.45 |
| basement-indoor, 4.0 M points | ccw | 1613 over 161.2 s | 0.12 s | 0 | 2.21 / 2.43 |
| mingda-basement, 63 k points | cw | 1297 over 129.6 s | 0.12 s | 0 | 2.57 / 2.79 |
| mingda-basement, 63 k points | ccw | 1609 over 160.8 s | 0.12 s | 0 | 2.62 / 2.77 |

`/localization/kinematic_state` has no gap over 0.04 s. The map update still
swaps the one tile every 20 m, now in 14-16 ms on 4 M points and 0.2 ms on
Ming-Da (217.8 ms on 2026-10-02), and cuda_ndt skips the rebuild ("target
already built", a392db8). Revisit only if a map grows past one tile or
`map_radius` (150 m).

### L10: board detection range, from the bags (desk)

The board was detected at 12 m in the 2026-09-10 replay. The Ming-Da straight
lane starts 17.8 m from it, and the loop passes it at several ranges. The
2026-09-24 loop bags see the board from every distance the cart drives.

**Done when:** the detector is replayed over both loop bags and the detection
rate is reported against range and bearing, so the start pose can be chosen
inside the range that works (on the cart, Phase 9 item 15 confirms it).

**Done at the desk 2026-10-24.** `scripts/localization/board_range_report.py`
runs the production detector (basement scenario, `accumulate_scans` 10) over
every 10-scan batch of both loop bags and scores each against the board's
position from a 1x Ming-Da NDT replay (board centre error 0.1-0.25 m). `raw`
stacking, what the node does, fails almost everywhere while moving (smeared
stack: `bad_width`, `not_planar`); `deskew` moves the scans through the NDT
poses first and stands in for a parked cart, which is what decides a start
pose. Both bags, deskewed, board within 60 deg of heading and aspect within
35 deg:

| range | batches | detected |
|---|---|---|
| 3-6 m | 5 | 100 % |
| 6-12 m | 20 | 100 % |
| 12-15 m | 21 | 100 % |
| 15-18 m | 25 | 100 % |
| 18-20 m | 23 | 0 %, all `out_of_range` (the 18 m gate) |

Oblique views fail: above 35 deg aspect, 46 % at 9-12 m, 7 % at 12-15 m, 0 from
15 m (too few retro points for `cluster_min_points`). Within 6 m and over 60 deg
of bearing, 32 % (`not_vertical`).

**The lane start (17.6, -4.9) is 17.84 m from the board, 0.16 m inside the
range gate.** Recommended start: **(16.0, -4.9, 180 deg)**, 16.3 m, bearing
-17 deg, aspect -17.5 deg. Do not raise `range_max`: at 30 m a second false
target appears (19.3 m, at Ming-Da (22.5, 37.8)).

**A false board.** A reflector at Ming-Da (15.23, 21.65, z 1.6), at the end of
the box wall on the top aisle, passes every gate at 3-5 m range (3 of 5
deskewed batches, confidence 0.62-0.86), and the live stack published it in
every clockwise replay, 19.5 m from the truth. The one-shot initializer had
finished, so nothing used it; any re-initialization must gate on it (L6).
On basement-indoor (about 3.5 deg of yaw off the board) board and NDT disagree
by 0.6-1.2 m at 12 m; on Ming-Da by 0.08-0.22 m.

### L6 design (desk)

L6 below needs a design before the cart: what declares NDT diverged (NVTL,
iteration cap, EKF innovation), what the stack does then (MRM stop), and whether
the board initializer may run again, and from how far.

**Done when:** the design is written here and the stop half is shown in a
replay with an injected divergence.

**Design and replay, 2026-10-24.** Clockwise bag on the Ming-Da map, EKF fed a
perfect-odometry twist from an earlier NDT track (the bags have no wheel
speed, so the recovery times below are optimistic), reset through
`/initialpose3d` at t = 40 s on the west straight at 0.75 m/s:

| injection | NDT | what flagged it |
|---|---|---|
| 1 m lateral | back in one scan; EKF within 0.3 m after 0.74 s | nothing needed |
| 15 deg yaw | back in 0.5 s | nothing needed |
| 3 m lateral | NVTL 2.7-2.85, every scan at the 30-iteration cap, nothing published; recovered alone after 55 s | EKF "pose is not updated": WARN +1.4 s, ERROR +2.6 s, `/autoware/localization` ERROR. `scan_matching_status` stayed **OK** |
| 5 m along the aisle | settled 2.5-4 m off for the remaining 90 s, NVTL 2.0-2.76 (median 2.31), above the 1.3 gate; EKF accepted it | **nothing** but one ERROR blip of ~1.3 s. Only the board, passed 85 s later, disagreed, by 4.2 m |

Why it is missed today: cuda_ndt's `scan_matching_status` goes ERROR only on a
failed sensor transform, never on skips, NVTL or the iteration cap; the 1.3
NVTL gate came from NTU on another input (L3), while healthy Ming-Da NVTL never
drops below 2.57; and the error monitor and EKF see only covariance growth,
not a confident wrong fit.

**Diverged** is any of, held ERROR until a re-initialization:

1. Iteration cap or skips: `skipping_publish_num` >= 5 consecutive scans
   (~0.5 s). Catches the 3 m case.
2. NVTL window: median of the last 10 scans below a per-map, per-input gate;
   2.5 for Ming-Da with today's input. On the recordings it flags the 5 m case
   at +1.1 s (94 % of its 1 s windows) and never fires on two healthy loops.
   Re-derive after L3 and from a cart run with people in view.
3. EKF Mahalanobis rejections or "pose is not updated": already ERROR after
   2 s through `sensor_fusion_status`.
4. Board consistency: a board pose inside the start zone (below) that
   disagrees with the EKF by more than 1.0 m.

**Response:** the leaf drives `/autoware/localization` ERROR, then
EMERGENCY_STOP, which S5 measured at 0.13-0.18 s to MRM and 0.15-0.21 s to
`Veh_Estop`. Either cuda_ndt's `scan_matching_status` goes ERROR on 1 and 2
(keeping the leaf name E1 fixed) or a small monitor adds a leaf. Because
`use_emergency_holding` is false and the cart drives on once a leaf clears
(S5), a localization leaf must latch until a successful re-initialization.

**Re-initialization from the board:** only stopped and on the operator's
request, never automatic; only from the zone L10 measured (board ahead within
60 deg of heading, aspect within 35 deg, 4-17 m), gating each detection on its
own range, bearing and aspect, which rejects the false board (seen at 58-62
deg aspect). Elsewhere recovery is the driver's: `just pose init`, or drive
back into the zone.

**Shown:** the stop half for the iteration-cap case, in replay
(`/autoware/localization` ERROR at +2.6 s; S5 covers the rest of the chain).
**Written 2026-10-24** (cuda_ndt_matcher 97637fe, reflective_pose_detector
fbf85c6):

- Detectors 1 and 2 and the latch are in cuda_ndt's `scan_matching_status`, so
  the leaf name is unchanged. Detector 1 is `validation.skipping_publish_num`
  (5, always on). Detector 2 is `divergence.nvtl_median_gate` over
  `divergence.nvtl_window_size` (10); the parent's launch argument
  `ndt_divergence_nvtl_median_gate` defaults to 0.0 (off), and
  `just launch-drive-mingda` passes 2.5. Only a successful `ndt_align` clears
  the latch; a bare `/initialpose3d` does not. New diagnostic keys:
  `divergence_latched`, `nvtl_window_median`, `nvtl_window_median_gate`.
- The seed zone is in the board **detector**, not the initializer, which has
  neither the board's normal nor the sensor TF: `detector.seed_zone` in
  `scenarios/basement/detector.yaml`, 4-17 m, bearing 60 deg, aspect 35 deg,
  as `board_range_report.py` defines them. Outside it nothing is published and
  the WARN names the bound. Offline over the three local bags every real-board
  detection from a parked cart passes; the false board was rejected at +84 deg
  aspect by the detector's own fit (58-62 above is survey geometry); three
  counter-clockwise detections at 10-12 m and ~+69 deg, the real board seen
  obliquely, are rejected by design.

**Not done:** a replay with an injected divergence against the new code (the
roadmap's injection setup is not scripted); detector 2 is off in the logging
sims unless the argument is passed; with `batch.enabled` cuda_ndt publishes no
`scan_matching_status` at all; the latch clears on `ndt_align` success even if
the initializer's later EKF step fails. Board consistency (item 4) is not
written.

**Check on the cart (item 16):** in every sim-time replay the
`/adapi/node/localization: state` leaf goes STALE for 0.1 s every 1-3 s (it is
published at 1 Hz against a 1.0 s timeout), and each blip turns
`/autoware/localization` ERROR. Possibly a bag-clock artifact; on a wall-clock
stack it would be a spurious MRM.

### L4-L7 (vehicle)

- **L4** ZED IMU corrector: offsets 0, noise copied from the Xsens. A few minutes
  parked.
- **L5** Wheel speed scale: default 1.0, and the reverse sign of VCU speed is
  unchecked.
- **L6** Recovery if NDT diverges while driving: the board initializer is one-shot
  and nothing else re-initializes. Design at the desk, prove on the cart.
- **L7** Phase 7's A3 motion guard: `twist_topic` stays empty until a bag with
  velocity verifies it.

## Track V: vehicle days (VCU back)

- **V1** Does the VCU accept command frames with checksum 0? Everything else
  depends on this. **Yes, 2026-10-22** ([Phase 9](9-mingda-autonomous-driving.md)).
- **V2** Steering sign: fixed in code (891e84a) after the vendor simulator.
  **Verified on the cart 2026-10-22**: keyboard left (+5 deg) went out as
  -4.98 deg and turned the wheels left.
- **V3** Measure maximum steer (0.349 rad is inherited from the PWM cart; ROOTS
  allows 30 deg) and the side overhangs (0.001 placeholders). **Evidence from
  2026-10-05:** the hand-driven clockwise lap turned its four corners at 3.3,
  3.4, 3.7 and 4.0 m radius (base_link path, decimated to 0.5 m). With the
  2.061 m wheelbase that needs about 30 deg of tire angle, the ROOTS limit,
  not 20 deg. At 0.349 rad Autoware's minimum radius is 5.66 m, and in the
  planning simulator the cart saturated and swung 0.8 m wide at those corners.
  Two places hold the limit and must move together:
  `vehicle_info.param.yaml` (`max_steer_angle`) and the vehicle interface's
  steering clamp (`max_tire_angle_rad`). **Both raised to 0.52 rad on
  2026-10-05**, just inside the VCU's 0.5236. Same route in the simulator: off
  the centreline p50 0.09 m, p95 0.27 m, max 0.30 m (was 0.15 / 0.61 / 0.81),
  steering at the old 0.349 for 18% of moving time and at the new limit for 2%.
  Still to confirm on the cart: that the wheels reach 30 deg and the sign is
  right (V2).
- **V4** Steering and longitudinal system identification: the interface's steering
  slew (0.4 / 0.8 rad/s) is slower than MPC's Lexus assumptions (delay 0.24 s,
  time constant 0.27 s). Then MPC and PID tuning. **Desk half:** a script that
  takes a CAN recording of steering and speed steps and fits delay, time
  constant and rate limit, so a vehicle day only has to record.

  **Desk half done 2026-10-24** (`scripts/testing/sysid/`, `just vehicle
  sysid-record|sysid-steps|sysid-fit`). `sysid_steps.py` publishes steering
  (standstill, and crawl doublets at 0.5 m/s), speed and brake step profiles,
  only in AUTO and refusing beside any other `control_cmd` publisher, so it runs
  on the orin without the stack; every profile fits in the 17.8 m lane, right
  steps capped at 20 deg. `sysid_record.sh` records a small bag plus candump.
  `sysid_fit.py` fits delay, time constant and rate limit in both the
  simulator's (lag rate-clipped) and MPC's (rate limit, then lag) form, since
  the wrong form trades delay for ramp, and prints `input_delay`,
  `vehicle_model_steer_tau`, `steer_rate_lim_dps_*`, `delay_compensation_time`
  and the `simulator_model.param.yaml` values; brakes are reported model-free
  per VCU stage (V5). Checked against simple_planning_simulator with known
  values (steering 0.30 s / 0.40 s / 0.13 rad/s fitted 0.288 / 0.384 / 0.130;
  velocity 0.25 s / 0.5 s / 0.6 m/s2 fitted 0.241 / 0.499 / 0.600) and against
  the real interface on vcan0 with mock_vcu (its 0.4 rad/s slew and the mock's
  0.2 s lag recovered). 23 tests. **Left steering cannot come from the report**
  (it reads 0, on CAN too); only from yaw rate at crawl, `steer_yaw`, checked
  in the simulator. No cart data exists yet, so no cart numbers. Found: the
  interface sends `Ads_Vcu_Target_Tire_Ang_Speed` as 0, so the cart's 7-8 deg/s
  may be the VCU's default for 0 (vendor question, or one vehicle-day test).
  Applying the numbers needs a golfcart control override (M9's 4a patch has the
  copies).
- **V5** S3's braking measurement.
- **V6** The crawl run: exit criteria 1-5.

## Smaller fixes found on the way

- **Heading rate** in `VelocityReport` was hardcoded 0; derive it from speed and
  steering (desk).
- **`control_test`'s trajectory player** sent no gear command, and the interface
  defaults to parking, so `just vehicle control-straight` could not move the cart
  (desk).
- **CLAUDE.md** still lists "Steering reversed" as a known issue (desk).

## Order

Desk now: E1, S1, S2, E2, then M1 and M2 as the proving ground for E3, S4, S5,
M3; L1 to L3 in parallel. Vehicle, in order: V1, V2, V3, then L4, L5, L7, S3, V4,
and V6 last.

From 2026-10-23 the desk queue is ordered in
[Phase 9, open issues](9-mingda-autonomous-driving.md#open-issues): L8, S5, M6,
M9, M3, M8, L10, L6 design, M7, V4 desk half, M4, L9 (L8 done 2026-10-23,
S5 desk half 2026-10-24).

## Status

**Current progress is tracked in [Phase 9](9-mingda-autonomous-driving.md)**
(from 2026-10-22: the VCU is back, the map is now `data/mingda-basement/`, and
AUTO is entered on the dashboard). The table below is the 2026-09-29 desk state.

2026-09-29, desk only (VCU still at the vendor). Committed and pushed the same day.

| Item | State |
|---|---|
| E1 cuda_ndt diagnostic name | **done**: `"<node>: <category>"`, node name as hardware_id; 2 new tests, crate suite 72/72 |
| E2 `map_path` | **done**: declared argument; dump shows every loader on the basement map with the override, COSS without |
| E3 diagnostic graph | **done for perception**: `launch_perception` alone selects the graph. False gives the base graph (upstream or ArUco) with `/autoware/perception` removed by the aggregator's `edits`; true gives the base graph unchanged. All four combinations checked by dump; both overlays load in the aggregator's `tree`. Accuracy leaf kept, pending L1 |
| E4 one command | **done**: `just launch-drive-basement "tx=on"` (`tx=` removed since, fc54edb: now plain `just launch-drive-basement`) |
| E5 procedure | **written**: `docs/guides/control_testing.md`; unexercised |
| S1 e-stop | **done**: independent driver and MRM flags, OR'd; 4 tests; bench-checked on vcan0 (a driver e-stop held 4 s against `emergency=false` at 20 Hz) |
| S2 deadband | **done**: `decel_deadband_mps2` 0.2, accepted in [0, 1.2); 5 tests. Small decels are not raised to 1.2 (S3) |
| heading rate | **done**: v tan(delta) / wheel base from the same corrected angle as `SteeringReport`, 0 when stale; 6 tests; bench 0.1475 rad/s at 1.5 m/s, 0.2 rad. Reverse relies on the VCU reporting negative speed, unchecked |
| trajectory player | **done**: sends DRIVE and the profile's acceleration. `straight_10m.yaml` now ends in a full 4 m/s2 brake instead of a coast |
| S4 speed cap | **planning default done**: `planning_speed_limit:=` (latched node, 7 tests). Interface ceiling at 1.5 m/s not yet set |
| S6 MRM guide | **done**: correction box at the top |
| M1 lanelet | **done**: the clockwise aisle ring, from the 2026-09-24 lap |
| M2 planning sim | **real route drives** to 0.09 m of its goal, within 0.30 m of the centreline with steer at 0.52 rad (V3); our launch's pieces still unexercised |
| L2 EKF | **done**: upstream values; replay check waits on L1 |
| L3 NDT input | deliberately not switched; see L3 |
| S5 MRM to the interface | **desk half done** (2026-10-24): `just sim-mrm-check`, injected leaf -> EMERGENCY_STOP -> safety brake and Veh_Estop on vcan0 within 0.21 s; cart half is exit criterion 4 in the crawl run (Phase 9 item 18) |
| L8 board init vs map | **done at the desk** (2026-10-23): failures before the matcher's map are free; boot race tested over ROS transport; cart check is Phase 9 item 16 |
| L1 | **done for NDT** (2026-10-02): both loops tracked end to end from the board, 0 jumps, NVTL never below the gate; the bags have no wheel speed, so EKF fusion waits on the VCU. Found L8 and L9 |
| everything else | not started |
