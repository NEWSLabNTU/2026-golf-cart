# Vehicle Interface Hardening

Fixup phase for `golfcart_vehicle_interface` (Rust). Findings from comparing
against Autoware's `pacmod_interface` reference implementation.

Scope: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/`

Last updated: 2026-05-04

---

## Critical (correctness / safety)

- [x] **#1 Clock source breaks sim-time** — `now_stamp()` uses `SystemTime`. Replace with `node.get_clock().now()` so `use_sim_time:=true` (bag replay, simulation) yields correct stamps. Keep `Instant` only for monotonic watchdog math.
- [x] **#2 Stale `last_control_at` on re-engage** — `disengage→engage` retains previous `last_control_at`, instantly trips `SafetyBrake`. Reset to `None` in `onControlModeRequest` when transitioning `auto_enabled` false → true.
- [x] **#3 No driver-override detection** — Watch `Vcu_Ads_Driving_State == Manual` while `auto_enabled`. On detection: clear `auto_enabled`, log warn.
- [x] **#4 No VCU report freshness check** — Timestamp each `Some(VcuAds*)` write in RX. Publish-timer rejects status older than `report_timeout_ms`. Diagnostic turns STALE.
- [x] **#5 `expect` on encode panics** — Setpoints from Autoware are not clamped. Add subscriber-side clamps for speed/accel/decel/throttle/tire-angle to DBC ranges. Replace `expect` with graceful skip + diag warn fallback.
- [x] **#6 `fault_latched` cleared by any non-AUTONOMOUS request** — Match exact `MANUAL`/`NO_COMMAND`. Reject unknown enum values with `success=false`.

## Medium (robustness)

- [x] **#7 Hardcoded watchdog timeout** — Add `control_timeout_ms` ROS parameter (default 500ms).
- [x] **#8 No steering rate limiter** — Slew-limit `target_tire_angle_rad` per tick. Separate stopped/low-vel/normal rates per `pacmod_interface.cpp:740-756`.
- [x] **#9 No throttle/accel/decel saturation** — Parameterize `max_throttle_pct`, `max_accel_mps2`, `max_decel_mps2`. Enforce on TX path.
- [x] **#10 No gear chatter / shift-with-brake** — Latch gear cmd; ≥2s margin between changes; force ~0.7 MPa brake while shifting at v<0.1.
- [x] **#11 Hazard echo recovery missing** — Track desired vs reported blinker; emit `vehicle_interface/blinker` WARN diagnostic on >500ms mismatch. *Auto-retry deferred — pending observation of real VCU blinker quirks (risk of triggering spurious blinker behavior with no hardware to verify).*
- [x] **#12 ControlMode partial-autonomy not real** — Either reject `AUTONOMOUS_STEER_ONLY`/`VELOCITY_ONLY` honestly, or implement bit-level gating.

## Low (quality / integration)

- [x] **#13 Lock-ordering not formalized** — Comment lock-acquisition order convention in `state.rs`.
- [x] **#14 Hand-rolled DiagnosticArray** — `FreqWindow` rolling-buffer rate per VCU_ADS_* frame; published as `rate_*_hz` kv pairs in top-level diagnostic.
- [x] **#15 Missing actuation status publish** — Publish `ActuationStatusStamped` (tier4_vehicle_msgs) on `~/output/actuation_status` from VcuAdsMtr/Brk/Eps.
- [x] **#16 No FSM unit tests** — Table tests covering each `TxMode::evaluate` transition.
- [x] **#17 Two CAN sockets RX/TX** — Decided no-change. Independent read/write timeouts and avoidance of head-of-line blocking outweigh fd savings. Rationale documented in `can_io::spawn`.
- [x] **#18 Custom std_msgs::Bool e-stop topic** — Added `~/input/emergency_cmd` subscriber on `tier4_vehicle_msgs::VehicleEmergencyStamped`; Bool topic kept for manual button. Both feed the same `cmd.estop` flag.

## Architectural — optional

- [x] **#19 CAN errors via `eprintln!` bypass ROS logger** — Pipe CAN error logs through `log_error!` so log levels/filters work. Pass `node.get_logger()` clone into threads.

---

## Out of scope

- Threading model (RX/TX threads + mutexes vs ROS timer): keep current. Migration cost > benefit; only #19 needs adjusting.
- `checksum_stub() = 0`: blocked on Turing Drive supplying checksum spec.
- VGR / steering offset: not needed for golf cart's direct EPS.
