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
| L8 board init vs map load race | ❌ | Initializer can spend its 5 attempts before the matcher has the map (Phase 8 L8) |
| cuda_ndt on the Orin | ⏸ | Align-service deadline issue no longer reproduces on the workstation; not re-measured on the Orin (CLAUDE.md) |
| L6 re-initialization after NDT divergence | ⏸ | Nothing re-initializes; the board initializer is one-shot |
| Manual pose seed | ✅ | `just pose init mingda SPOT` works against a running stack (planning sim test 2026-10-21); no Ming-Da spots captured yet |
| L5 wheel speed scale and reverse sign | ❌ | Needs the cart pushed or driven with the VCU on |

### VCU and vehicle interface

| Item | State | Evidence / note |
|---|---|---|
| VCU on CAN (orin can0) | ✅ | 800 frames / 2 s, 0x100-0x103 at ~100 Hz, every error code "No Error" (2026-10-22) |
| V1 VCU accepts our frames (checksum 0) | ✅ | VCU states went Invalid -> Manual once our frames ran; bus error counters tx 109 -> 0; `/vehicle/status/*` all at 50 Hz, control mode MANUAL, gear NEUTRAL |
| Entering AUTO | ✅ | Dashboard: brake + button. All four subsystems reported Autonomous; `Veh_Auto_En` claimed |
| V2 steering sign | ✅ | Keyboard left (+5 deg) turned wheels and steering wheel CCW (left); interface sends -4.98 deg to the VCU, so `invert_steering` is right |
| V3 steering range | 🟡 | Left: wheels kept turning to the 0.52 rad command (>= 29.8 deg). **Right: mechanical stop at ~22 deg** (VCU report plateaus 22.1-22.7 deg, wheels stop at the 23rd 1-deg step). `max_steer_angle` is still 0.52, which the right side cannot reach |
| Steering angle feedback | ❌ | VCU `0x102 Vcu_Ads_Tire_Angle` is live **only in AUTO and only for right turns**: left reads 0.000, manual steering reads a frozen +0.210 deg over a full sweep. Autoware's lateral controller has no usable feedback. **Vendor** |
| VCU state after leaving AUTO | ⏸ | `Driving_State` (and earlier `Brake_State`) read `Invalid`, not `Manual`, after the first AUTO session. The interface treats it as hands off. **Vendor question** |
| Mode request honesty | ✅ | golfcart_vehicle_launch 960a2be: MANUAL now refused while the VCU is still Autonomous (was answered success). Live: MANUAL accepted / AUTONOMOUS refused with the cart in manual; the AUTO-side refusal is unit-tested only |
| Steering slew | ✅ | Command ramps at the interface limit (1 deg per ~0.7 s per key; -29.6 -> 0 deg in 1.29 s); right-side report returns 22.7 -> 0 deg in ~3 s (~7-8 deg/s at the wheels) |
| V4 steering / longitudinal system ID | ❌ | Not started; MPC still carries Lexus delay and time constant |
| S3 braking below 1.2 m/s2 | ❌ | VCU does not brake below 1.2 m/s2; gentle stops may coast |
| S4 interface speed ceiling 1.5 m/s | ❌ | `max_speed_mps` still the 5.0 default; only the 1.0 m/s planning default exists |
| S5 MRM reaches the VCU | ❌ | Wired (emergency_cmd bridged, SafetyBrake path) but never run end to end |
| Physical e-stop reported | ⏸ | Not tested on the cart today |

### Planning and control integration

