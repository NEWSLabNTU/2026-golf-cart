# Phase 9: autonomous driving in the Ming-Da basement, progress tracker

The one place to see how far the cart is from a supervised autonomous drive in
the Ming-Da basement, and what blocks it. Work items and their reasoning stay in
[Phase 8](8-autonomous-driving.md) (IDs E, S, M, L, V below are its items) and
[Phase 7](7-reflective-board-cold-start.md) (board cold start); this file tracks
state and evidence only. Update the tables when something changes, with the date
and the evidence, never a bare "done".

Started 2026-10-22, the day the VCU was back in the cart and first answered our
frames.

## Goal

Phase 8's exit criteria, on the Ming-Da map: one command brings the stack up,
the cart localizes from the reflective board, Autoware follows a route on a
drivable lanelet at no more than 1.0 m/s and stops within 0.5 m of the goal, a
driver e-stop holds the cart, an injected MRM stops it, and every run is
recorded and replays.

## What changed the plan on 2026-10-22

- **The map is `data/mingda-basement/`, not `data/basement-indoor/`.** The
  Falcon survey was re-anchored to the board (a cleaner detection: 0.66 x 0.60 m,
  residual 0.024, against 0.87 x 0.61 m with the second retro band merged). The
  new frame is **+3.46 deg of yaw** from basement-indoor's, so basement-indoor's
  lanelet ring and `route_loop_cw.yaml` (traced in the old frame) sit up to 1.8 m
  off in the new cloud and are not used. The board itself is at the origin facing
  +x in both, so the `basement` detector scenario serves both.
- **The lanelet is a hand-drawn straight lane** for the first drive:
  `route_straight.yaml`, (17.6, -2.8) to (2.6, -2.8), travelling -x, 2.4 m wide,
  4 km/h, built by `scripts/map/centerline_to_lanelet.py`.
- **There is no CAN TX switch.** The interface always transmits; the cart's power
  switch is the master enable (fc54edb).
- **AUTO is entered and left only on the dashboard: brake pedal held + the AUTO
  button.** Nothing over CAN moves the VCU between modes; Autoware reads the mode
  the VCU reports.

## Status

Legend: ✅ done and evidenced · 🟡 partly done or done on the desk only ·
❌ open, blocking · ⏸ open, not blocking the first straight-lane drive.

### Map and localization (board cold start, NDT)

| Item | State | Evidence / note |
|---|---|---|
| Ming-Da map package | ✅ | Map loader takes it: 3,995,308 points in `map`, lanelet `format_version 1`, no metadata file needed for one PCD (2026-10-22) |
| Lanelet for the first drive | ✅ | 2.4 m straight lane; nothing at 0.3-1.8 m inside it, 2.36 m to the nearest pillar; floor returns at z 0.09-0.16 m only |
| `just launch-drive-mingda` | ✅ | Dump of the master launch: 147 nodes, `pose_initializer` with `gnss_enabled: false`, no `automatic_pose_initializer`, board detector + board initializer, `fallback_to_user_defined_pose: false` |
| Board detector, live | 🟡 | `just tool board-detector` runs on the cart: VLP-32C at 9.95 Hz, calibrated TF, detector at 1 Hz. **Not yet seen detecting the board on the cart**; the cart has not been parked with the board in view |
| Board detection range | ❌ | Detected at 12 m in the 2026-09-10 replay. The lane start (17.6, -2.8) is 17.8 m from the board: untested |
| L8 board init vs map load race | ✅ desk | Failures before the matcher has a map no longer count (a83b3f8); the cart check is item 16 |
| cuda_ndt on the Orin | ⏸ | Align-service deadline issue no longer reproduces on the workstation; not re-measured on the Orin (CLAUDE.md) |
| L6 re-initialization after NDT divergence | ⏸ | Nothing re-initializes; the board initializer is one-shot |
| Loop lanelet (clockwise, `lanelet2_map_loop.osm`) | 🟡 | Refitted 2026-10-23 (6a35f04). The top aisle's "parked car" was an object present only on the survey day (no live VLP-32C hit on the 2026-09-24 drive, open floor on the left camera); the real constraint is a **board hanging from the ceiling** over the north half of the aisle, x 12.35-12.6, lowest edge 2.15 m, which the old 0.25-2.0 m obstacle band missed. Obstacle band now up to 2.13 m (the hand drive passed under nothing lower than 2.14 m), adding a duct at 2.11 m (north-west corner) and an item at 2.04 m (16.15, -6.95). Lane 1.5 m and 2 km/h past the board, centre y 22.70: the 1.215 m cart 0.29 m off the box wall, 0.28 m off the board. No obstacle cell inside the built lanelets, tightest radius 3.8 m. Curb extent on the bottom straight still assumed |
| 0.30 m point cloud map | ✅ | `pointcloud_map.pcd` tracked at 0.30 m voxels, 1.0 MB (8f3bbe4). Replay of the clockwise bag on it: 1319/1319 poses, NVTL >= 2.57, <= 3 iterations, 8.8 cm p95 from the full-map run. The full 64 MB cloud on the cart must be moved aside before `git pull` |
| Manual pose seed | ✅ | `just pose init mingda SPOT` works against a running stack (planning sim test 2026-10-21); no Ming-Da spots captured yet |
| L5 wheel speed scale and reverse sign | ❌ | Needs the cart pushed or driven with the VCU on |

