# Handover 2026-11-10: full autonomous Ming-Da loop, ZED stereo recording, NTU prep

From the cart-master session (2026-11-09 evening to 2026-11-10 ~02:00). Phase 9
tracker: [docs/roadmaps/9-mingda-autonomous-driving.md](../roadmaps/9-mingda-autonomous-driving.md).

## State at the end of the day

* **Complete supervised autonomous clockwise lap on the Ming-Da loop** (driver's report,
  ~00:32): speed limits held in every lanelet and the stop-and-go surging at low lane
  speeds is gone. A second clockwise run with stereo was recorded at 01:39.
* Both hosts are on parent `6c50a60`; vehicle interface `b0b9191` (branch 2026-golf).
  Everything is pushed to `origin` and the local bare repos, and the orin pulled.
* Stack stopped by the user at the end. The orin's play_launch is 0.30.0 (pip, `--user`);
  `play_launch setcap` there still needs sudo.

## What changed (commits, oldest first)

| commit | what |
|---|---|
| c91ff3d | Ming-Da loop refitted from three driven clockwise laps |
| 985578e | RViz: Autoware splash and qt5ct theme (`scripts/rviz/`), golf cart mesh shown |
| d78cacb | vehicle interface: a latched VCU fault clears after 2 s in Manual (`fault_clear_hold_ms`) |
| b3e93ab | loop at 5 km/h, 3 km/h through the narrow north lane, four right corners tagged `turn_direction: right`; `centerline_to_lanelet.py` learns a per-point `turn:`; lanelets split evenly between breaks (no stubs); `min_speed_mps` 1.5 -> 0.8 (interface b0b9191) |
| 255a63d | setup: `isaac-h264-encoder` falsely reported "no apt candidate" (pipefail + `grep -q` SIGPIPE) |
| 0774e7d | `zed_stereo_video` defaults to true: H.264 left/right recorded on the orin |
| e506b94 | the orin runs play_launch containers in `stock` mode (`config/runtime.conf`) |
| b5d22d7 | `config/launch/ntu-r01.args` for the first outdoor drive |
| 6c50a60 | CLAUDE.md: current system, arg-file table, "Field practice" section |

play_launch: issue **#0082** filed on NEWSLabNTU/play_launch main (01ac7687).

## Findings worth keeping

* **Stop-and-go at low lane speeds was the speed floor.** With `min_speed_mps` above a
  lane's limit the VCU drove to the floor, Autoware commanded a deceleration, any decel
  over 0.2 m/s^2 cuts motor torque, the cart slowed, and the loop repeated. Keep the
  floor below every lane limit (0.8 < 3 km/h = 0.83 m/s). 3 km/h did not stall.
* **ZED stereo** (Isaac ROS 3.2 encoder, NVENC, qp 20, I-frame every 5): ~40 Mbit/s per
  side. With the RGB JPEG also subscribed (as the recorder does) every ZED stream runs
  at 15 Hz; without it, 30 Hz. ZED IMU stays at 100 Hz.
* **play_launch `observable` doubles frames into one encoder** (#0082): it runs a
  `component_container_isolated` on one thread. `stock` is clean, verified in the
  01:29 test bag (674/673 frames, all stamps unique, both decode).
* **Full GPU (NITROS) stereo path does not work yet.** With `debug.disable_nitros:false`
  the wrapper turns NITROS off while the ZED node has intra-process on; with IPC off,
  NITROS engages, the RGB JPEG topic disappears (rigloc reads it), CPU drops only
  ~112 -> 85 %, and the right encoder receives both chains while the left gets none,
  in the stock container too. Isaac NITROS nodes refuse intra-process. Parked; the
  ZED SDK's own SVO2 recording (NVENC, outside the bag) is the other option.

## Recordings

| session | what | archive |
|---|---|---|
| `20261110_003202` | the full autonomous lap (no stereo yet) | `recordings/20261110_003202.tar.zst` (8.4 GB) |
| `20261110_012903_stereo-check` | 45 s stereo test, VCU off | not collected |
| `20261110_013933` | clockwise drive with stereo, 87 m NDT path, 1.46 m/s peak; collected | `recordings/20261110_013933.tar.zst` (10.3 GB) |
| `20261110_013810`, `_013843` | short starts | not collected |

The archives are on the master's SSD and the user's phone; not on GitHub.

## Open, in order

1. **NTU r01 outdoor drive (planned 2026-11-11)**: `just up @ntu-r01`. First GNSS init
   on this map; RViz 2D Pose Estimate as fallback. Record with `autonomy` scope. After
   it: derive the NTU NVTL gate from the bag, add `turn_direction` tags to r01.
2. **Blinker/hazard on the VCU**: tags now make Autoware request turn signals on the
   loop; whether the VCU lights them is still unconfirmed (check `0x103 Vcu_Ads_Blinker`
   in the 013933 CAN log, or watch the lamps).
3. Fault-latch auto-clear seen working? Check the interface log of the 003202 run.
4. Loop map: tightest corner radius 3.0 m (cart minimum 3.6 m); a notch on lanelet 13's
   inner edge near (19.5, -1).
5. play_launch #0082 fix, then the orin can return to `observable` if wanted.
6. NITROS stereo (above), or SVO2.
