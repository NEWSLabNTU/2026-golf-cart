# Standalone Vehicle-Interface Testing: One Recipe, One Launch File

**Status**: Design approved (2026-08-12)
**Scope**: `justfile`, `src/vehicle/golfcart_vehicle_launch/`, `src/vehicle/control_test/`,
`src/vehicle/external/autoware_manual_control` (submodule)
**Phase doc**: [../roadmaps/2-vehicle-interface-standalone-refactor.md](../roadmaps/2-vehicle-interface-standalone-refactor.md)

## Goal

A single justfile recipe for standalone `golfcart_vehicle_interface` testing,
with two options that matter on a bench or a jacked-up cart:

- **a.** CAN TX open or closed.
- **b.** Keyboard manual control on or off, driving the vehicle through Autoware
  control messages (`autoware_control_msgs/Control` + `GearCommand`).

Everything else about the current vehicle-interface recipe surface collapses into
that one recipe.

## Problem

Seven recipes touched the vehicle interface, through three near-duplicate launch
files, with three different TX defaults.

| Recipe | Path taken | TX default |
|---|---|---|
| `vehicle-interface CAN TX` | `golfcart_autoware.launch.xml` + 10 × `launch_*:=false` | **true** |
| `control-vehicle-test CAN TX` | `vehicle_interface_test.launch.xml` | false |
| `control-teleop-real CAN` | `teleop_bench.launch.xml` | hardcoded **true** |
| `control-basic` | `control_test/basic_control.launch.xml` | unset → false |
| `control-keyboard` | `control_test/keyboard_control.launch.xml` (GUI) | n/a |
| `manual-control` | `scripts/control/keyboard_control_direct.sh` (terminal) | n/a |
| `can-test` | `vehicle_interface_test.launch.xml` + CAN replay | false |

Specific defects:

1. **Duplicated node definition.** `vehicle_interface_test.launch.xml` repeats the
   node block and all 14 remaps of `vehicle_interface.launch.xml` verbatim; only
   the comments differ. Two places to keep in sync, silently.
2. **Undeclared arguments.** `just vehicle-interface` passed `can_interface:=` and
   `tx_enabled:=` to `golfcart_autoware.launch.xml`, which declares neither
   (`golfcart_autoware.launch.xml:19-33`). It worked only because a command-line
   argument leaks into included scopes as a launch configuration. A child that
   re-declares the name breaks it silently.
3. **Heavy path for a bare CAN node.** That same route unconditionally starts
   `autoware_global_parameter_loader` and `pointcloud_container`
   (`golfcart_autoware.launch.xml:57-69`).
4. **Inconsistent TX defaults.** Two of the three most dangerous entry points put
   frames on the bus by default.
5. **Three manual controllers**, one recipe each: two Tk GUIs
   (`control_test/keyboard_control.py`, `golfcart_vehicle_launch/scripts/teleop_gui.py`)
   and one terminal controller (`autoware_manual_control`). All three publish the
   same `/control/command/control_cmd` + `gear_cmd`.

## Design

### Recipe

```
just vehicle-interface                        # RX only, no keys
just vehicle-interface keyboard=on            # teleop, TX still off — dry run
just vehicle-interface tx=on keyboard=on      # drives the cart
just vehicle-interface can=vcan0 keyboard=on  # bench, against mock_vcu
just vehicle-interface converter=on           # + robot_state_publisher + velocity converter
```

Options are `KEY=VALUE`, order-free, unknown keys rejected. Defaults:
`can=can0 tx=off keyboard=off converter=off`.

Named options rather than positional parameters: `just` has no `NAME=value` syntax
for recipe parameters, so positional arguments silently shift when one is omitted —
`just vehicle-interface can1 false` reads fine but `just vehicle-interface false`
sets the *interface* to `false`. Parsing `KEY=VALUE` inside the recipe body avoids
that whole class of mistake and makes `tx=on` self-documenting at the call site.

