# VCU ↔ vehicle interface — notes for the deck

Source: `Roots_can_test_0811.zip` on the NAS, at
`autoveh/logs/2026 Golf Cart/2026-06-28 VCU manual/`. A Python test bench written
against the real VCU, plus its README recording what the bench runs established.

## Lineage — this is the through-line for the slide

The vehicle interface was not written from a specification. It was grown from
the vendor's own test code:

1. **Turing Drive supplied a CAN test script.**
2. **We modified it and added safety measures** — the bench's clamps are ours:
   target speed can never go negative (a negative target upsets the VCU; reverse
   is gear `R`), gear `P` pins speed and angle to zero and re-applies that every
   cycle so nothing can leak onto the bus, and the ESTOP release key falls back
   to `CTRL+SPACE` on terminals that cannot report `SHIFT+SPACE`, "so ESTOP is
   never a state you cannot leave".
3. **We drove the vehicle from that script** — the bench is not a desk exercise,
   it moved the cart.
4. **`golfcart_vehicle_interface` is based on it**, and generates its CAN
   bindings from the same `CAX_ADS_CAN.dbc` at build time.
5. **A full test suite sits on top**, in `control_test`, built on a modified
   Autoware manual control (`NEWSLabNTU/autoware_manual_control`, forked from
   `evshary/autoware_manual_control`).

That is a good story for the deck: vendor script → hardened with our safety
rules → driven → productionised into the interface → covered by a test suite.
Each step is a thing that exists in the repo, not a claim.

## The test suite

`src/vehicle/control_test/` drives `golfcart_vehicle_interface` through Autoware
command topics:

- `keyboard_control` — Tkinter GUI manual control, arrow keys to `Control` and
  `GearCommand`, live readout from `/vehicle/status/*`; speed and steering steps,
  limits (`max_speed_ms`, `max_steer_deg 22.5`) in config
- `control_command_service` — service-driven publisher
- `trajectory_player` — open-loop trajectory replay, with `straight_10m.yaml`
  and `circle.yaml` supplied

**The engage workflow is the part worth showing**, because it is where the VCU
state machine meets our side:

> Golf Cart has no `vehicle_cmd_gate` external selector. The driver switches the
> vehicle to autonomous on its own controls; `golfcart_vehicle_interface`
> commands nothing until all four VCU subsystem states (MTR, BRK, EPS, Drv)
> report autonomous — **no service call can force it**.

## What the bench is

A **virtual ADS**: it sends the four `RX_ADS_VCU_*` messages the VCU expects from
an autonomous driving system, decodes the four `TX_VCU_ADS_*` messages it sends
back, and shows both sides live in a keyboard-driven terminal dashboard.

```
Roots_ipc_can_test.py   simulator + dashboard, 100 Hz on can0
vcu_state_probe.py      state diagnosis: passive / hold / stimulus sweep
keydump.py              what bytes a terminal sends for a keypress
dbc_decode.py           cantools wrapper, encode/decode by name
CAX_ADS_CAN.dbc         message and signal definitions — single source of truth
```

Message ids, frame format and units all come from the DBC at start-up; no
hard-coded ids, and every signal in those eight messages is decoded and displayed
without per-signal code. Adding a signal to the DBC makes it appear.

Worth noting for the deck: this is the same `CAX_ADS_CAN.dbc` that
`golfcart_vehicle_interface` generates its CAN bindings from at build time.

## The finding that matters

**After a VCU restart, `Vcu_Ads_Brake_State` and `Vcu_Ads_Driving_State` come up
`Invalid`, and only a brake-pedal press moves them to `Manual`.**

Measured on the live bus, not inferred from the DBC:

- **MTR and EPS** leave `Invalid` on the *mere presence* of ADS frames. Content is
  irrelevant — `Ads_Vcu_Ads_Status`, the rolling counter and `Veh_Auto_En` change
  nothing. Once set they latch, and survive the ADS going silent.
- **BRK and Drv** ignored every signalling-level stimulus and every enable bit
  (`Brk_En` with mode 0 / stroke / pressure). In one run they flipped to `Manual`
  0.14 s after idle frames resumed; in an earlier run 16 s of the same frames
  left them `Invalid`. So a further precondition exists — cumulative ADS
  presence, a post-boot timer, or the pedal press — and it was **not reproducible
  from the CAN side alone**.
- `Drv` always tracked `BRK`; they never disagreed.
- Brake feedback reads `Brake_Stroke = 255`, `Brake_Pressure = 12.75` — the DBC's
  documented *invalid* markers — in both `Invalid` and `Manual` states, so brake
  state is not derived from those sensor values.
- Unexplained: at some stimulus switches all four states blink `Invalid` for
  ~40 ms while `0x100` reports `stroke=0 pressure=0.00` instead of the usual
  invalid markers. Possibly a second node transmitting `0x100`, possibly a VCU
  re-init.

## Why this belongs on a slide

**It is a blocker for the autonomous run, and it is not ours to fix.**

Quoting the bench README: *"what exactly clears the `Invalid` brake state after a
restart? If a pedal press is genuinely required, unattended autonomous start-up
is blocked, and no ADS-side CAN message can work around it."*

That is a clean, honest status for step 5 of the bring-up sequence: the ADS side
is built and exercised against the real VCU, and the remaining gap is a vendor
question about VCU state entry — not more software on our side.

## Corroboration from the NTU runs

The August recordings agree with the bench. In the replayed diagnostics the
vehicle interface reports all four subsystems in `Manual`:

```
vehicle_mode: Manual
subsystem_states: mtr=Manual brk=Manual eps=Manual drv=Manual
fault_latched: true
driver_estop: false
speed_mps: 0.000
```

So during those runs the states *had* reached `Manual` — consistent with a pedal
press having happened during a manual drive — while `fault_latched: true` says
engage would still be refused until a MANUAL / NO_COMMAND request. Worth
confirming with whoever drove.

Also observed in those bags, and worth checking against the DBC before claiming
anything: `VelocityReport.heading_rate` and `lateral_velocity` are always 0, so
the VCU reports longitudinal speed only. Localization does not need them — the
IMU supplies yaw rate — but it is a gap worth knowing.

## Safety details the bench encodes

Two rules are built into the simulator's keys and are worth a line if the slide
covers testing:

- **Speed is never negative.** `Ads_Vcu_Target_Speed` clamps at 0; a negative
  target upsets the VCU. Reverse is gear `R`, not negative speed.
- **Gear P pins speed and angle to 0**, re-applied every cycle so nothing can
  leak onto the bus. P is the start-up gear.

The ESTOP release key is terminal-dependent — VTE terminals cannot distinguish
`SHIFT+SPACE` from `SPACE`, so the bench probes the terminal and falls back to
`CTRL+SPACE`, "so ESTOP is never a state you cannot leave."
