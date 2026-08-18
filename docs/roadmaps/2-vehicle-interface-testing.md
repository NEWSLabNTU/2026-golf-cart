# Vehicle Interface Testing — CAN + ROS Levels

Two-tier testing strategy for `golfcart_vehicle_interface`. Reuses what
ports cleanly from `~/repos/AutoSDV` (ROS-level tools: keyboard control,
service-driven publisher, trajectory player, drive TUI). Adds a CAN-level
bench rig (vcan0 + mock VCU) that AutoSDV did not need (its actuators were
PCA9685 PWM, ours are CAN frames).

Scope: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/` +
new `scripts/can/` + new tests inside `control_test`.

Last updated: 2026-05-05

---

## Tier 1: CAN bench rig (no hardware)

Highest leverage. Most fault-handling scenarios become reproducible once
this is in place. Runs on a virtual CAN interface (`vcan0`); CI-friendly.

- [x] **T-1 vcan0 bring-up script** — `scripts/can/up-vcan0.sh` + `down-vcan0.sh`. Idempotent, root-required, prints `ip -details link show` after bring-up.
- [x] **T-2 mock_vcu** — Rust bin (`src/bin/mock_vcu.rs`) sharing dbc-codegen via `#[path = "../dbc.rs"] mod dbc;`. Two-thread RX/TX, first-order physics on speed (τ=0.5s) and tire angle (τ=0.2s), gear mirror, VCU_ADS_* emit at 50 Hz. Built as `mock_vcu` exec alongside `golfcart_vehicle_interface`.
- [x] **T-3 mock_vcu fault injection CLI** — flags wired: `--estop`, `--err-{sys,mtr,eps,brk}`, `--drop-{mtr,eps,brk,veh}`, `--auto`, `--manual`, `--brk-invalid`, `--rate`, `--interface`. `--help` prints usage. `--auto` models the driver switching the vehicle over (all four subsystem states report Autonomous); without it the mock stays Manual and the interface commands nothing.
- [x] **T-4 candump-style monitor** — `scripts/can/monitor_can.py`. Pure stdlib SocketCAN (no python-can dep). ANSI-color decoded view of all 8 protocol IDs; highlights age and field changes; configurable render rate.
- [x] **T-5 Static-frame test** — `scripts/can/static_can_test.py`. Heartbeat sender for bringup smoke. CLI: `--seconds`, `--rate`, `--gear`, `--speed`. Args mirror AutoSDV's `static_pwm_test` ergonomics.
- [x] **T-6 Sweep tests** — `sweep_speed.py`, `sweep_steer.py`, `sweep_brake.py`. Triangle-wave setpoint with concurrent RX thread reading the matching VCU_ADS_* echo; CSV output for `(t, target, measured)`. Share `static_can_test.py` build helpers via sys.path insert.

## Tier 2: ROS-level test tools (port from AutoSDV)

Tools already exist in `~/repos/AutoSDV/src/vehicle/control_test/` and
`~/repos/AutoSDV/scripts/testing/`. Topic names match Autoware conventions
that we already use, so most port verbatim.

- [x] **T-7 Port `control_test` package** — Already ported earlier (commit `595c649 Eliminate AutoSDV refs`). Reverified: `keyboard_control.py`, `control_command_service.py`, `trajectory_player.py`, `circle.yaml`, `straight_10m.yaml` all present and building. PCA9685-only tools never copied.
- [x] **T-8 Adapt keyboard_control presets** — Default flipped to `Direct` (`/control/command/*`); `External (Standard)` preset removed (no `vehicle_cmd_gate` external selector in Golf Cart chain). `Custom` retained. README + launch comment updated. `basic_control.launch.xml` rewritten to include `golfcart_vehicle_launch/launch/vehicle_interface.launch.xml` (the AutoSDV stub nodes `velocity_report` / `actuator` no longer exist).
- [x] **T-9 Port drive TUI** — `scripts/testing/drive/run.py` already in tree, wired into justfile as `just tool tui`. adapi-only, vehicle-neutral; works against current launch.
- [x] **T-10 Port rosbag recording** — `scripts/rosbag/record_outdoor.sh` activated with Golf Cart sensor topic list (VLP-32C, u-blox, Tamagawa, USB front camera, vehicle_interface status + `/diagnostics`, TF). Removed the `exit 1` guard.

## Tier 3: Golf-Cart-specific test additions

New tools that AutoSDV didn't have, tailored to our CAN interface and
diagnostic surface.

