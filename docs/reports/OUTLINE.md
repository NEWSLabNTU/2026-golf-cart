# Progress deck — proposed organisation

Audience: **Autoware LSV meeting**. They know Autoware. Do not explain the
architecture, the launch system or NDT. Spend the time on what is specific to
this vehicle and on what transfers to other low-speed vehicles.

Shape: **overview with status first**, then depth per topic.

---

## Part 0 — Frame (3 slides)

| # | Slide | Content | Asset |
|---|---|---|---|
| 1 | Title | Golf Cart progress · NEWSLab NTU | — |
| 2 | The vehicle | What it is, where it runs, who drives it | `vehicle_blvd_init.jpg` |
| 3 | **Progress overview** | The wiring diagram **plus a status badge per block** — one picture answering "what exists and what works" | `sensor_wiring.png` |

Slide 3 is the spine of the talk. Everything after it is a zoom-in.

---

## Part 1 — Sensors  ⟨status: proposed READY, with caveats⟩

| # | Slide | Content | Asset |
|---|---|---|---|
| 4 | Sensor set | VLP-32C, Falcon, 3× GMSL, ZED X, u-blox, IMU — and which host each lives on | (reuse wiring, dimmed) |
| 5 | **oToCam: the overlay costs you the USB ports** | IMX390 + MAX9296; vendor `.ko` + DT overlay; enabling the overlay kills USB. Declarative fix in `scripts/hardware/otocam/`. ABI-bound to kernel `5.15.148-tegra`; a JetPack OTA silently reverts it | — |
| 6 | **oToCam: a conversion with no GPU element** | Cameras emit UYVY, consumers want RGB/JPEG, no GPU GStreamer element found to convert → CPU `videoconvert`, once per camera, 3 × 1920×1280 × 30 fps. `gmslcam` is the planned fix | — |
| 7 | IMU reality | Xsens MTi on CAN is not working → the stack runs on the **ZED X built-in IMU**, which lives on the other machine and crosses the DDS link at 100 Hz | (wiring, IMU path highlighted) |
| 7b | **Why the GNSS is on the other machine** | Five USB devices, fewer ports: keyboard, mouse, phone tethering for internet, external disk (the eMMC is too small), and the u-blox. The GNSS lost. A second localization input now crosses the wifi link, and neither is remote by design | (wiring, GNSS path highlighted) |

**LSV relevance:** GMSL camera bring-up on Jetson is a shared pain. The overlay/USB
tradeoff and the missing GPU colour-conversion path are both reusable warnings.

Slide 7b is the one nobody else will present: the compute box is also the
development workstation, the internet gateway and the data logger, and those
roles compete with the sensors for physical ports. That is a real constraint on a
research vehicle and it decided a piece of the architecture. Keep it separate
from slide 5 — the overlay's USB problem and the port shortage are two different
things, and merging them makes a claim the team has not made.

---

## Part 2 — System: multi-host  ⟨status: proposed READY⟩

| # | Slide | Content | Asset |
|---|---|---|---|
| 8 | Why two machines | Compute limit, driver conflict (shared kernel module name), ZEDLink only works on Orin | `thermal_fan_cooling.jpg` |
| 9 | What ROS 2 does not give you | ROS 1 had `machine` tags; ROS 2 dropped them. Non-standard RMW. Orchestration is the user's problem | — |
| 10 | How we launch | `host:=` argument, systemd user units, cgroup jail, watchdog on the Orin | `multihost_launch_diagram.png` |
| 11 | **Startup governor** | 144 processes at once can kill the host. Pacing was implemented, measured, **rejected** (10.6 s → 23.8 s for ~10% fewer runnable tasks). What ships is a 1 GiB `MemAvailable` floor | `htop_before_governor.jpg` |

**LSV relevance:** the strongest transferable content in the deck. Multi-host is a
real ROS 2 gap, and the governor is a negative result other people would
otherwise re-derive.

---

## Part 3 — Vehicle interface: VCU  ⟨status: proposed IN PROGRESS⟩

