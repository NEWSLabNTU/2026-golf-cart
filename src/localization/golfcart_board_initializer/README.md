# golfcart_board_initializer

Cold-start localization indoors from a retroreflective board, replacing GNSS as
the initial-pose source.

Design: [docs/design/board_pose_initializer.md](../../../docs/design/board_pose_initializer.md)
Phase: [docs/roadmaps/3-indoor-e-board-initializer.md](../../../docs/roadmaps/3-indoor-e-board-initializer.md)

The node detects the board in an accumulated stationary scan, composes the
vehicle pose in the map frame, and calls `/localization/initialize` with
`method=AUTO` — the board supplies a guess and NDT align refines it.

## Layout

| Path | Role |
|------|------|
| `golfcart_board_initializer/detector.py` | Detection. Pure numpy, no `rclpy`. |
| `golfcart_board_initializer/geometry.py` | Pose composition and covariance. Pure numpy. |
| `golfcart_board_initializer/vlp32.py` | Beam table, read from the Nebula calibration with an embedded fallback. |
| `golfcart_board_initializer/simulation/` | Synthetic VLP-32C scans and scenes. |
| `golfcart_board_initializer/node.py` | ROS wiring, state machine, diagnostics. |
| `golfcart_board_initializer/scene_publisher.py` | Publishes synthetic scans for desk testing. |
| `rviz/board_initializer.rviz` | RViz layout for the debug topics. |

`detector.py` and `geometry.py` import no ROS. That is what lets the tests run
with nothing installed, and it lets the offline map-anchoring step share the code
that runs at runtime.

## Running the tests

```bash
python3 -m pytest test
```

No ROS, no hardware, no bag. 30 tests, roughly one second.

## Desk test with synthetic scans

```bash
ros2 launch golfcart_board_initializer simulated_scene.launch.xml
ros2 launch golfcart_board_initializer simulated_scene.launch.xml scene:=two_boards
ros2 launch golfcart_board_initializer simulated_scene.launch.xml scene:=distractors
```

Add `rviz:=true` to open RViz with `rviz/board_initializer.rviz`: the raw scan
coloured by intensity over a fixed 0–255 range — the retroreflector band above
100 then separates visually — the detected board points in green, a green arrow
along the board normal, every rejected cluster labelled with its reason, and the
dry-run initial pose with its covariance.

An ambiguous result draws **both** candidates in green with red `AMBIGUOUS
candidate N` labels. Every debug topic is cleared at the start of each attempt:
they are latched, so without that a stale detection from a previous run keeps
drawing and reads as a current one. The `Board pose` display is off by default
for the same reason — a latched `PoseStamped` cannot be retracted, so the arrow
marker carries that pose instead.

`dry_run` defaults to true there: the composed pose is published on
`~/debug/initial_pose` instead of calling the service, so the whole path runs
without a localization stack. Expected outcomes are a detection, an ambiguity
abort, and a clean no-candidate respectively.

`ros2 launch` under a shell `timeout` can leave the publisher running. A stale
publisher feeding a second scene into the same topic looks exactly like a
detector bug — check `pgrep -f board_scene_publisher` before believing one.

## On the vehicle

```bash
ros2 launch golfcart_board_initializer board_initializer.launch.xml
```

Requires a map anchored to the board (see the mapping design), `gnss_enabled:=false`,
and the board mounted where it was when the map was built.
