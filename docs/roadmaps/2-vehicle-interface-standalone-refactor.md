# Standalone Vehicle-Interface Recipe Refactor

Collapses seven overlapping vehicle-interface recipes into one, with options for
CAN TX and keyboard manual control. Design:
[../design/vehicle_interface_standalone.md](../design/vehicle_interface_standalone.md).

Scope: `justfile`, `src/vehicle/golfcart_vehicle_launch/`, `src/vehicle/control_test/`,
`src/vehicle/external/autoware_manual_control` (submodule).

Last updated: 2026-08-12

---

## Step 1: Fork fixes — `NEWSLabNTU/autoware_manual_control`

Branch off `main` (== `origin/main` == `origin/2026-golf` == `dbfc812`), land the
fixes, fast-forward `main`, push, bump the submodule pointer here.

- [x] **F1 tty guard** — `terminal_reader.hpp`: `isatty(STDIN_FILENO)` + check the
      `tcgetattr` return. No tty → `RCLCPP_ERROR` naming `just vehicle-interface
      keyboard=on`, skip the key thread instead of spinning on EOF.
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

## Step 2: tmux wrapper

- [x] **W-1 `run_in_tmux.sh`** — `golfcart_vehicle_launch/scripts/run_in_tmux.sh`,
      `SESSION -- <cmd...>`. tmux missing → exit 127 with an install hint. Existing
      session → refuse, print attach/kill hints. `new-session -d` with ROS env via
      `-e`, attach hint on stdout, `trap INT TERM EXIT` → SIGINT the pane, then
      `kill-session`.
      *Implementation note: `remain-on-exit` + a `#{pane_dead}` poll was the plan,
      but the option can only be set after the session exists, and a command that
      fails instantly takes the session with it first — the status was lost exactly
      when it mattered. The pane now writes its exit status to a temp file and
      parks on `sleep`, so the wrapper reads the status, dumps the last 20 lines
      of pane output into the launch log, and exits with the same code. Verified:
      exit 0, exit 3, duplicate-session refusal, and SIGINT teardown (session
      killed, status 130 propagated, no leftover session or temp file).*
- [x] **W-2 install rule** — `install(PROGRAMS scripts/run_in_tmux.sh DESTINATION
      share/${PROJECT_NAME}/scripts)` in `golfcart_vehicle_launch/CMakeLists.txt`,
      so the launch file resolves it via `$(find-pkg-share ...)`.

## Step 3: Standalone launch file

- [x] **L-1 `vehicle_interface_standalone.launch.xml`** — args `can_interface`
      (`can0`), `tx_enabled` (`false`), `manual_control` (`false`),
      `vehicle_description` (`false`), `velocity_converter` (`false`). Includes
      `vehicle_interface.launch.xml` unchanged.
- [x] **L-2 keyboard group** — `autoware_manual_control/keyboard_control` under the
      `run_in_tmux.sh` `launch-prefix`, remapped onto `/control/command/control_cmd`
      + `gear_cmd`, with `mode_backend:=control_mode` and golf-cart speed/steer limits.
- [x] **L-3 description + converter groups** — `robot_state_publisher` and
      `autoware_vehicle_velocity_converter`, lifted from `basic_control.launch.xml:13-33`.

## Step 4: Justfile

- [x] **J-1 single `vehicle-interface` recipe** — `KEY=VALUE` options
      (`can`, `tx`, `keyboard`, `converter`), order-free, unknown keys rejected,
      defaults `can0 / off / off / off`. `tx=on` prints a warning banner and counts
      down 3 s.
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
- [x] **V-2 launch parses** — `--show-args` lists all five arguments with their
      defaults.
- [x] **V-3 bench smoke, keys off** — `just vehicle-interface can=vcan0` against
      `mock_vcu --auto` on an isolated `ROS_DOMAIN_ID`: `/vehicle/status/velocity_status`
      published, `/vehicle/status/control_mode` = 1 (AUTONOMOUS), and `candump`
      showed only the mock's four `VCU_ADS_*` IDs — no `ADS_VCU_*` frames, i.e. TX
      really is off.
- [ ] **V-4 bench smoke, keys on** — `just vehicle-interface can=vcan0 keyboard=on`;
      tmux session appears, attach works, keys move `mock_vcu` state, launch log
      stays unscrambled. *Started, then aborted before it could be inspected: the
      Orin is shared and another person was running ROS on it.*
- [ ] **V-5 teardown** — Ctrl-C on the launch terminal kills the tmux session; no
      orphan `keyboard_control`, no orphan session. *The wrapper's own SIGINT path
      is verified standalone (see W-1); what remains untested is that path driven
      by `ros2 launch`.*
- [ ] **V-6 `can-test`** — still works after the rewire.

## Step 7: Docs

- [x] **X-1 `CLAUDE.md`** — control-testing command block (`:45`).
- [x] **X-2 `src/vehicle/control_test/README.md`** — `basic_control` removal, keyboard GUI scope.
- [x] **X-3 `golfcart_vehicle_interface/README.md`** — bench-run instructions (`:54`).
- [x] **X-4 `golfcart_vehicle_launch/README.md`** — launch file inventory.
- [x] **X-5 `docs/roadmaps/2-vehicle-interface-testing.md`** — T-14 (`just test-can-bench`
      etc. collapse into this recipe).
- [x] **X-6 `docs/README.md` + root `README.md`** — index entries for the design and
      phase docs.

## Remaining work

V-4, V-5 and V-6 need the machine to themselves — a keyboard session, a Ctrl-C,
and a CAN replay, none of which can share an Orin with someone else's ROS graph.
Run them together on the bench:

```bash
sudo ./scripts/can/up-vcan0.sh vcan0
ros2 run golfcart_vehicle_interface mock_vcu --interface vcan0 --auto &
just vehicle-interface can=vcan0 keyboard=on
# second terminal: tmux attach -t golfcart-teleop, then x / u / j and watch mock_vcu
# back on the launch terminal: Ctrl-C, then confirm `tmux ls` shows no golfcart-teleop
just can-test
```

## Risks

- **tmux under `launch-prefix`** — the wrapper must block for the node's lifetime,
  or launch declares the node dead immediately. Covered by V-4/V-5.
- **Deleting `basic_control.launch.xml`** — `control-straight` / `control-circle`
  assume that stack is already up. Their comments must point at
  `just vehicle-interface converter=on`.
- **Submodule pointer** — the bump must not land before the fork's `main` is pushed,
  or a fresh `just checkout` breaks for everyone else.
