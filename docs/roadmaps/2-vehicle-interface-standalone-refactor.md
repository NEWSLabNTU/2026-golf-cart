# Standalone Vehicle-Interface Recipe Refactor

Collapses seven overlapping vehicle-interface recipes into two: `vehicle-interface`
with CAN TX and extras as options, and `manual-control` for keyboard teleop. Design:
[../design/vehicle_interface_standalone.md](../design/vehicle_interface_standalone.md).

Scope: `justfile`, `src/vehicle/golfcart_vehicle_launch/`, `src/vehicle/control_test/`,
`src/vehicle/external/autoware_manual_control` (submodule).

Last updated: 2026-08-12

---

## Step 1: Fork fixes — `NEWSLabNTU/autoware_manual_control`

Branch off `main` (== `origin/main` == `origin/2026-golf` == `dbfc812`), land the
fixes, fast-forward `main`, push, bump the submodule pointer here.

- [x] **F1 tty guard** — `terminal_reader.hpp`: `isatty(STDIN_FILENO)` + check the
      `tcgetattr` return. No tty → `RCLCPP_ERROR` pointing at `just manual-control`,
      skip the key thread instead of spinning on EOF.
- [x] **F2 limits as parameters** — `max_speed`, `step_speed`, `max_steer_angle`,
      `step_steer_angle`, replacing the `#define`s at `keyboard_control.cpp:9-12`
      (100 km/h max, 5 km/h per keypress).
- [x] **F3 topics as parameters** — `control_cmd_topic`, `gear_cmd_topic`,
      replacing the hardcoded `/external/selected/*` at `manual_control_node.hpp:44-47`.
- [x] **F4 `mode_backend`** — `gate | control_mode | none`. `gate` keeps today's
      `GateMode` + `/api/autoware/set/engage` behavior; `control_mode` calls
      `/control/control_mode_request`; `none` disables the `z` key.
- [x] **F5 control-mode status** — subscribe `/vehicle/status/control_mode`, render
      it in the `s` status line.
- [x] **F6 hygiene** — node name `ManualControl` → `manual_control`; initialize
      `gate_mode_` / `current_engage_` (`manual_control_node.hpp:173-176`).
- [x] **Build + ff-merge** — `colcon build --packages-select autoware_manual_control`,
      ff-merge to `main`, push, bump submodule pointer with a `chore(submodule)` commit.

## Step 2: keyboard controller placement — REVISED

Originally a node inside the launch file, handed a terminal by a
`run_in_tmux.sh` `launch-prefix` wrapper. Built, and verified working under plain
`ros2 launch`. Dropped anyway: **`play_launch` does not support `launch-prefix`**,
and `play_launch` runs the full stack, so that path would work in one launcher
and silently do nothing in the other.

- [x] **W-1 `run_in_tmux.sh`** — built, verified (exit 0, exit 3, duplicate-session
      refusal, SIGINT teardown), then **removed** along with its install rule and
      the `autoware_manual_control` exec_depend it justified.
- [x] **W-2 `just manual-control`** — runs `ros2 run autoware_manual_control
      keyboard_control` directly, so it owns the terminal it is typed in. Passes
      `mode_backend:=control_mode`, the `/control/command/*` topics, and the cart's
      limits (`max_speed:=5.0`, `step_speed:=0.25`, `max_steer_angle:=0.349`,
      `step_steer_angle:=0.0174`). Extra `--ros-args` pass through via `ARGS`.

## Step 3: Standalone launch file

- [x] **L-1 `vehicle_interface_standalone.launch.xml`** — args `can_interface`
      (`can0`), `tx_enabled` (`false`), `vehicle_description` (`false`),
      `velocity_converter` (`false`). Includes `vehicle_interface.launch.xml`
      unchanged. Vehicle interface only — no keyboard node, see step 2.
- [x] **L-2 keyboard group** — *dropped, superseded by `just manual-control`.*
- [x] **L-3 description + converter groups** — `robot_state_publisher` and
      `autoware_vehicle_velocity_converter`, lifted from `basic_control.launch.xml:13-33`.

## Step 4: Justfile

- [x] **J-1 single `vehicle-interface` recipe** — `KEY=VALUE` options
      (`can`, `tx`, `converter`), order-free, unknown keys rejected, defaults
      `can0 / off / off`. `tx=on` prints a warning banner and counts down 3 s.
      Keyboard control lives in `just manual-control` (step 2).
- [x] **J-2 remove superseded recipes** — `control-vehicle-test`,
      `control-teleop-real`, `control-basic`, `control-keyboard`, `manual-control`.
- [x] **J-3 rewire `can-test`** — point at `vehicle_interface_standalone.launch.xml`
      (last reference to the deleted test launch).
