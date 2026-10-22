# Handover 2026-10-22: Ming-Da stationary rehearsal, mid-session

From the cart-master session to golfcart 243. Phase 9 tracker:
[docs/roadmaps/9-mingda-autonomous-driving.md](../roadmaps/9-mingda-autonomous-driving.md).

## State when handed over (16:40 CST)

- Stack **running on both hosts**:
  `just launch-drive-mingda "launch_perception:=true perception_preset:=minimal"`.
  It was restarted at 16:38 for perception. TensorRT engines for CenterPoint are not cached in
  `data/autoware_data/lidar_centerpoint/`, so the first start builds them (10-30 min).
- Cart parked **inside the new lane** at x 11.27, y -3.94, heading 179.9 (board init and NDT
  agree). The right wheel is 5 cm from a curb. Driver at the cart, VCU on. Nothing engaged.
- Orin built at 3b21cbe (interface 59dfd2c: 1.5 m/s cap). chrony enabled on the orin.

## Done this session

- Board detector live: **PASS at 8 m** (56/56, spread 0.058 m / 0.33 deg). It failed at 12.5 m
  on bad_height 0.44 (ring quantization). The workstation fix c279bd9 (reflective_pose
  b35485c) is pulled and built on the master; **12.5 m and 17.8 m re-runs are still to do**
  (`just stop-all` first; `just tool board-check duration=60`).
- Board confirmed by tape: 1.0-1.6 m above the floor (config right).
- **Lane moved off a curb** (dd58eb4): the hand-drawn lane at y -2.8 overlapped a curb at
  y ~ -3.2 that is not in the drawing and not resolvable in the PCD. The new lane centre is
  y -4.9, width 2.4 (edges -3.7 / -6.1), x 2.6-17.6. Goal **(5.95, -4.9, 180)**.
  The curb was located at x ~11 only; it is assumed to be parallel to the lane.
- Steering decision 4a recorded (stock settings for the straight lane).

## Open, in order

1. **Planning chain with perception on.** With perception off, behavior_path_planner logged
   `waiting for occupancy_grid`, so it produced no path. A hand-published all-free grid
   got `path_with_lane_id` out, but `behavior_planning/path` and everything downstream
   stayed empty. AEB logs `waiting for object pointcloud`. The user chose minimal perception
   (now running). Next: once it is up, set the route
   (`/api/routing/set_route_points`, goal above, `allow_goal_modification` false), then
   probe each stage: `.../behavior_planning/path`,
   `.../motion_planning/path_optimizer/trajectory`, `.../lane_driving/trajectory`,
   `/planning/scenario_planning/trajectory`, `/control/command/control_cmd`. Then check
   `is_autonomous_mode_available` and the `waiting for` lines in `~/.ros/log`.
2. **Localization loses track when the cart moves (blocking).** Twice, pushing or driving
   the cart sent NDT 14-25 m off while the board detector still had it right. Nothing
   re-initializes after that (L6). Suspected cause, unconfirmed: the VCU speed report while
   moving (L5). To diagnose, log `/vehicle/status/velocity_status`,
   `/localization/twist_estimator/twist_with_covariance`, the EKF and NDT poses, and
   `board_pose` while the driver creeps 1 m forward along the curb.
3. Only after 1 and 2: the crawl drive (Phase 8 V6). The driver enters AUTO (brake + dashboard
   button), then engage at <= 1.0 m/s, about 5 m to the goal.
4. Workstation: board-check re-runs at 12.5 / 17.8 m; report any "ambiguous" outcomes.

## Rules learned today

- The master's display `:0` is the driver's screen: no windows and no xdotool on it during
  runs. A passive screenshot only when asked.
- Treat the lane geometry as suspect until a curb and clearance check has been done from the
  cart. The PCD floor is too sparse to show curbs.