### VCU and vehicle interface

| Item | State | Evidence / note |
|---|---|---|
| VCU on CAN (orin can0) | ✅ | 800 frames / 2 s, 0x100-0x103 at ~100 Hz, every error code "No Error" (2026-10-22) |
| V1 VCU accepts our frames (checksum 0) | ✅ | VCU states went Invalid -> Manual once our frames ran; bus error counters tx 109 -> 0; `/vehicle/status/*` all at 50 Hz, control mode MANUAL, gear NEUTRAL |
| Entering AUTO | ✅ | Dashboard: brake + button. All four subsystems reported Autonomous; `Veh_Auto_En` claimed |
| V2 steering sign | ✅ | Keyboard left (+5 deg) turned wheels and steering wheel CCW (left); interface sends -4.98 deg to the VCU, so `invert_steering` is right |
| V3 steering range | 🟡 | Left: wheels kept turning to the 0.52 rad command (>= 29.8 deg). **Right: mechanical stop at ~22 deg** (VCU report plateaus 22.1-22.7 deg, wheels stop at the 23rd 1-deg step). `max_steer_angle` is still 0.52, which the right side cannot reach. **The clockwise loop is all right turns.** Planning sim 2026-10-23, one lap per case on the refitted loop: with 0.52 rad, steering peaked at -28.7 deg (NE corner) but only transiently; capped at 0.384 rad (22 deg), and again with the wheels slewing at the cart's ~0.13 rad/s, every leg arrived and the footprint stayed >= 0.11 m from every obstacle cell, the same as uncapped (0.12 m). The planner uses the lane width for wider arcs. **But steering sat at 22 deg for 14% of moving time (NW and NE corners): no reserve**, and the simulator's steering feedback is perfect |
| Steering angle feedback | ❌ | VCU `0x102 Vcu_Ads_Tire_Angle` is live **only in AUTO and only for right turns**: left reads 0.000, manual steering reads a frozen +0.210 deg over a full sweep. Autoware's lateral controller has no usable feedback. **Vendor**. Decided 2026-10-22: no change for the straight lane, where the command stays under `converged_steer_rad` (0.1 rad) so the convergence hold clears against a 0 report; see open issue 4a before any left turn |
| VCU state after leaving AUTO | ⏸ | `Driving_State` (and earlier `Brake_State`) read `Invalid`, not `Manual`, after the first AUTO session. The interface treats it as hands off. **Vendor question** |
| Mode request honesty | ✅ | golfcart_vehicle_launch 960a2be: MANUAL now refused while the VCU is still Autonomous (was answered success). Live: MANUAL accepted / AUTONOMOUS refused with the cart in manual; the AUTO-side refusal is unit-tested only |
| Steering slew | ✅ | Command ramps at the interface limit (1 deg per ~0.7 s per key; -29.6 -> 0 deg in 1.29 s); right-side report returns 22.7 -> 0 deg in ~3 s (~7-8 deg/s at the wheels) |
| V4 steering / longitudinal system ID | ❌ | Not started; MPC still carries Lexus delay and time constant |
| S3 braking below 1.2 m/s2 | ❌ | VCU does not brake below 1.2 m/s2; gentle stops may coast |
| S4 interface speed ceiling 1.5 m/s | 🟡 | `max_speed_mps: 1.5`, unit-tested (golfcart_vehicle_launch 9ff59ac). **The orin still runs the old binary**: needs `just checkout && just build` there and an interface restart |
| S5 MRM reaches the VCU | 🟡 desk | `just sim-mrm-check` (2026-10-24): NDT leaf forced to ERROR at 0.8 m/s in the planning sim -> EMERGENCY_STOP at +0.15 s, the real interface on vcan0 sends the 3.0 m/s2 safety brake and Veh_Estop at +0.2 s, stopped and MRM_SUCCEEDED at +1.9 s, released 0.2 s after the leaf clears; 7/7 runs plus a control. Not covered: the master/orin bridge hop and the VCU. Cart half: exit criterion 4 in the crawl run, item 18 |
| Physical e-stop reported | ⏸ | Not tested on the cart today |

