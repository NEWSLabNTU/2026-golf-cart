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

1. `just launch-all "tx=on ..."`. Without TX the VCU sees no heartbeat and
   refuses AUTO.
2. Localize (board), set a route.
3. **Driver presses AUTO on the cart.** The interface's control-mode service only
   acknowledges; it succeeds once the VCU already reports all four subsystems
   autonomous. Autoware is still in STOP here, so `stop_hold_acceleration`
   (-1.5 m/s2) goes out.
4. `/api/operation_mode/change_to_autonomous`.

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
and route over it. **What is left is choosing the route**, which is a human
decision: which aisle, which direction, where it ends.

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

Still open for M2 proper: the real route (M1), and the golfcart launch's own
pieces, which the stock planning simulator does not load (E1, E3, S4, S5).

### M3: planning parameters for a slow cart indoors (desk)

Everything is stock `autoware_launch`: `stop_margin` 5.0 m (large in a garage
aisle), lane change, avoidance, crosswalk, intersection and traffic-light modules
all on.

**Done when:** a golfcart planning preset exists with the reasons for each change,
exercised in M2.

### M4: an obstacle source (desk, then vehicle)

With perception off there is none: objects are an empty publisher and the
pointcloud obstacle stop is disabled upstream. Either `lidar_only` perception
(CenterPoint, never run on this cart) or a pointcloud-based stop.

**Done when:** a box placed in the aisle of a replay stops the planned trajectory.

### M5: basement poses for the route TUI (desk, after M1)

`scripts/testing/drive/poses.json` holds COSS-era poses.

## Track L: localization under the cart's own motion

No recorded run fuses velocity and IMU with NDT. The Phase 7 replay bag had one
topic.

### L1: analyse the 2026-09-24 indoor loops (desk)

Driven by hand on the vehicle, recorded with the master's and orin's topic lists,
so they likely hold velocity and the ZED IMU. Only the base_link yaw fix came out
of them.

**Done when:** a replay reports NVTL distribution, EKF ellipse, pose jumps and
drift at loop closure, and the numbers are written here.

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
  depends on this.
- **V2** Steering sign: fixed in code (891e84a) after the vendor simulator, never
  re-tested on the cart.
- **V3** Measure maximum steer (0.349 rad is inherited from the PWM cart; ROOTS
  allows 30 deg) and the side overhangs (0.001 placeholders).
- **V4** Steering and longitudinal system identification: the interface's steering
  slew (0.4 / 0.8 rad/s) is slower than MPC's Lexus assumptions (delay 0.24 s,
  time constant 0.27 s). Then MPC and PID tuning.
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

## Status

2026-09-29, desk only (VCU still at the vendor). Committed and pushed the same day.

| Item | State |
|---|---|
| E1 cuda_ndt diagnostic name | **done**: `"<node>: <category>"`, node name as hardware_id; 2 new tests, crate suite 72/72 |
| E2 `map_path` | **done**: declared argument; dump shows every loader on the basement map with the override, COSS without |
| E3 diagnostic graph | **done for perception**: `launch_perception` alone selects the graph. False gives the base graph (upstream or ArUco) with `/autoware/perception` removed by the aggregator's `edits`; true gives the base graph unchanged. All four combinations checked by dump; both overlays load in the aggregator's `tree`. Accuracy leaf kept, pending L1 |
| E4 one command | **done**: `just launch-drive-basement "tx=on"` |
| E5 procedure | **written**: `docs/guides/control_testing.md`; unexercised |
| S1 e-stop | **done**: independent driver and MRM flags, OR'd; 4 tests; bench-checked on vcan0 (a driver e-stop held 4 s against `emergency=false` at 20 Hz) |
| S2 deadband | **done**: `decel_deadband_mps2` 0.2, accepted in [0, 1.2); 5 tests. Small decels are not raised to 1.2 (S3) |
| heading rate | **done**: v tan(delta) / wheel base from the same corrected angle as `SteeringReport`, 0 when stale; 6 tests; bench 0.1475 rad/s at 1.5 m/s, 0.2 rad. Reverse relies on the VCU reporting negative speed, unchecked |
| trajectory player | **done**: sends DRIVE and the profile's acceleration. `straight_10m.yaml` now ends in a full 4 m/s2 brake instead of a coast |
| S4 speed cap | **planning default done**: `planning_speed_limit:=` (latched node, 7 tests). Interface ceiling at 1.5 m/s not yet set |
| S6 MRM guide | **done**: correction box at the top |
| M1 lanelet | tools done and tested; **route not chosen** |
| M2 planning sim | **mechanism done**: a test lane drove to 0.09 m of its goal in simulation; the real route waits on M1 |
| L2 EKF | **done**: upstream values; replay check waits on L1 |
| L3 NDT input | deliberately not switched; see L3 |
| L1 | **blocked**: the NAS mount (`~/nas`) returns I/O errors, so the 2026-09-24 bags are unreachable |
| everything else | not started |
