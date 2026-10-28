# Handover 2026-10-28: Ming-Da drive day, from localization to the first engage

From the cart-master session. Phase 9 tracker:
[docs/roadmaps/9-mingda-autonomous-driving.md](../roadmaps/9-mingda-autonomous-driving.md).
The VCU speed findings have their own note:
[docs/research/system/vcu-speed-report.md](../research/system/vcu-speed-report.md).

## State at the end of the day

* The cart reached **AUTO on the dashboard with a route set and the AUTO button
  enabled in RViz**. On engage it **always turned to the rightmost steering
  angle**. Not investigated; see open item 1.
* Localization works: board init at launch scores 2.5 to 2.86 (`reliable=true`),
  and in recorded drives the pose moved along its heading in Drive and against it
  in Reverse, EKF and NDT agreeing within 0.1 m.
* Everything below is committed by topic and pushed to `origin` and the local bare
  repos. **The orin is on the earlier sync** (parent 52a1c7b, interface 4a8025a):
  it lacks the perception stand-in (master-only, not needed there) and the
  interface's half-step speed correction.
* Deliberately **not committed**: the dense 0.15 m `pointcloud_map.pcd` on the
  master (64 MB; the tracked file stays the 0.30 m one, 1 MB). `git checkout
  data/mingda-basement/pointcloud_map.pcd` puts the tracked one back.

## Findings, in the order they were hit

1. **The VCU speed is km/h, whole steps, unsigned.** The interface now converts,
   signs by gear and adds half a step back. Details and evidence in the research
   note. Closes L5 for the VCU's own report.
2. **RViz was showing a correct localization as a wrong one.** Three separate
   causes, all in the profile:
   * `golfcart.rviz` has the `BirdEyeView` with **Target Frame `base_link`**. The
     camera follows the vehicle, so the vehicle is pinned on screen and the map
     scrolls past it; forward motion looks like the map moving backward. Changing
     only Fixed Frame does not change the camera.
   * With Fixed Frame `base_link`, the **lanelet markers error** (`Lookup would
     require extrapolation`): they are published once with an old stamp and RViz
     looks up `map->base_link` at that stamp. Fixed Frame `map` clears it.
   * The static map clouds had **`Use Fixed Frame: true`**, which places a cloud
     once, when it arrives, and never moves it again. PointCloudMap and
     NDTLoadedPCDMap now have it false.
   Use `just tool rviz-drive` (`golfcart_drive.rviz`): Fixed Frame and a
   TopDownOrtho view both on `map`, plus a green EKF heading arrow. The vehicle
   model is a symmetric 0.4 m box and has no front.
