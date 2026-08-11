# control_test

Test utilities for the Golf Cart vehicle control chain. Drives
`golfcart_vehicle_interface` (Turing Drive CAN) via Autoware command
topics. Ported from AutoSDV; PCA9685 PWM-specific tools dropped (Golf
Cart uses CAN, not PCA9685).

## Nodes

### `keyboard_control` — Tkinter GUI manual control

Arrow-key publish to `Control` and `GearCommand`. Subscribes to
`/vehicle/status/*` for live readout.

**Requires**: X11 display (`$DISPLAY`).

```bash
ros2 launch control_test keyboard_control.launch.xml
```

**Output topic presets** (selectable in GUI):

| Preset | control_cmd topic | gear_cmd topic | Use |
|---|---|---|---|
| `Direct` (default) | `/control/command/control_cmd` | `/control/command/gear_cmd` | Standard Golf Cart path — feeds `golfcart_vehicle_interface` directly. |
| `Custom` | user-defined | user-defined | Ad-hoc / custom pipelines. |

**Controls**:

| Key | Action |
|---|---|
| ↑ / ↓ | Increase / decrease speed (`speed_step_ms`) |
| ← / → | Steer left / right (`steering_step_deg`) |
| Space | Stop (speed = 0) |
| Enter | Center steering |
| `x` / `c` / `v` | Gear DRIVE / REVERSE / PARK |
| `s` | Status print |
| `h` | Help |
| `q` | Quit |

**Config** (`config/keyboard_control.yaml`):
```yaml
speed_step_ms: 0.5
steering_step_deg: 1.0
max_speed_ms: 10.0
max_steer_deg: 22.5
publish_rate: 30.0
```

**Engage workflow** (Golf Cart has no `vehicle_cmd_gate` external selector):

1. Launch system: `just launch`
2. Launch keyboard_control: `ros2 launch control_test keyboard_control.launch.xml`
3. Have the driver switch the vehicle to autonomous on its own controls.
   `golfcart_vehicle_interface` commands nothing until all four VCU subsystem
   states (MTR, BRK, EPS, Drv) report autonomous — no service call can force
   it. Confirm with:
   ```bash
   ros2 topic echo --once /vehicle/status/control_mode   # mode: 1 == AUTONOMOUS
   # or use: just tool-tui
   ```
   If a fault is latched (`mode: 5`, DISENGAGED), clear it after fixing the
   cause:
   ```bash
   ros2 service call /control/control_mode_request \
     autoware_vehicle_msgs/srv/ControlModeCommand "{mode: 4}"
   ```
4. Set gear (`x` for DRIVE), then drive with arrow keys.

### `control_command_service` — service-driven publisher

Param-driven setpoints; `~/enable` SetBool gates publishing. Suitable
for scripted / automated tests.

```bash
ros2 launch control_test control_command_service.launch.xml \
    target_speed:=1.5 target_steering:=0.1
ros2 service call /control_command_service_node/enable \
    example_interfaces/srv/SetBool "{data: true}"
```

**Parameters**: `target_speed` (m/s), `target_steering` (rad),
`target_acceleration` (m/s²), `publish_rate` (Hz).

### `trajectory_player` — open-loop trajectory replay

Plays a YAML trajectory of `(t, speed, steering)` tuples.

```bash
ros2 run control_test trajectory_player --ros-args -p trajectory_file:=straight_10m.yaml
ros2 run control_test trajectory_player --ros-args -p trajectory_file:=circle.yaml
```

Trajectory files in `trajectories/`. Add new ones following the same
schema.

## Launch files

| File | Purpose |
|---|---|
| `basic_control.launch.xml` | Minimal vehicle stack: `robot_state_publisher`, `golfcart_vehicle_interface`, `vehicle_velocity_converter`. Used as a thin shim for control testing. Configurable `can_interface` (default `can0`). |
| `keyboard_control.launch.xml` | GUI manual control (above). |
| `control_command_service.launch.xml` | Service publisher (above). |
| `trajectory_player.launch.xml` | Trajectory replay (above). |

## Workflow examples

**Bench (vcan0) smoke**:
```bash
sudo modprobe vcan && sudo ip link add vcan0 type vcan && sudo ip link set up vcan0
ros2 launch control_test basic_control.launch.xml can_interface:=vcan0
# then in another terminal:
ros2 launch control_test keyboard_control.launch.xml
```

**Trajectory regression**:
```bash
just launch
ros2 launch control_test trajectory_player.launch.xml \
    trajectory_file:=straight_10m.yaml
ros2 topic echo /vehicle/status/velocity_status
```

**Manual override**:
```bash
ros2 launch control_test keyboard_control.launch.xml
# preset already on `Direct` — drives /control/command/* into
# golfcart_vehicle_interface.
```

## Notes

- **GUI requires X11**. Not runnable headless.
- **Service-based control** (`control_command_service`) is the right
  pick for automated / CI tests — TTY-free.
- **No PCA9685 tools**: Golf Cart drives Turing Drive over SocketCAN.
  AutoSDV's `static_pwm_test`, `pid_speed_control`,
  `keyboard_pwm_control.py` are not ported.
- **Engage path**: `/control/control_mode_request` service
  (`AUTONOMOUS` to engage, `MANUAL` / `NO_COMMAND` to disengage —
  partial-autonomy modes rejected).

## Dependencies

- `golfcart_vehicle_interface`: Vehicle interface node (Rust).
- `autoware_control_msgs`, `autoware_vehicle_msgs`,
  `tier4_control_msgs`, `tier4_external_api_msgs`: command messages.

## See also

- [Vehicle interface README](../golfcart_vehicle_launch/golfcart_vehicle_interface/README.md) — protocol, FSM, topics, parameters.
- [`docs/roadmaps/2-vehicle-interface-testing.md`](../../../docs/roadmaps/2-vehicle-interface-testing.md) — test phase doc covering CAN-level + ROS-level tools.
