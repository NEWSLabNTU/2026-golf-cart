# Vehicle Interface — Fault Handling Hardening

Follow-up to `2-vehicle-interface-hardening.md`. Targets failure modes around
ROS subscription drop and CAN message drop / bus failure.

Scope: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/`

Last updated: 2026-05-04

---

## Critical (real-hardware risk)

- [x] **F-1 TX uses stale `mtr.vehicle_speed` without freshness check** — `can_io.rs:233`. Steer-rate bucket selection and gear-shift gate consume cached MTR. If MTR frames stop while cart moves, `low_speed` gate could allow a gear shift mid-motion (gearbox damage). Treat stale MTR as unknown speed (`f32::INFINITY`) to force nominal-rate steer + block gear shift.
- [x] **F-2 TX write failures never escalate** — `can_io.rs:312`. Bus-down floods logs at 400 Hz with no counter, no diag, no SafetyBrake. Add consecutive-failure counter; on threshold, set `fault_latched=true` and emit `vehicle_interface/can_tx` ERROR diag. Rate-limit log to ≤ 1 Hz.
- [x] **F-3 No socket reopen on interface bounce** — `can_io.rs:101`. CAN0 link-down → fd invalid forever, process restart required. Add reopen path on persistent error; emit diag during outage.

## Medium (diagnostic / operability)

- [x] **F-4 Bad-frame decode silently dropped** — `can_io.rs:134`. Counter on decode `Err`, surface as `bad_frames` kv in top-level diag. Helps distinguish flaky-transceiver from silent-VCU.
- [x] **F-5 mtr/eps/brk freshness not in diag** — `node.rs:563`. Only `veh_fresh` drives diag level. Add per-frame STALE entries using `*_at` we already capture.
- [x] **F-6 Subscription QoS not specified** — All subs use rclrs default. Autoware QoS mismatch (BEST_EFFORT vs RELIABLE) → silent zero-messages. Specify explicit QoS matching Autoware convention; document.

## Low (defensive)

- [x] **F-7 Driver e-stop publisher death = stuck SafetyBrake** — Acceptable fail-safe (stuck-on > stuck-off). Document in `state.rs` near `estop` field. Optionally watchdog `last_estop_at` and log warn periodically while latched.

## Already correct (no action)

- F-8 RX log rate-limited via 50ms sleep
- F-9 Gear/turn/hazard cmd drop — Control watchdog is master gate
- F-10 NaN/Inf clamp behavior — clamp_f32 safe
- F-11 Lock ordering — cmd→status preserved
- F-12 Per-frame independent freshness gating in publish_status
- F-13 `expect()` in send_frame — invariants hold

---

## Out of scope

- CAN bus health monitor (transmit error counter from socketcan stats) — kernel-level metrics, separate effort
- Replay-based test harness for fault injection — test infra work