- [ ] **T-11 `can_replay` node** — Plays a `candump -L` capture against `vcan0`. Captures real drives once, replays forever for regression. Located in `control_test/can_replay.py` or as Rust bin.
- [ ] **T-12 `diag_watcher`** — Subscribes `/diagnostics`, asserts no `vehicle_interface/*` entry exceeds threshold level for N seconds. Returns non-zero exit on assertion failure — usable in CI.
- [ ] **T-13 `fsm_assert`** — Scripted scenario runner. Drives `~/control_mode_request` + `control_cmd` through a YAML-defined sequence; verifies `ControlModeReport` transitions match expected. Integrates with `mock_vcu` for fault injection.
- [x] **T-14 Justfile entries** — collapsed into a single `just vehicle interface` with `can=` / `tx=` / `keyboard=` / `converter=` options instead of a recipe per rig; `just vehicle interface can=vcan0` is the bench entry (pair with `mock_vcu`), `just can test` still drives the replay rig. See [2-vehicle-interface-standalone-refactor.md](2-vehicle-interface-standalone-refactor.md). `test-fsm` remains open, blocked on T-13.

## Scenario coverage matrix

Twelve scenarios drive the test suite. Most can run on `vcan0 + mock_vcu`;
items 5, 9 are highest priority — they exercise the F-1 / F-2 fault
handling fixes from `2-vehicle-interface-fault-handling.md`.

| # | Scenario | Tool path | Expected | Bench OK? |
|---|---|---|---|---|
| 1 | Cold start → engage → no Control msg | service call + `diag_watcher` | `EngagedWaiting`, motor disabled | ✓ |
| 2 | Engage → Control → planner crash mid-drive | `trajectory_player` + kill | `SafetyBrake` within `control_timeout_ms` | ✓ |
| 3 | Driver e-stop press → release → MANUAL | std_msgs/Bool publisher | SafetyBrake until MANUAL request | ✓ |
| 4 | ECU fault inject | `mock_vcu --estop` | `fault_latched=true`, engage refused | ✓ |
| 5 | CAN cable disconnect mid-drive | `ip link set vcan0 down` | `tx_failed=true` → SafetyBrake | ✓ |
| 6 | Gear chatter | rapid `GearCommand` flap | one shift per `gear_change_margin_ms` | ✓ |
| 7 | Steer slew | step `steering_tire_angle` 0→max | rate-limited per speed bucket | ✓ |
| 8 | Setpoint clamp | publisher with `velocity=100` | clamped to `max_speed_mps` | ✓ |
| 9 | Stale MTR | `mock_vcu --drop-mtr` | `speed_known=false` → stopped steer + no shift | ✓ |
| 10 | Re-engage after fault | MANUAL → AUTONOMOUS | `last_control_at=None`, no instant SafetyBrake | ✓ |
| 11 | Partial-autonomy reject | service `AUTONOMOUS_STEER_ONLY` | `success=false` | ✓ |
| 12 | Stale VCU report | kill mock_vcu | `ControlModeReport::NOT_READY`, diag STALE | ✓ |

All twelve runnable on the bench. Real-hardware-only items (cable-yank
recovery timing, mechanical EPS slew tracking, gearbox engagement noise)
are downstream of the bench suite and validated during the field-test
phase.

## Test rig variants

| Rig | Hardware | Use case |
|---|---|---|
| **Bench** | vcan0 + mock_vcu | Daily dev, CI, regression of FSM + diagnostics |
| **HIL (jacked-up vehicle)** | Real Turing Drive CAN, wheels off ground | Actuator response calibration, sweep tests |
| **Field** | Full vehicle on track | TUI + trajectory_player + diag_watcher recording |

## Priority order

1. **T-1, T-2, T-3** — vcan0 + mock_vcu. Unlocks 11/12 scenarios offline.
2. **T-4, T-5** — `monitor_can.py` + `static_can_test.py` for first hardware bringup.
3. **T-7, T-8** — port `control_test` for manual smoke test.
4. **T-12, T-13** — `diag_watcher` + `fsm_assert` for automated regression.
5. **T-9, T-10** — verify drive TUI + rosbag recording.
6. **T-6, T-11** — sweep tests + can_replay once vehicle is moving.
7. **T-14** — justfile wiring last (after individual tools work).

## Out of scope

- PCA9685 PWM tools — AutoSDV legacy, not applicable.
- `vehicle_cmd_gate` external-selector workflow — Golf Cart drives planner straight to vehicle_interface; no gate-mode toggle needed.
- HIL automation harness — manual operator coverage sufficient for now.
- Closed-loop tuning (PID gain identification) — Turing Drive owns that side; we only validate the interface.