### Planning and control integration

| Item | State | Evidence / note |
|---|---|---|
| Route on the Ming-Da lane (planning sim) | 🟡 | `sim_route_check.py --start 17.6 -2.8 180 --goal 5.5 -2.8 180`: engaged, forward along the lane at 1.18 m/s, zero lateral deviation. Stops at x = 6.5, **1.0 m short**. **Cause found 2026-10-22**: behavior_path_planner extends the drivable area 3.29 m past the goal; the lane ends at x = 2.6 and truncates it, and path_optimizer stops the path where it leaves the drivable area. Goals at x >= 5.9 avoid it; extending the lane end is open issue 4b |
| Goal placement | ✅ | `base_link` is the rear axle, nose 2.47 m ahead: the furthest valid goal on this lane is x = 5.1 (`Goal's footprint exceeds lane!` otherwise) |
| Two-host stack bring-up | 🟡 | Both hosts start; master failed once on a stale install (fixed by `just build`). Two launch faults fixed 2026-10-22: the diagnostic aggregator SIGSEGV with `launch_perception:=false` (488d093: remove the perception and-unit by path; upstream's remove edit orphans diag leaves and `DiagUnit::create_struct` crashes on any removed leaf) and the concatenated cloud's frame left as the literal `$(var base_frame)` (sensor kit c5a7d8e). Full sensors + link + map + localization never brought up together on the cart yet |
| Engage path through the link | 🟡 | All command and status lanes present in `config/link/topics.yaml`, control-mode service bridged; never exercised end to end with Autoware |
| Software e-stop | 🟡 | `teleop_gui.py` `estop_only` mode publishes only `/vehicle/emergency_stop` (golfcart_vehicle_launch 59dfd2c). Not yet run beside Autoware on the cart |
| M3 slow-cart planning / control tuning | ❌ | Stock autoware_launch tuning; side overhangs 0.001 placeholders |
| Loop route (planning sim) | 🟡 | One route round the whole loop **fails**: with the goal just behind the start, behavior_path_planner's drivable area collapses (left bound cut to 2 points) and path_optimizer stops the cart ("outside drivable area"). Driven as chained routes instead (3 goals a lap, scratch `loop_legs.py`): two laps, every leg ARRIVED within 0.11 m, 1.18 m/s, steering <= 28.7 deg (2026-10-23). The route TUI / procedure must chain goals for a loop. Goals at a lanelet boundary or in the 1.5 m stretch are refused ("Goal's footprint exceeds lane!") |
| Vehicle footprint dimensions | ❌ | `left_overhang` / `right_overhang` are 0.001 placeholders (footprint 1.215 m, the wheel tread) and `vehicle_height` 2.005 m is unmeasured. The loop's top aisle leaves the modelled cart 0.28 m each side and the board hangs at 2.15 m: mirrors, the roof or the LiDAR mount sticking out would eat that. Measure width at its widest and height to the top of the LiDAR |
| M4 obstacle detection | ⏸ | Perception off by default: no obstacle stop; the driver is the only obstacle detector. **2026-10-23, desk:** `launch_perception:=true` with `lidar_only` now runs CenterPoint tiny alone, nothing else: clustering (whose output the lidar-mode tracker never read), traffic lights and the analytics publisher are off, through our copy of the perception launch (`use_lidar_rule_detector`). Resolved launch 156 nodes (perception off 147, unchanged); no TensorRT engine built on the master yet (`just build-engines`), never run. Only CenterPoint's road classes become objects: a box in the aisle does not |

### Build, tooling, infrastructure

| Item | State | Evidence / note |
|---|---|---|
| Orin build | ✅ | Plain `just build`, 40 packages, offline (crates from the master's registry cache); u-blox driver skipped while mavros_msgs is absent |
| Orin clock | 🟡 | chrony was following the master (offset ~1 us), but after the 13:39 reboot the clock read 1970: the setup step restarted chrony without enabling it. Fixed in 690dd2f; confirm `systemctl is-enabled chrony` on the orin after `./setup.sh --rerun chrony-orin` |
| `local` bare repos | ✅ | Fast-forwarded to GitHub; the orin pulls from them |
| rclrs pinned to 0.7 | 🟡 | vehicle interface (da78dc5), aruco detector (8b158d5) and cuda_ndt_matcher (d2e43e9, after the repo's ACL was fixed) pushed. aruco still resolves rclrs 0.8 for `rclrs_image_transport` on a fresh lock (workstation, 2026-10-22) |
| Sharing large files with the workstation | ❌ | `~/nas` not mounted on the cart; the repo is public, so the Falcon PCD is not on GitHub |

## Open issues

Who has to move, so nothing waits on the wrong person.

**Turing Drive (vendor)**
1. `Vcu_Ads_Tire_Angle` (0x102) live only in AUTO and only for right turns; left
   reads 0, manual reads a frozen value. Blocks closed-loop lateral control.
2. Right steering stops mechanically at ~22 deg against the 30 deg spec; left
   reaches the 29.8 deg command.
3. `Driving_State` reads `Invalid` in manual after an AUTO session.

**Decisions for the team**
4. `max_steer_angle` 0.52 -> 0.38 rad (vehicle model, keyboard recipe, lane tool),
   until the right side is fixed. **New evidence 2026-10-23**: the clockwise loop
   still drives in the planning sim at 0.384 rad (and at the cart's slew rate),
   so the lower limit costs the loop nothing in simulation, but leaves the
   steering saturated in two corners for 14% of the lap.
4c. **Loop direction vs the two steering faults.** Clockwise is all right turns:
   right feedback works in AUTO, but the right stop is ~22 deg (sim above: drives,
   saturated). Counter-clockwise is all left turns: range is fine, but left
   feedback reads 0, so issue 4a's convergence hold applies on every corner.
   Until the vendor fixes either, clockwise at 0.38 rad is the candidate.
   Note the clockwise lap still commands up to +7 deg of left steer briefly (over
   the 0.1 rad `converged_steer_rad`).
4d. Measure the cart's width at its widest (mirrors, roof) and height to the top
   of the LiDAR, then set the overhangs and `vehicle_height` and refit the loop
   if they differ: the top aisle has 0.28 m a side for the modelled cart.
4a. **Decided 2026-10-22, steering feedback vs the controller.** The straight-lane
   drive keeps stock settings. Before any left turn: set `keep_steer_control_until_converged`
   (MPC) and `enable_keep_stopped_until_steer_convergence` (PID) to false, since a
   left command over 0.1 rad never "converges" against the 0 report and the cart
   would never leave a stop; and either `use_steer_prediction: true` with a
   steering lag measured on this cart (V4; the stock 0.27 s is a Lexus value, the
   cart slews at ~7-8 deg/s) or the vendor's fixed report. `use_steer_prediction`
   alone does not clear the hold: it replaces only the MPC's initial steer state
   (universe 0.48.0 `mpc.cpp:347`), while `isSteerConverged` always compares the
   command with the measured angle (`mpc_lateral_controller.cpp:348`).
5. Transfer of `data/mingda-basement/pointcloud_map.pcd` to the workstation: NAS
   mount on the master, a private repo, or the public repo.
4b. Lane end: extend `route_straight.yaml` from x = 2.6 to 1.6 (needs the floor
   confirmed clear there), or keep the lane and use goals at x >= 5.9.
6. ~~Write access for `NEWSLabNTU/cuda_ndt_matcher`.~~ **Done 2026-10-22**: ACL
   fixed, d2e43e9 pushed.
7. golfcart_aruco_detector on a fresh clone: track its Cargo.lock, and/or bump
   `rclrs_image_transport` to a rev that pins rclrs 0.7.
8. cuda_ndt_matcher's tracked Cargo.lock churns on every build (0.0.0 vs real
   binding versions), as gmslcam's did before ec7a3ea.

**Desk work, in order** (arranged 2026-10-23; each ID is a
[Phase 8](8-autonomous-driving.md) item with its "done when")
13. ~~**L8** the board initializer waits for the matcher's map.~~ Done
    2026-10-23, see Done below.
13a. ~~**S5** MRM in the planning sim: injected fault -> MRM_OPERATING -> emergency
    stop at the interface. Exit criterion 4, desk half.~~ Done 2026-10-24, see
    Done below.
13b. **M6** the loop as chained goals: goal poses beside the map, a tested
    recipe for N laps. Nothing drives the loop without it.
13c. **M9** steering limits (decisions 4, 4a) applied in all four places, loop
    sim rerun. Waits on the team's decision; the sim says 0.38 rad costs nothing.
13d. **M3** a slow-cart planning preset (stock `stop_margin` 5.0 m, lane change,
    crosswalk, intersection modules), exercised on both lanes in the sim.
13e. **M8** loop sim with replay-measured pose noise and the 22 deg cap: does
    0.11 m clearance survive a real pose.
13f. **L10** board detection rate against range, from the 2026-09-24 loop bags;
    chooses a start pose inside the working range before item 15.
13g. **L6 design** NDT divergence: detect, stop, re-initialize or not.
13h. ~~**M7** the loop-lane fit as `scripts/map/` tooling, so 4d's measurements
    can be refitted.~~ Done 2026-10-24: reproduces the committed lane byte for
    byte from the full cloud (Phase 8 M7).
13i. **V4 desk half** a fit script for steering and speed step responses, so the
    vehicle day only records.
13j. **M4** an obstacle source. Perception is CenterPoint tiny only (decided
    2026-10-23, wired, unrun): build the engine on the master, replay a bag with
    a person walking the aisle, measure the master's load. Boxes and trolleys
    are not detected by design; the driver covers them. **Desk half done
    2026-10-24** (Phase 8 M4): engine builds and runs; the bags have no person;
    cars seen only beyond 7.4 m; a dummy pedestrian stops the sim cart. Needs a
    recording with a person in the aisle and the master's load, on the cart.
13k. **L9** map tiling: re-check first, the 0.30 m map is one 1 MB tile and its
    reload may no longer stall.
13l. Housekeeping: issues 7 and 8 (aruco and cuda_ndt_matcher Cargo.lock).

Done: 9 teleop e-stop-only mode (59dfd2c); 10 S4 `max_speed_mps: 1.5`
(9ff59ac, orin rebuild pending); 11 interface rate warning (e8ef6e3); 12 why the
sim stopped 1.0 m short (root cause found, remedy 4b); 14 `tx=` and "driver
presses AUTO" removed from the docs (2026-10-22); 13 L8, failed aligns before the
scan matcher has a map no longer spend the board initializer's budget
(reflective_pose_detector a83b3f8, 2026-10-23; item 16 checks it on the cart);
13a S5 desk half, `just sim-mrm-check` follows an injected fault down to the
interface's CAN frames (2026-10-24; findings in Phase 8 S5).

**On the cart**
15. Park with the board in view: board detection, then from the lane start
    (17.8 m).
16. Stationary rehearsal: `just launch-drive-mingda`, board init, NDT lock, route
    on the lane, no engage.
17. L5 speed report (push the cart a metre, forward and reverse), physical e-stop,
    S3 braking, V4 system identification.
18. The crawl run (Phase 8 V6), after 1, 4, 9, 10, 13, 15 and 16.
19. Walk the loop with a tape: the curb on the bottom straight (y -3.2, extent
    x 7.5-16.0 assumed), the hanging board's height, and the ceiling items at
    2.04 m (16.15, -6.95) and 2.11 m (3, 20) against the cart's height (4d).

## Log

- **2026-10-23** 0.30 m Ming-Da point cloud tracked (8f3bbe4), NDT replay proof
  recorded. Planning sim on the loop: one route round the loop fails (drivable
  area collapses), chained goals drive it. Top aisle refitted (6a35f04): the
  "parked car" was a survey-day object, the real pinch is a board hanging at
  2.15 m; obstacle band raised to 2.13 m; lane 1.5 m past the board. Lanelet
  builder now reads the steering limit from the vehicle description. Loop drives
  in sim at 22 deg and at the cart's steering slew, saturated 14% of the lap.

- **2026-10-22 (later)** Interface speed cap, rate warning and e-stop-only GUI;
  diagnostic aggregator crash without perception fixed; concatenator frame fixed;
  1 m short root cause found; chrony enable fix; steering-feedback decision (4a).
- **2026-10-22** VCU back. V1 pass, V2 pass, V3 partial (right stop 22 deg),
  steering feedback found broken (vendor). Mode-request fix (960a2be),
  `just can vcu-status` (receive-only VCU readout),
  `just tool board-detector`, check-script fixes, rclrs pins, orin build and
  clock fixed, Ming-Da lane widened to 2.4 m. This tracker started.
- **2026-10-21** Ming-Da map extracted and verified; lanelet elevation fixed
  (was on the ceiling); straight first-drive lane drawn and verified in the
  planning sim; `just launch-drive-mingda`.