| Item | State | Evidence / note |
|---|---|---|
| Route on the Ming-Da lane (planning sim) | 🟡 | `sim_route_check.py --start 17.6 -2.8 180 --goal 5.5 -2.8 180`: engaged, forward along the lane at 1.18 m/s, zero lateral deviation. Stops at x = 6.5, **1.0 m short**; PASS at 1.00 m once, FAIL at 1.02 m twice (tolerance 1.0 m). Cause not found |
| Goal placement | ✅ | `base_link` is the rear axle, nose 2.47 m ahead: the furthest valid goal on this lane is x = 5.1 (`Goal's footprint exceeds lane!` otherwise) |
| Two-host stack bring-up | 🟡 | Both hosts start; master failed once on a stale install (fixed by `just build`). Full sensors + link + map + localization never brought up together on the cart yet |
| Engage path through the link | 🟡 | All command and status lanes present in `config/link/topics.yaml`, control-mode service bridged; never exercised end to end with Autoware |
| Software e-stop | ❌ | `teleop_gui.py` publishes its own `control_cmd` (speed 0) continuously; used beside Autoware the two interleave. Needs an e-stop-only mode |
| M3 slow-cart planning / control tuning | ❌ | Stock autoware_launch tuning; side overhangs 0.001 placeholders |
| M4 obstacle detection | ⏸ | Perception off: no obstacle stop; the driver is the only obstacle detector |

### Build, tooling, infrastructure

| Item | State | Evidence / note |
|---|---|---|
| Orin build | ✅ | Plain `just build`, 40 packages, offline (crates from the master's registry cache); u-blox driver skipped while mavros_msgs is absent |
| Orin clock | ✅ | chrony following the master, offset ~1 us |
| `local` bare repos | ✅ | Fast-forwarded to GitHub; the orin pulls from them |
| rclrs pinned to 0.7 | 🟡 | vehicle interface (da78dc5) and aruco detector (8b158d5) pushed. **cuda_ndt_matcher d2e43e9 rejected by GitHub** (no write access). aruco still resolves rclrs 0.8 for `rclrs_image_transport` on a fresh lock (workstation, 2026-10-22) |
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
   until the right side is fixed.
5. Transfer of `data/mingda-basement/pointcloud_map.pcd` to the workstation: NAS
   mount on the master, a private repo, or the public repo.
6. Write access for `NEWSLabNTU/cuda_ndt_matcher` (or someone pushes d2e43e9).
7. golfcart_aruco_detector on a fresh clone: track its Cargo.lock, and/or bump
   `rclrs_image_transport` to a rev that pins rclrs 0.7.
8. cuda_ndt_matcher's tracked Cargo.lock churns on every build (0.0.0 vs real
   binding versions), as gmslcam's did before ec7a3ea.

**Desk work, ready to hand out once approved**
9. Teleop GUI e-stop-only mode (no `control_cmd`).
10. S4: `max_speed_mps: 1.5` in the interface params.
11. Interface rate warning: "30.3 Hz below 10.0 Hz" when the input has stopped;
    say "no control input for X s".
12. Why the planning sim stops 1.0 m short of the goal on the Ming-Da lane
    (candidate for the workstation, once it has the map).
13. L8: the board initializer waits for the matcher's map.
14. Docs: `control_testing.md` and Phase 8's engage sequence still say `tx=on`
    and "driver presses AUTO"; both should say brake + dashboard button.

**On the cart**
15. Park with the board in view: board detection, then from the lane start
    (17.8 m).
16. Stationary rehearsal: `just launch-drive-mingda`, board init, NDT lock, route
    on the lane, no engage.
17. L5 speed report (push the cart a metre, forward and reverse), physical e-stop,
    S3 braking, V4 system identification.
18. The crawl run (Phase 8 V6), after 1, 4, 9, 10, 13, 15 and 16.

## Log

- **2026-10-22** VCU back. V1 pass, V2 pass, V3 partial (right stop 22 deg),
  steering feedback found broken (vendor). Mode-request fix (960a2be),
  `just tool board-detector`, check-script fixes, rclrs pins, orin build and
  clock fixed, Ming-Da lane widened to 2.4 m. This tracker started.
- **2026-10-21** Ming-Da map extracted and verified; lanelet elevation fixed
  (was on the ceiling); straight first-drive lane drawn and verified in the
  planning sim; `just launch-drive-mingda`.
