# Progress deck — organisation

**30 minutes. 14 slides. ~2 minutes each.**

Audience: Autoware LSV meeting. They know Autoware — explain nothing about the
architecture, the launch system or NDT. Spend the time on this vehicle.

Rules for building it:

- **A figure or a photo carries the slide** wherever one exists.
- **Where none exists, short bullets and prose.** Not paragraphs.
- **No diagram for a detail a sentence covers.** Micro-facts are bullets.
- Anything that needs a second look belongs in the backup, not the run.

---

## The 14

| # | Slide | Carried by | Notes |
|---|---|---|---|
| 1 | Title | — | |
| 2 | The vehicle | `vehicle_blvd_init.jpg` | what it is, where it runs |
| 3 | **Progress overview** | `sensor_wiring.png` + status badges | **the spine** — what exists, what works |
| 4 | Sensors: what bit us | bullets | oToCam DT overlay, ABI-bound to the kernel · Xsens dead, running on the ZED IMU · GNSS on the Orin, short of USB ports |
| 5 | **GMSL cameras cost CPU** | bullets | cameras emit UYVY at 3 × 1920×1280 @ 30 fps, consumers want RGB/JPEG. We tried `nvvidconv`; the conversion still costs CPU per camera. `gmslcam` is the fix |
| 6 | The machine is at its limit | `thermal_fan_cooling.jpg` | slide 5 is one reason. Hence two machines: compute, driver conflict, ZEDLink is Orin-only |
| 7 | Launching across two hosts | `multihost_launch_diagram.png` | ROS 2 has no `machine` tag; orchestration is ours |
| 8 | **Startup governor** | `htop_before_governor.jpg` | 144 processes can kill the host. Pacing measured and **rejected**; a 1 GiB `MemAvailable` floor ships |
| 9 | Vehicle interface: how it was built | `vcu_lineage.png` | vendor script → our safety rules → drove it → interface → test suite |
| 10 | **Engage, and the blocker** | `vcu_states.png` | the VCU decides. BRK/Drv leave `Invalid` only on a pedal press — not reproducible from CAN, so unattended start-up is blocked |
| 11 | Data collection | `vehicle_csie_init.jpg` | 3 NTU runs, two hosts, merged; replay in one command |
| 12 | **NDT: attempted, and it breaks** | `ndt_slide_chart.png` | one page. Tuned it, converges parked, degrades once moving. Root cause is the recording — fragmented scans, stale by 376 ms, no raw packets to re-decode |
| 13 | **Status board** | table | the five steps, ready / in progress, one blocker each |
| 14 | Next | bullets | raw packets · VCU state entry with the vendor · gmslcam |

**Slides 5 → 6 → 8 are one argument, in order:** a per-camera CPU colour
conversion is part of why the box runs hot, which is part of why there are two
machines, and 144 processes starting at once on a box already at its limit is
what the governor exists for. Do not let them drift apart in the file.

## What the LSV room takes away

Three things, and the deck should not dilute them:

1. **Multi-host is a real ROS 2 gap** (6) — ROS 1 had `machine` tags, ROS 2 has
   nothing, and everyone deploying more than one box hits it.
2. **The startup governor is a negative result** (7) — implemented, measured,
   rejected. Worth saying out loud so nobody re-derives it.
3. **An independent metric caught a sensor defect** (12) — ranking on
   scan-to-map residual rather than NVTL is what found the fragmentation. One
   slide: we tuned it, it still breaks, and the cause is upstream of NDT.

## Cut, and where it went

Held in the notes for questions, not on a slide:

- TSN — `tsn_setup.typ`, a separate deck. Future work.
- oToCam mechanics — `notes-otocam.md`. Slide 4 gets one line.
- Which GStreamer element refused UYVY — `notes-otocam.md`. `nvvidconv` was
  tried and can be named. But the committed camera configs show an all-GPU
  pipeline with no CPU `videoconvert` in it, so do not put a CPU figure or an
  element count on the slide until that is reconciled.
- USB port budget — `notes-usb-ports.md`. Slide 4 gets one line: *short of ports*.
- VCU bench detail, safety rules, test suite inventory — `notes-vcu.md`.
- NDT crop-range tuning numbers and the NVTL-versus-residual argument — the
  tuning doc. Slide 12 shows the outcome only.

## Statuses — CONFIRM BEFORE BUILDING

Slide 3 and slide 13 both depend on these. Inferred from the repo; correct them.

| Step | Proposed | Blocker |
|---|---|---|
| Sensors | ready | scan fragmentation; Xsens dead |
| System (multi-host) | ready | — |
| Vehicle interface | in progress | VCU state entry |
| Data collection | done | data carries the sensor defects |
| Autonomous run | not started | gated on the VCU blocker |