- [x] **J-4 section headers** — group the vehicle-interface and CAN recipes so
      `just --list` reads cleanly.

## Step 5: Deletions

- [x] **D-1** `golfcart_vehicle_launch/launch/vehicle_interface_test.launch.xml`
      (duplicate of `vehicle_interface.launch.xml`).
- [x] **D-2** `golfcart_vehicle_launch/launch/teleop_bench.launch.xml`.
- [x] **D-3** `control_test/launch/basic_control.launch.xml` (→ `converter=on`).
- [x] **D-4** `scripts/control/keyboard_control_direct.sh` (absorbed by F3 + F5).
- [x] **D-5** `teleop_gui.py` — kept as a tool, run with
      `ros2 run golfcart_vehicle_launch teleop_gui.py` when a display is available.
      Only its launch file (D-2) went; the install rule stays.

## Step 6: Build and verify

- [x] **V-1 `just build`** — `autoware_manual_control`, `golfcart_vehicle_launch`
      and `control_test` all build. `control_test` needed its stale `build/`
      directory removed: setup.py globs the launch dir, and the copy list still
      held the deleted `basic_control.launch.xml`.
- [x] **V-2 launch parses** — `--show-args` lists the four arguments with their
      defaults, and no keyboard-related ones.
- [x] **V-3 bench smoke, keys off** — `just vehicle-interface can=vcan0` against
      `mock_vcu --auto` on an isolated `ROS_DOMAIN_ID`: `/vehicle/status/velocity_status`
      published, `/vehicle/status/control_mode` = 1 (AUTONOMOUS), and `candump`
      showed only the mock's four `VCU_ADS_*` IDs — no `ADS_VCU_*` frames, i.e. TX
      really is off.
- [x] **V-4 keyboard smoke** — `just manual-control` in a second terminal, against
      `just vehicle-interface can=vcan0`: help menu plus
      `Limits: speed <= 5 m/s (step 0.25), steer <= 19.9962 deg` (F2 live); keys
      `x u u u l` produced `/control/command/control_cmd` (velocity 0.75, steering
      -0.0174) and `gear_cmd` command 2 = DRIVE; `s` printed
      `Vehicle:Autonomous Gear:D` (F5 live).
      *First verified in the tmux/`launch-prefix` form; re-verified after the
      rework as a standalone recipe.*
- [x] **V-5 teardown** — Ctrl-C on the controller: `signal_handler(SIGINT/SIGTERM)`,
      process exits, terminal settings restored, no orphan. `just` prints
      `terminated ... by signal 2`, which is its normal report for an interrupted
      recipe.
- [x] **V-6 `can-test`** — runs the standalone launch on `vcan0` and replays
      `can_can0_20260507_163716.log`; `/vehicle/status/*` publish from the replayed
      frames (`control_mode` = 6/NOT_READY, as expected from a capture whose four
      subsystem states are not all autonomous).

## Step 7: Docs

- [x] **X-1 `CLAUDE.md`** — control-testing command block (`:45`).
- [x] **X-2 `src/vehicle/control_test/README.md`** — `basic_control` removal, keyboard GUI scope.
- [x] **X-3 `golfcart_vehicle_interface/README.md`** — bench-run instructions (`:54`).
- [x] **X-4 `golfcart_vehicle_launch/README.md`** — launch file inventory.
- [x] **X-5 `docs/roadmaps/2-vehicle-interface-testing.md`** — T-14 (`just test-can-bench`
      etc. collapse into this recipe).
- [x] **X-6 `docs/README.md` + root `README.md`** — index entries for the design and
      phase docs.

## Status

Complete, verified on the bench 2026-08-12 (`vcan0` + `mock_vcu`, isolated
`ROS_DOMAIN_ID`). Reproduce with:

```bash
sudo ./scripts/can/up-vcan0.sh vcan0
ros2 run golfcart_vehicle_interface mock_vcu --interface vcan0 --auto &
just vehicle-interface can=vcan0
# second terminal: just manual-control, then x / u / j
just can-test
```

Untested and out of scope: whether `play_launch` preserves `launch-prefix`. Only
matters if teleop later moves inside the full `just launch` stack; this recipe
uses plain `ros2 launch`. Real-bus (`can0`, `tx=on`) driving is field-test work.

## Risks

- **`launch-prefix` is not portable across launchers** — `play_launch` ignores it,
  so anything that depends on it works under `ros2 launch` only. This is why the
  keyboard controller is a recipe rather than a node. Same family as play_launch
  dropping `executable:` entries.
- **Deleting `basic_control.launch.xml`** — `control-straight` / `control-circle`
  assume that stack is already up. Their comments must point at
  `just vehicle-interface converter=on`.
- **Submodule pointer** — the bump must not land before the fork's `main` is pushed,
  or a fresh `just checkout` breaks for everyone else.
