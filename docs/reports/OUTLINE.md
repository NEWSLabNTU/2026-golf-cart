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
| 7 | Launching across two hosts | `multihost_launch_diagram.png` | two problems, two answers — see below |
| 8 | **Startup governor: the bill for slide 7** | `htop_before_governor.jpg` | the speed *is* the problem — spawning that fast bricks the machine. Pacing measured and **rejected**; a 1 GiB `MemAvailable` floor ships |
| 9 | Vehicle interface: how it was built | `vcu_lineage.png` | vendor script → our safety rules → drove it → interface → test suite |
| 10 | **Engage, and the blocker** | `vcu_states.png` | the VCU decides. BRK/Drv leave `Invalid` only on a pedal press — not reproducible from CAN, so unattended start-up is blocked |
| 11 | Data collection | `vehicle_csie_init.jpg` | 3 NTU runs, two hosts, merged; replay in one command |
| 12 | **NDT: attempted, and it breaks** | `ndt_slide_chart.png` | one page. Tuned it, converges parked, degrades once moving. Root cause is the recording — fragmented scans, stale by 376 ms, no raw packets to re-decode |
| 13 | **Status board** | table | the five steps, ready / in progress, one blocker each |
| 14 | Next | bullets | raw packets · VCU state entry with the vendor · gmslcam |

### Slide 7 — the two problems worth naming

ROS 2 dropped ROS 1's `machine` tag, so orchestration is ours. What that turns
into, concretely:

1. **One instance, and nothing left behind.** Two hosts make both failures worse:
   a second launch racing the first, and orphaned nodes surviving a crash and
   quietly poisoning the next run. Answered in two layers:

   - **play_launch**, inside each host — it cleans up orphans when the launch
     dies, and it starts the stack in **~20 s against ~60 s for `ros2 launch`**.
     A 3× cut on every iteration, on hardware where you re-launch all day.
     *Set this up as a win and leave it — slide 8 is the bill for it.*
   - **systemd user units**, around it — singleton by construction, and
     `KillMode=control-group` to take the whole tree down. `KillSignal=SIGINT`
     because play_launch ignores SIGTERM.

2. **CycloneDDS has to be configured on both sides, and then lived with.** One
   XML profile per role in `config/cyclonedds/`, and a `config/host` marker file
   naming the role — read by `scripts/env.sh`, which every shell and every unit
   sources, so a terminal on either box is correct the moment it opens.
   `.envrc` wires it into direnv. Units pass `GOLFCART_ENV_ROLE`, which outranks
   the marker, because a unit must not depend on a file someone can edit
   underneath it.

The second one is the unglamorous half and worth a sentence out loud: most of
the multi-host work was making the *terminal experience* not require anyone to
remember which machine they were on.

### Slides 7 → 8 — the turn

Do not present the governor as an unrelated hardening job. It is the direct
consequence of what slide 7 just sold:

> play_launch is fast **because** it starts nodes as fast as it can. On a box
> already at its limit, that is a thundering herd — every node initialising at
> once, and the machine locks up hard enough to need a power cycle. The htop
> photo is that moment.

That makes the rejected fix interesting rather than a footnote. **Pacing the
spawns is the obvious answer and we measured it losing:** roughly a 10% cut in
runnable tasks for more than double the startup time — which spends the exact
advantage that made play_launch worth adopting. What ships instead is a **1 GiB
`MemAvailable` floor**: it does nothing at all on a healthy boot and only holds
back when the machine is genuinely about to die.

The transferable line: *the speed is the feature and the failure mode; gate on
the resource that actually runs out, not on the rate.*

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