**TX safety.** `tx=off` everywhere by default. `tx=on` prints a warning banner and
counts down 3 seconds before launching — no interactive prompt, so the recipe stays
usable from scripts.

### Launch file

New `golfcart_vehicle_launch/launch/vehicle_interface_standalone.launch.xml`:

```xml
<arg name="can_interface"       default="can0"/>
<arg name="tx_enabled"          default="false"/>
<arg name="manual_control"      default="false"/>
<arg name="vehicle_description" default="false"/>
<arg name="velocity_converter"  default="false"/>
```

It `<include>`s the existing `vehicle_interface.launch.xml` unchanged — that file
stays the single owner of the node and its remaps, shared with the full Autoware
stack — and adds conditional groups for the keyboard controller, the
`robot_state_publisher` (URDF/TF), and `autoware_vehicle_velocity_converter`. The
latter two blocks are lifted from `basic_control.launch.xml:13-33`, which this
file replaces.

Launched with plain `ros2 launch`, not through `golfcart_autoware.launch.xml`. No
global parameter loader, no pointcloud container, and every argument is declared
where it is used.

### Keyboard control in its own tmux session

The keyboard controller is `autoware_manual_control` (terminal, raw tty). The two
Tk GUIs are not wired into the standalone path.

Why not the GUIs: `control_test/keyboard_control.py` was built for the full stack —
it publishes `GateMode` and calls `/api/autoware/set/engage`
(`keyboard_control.py:15-17`), and neither `vehicle_cmd_gate` nor adapi runs
standalone. It stays in the tree for use with `just launch`. `teleop_gui.py` and
its `teleop_bench.launch.xml` are superseded by the terminal controller plus the
fork fixes below.

The terminal controller cannot simply be added as a node: under `ros2 launch` its
stdin is not the terminal, so `tcgetattr` fails and `getchar()` returns EOF
forever — a live node that reads no keys. Nor should it share a terminal with
launch: log lines would scramble a raw-tty interface mid-render.

So the node runs inside its own **tmux session**, spawned by a `launch-prefix`
wrapper:

```xml
<node pkg="autoware_manual_control" exec="keyboard_control" name="manual_control"
      if="$(var manual_control)"
      launch-prefix="$(find-pkg-share golfcart_vehicle_launch)/scripts/run_in_tmux.sh golfcart-teleop --">
```

`launch-prefix` is split on whitespace and prepended to the node's argv, so the
wrapper receives the full node command (including `--ros-args`) as trailing
arguments. Remaps and parameters are unaffected.

**`run_in_tmux.sh SESSION -- <cmd...>`**, installed to
`share/golfcart_vehicle_launch/scripts/` so the launch file can name it with a
plain `$(find-pkg-share ...)` path:

1. No `tmux` on `PATH` → exit 127 with an install hint. tmux only; no X-terminal
   fallback, no inline mode. Field work is over SSH, where `DISPLAY` is unset, and
   one backend means one behavior to reason about.
2. Session name already taken → refuse rather than steal it; print `attach` and
   `kill-session` hints.
3. `tmux new-session -d`, with the ROS environment passed through explicitly via
   `-e` (tmux 3.2a copies the client environment into a new session, but an
   already-running server with a stale global environment would otherwise poison
   it).
4. `set-option remain-on-exit on` — a node that dies at startup leaves its error
   on screen instead of the pane vanishing.
5. Print the attach hint on stdout, so it lands in the launch log.
6. Block by polling `#{pane_dead}`, then exit with `#{pane_dead_status}`. Launch
   treats a returning prefix process as node death, so the wrapper must outlive
   the node. Polling `has-session` would hang forever given `remain-on-exit on`.
7. `trap INT TERM EXIT` → `kill-session`, so launch shutdown never orphans a
   session.

Result: launch logs stay on the launch terminal, the keyboard UI owns a clean pty,
and both die together.

### Fork fixes: `NEWSLabNTU/autoware_manual_control`

The submodule sits detached at `dbfc812`; `main`, `origin/main` and
`origin/2026-golf` all point at the same commit, so the merge back is a
fast-forward.