3. **The board initializer was one-shot and its clicks were worse than the board.**
   After one success it ignores every later pose. Hand-placed RViz poses aligned
   to the wrong local optimum (NVTL 1.5 to 1.66, `reliable=false`); the board
   seed gave 2.5 to 2.86. Now:
   * `just pose board` calls `/localization/board_pose_initializer/reinitialize`
     (`std_srvs/Trigger`): it resets the attempt budget and acts on the detector's
     latest pose if under about 3 s old. The same gates apply (cart stopped 3 s,
     NDT has a cloud). Refused only while an initialize call is in flight.
   * The detector searches every cloud, then backs off in steps to one attempt per
     2 s while no board is in view (`search_interval_max`, `search_lost_grace`),
     and logs one line per miss streak. The initializer waits
     `min_attempt_spacing` (1 s) between calls. `pose_wait_timeout` stays 0 in the
     vehicle files: a timeout is terminal and the driver may take minutes.
   * The seed zone is range 4-17 m, bearing 60 deg, aspect 35 deg. Beyond 15 m the
     detector alternates detections with `not_planar` misses; 8 to 12 m worked.
   * A node restart also re-arms it: play_launch's UI, or `POST
     /api/nodes/node:%2Flocalization%2Fboard_pose_initializer/stop` then `/start`.
4. **The NVTL divergence gate was inherited from the wrong map.** 2.5 was set on
   the 0.30 m cloud. On the dense cloud a healthy lock scores a median 2.53 (single
   scans down to 2.03, rolling median of 10 never below 2.51), so 2.5 latched on a
   good lock. Now **2.1** in `launch-drive-mingda`; clicked wrong poses were 1.5
   to 1.66. `/localization/pose_estimator/nearest_voxel_transformation_likelihood`
   is on the master recording list so the next bag can re-derive it.
5. **No trajectory without perception outputs.** With `launch_perception:=false`
   behavior_path_planner logs `waiting for occupancy_grid` and the whole chain
   stays silent, so `is_autonomous_mode_available` is false and the AUTO button is
   disabled. `scripts/perception_stubs.py` (started when perception is off)
   publishes an all-free grid and an empty obstacle cloud; on the live stack that
   woke the chain (path, trajectory 10 Hz, `control_cmd` 33 Hz). **The driver is
   the obstacle detector in this mode.** Do not use `perception_preset:=minimal`
   as the fix: CenterPoint's TensorRT build blocks its composable container for
   10 to 30 minutes (`dds_report.txt`: `lidar_centerpoint`, `common_ground_filter`
   "still loading after 238 s"), and the ground filter behind it never starts.
6. **The cart must be inside the route's first lanelet.** At (11.7, -4.4) it was in
   none of the 18 lanelets (0.63 m outside 300000) and no path was published. The
   loop's start is (10.98, -6.27, 178.2 deg), on the centreline. A route set while
   outside stays latched; clear it (`C` in the TUI) and set it again after moving.
7. **The dense cloud is on the master.** From `~/Downloads/autoware_falcon_map.zip`:
   the 0.15 m variant is the original 3,995,308-point survey cloud in our frame (99.9%
   of the 0.30 m map's 0.5 m voxels covered); the 0.5 m variant is a different
   frame and was not used. NDT loads it in about 5 s. It makes RViz heavy.
8. **Speed limits are three layers**: `planning_speed_limit:=` (startup default,
   1.0 m/s in the recipes), the RViz panel slider or the route TUI's `L` (runtime
   replacement), and the interface's `max_speed_mps` 1.5 m/s as the hard ceiling.
9. **Lane against vehicle width.** `vehicle_info` width is 1.215 m
   (`wheel_tread 1.213 + 0.001 + 0.001`), which excludes the tires (wheel_width
   0.14). 15 of 18 lanelets are 2.50 m. 300007 is 2.45 to 2.50, 300008 is 1.50 to
   2.36, 300009 is 1.50 m (narrowest at (15.6, 22.1)), 300010 is 1.50 to 2.50. At
   1.5 m the modelled clearance is 0.14 m a side, and under 0.08 m with tires.
   Measure the real body width before that stretch; the older "0.28 m each side"
   figure assumed a narrower cart.
10. **The orin has no internet** except the AEON hotspot. `golfcart_aruco_detector`
    fetches crates and failed until it was connected; `just build` there needs it
    on. rig_localization was not initialized on the orin and was cloned from the
    local bare repo.

## Open, in order

1. **The motor does not start in AUTO (blocking); steering looks consistent.**
   Measured live at 20:40 to 20:50 with the brake pedal held and the stack up (VCU restarted before it):
   * Autoware engaged (`mode 2`); the cart was 0.04 m from the path with a 4.6 deg
     heading error. `control_cmd` steering stayed at **-0.178 rad (-10.2 deg, right)**
     for the whole 60 s; it never moved toward the 22 deg stop. Autoware asked for
     0.25 m/s with +0.5 m/s2; the VCU reported 0.000 and the cart did not move.
   * The CAN frames match that command: 0x065 `en=1 mode=1 (front-wheel)
     target=+10.228 deg ang_speed=0.0`; 0x075 `Speed Control, gear Drive,
     accel 0.500, target_speed 0.250`; brake released (0x068 pedal 0).
   * First reported as "rightmost"; on a second look the user judged the wheel to
     be about 10 deg right, which matches the +10.2 deg command. So steering may be
     fine. It stays unmeasured (see the echo below), and the loop's right-hand
     corner will ask for 16 to 28 deg, past the cart's roughly 22 deg stop.
   * **The VCU's tire-angle report is an echo of our target**, bit for bit (0x102
     `13fa` equals 0x065 `13fa`, +10.228 in both). It is not a measurement, so
     nothing in the stack can see the disagreement, and a controller that believes
     the report sees perfect tracking.
   * `Ads_Vcu_Target_Tire_Ang_Speed` (0x065 byte 3, "steering angular speed
     control") is never set by the interface: it is always 0.0 deg/s. Nobody knows
     what the EPS does with a rate of zero.
   Hypotheses, none confirmed:
   * (steering, now unlikely) the EPS reads our angle on another scale than the DBC
     says. The 2026-10-22 check only showed direction; the magnitude has still not
     been measured against the wheel.
   * (motor) the target speed is also km/h in whole steps, so 0.25 reads as 0 and
     the speed loop never leaves rest; Autoware's start velocity is 0.25 m/s and
     does not ramp while the cart is stopped, so it stays there. The VCU may also
     have a minimum creep speed.
   Experiment for the motor (stack DOWN, driver aboard, cart on the ground, clear
   run ahead): on the orin `just vehicle interface`, then
   `just vehicle sysid-steps speed --levels 0.25,0.5,1.0 --hold 3`, which publishes
   `control_cmd` with no Autoware in the way, with a candump or `just vehicle
   sysid-record` running. Read `/vehicle/status/velocity_status` (m/s, already
   converted) at each step. If the cart stays at rest at 0.25 and moves at 0.5 or
   1.0, the VCU has a minimum speed and the interface needs a floor for a nonzero
   command. If it reaches about 0.28 m/s at a command of 1.0, the target is in
   km/h and the interface needs the 3.6 conversion on the command side. If it
   reaches about 1.0, the target is m/s and the cause is elsewhere (acceleration,
   gear, brake). For steering, `steer-standstill` in the same tool, writing down the
   physical angle for each step.
   Other leads from before: `max_steer_angle` 0.52 rad (was 0.349) against a cart
   right stop of about 22 deg (the loop is all right turns; simulated, the cap was
   hit for 14% of a lap), and the first leg ends at a right-hand corner.
2. The half-step speed correction is not on the cart. Deploy it, then compare the
   EKF-minus-NDT offset while moving (it was about 0.2 m).
3. Autoware's CPU NDT as a control run: `just launch-drive-mingda-loop
   "pose_source:=ndt"`. Not done.
4. The physical checks in `docs/guides/control_testing.md`: e-stop, steering sign
   (passed 2026-10-22), speed report (now done above).
5. Read the NVTL score distribution from a drive at the speed where NDT loses lock
   (the user had to drive slowly). The recorded bags only reach 2 km/h.
6. The master load average sat at 30 to 34; the control watchdog is 500 ms.

## Commands that were useful

```bash
just record start / record stop            # master + orin bags to /mnt/external/rosbags
just can vcu-status --once                 # receive-only VCU readout
just pose board                            # re-arm the board initializer
just tool rviz-drive                       # fixed map frame, heading arrow
python3 scripts/testing/mingda/plan_probe.py   # the planning chain, first silent stage
```
