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

### Recipes

```
just vehicle-interface                  # RX only
just vehicle-interface tx=on            # drives the cart
just vehicle-interface can=vcan0        # bench, against mock_vcu
just vehicle-interface converter=on     # + robot_state_publisher + velocity converter
just manual-control                     # keyboard teleop, second terminal
```

Options are `KEY=VALUE`, order-free, unknown keys rejected. Defaults:
`can=can0 tx=off converter=off`. Keyboard control is a second recipe, for the
terminal-ownership reason below.

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
<arg name="vehicle_description" default="false"/>
<arg name="velocity_converter"  default="false"/>
```

It `<include>`s the existing `vehicle_interface.launch.xml` unchanged — that file
stays the single owner of the node and its remaps, shared with the full Autoware
stack — and adds conditional groups for the
`robot_state_publisher` (URDF/TF) and `autoware_vehicle_velocity_converter`. The
latter two blocks are lifted from `basic_control.launch.xml:13-33`, which this
file replaces.

Launched with plain `ros2 launch`, not through `golfcart_autoware.launch.xml`. No
global parameter loader, no pointcloud container, and every argument is declared
where it is used.

### Keyboard control as a separate recipe

The keyboard controller is `autoware_manual_control` (terminal, raw tty). The two
Tk GUIs are not wired into the standalone path.

Why not the GUIs: `control_test/keyboard_control.py` was built for the full stack —
it publishes `GateMode` and calls `/api/autoware/set/engage`
(`keyboard_control.py:15-17`), and neither `vehicle_cmd_gate` nor adapi runs
standalone. It stays in the tree for use with `just launch`. `teleop_gui.py` and
its `teleop_bench.launch.xml` are superseded by the terminal controller plus the
fork fixes below.

It cannot be a node in the launch file: under `ros2 launch` its stdin is not the
terminal, so `tcgetattr` fails and `getchar()` returns EOF forever — a live node
that reads no keys. Nor should it share a terminal with launch: log lines would
scramble a raw-tty interface mid-render.

A `launch-prefix` that hands the node its own tmux session solves both, and was
built and verified — but **`play_launch` does not support `launch-prefix`**, and
that is what runs the full stack. A keyboard path that only works under plain
`ros2 launch` is a path that breaks the moment teleop is wanted inside `just
launch`. So the launch file starts the vehicle interface and nothing else, and
the controller is its own recipe:

```bash
just vehicle-interface        # terminal 1
just manual-control           # terminal 2
```

`manual-control` runs the node directly, so it owns the terminal it is typed in —
no wrapper, no session management, nothing to tear down, and it composes with any
way of starting the interface (`vehicle-interface`, `just launch`, or a launch
file of your own). It passes the golf cart's limits and the standalone topic and
mode settings:

```
-p mode_backend:=control_mode
-p control_cmd_topic:=/control/command/control_cmd
-p gear_cmd_topic:=/control/command/gear_cmd
-p max_speed:=5.0  -p step_speed:=0.25
-p max_steer_angle:=0.349  -p step_steer_angle:=0.0174
```

`mode_backend=control_mode`: no `vehicle_cmd_gate` and no adapi run here, so `z`
asks the vehicle interface directly. Whether the vehicle obeys is still the
driver's call — the interface transmits only while the VCU reports all four
subsystems autonomous.

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
| `just control-teleop-real can0` | `just vehicle-interface tx=on` + `just manual-control` |
| `just control-keyboard` / old `just manual-control` | `just manual-control` (now parameterized for the cart) |
| `just control-basic` | `just vehicle-interface converter=on` |

## Consequences

- One TX default, `off`, on every path. No recipe reaches the bus without `tx=on`.
- One node definition. Remap drift between the real and test launch files becomes
  impossible.
- `can-test` re-points at the standalone launch, removing the last reference to the
  deleted test file.
- The standalone launch file requires one `just build`: `--symlink-install` only
  covers files present at configure time.
- Teleop is one recipe regardless of how the interface was started — standalone,
  `just launch`, or a launch file of your own — because it is not bound to any of
  them.

## Status

Implemented and verified on the bench 2026-08-12 (`vcan0` + `mock_vcu`, isolated
`ROS_DOMAIN_ID`):

- `tx=off` — interface publishes `/vehicle/status/*`, reports `AUTONOMOUS`, and
  puts no `ADS_VCU_*` frames on the bus.
- `just manual-control` in a second terminal — shows the golf-cart limits
  (5 m/s in 0.25 m/s steps, 20° in 1° steps), keys produce
  `/control/command/control_cmd` (0.75 m/s, -0.0174 rad after `u u u l`) and
  `gear_cmd` = 2 (DRIVE), and `s` reports `Vehicle:Autonomous Gear:D` — the
  vehicle's own `ControlModeReport`. Ctrl-C restores the terminal and exits.
- `can-test` — replay rig still works after the rewire.

Real-bus driving (`can0`, `tx=on`) is field-test work.

### History

The keyboard controller was first built as a node inside the launch file, given a
terminal by a `run_in_tmux.sh` `launch-prefix` wrapper. That worked under plain
`ros2 launch` — session spawned, keys delivered, teardown clean — but
`play_launch`, which runs the full stack, does not support `launch-prefix`. The
wrapper was removed rather than left as a path that works in one launcher and
silently does nothing in the other.