| ID | Fix | Why |
|---|---|---|
| F1 | `isatty()` + checked `tcgetattr` in `terminal_reader.hpp:12`; no tty → `RCLCPP_ERROR` and skip the key thread | Today the node spins silently on EOF |
| F2 | `max_speed`, `step_speed`, `max_steer_angle`, `step_steer_angle` as ROS parameters | `keyboard_control.cpp:9-12` hardcodes 100 km/h max and 5 km/h per keypress — absurd, and unsafe, on a golf cart |
| F3 | Topic names as parameters | `manual_control_node.hpp:44-47` hardcodes `/external/selected/*`; the shell script existed largely to remap them |
| F4 | `mode_backend: gate \| control_mode \| none` | `z` publishes `GateMode` and calls `/api/autoware/set/engage` (`:40-43,66-77`); both are dead standalone. `control_mode` calls `/control/control_mode_request` instead |
| F5 | Subscribe `/vehicle/status/control_mode`, show it in the `s` status line | Absorbs the pre-flight mode check in `keyboard_control_direct.sh:29-46` |
| F6 | Node name `ManualControl` → `manual_control`; initialize `gate_mode_` / `current_engage_` | `:173-176` are read uninitialized by the first `s` |

F3 and F5 are what make `scripts/control/keyboard_control_direct.sh` redundant.

Control authority is unchanged and stays with the driver: the interface transmits
only while the VCU reports all four subsystems autonomous. No key in this
controller can override that.

## Deletions

**Launch files**: `vehicle_interface_test.launch.xml` (duplicate),
`teleop_bench.launch.xml`, `control_test/launch/basic_control.launch.xml`.

**Recipes**: `control-vehicle-test`, `control-teleop-real`, `control-basic`,
`control-keyboard`, `manual-control`.

**Script**: `scripts/control/keyboard_control_direct.sh`.

**Kept**: `vehicle_interface.launch.xml` (sole node definition),
`control_test/launch/keyboard_control.launch.xml` (full-stack GUI, no recipe),
`control-straight`, `control-circle`, and all `can-*` recipes.

### Migration

| Old | New |
|---|---|
| `just vehicle-interface can0 true` | `just vehicle-interface tx=on` |
| `just control-vehicle-test vcan0` | `just vehicle-interface can=vcan0` |
| `just control-teleop-real can0` | `just vehicle-interface keyboard=on tx=on` |
| `just control-keyboard` / `just manual-control` | `just vehicle-interface keyboard=on` |
| `just control-basic` | `just vehicle-interface converter=on` |

## Consequences

- One TX default, `off`, on every path. No recipe reaches the bus without `tx=on`.
- One node definition. Remap drift between the real and test launch files becomes
  impossible.
- `can-test` re-points at the standalone launch, removing the last reference to the
  deleted test file.
- New files (`run_in_tmux.sh`, the standalone launch) require one `just build`:
  `--symlink-install` only covers files present at configure time.
- The keyboard controller now depends on tmux at runtime. It is already installed
  on the Orin; the wrapper fails loudly if it ever is not.

## Status

Implemented 2026-08-12. Verified on the bench (`vcan0` + `mock_vcu`, isolated
`ROS_DOMAIN_ID`): the interface comes up, publishes `/vehicle/status/*`, reports
`AUTONOMOUS`, and puts no `ADS_VCU_*` frames on the bus with `tx=off`. The tmux
wrapper is verified standalone for normal exit, non-zero exit, duplicate-session
refusal and SIGINT teardown.

Open, and needing an Orin that is not shared with someone else's ROS graph:

- the keyboard path end to end (`keyboard=on`: attach, drive `mock_vcu`, confirm
  the launch log stays clean), and tmux teardown driven by a launch Ctrl-C;
- `can-test` after the rewire;
- whether `play_launch` preserves `launch-prefix` — only matters if teleop later
  moves inside the full `just launch` stack; the standalone recipe uses plain
  `ros2 launch`.

See the phase doc for the exact commands.
