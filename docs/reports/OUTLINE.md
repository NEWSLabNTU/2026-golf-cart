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
| 4 | Sensors: what bit us | bullets | oToCam DT overlay · UYVY→JPEG on CPU · Xsens dead, running on the ZED IMU · GNSS on the Orin, short of USB ports |
| 5 | Why two machines | `thermal_fan_cooling.jpg` | compute limit, driver conflict, ZEDLink is Orin-only |
| 6 | How we launch across two hosts | `multihost_launch_diagram.png` | ROS 2 has no `machine` tag; orchestration is ours |
| 7 | **Startup governor** | `htop_before_governor.jpg` | 144 processes can kill the host. Pacing measured and **rejected**; a 1 GiB `MemAvailable` floor ships |
| 8 | Vehicle interface: how it was built | `vcu_lineage.png` | vendor script → our safety rules → drove it → interface → test suite |
| 9 | **Engage, and the blocker** | `vcu_states.png` | the VCU decides. BRK/Drv leave `Invalid` only on a pedal press — not reproducible from CAN, so unattended start-up is blocked |
| 10 | Data collection | `vehicle_csie_init.jpg` | 3 NTU runs, two hosts, merged; replay in one command |
| 11 | NDT: where tracking breaks | `ndt_slide_chart.png` | converges parked, degrades 3.5 s after motion |
| 12 | NDT: root cause is the recording | bullets | 45% of scans are 162° fragments over 2.1 ms; 376 ms stale; no raw packets recorded |
| 13 | **Status board** | table | the five steps, ready / in progress, one blocker each |
| 14 | Next | bullets | raw packets · VLP-32C rotation config · VCU state entry with the vendor · gmslcam |

## What the LSV room takes away

Three things, and the deck should not dilute them:

1. **Multi-host is a real ROS 2 gap** (6) — ROS 1 had `machine` tags, ROS 2 has
   nothing, and everyone deploying more than one box hits it.
2. **The startup governor is a negative result** (7) — implemented, measured,
   rejected. Worth saying out loud so nobody re-derives it.
3. **An independent metric caught a sensor defect** (11–12) — ranking on
   scan-to-map residual rather than NVTL is what found the fragmentation.

## Cut, and where it went

Held in the notes for questions, not on a slide:

- TSN — `tsn_setup.typ`, a separate deck. Future work.
- oToCam mechanics — `notes-otocam.md`. Slide 4 gets one line.
- USB port budget — `notes-usb-ports.md`. Slide 4 gets one line: *short of ports*.
- VCU bench detail, safety rules, test suite inventory — `notes-vcu.md`.
- NDT crop-range tuning numbers — the tuning doc. Slide 11 shows the outcome.

## Statuses — CONFIRM BEFORE BUILDING

Slide 3 and slide 13 both depend on these. Inferred from the repo; correct them.

| Step | Proposed | Blocker |
|---|---|---|
| Sensors | ready | scan fragmentation; Xsens dead |
| System (multi-host) | ready | — |
| Vehicle interface | in progress | VCU state entry |
| Data collection | done | data carries the sensor defects |
| Autonomous run | not started | gated on the VCU blocker |
