# Handover, 2026-09-11: reflective-board cold start (phase 7)

Where the indoor NDT cold-start campaign stands at the end of 2026-09-11, and
what the next session picks up. The checklist of record is
[docs/roadmaps/7-reflective-board-cold-start.md](../roadmaps/7-reflective-board-cold-start.md),
section *Steps*; this page is the short version.

## Done

- **D1a passes.** Replaying `vlp32_1` against `data/basement-indoor`, the
  detector finds the board at 12 m, `board_pose_initializer` calls
  `/localization/initialize`, and Autoware's NDT align succeeds. Run it with
  `just indoor-test run`.
- **The map is reproducible (B3, C3).** `scenarios/basement/falcon_map.yaml` is
  the configuration the survey team anchored with, found by reproducing the
  anchor to five decimals. `scripts/map/anchor_reflective_map.sh` rebuilds the
  map, dry-run by default, refuses a moved anchor, and writes
  `anchor_run.txt` beside the result.
- **The map has been looked at (B4).** The board's returns fill the mapped
  polygon; the ceiling band at 2.4 to 2.8 m must stay.
- **The detector** has the decided gates (threshold 100, board 0.6 x 0.6 m at
  1.3 m), non-terminal ambiguity, a confidence gate, the motion guard's
  `TwistWithCovarianceStamped` with `twist_type`, and the board outline on
  `~/debug/board_outline` (A5), shown in `golfcart.rviz` and
  `golfcart_ntu.rviz`.
- **play_launch** runs this stack with its default Rust parser. Issues 0028,
  0029 and 0030 were fixed upstream; the installed wheel is built from its
  `main` at `7911fd0f`.

## Next, in order

1. **D1b, on the vehicle:** record a basement bag with the vehicle interface
   and IMU running, the board in view from a standstill, then a drive. It
   answers the open question from D1a (34 s after initialization the fused
   pose read (2.1, 2.7) against the board guess (11.5, -4.6): tracking or
   walk-off) and unblocks the next two.
2. **A3:** set `twist_topic` to
   `/sensing/vehicle_velocity_converter/twist_with_covariance` in
   `config/localization/reflective_pose/board_detector.param.yaml` (the type
   is already named) and check on that bag that scans taken while moving are
   dropped.
3. **D2:** the full sequence on the cart, CAN TX off.

Deferred: a `lanelet2_map.osm` with a drivable route, only once planning is
wanted.

## Things that will bite

- **Copy NAS datasets into the repo before using them.** A replay straight off
  the sshfs mount delivered no messages at all today; the local copy replays
  normally. The copies live in gitignored `rosbags/basement/vlp32_1` and
  `data/basement-indoor/source/`, and both scripts default to them. A new
  machine has to make the copies first; the commands are in each script's
  header.
- **Loopback multicast is off on the workstation.** Stock launches exhaust
  DDS participant indexes under the repo's loopback profile; today's replays
  used a unicast profile through `CYCLONEDDS_URI`. The fix needs sudo:
  `sudo systemctl start multicast-lo`.
- **Three submodules are one commit behind their recorded pointers**
  (`cuda_ndt_matcher`, `golfcart_sensor_kit_launch`, `golfcart_vehicle_launch`):
  another session's dependency fixes. `just checkout` aligns them.
- **The map's z origin may be off by up to ~0.2 m.** The survey cloud has
  almost no floor, and the anchor's height comes from the configured 1.3 m.
  The bag measures 1.30 to 1.40 m near level floor; NDT matches on the
  ceiling, so this is recorded, not blocking.
- **`pkill -f` can kill your own shell** when the pattern also appears in the
  command line that runs it. Use `[x]yz` patterns, or PIDs.
