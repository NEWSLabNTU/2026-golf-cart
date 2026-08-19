# Progress deck — organisation

**30 minutes. 14 slides. ~2 minutes each.**

> Both landed: map preparation is the fourth of **six** steps, and 華夏科大 is
> not named anywhere. Slide 2 carries the six steps with a status chip each, so
> the wiring diagram on slide 3 no longer repeats them and gets the full page.

Audience: Autoware LSV meeting. They know Autoware — explain nothing about the
architecture, the launch system or NDT. Spend the time on this vehicle.

Rules for building it:

- **A figure or a photo carries the slide** wherever one exists.
- **Where none exists, short bullets and prose.** Not paragraphs.
- **No diagram for a detail a sentence covers.** Micro-facts are bullets.
- Anything that needs a second look belongs in the backup, not the run.

---

## The 14

| # | Slide | Carried by |
|---|---|---|
| | **what works** | |
| 1 | Title | template band, logos |
| 2 | Vehicle platform, and the six steps | `vehicle_blvd_init.jpg` + status chips |
| 3 | System architecture | `sensor_wiring.png`, full page |
| 4 | Sensor integration | table: sensor, host, what it feeds |
| 5 | Multi-host orchestration | play_launch + systemd, DDS + host marker |
| 6 | Vehicle interface | `vcu_lineage.png` |
| 7 | Data acquisition | `vehicle_csie_init.jpg` |
| | **what needs fixing** | |
| 8 | Integration findings | oToCam video-or-USB and our workaround, Xsens cable, GNSS on the Orin |
| 9 | Compute and thermal limits | `thermal_fan_cooling.jpg`, UYVY on CPU |
| 10 | Start-up contention | `htop_before_governor.jpg` |
| 11 | Autonomous engagement and VCU state entry | `vcu_states.png` |
| 12 | NDT localization | `ndt_run_still.png`, from the run clip |
| | **close** | |
| 13 | Bring-up status | table |
| 14 | Next steps | bullets |

**The order is the point.** Achievement first, caveats second. Do not move a
problem up into slides 2 to 7 "for context": the room should hear what runs
before it hears what is wrong with it. Slide 8 is where the tone turns, and it
turns once.

Two arcs survive the split and should still be said out loud:

- slide 5 sells play_launch's speed, and **slide 10 collects the bill for it**.
  The governor is not a separate hardening job; it is what that speed cost.
- slide 9's per-camera CPU conversion is one reason the box is at its limit,
  which is one reason there are two machines at all.

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
- NDT crop-range tuning numbers, and `ndt_slide_chart.png` itself. Slide 12
  used to carry the chart; it now carries a frame from the run, which shows the
  scan aligned to the map and is what the room actually wants to see. The chart
  stays in assets/ for questions.

**A PDF cannot animate a GIF.** `data/captures/ndt_run.gif` and `ndt_run.mp4`
are the 2x clip of 02:20 to 03:20, cropped to the RViz 3D view. The slide shows
a still from it. To present the motion, insert the GIF into PowerPoint or open
the deck in a browser; the PDF will only ever show the first frame. The clip is
16 MB and lives with the source recording rather than in the repository.

## Statuses — CONFIRM BEFORE BUILDING

Slide 3 and slide 13 both depend on these. Inferred from the repo; correct them.

| Step | Proposed | Blocker |
|---|---|---|
| Sensors | ready | scan fragmentation; Xsens cable being remade |
| Two-host system | ready | none |
| Vehicle interface | in progress | VCU state entry |
| Map preparation | ready | none |
| Data collection | done, data flawed | data carries the sensor defects |
| Autonomous run | not started | gated on the VCU blocker |
