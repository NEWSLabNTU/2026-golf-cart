# The VCU speed report: km/h, whole steps, no sign

Measured 2026-10-28 on the cart, Ming-Da basement, with the vehicle interface
running. Closes roadmap item **L5** (wheel speed scale and reverse sign) for the
VCU's own report; what it leaves open is at the end.

## What the VCU sends

`TX_VCU_ADS_MTR` (0x101, 100 Hz) carries `Vcu_Ads_Vehicle_Speed`, bytes 3 and 4,
little-endian signed, factor 0.001, declared **m/s** in `CAX_ADS_CAN.dbc`. Three
things are wrong with reading it as that:

| What | Evidence |
|---|---|
| **The unit is km/h.** | The dashboard showed 5 km/h when the report read 5.000. Read as m/s that is 18 km/h, which this cart never did. |
| **It is whole km/h, floored, and each value is 0.001 short.** | In `drive_20261028_185446.log` (43 s) the field takes only 0, 0.999, 1.999, 2.999, 3.999 and 5.000. Nothing between, in either direction. |
| **It has no sign.** | The same log, gear Reverse (raw 3), 21 to 43 s: +0.999, +1.999, +2.999. The interface published that unchanged, so Autoware was told the cart reversed forward. |

CAN IDs on the bus: 0x100 brake, 0x101 motor (gear in the low bits of byte 2,
speed in bytes 3-4), 0x102 steering, 0x103 vehicle (byte 0 is the rolling
counter). Gear raw values: 0 Parking, 1 Drive, 2 Neutral, 3 Reverse. Autoware's
`GearReport` numbering (Neutral 1, Drive 2, Reverse 20, Park 22) is the
interface's mapping of those and is not the raw field.

**A capture is only valid with the interface running.** The VCU repeats a frozen
frame (counter stuck, speed 0) when it does not hear our rolling counter.
`drive_20261028_185240.log` is one of those, and says nothing about motion. Check
for our command IDs (0x065, 0x068, 0x075, 0x43F) beside 0x100 to 0x103 before
trusting a log.

## How it was checked against the truth

NDT is independent of the speed report, so it is the reference. Two bags, EKF
`map->base_link` and NDT `map->ndt_base_link` against `/vehicle/status/velocity_status`:

* Reported against NDT-derived speed, floored report: Drive 0.42 against 0.52 m/s,
  Reverse 0.28 against 0.42 m/s. That is 19% and 34% low.
* The mean loss of flooring is half a step, 0.5 km/h = 0.14 m/s. Adding it back
  gives Drive 0.56 and Reverse 0.42 against 0.52 and 0.42.
* Integrated, the floored report gave 2.12 m against NDT's 2.80 m (Drive) and
  1.56 m against 2.63 m (Reverse).
* Consequence while moving: the EKF trails NDT by about **0.20 m** (0.20 m at
  0.28 m/s, 0.22 m at 0.55 m/s, so a bias and not a delay). Stopped, the two agree
  to 0.03 m. RViz places the live scan with the EKF pose, so the scan looks
  displaced from the map by that much when you drive.
* Localization itself was never wrong in these runs: the pose moved along its
  heading in Drive and against it in Reverse, EKF and NDT agreeing within 0.1 m.

## The fix (`golfcart_vehicle_launch` 4a8025a, then the midpoint commit)

All in `golfcart_vehicle_interface`; every consumer goes through one helper so
none can disagree.

1. `dbc::vcu_speed_mps` converts km/h to m/s (divide by 3.6). It feeds the
   published `VelocityReport`, its derived yaw rate, the `speed_mps` diagnostics
   value, and the TX-side gear-shift and steering-rate gates, which had been
   comparing a km/h number against m/s thresholds.
2. `node::signed_speed` makes the speed negative in Reverse, from the gear. A
   speed the VCU already signs negative is left alone.
3. `dbc::midpoint_of_floored_kmh` adds half a step back to a reading that sits on
   a whole number (within 0.002 km/h): 0.999 reports as 1.5 km/h. Zero stays zero.
   It switches itself off for any reading that is not a whole step, so a vendor
   change to finer resolution is not corrupted.
4. `mock_vcu` emits km/h, unsigned, so the bench matches the real VCU.

Cargo tests cover all of it (70 + 6 in the crate).

## What is still true

* **Resolution is 1 km/h (0.28 m/s).** Anything below 1 km/h reads zero. The EKF
  sees 0, 0.28, 0.56 and so on; NDT at 10 Hz carries the rest.
* **The midpoint correction is not yet driven on the cart.** The first two items
  were (4a8025a, verified in bags `190547` and `192241`). Compare the EKF-minus-NDT
  offset before and after: it should fall from about 0.2 m toward 0.05 m.
* **The VCU's steering report is a separate problem** (frozen in manual, reads 0
  for left turns, live only in AUTO and only for right turns; vendor). See the
  2026-10-28 handover, open item 1.
* Ask the vendor how the speed signal is meant to be scaled and whether finer
  steps exist. Everything above is measured, not specified.

## Reproducing

```bash
# on the orin, with the interface running
mkdir -p ~/can && candump -L -td can0 > ~/can/drive_$(date +%Y%m%d_%H%M%S).log
# decode: byte 2 & 3 = gear raw, bytes 3-4 little-endian signed * 0.001 = speed
python3 - <<'PY'
import glob
f = sorted(glob.glob('/home/jetson/can/drive_*.log'))[-1]
for line in open(f):
    p = line.split()
    if p[2].startswith('101#'):
        b = bytes.fromhex(p[2][4:])
        print(p[0], 'gear', b[2] & 3, 'speed',
              int.from_bytes(b[3:5], 'little', signed=True) * 0.001)
PY
```
`just can vcu-status --once` is the receive-only live readout. Record bags with
`just record start` / `just record stop` (the master list now includes the NVTL
score), and compare `/localization/pose_estimator/pose` against
`/vehicle/status/velocity_status`.
