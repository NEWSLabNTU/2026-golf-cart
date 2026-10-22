# Control testing: the first supervised autonomous drive

Procedure for Phase 8 ([roadmap](../roadmaps/8-autonomous-driving.md)): Autoware
driving the cart along a route in the Ming-Da basement at crawl speed, with a
driver aboard. It was written before the first run. On 2026-10-22, with the VCU
back, the cart-side pieces were checked one by one (V1, V2, entering and leaving
AUTO; progress in [Phase 9](../roadmaps/9-mingda-autonomous-driving.md)); the
drive itself, and engaging with Autoware, have not run. Every step marked
*unverified* is a claim read from the code, and the first run is what checks it.

## Roles

- **Driver**, in the seat, hands near the wheel, foot near the brake, and the one
  person who puts the cart in AUTO and takes it out: **brake pedal held, then the
  dashboard AUTO button**, both ways. Nothing over CAN changes the VCU's mode, so
  no one at a keyboard can. Any subsystem switched back to manual breaks the
  VCU's unanimity and the interface goes idle: that is the override.
- **Operator**, at the master, runs the stack and the engage call and watches the
  mode strip at `http://localhost:8080/`.

## Before the day

1. The VCU is back and `VCU_EXPECTED=1 scripts/check/vehicle.sh` passes.
2. Phase 8 V1: the VCU accepts command frames with checksum 0. Answered yes on
   2026-10-22; if the VCU firmware changes, ask again, because a cart that
   ignores every command makes nothing else here mean anything.
3. The drivable lanelet exists in `data/basement-indoor/lanelet2_map.osm`
   (Phase 8, M1).
4. The planning simulator scenario on that map passes route, engage and MRM stop
   (Phase 8, M2).

## Pre-drive checks, cart stationary

`just can vcu-status` on the master shows, receive only, what the VCU reports and
what the interface sends (modes, estop, error codes, tire angle, gear, speed),
which is the quickest way to answer "does the VCU agree" at any step below.

1. Physical e-stop: locate it, press it, confirm the VCU reports it
   (the interface logs the hardware e-stop as a safety brake; `vcu-status`
   shows `estop=Pressed`).
2. Steering sign (Phase 8, V2): with the interface running, put the cart in AUTO
   (brake held + dashboard button), stationary, and with the keyboard controller
   command left: the wheels and the steering wheel turn left. The EPS follows
   commands only in AUTO, so in manual this check shows nothing. Passed on
   2026-10-22 (+5 deg left went out as -4.98 deg to the VCU). Do not read the
   angle off `/vehicle/status/steering_status`: the VCU's tire-angle report is
   frozen in manual and reads 0 for left turns (vendor issue), so watch the
   wheels.
3. Speed report: push the cart a metre, `ros2 topic echo
   /vehicle/status/velocity_status` shows a positive speed, and a negative one
   in reverse (Phase 8, L5).

## Bring-up

```bash
just launch-drive-basement
```

This is `launch-all` with the board initializer, the basement map, no GNSS,
perception off and planning defaulting to 1.0 m/s. **With perception off there
is no obstacle detection.** The driver is the obstacle detector.

Then:

1. Drive the cart manually until the board is in view and stop. The detector
   seeds `/localization/initialize`; `scripts/localization/check_ndt_activated.py`
   reports when NDT is tracking.
2. In RViz on the master, confirm the scan overlays the map.
3. Set the route with goal modification **off**, a few metres short of the
   lane's end. With it on (the route TUI's setting), the goal planner looks for a
   pull-over spot, finds no road shoulder in the basement, and holds the cart at
   zero speed with a `goal-planner` stop: engaged, and going nowhere. Seen in the
   planning simulator, 2026-09-29.
4. Confirm on the mode strip that autonomous is available. If it is not, the
   strip names the leaf; do not proceed past a red leaf you cannot explain.

## Engage

The cart enters and leaves AUTO only on the dashboard. Nothing over CAN moves the
VCU between modes, and Autoware reads the mode the VCU reports. The interface's
control-mode service acknowledges in both directions and commands neither
(golfcart_vehicle_launch 960a2be): AUTONOMOUS succeeds only once all four VCU
subsystems report Autonomous, MANUAL only once they no longer do. The order is:

1. **Driver holds the brake pedal and presses the dashboard AUTO button.**
   Autoware is still in STOP, so it sends a stop-hold (-1.5 m/s2, which is only
   the VCU's first brake stage).
2. **Operator engages:** the RViz *AUTO* button in the operation mode panel, or
   the TUI, which calls `/api/operation_mode/change_to_autonomous`.

## Stopping

| Situation | Action |
|---|---|
| Anything unexpected | Driver takes over: brake or steer. That breaks unanimity and the interface stops commanding. |
| Driver cannot reach the controls | Physical e-stop. |
| Operator sees a problem | Software e-stop: the teleop GUI's button on `/vehicle/emergency_stop`. It now holds until released even while Autoware keeps publishing (Phase 8, S1). |
| End of run | Operator: `/api/operation_mode/change_to_stop`, then the driver leaves AUTO: brake held + dashboard AUTO button. Autoware's own disengage does not take the cart out of AUTO. |

**Known weakness:** the VCU does not brake below 1.2 m/s2 (Phase 8, S3), so
gentle planner stops and Autoware's comfortable-stop MRM may coast. Keep speeds
at the 1.0 m/s default until S3 is measured.

## Record everything

`just record start` before engaging on both hosts, `just record stop` after. Each
run's bag must replay through the logging simulation with the same route (exit
criterion 5).