| # | Slide | Content | Asset |
|---|---|---|---|
| 12 | **How it was built** | Turing Drive script → our safety measures → drove the vehicle → `golfcart_vehicle_interface` → test suite. Each step exists in the repo | — |
| 13 | Safety measures we added | Speed never negative; gear P pins speed/angle every cycle; ESTOP release never unreachable | — |
| 14 | Test suite | `keyboard_control`, `control_command_service`, `trajectory_player` (straight 10 m, circle), on modified Autoware manual control | — |
| 15 | **Engage: the VCU decides** | No `vehicle_cmd_gate` external selector. The interface commands nothing until all four VCU states report autonomous — no service call can force it | — |
| 16 | **The blocker** | After a VCU restart, BRK and Drv come up `Invalid`; only a pedal press was observed to clear them. Not reproducible from CAN. **Unattended autonomous start-up is blocked** — a vendor question | — |
| 17 | CAN wiring | Broken connector, remake with plastic-coated cable, RS232 connector change | `can_connector_broken.jpg`, `can_wire_remake.jpg` |

**LSV relevance:** what integrating a third-party VCU actually costs. The
"state entry we cannot trigger" problem is common and rarely written down.

---

## Part 4 — Data collection run  ⟨status: proposed DONE, data flawed⟩

| # | Slide | Content | Asset |
|---|---|---|---|
| 18 | The NTU runs | 3 sets (CSIE-1, CSIE-2, BLVD-1), two hosts recording separately, merged; merged r01+r02 map, 6.6 M points, MGRS 51RUH | `vehicle_csie_init.jpg` |
| 19 | Replay in one command | `just ntu-test run` — bag paused for `/clock`, stack, RViz, pose, in the only order that works | — |

---

## Part 5 — Localization: NDT  ⟨status: proposed IN PROGRESS⟩

| # | Slide | Content | Asset |
|---|---|---|---|
| 20 | **Measure alignment, not the score** | Ranked on scan-to-map residual, not NVTL. NVTL is a mean per-point score that moves with sampling — the change that improved accuracy most *lowered* it | — |
| 21 | Tuning: the crop range | ±20 m (inherited) → ±60 m: p95 1.661 → 0.469 m. Voxel 0.5 kept (stock 3.0 is far worse). Gate re-derived, and it is not portable | — |
| 22 | Where tracking breaks | Converges at 0.14 m parked; degrades 3.5 s after motion starts, not at the turn. Iterations cap first, score lags ~50 s | `ndt_slide_chart.png` |
| 23 | **Root cause is the recording** | 45% of scans are 162° fragments spanning 2.1 ms; scans arrive 376 ms stale. No raw packets recorded, so the bags cannot be re-decoded | — |

**LSV relevance:** the methodology point — an independent metric caught a sensor
defect that tuning would have chased forever.

---

## Part 6 — Close (2 slides)

| # | Slide | Content |
|---|---|---|
| 24 | **Status board** | The five steps with ready / in-progress, and the one blocker per step |
| 25 | Next | Record raw Velodyne packets · check VLP-32C rotation config · VCU state entry with the vendor · gmslcam migration |

Total ≈ 25 slides. Trim Part 1 or Part 4 first if it needs to be shorter.

---

## Proposed statuses — CONFIRM BEFORE BUILDING

Inferred from the repo, not from anyone's judgement. Correct these.

| Step | Proposed | Basis | Caveat |
|---|---|---|---|
| Sensors | **ready** | all publish, recorded in bags | VLP-32C scan fragmentation; Xsens dead; gmslcam pending |
| System (multi-host) | **ready** | units on both hosts, cgroup cleanup, watchdog, governor | — |
| Vehicle interface | **in progress** | interface + test suite exist, vehicle driven from it | VCU state entry blocks unattended engage |
| Data collection | **done** | 3 sets recorded and replayable | data has the fragmentation and latency defects |
| Autonomous run | **not started** | no evidence in repo | gated on the VCU blocker |

Confirmed 2026-08-19: **Falcon working. u-blox working, but moved to the Orin**
because the Advantech has no free USB port — keyboard, mouse, phone tethering,
and an external disk (the eMMC is too small) take them all. Nothing to do with the
oToCam overlay; see `notes-usb-ports.md`. Diagram updated.

**Mismatch this exposes, and it is not cosmetic.** The software still places the
GNSS on the master:

- `golfcart.launch.yaml` host profile: `orin -> ZED camera only`, master gets
  everything else — so on the Orin the u-blox driver is never started.
- `config/recording/master_topics.txt` lists `/sensing/gnss/*`;
  `orin_topics.txt` lists no GNSS at all — so the host without the device is the
  one told to record it, against this repo's own first-hand-topics rule.

Neither is a deck problem, but both are real and should be fixed before the next
recording run, or the GNSS is silently absent from it. Say the word and I will.

## Deliberately out

TSN — moved to `tsn_setup.typ`. Future work, not a bring-up step. Mention in one
line on the Next slide if asked.
