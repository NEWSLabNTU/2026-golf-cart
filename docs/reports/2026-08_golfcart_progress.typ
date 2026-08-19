// Golf Cart bring-up progress, for the Autoware LSV meeting, 30 minutes.
//
//   typst compile docs/reports/2026-08_golfcart_progress.typ
//
// Fourteen slides for a thirty-minute slot, about two minutes each.
//
// ORDER: what works first, what needs fixing second. Slides 2 to 7 are the
// achievement; 8 to 12 are the problems and the follow-ups; 13 and 14 close.
// Do not fold a problem back into the first half to "give context" -- the point
// of the split is that the room hears the progress before the caveats.
//
// Content rules:
//   - a figure or a photograph carries the slide wherever one exists
//   - where none exists, short bullets, never paragraphs
//   - no diagram for a detail a sentence covers
//   - no em dashes, no middots: neither is on a keyboard
//
// The audience knows Autoware. Nothing here explains the architecture, the
// launch system or NDT; the time goes to what is specific to this vehicle.
//
// TSN lives in tsn_setup.typ. Detail cut from these slides is held in NOTES.md,
// notes-otocam.md, notes-usb-ports.md, notes-vcu.md and notes-map.md.
//
// GEOMETRY IS MEASURED FROM THE LAB TEMPLATE, 20251029_Progress.pptx, and the
// page is deliberately its size (25.4 x 14.2875 cm) so that every point size
// transfers one to one instead of being guessed at a different scale:
//
//   content title   48pt bold, accent1, at x 1.40cm y 0.24cm, no rule
//   body starts     y 2.99cm
//   title slide     title 25pt, subtitle 20pt, white band y 4.75 to 10.87
//   NTU logo        2.73 x 0.64 cm      NEWSLab logo   3.97 x 0.88 cm
//   Autoware logo   2.19 x 0.88 cm, and 8.34 x 3.21 cm on the title slide
//
// If the deck ever looks "not quite like the template", re-measure from the
// layout XML rather than nudging: that is where these numbers came from.
//
//   accent1 #4285F4   accent4 #FFAB40   accent5 #0097A7   lt2 #535353
//   major Helvetica, minor Arial

#let accent = rgb("#4285F4")
#let ink    = rgb("#000000")
#let muted  = rgb("#535353")
#let teal   = rgb("#0097A7")
#let amber  = rgb("#A85F00")   // darkened accent4, legible on white
#let red    = rgb("#C5372C")

// Logo furniture, at the template's own coordinates, on every slide but the
// title. Placed absolutely rather than laid out, because the template sets the
// three marks at three different heights.
#let furniture = context {
  if counter(page).get().first() > 1 {
    place(top + left, dx: 0.36cm, dy: 13.25cm,
          image("assets/logo_ntu.png", height: 0.64cm))
    place(top + left, dx: 3.31cm, dy: 13.13cm,
          image("assets/logo_newslab.png", width: 3.97cm))
    place(top + left, dx: 22.94cm, dy: 13.13cm,
          image("assets/logo_autoware_small.png", width: 2.19cm))
  }
}

#set page(
  width: 25.4cm, height: 14.2875cm,
  margin: (left: 1.40cm, right: 1.40cm, top: 0.24cm, bottom: 1.45cm),
  background: furniture,
)
#set text(font: ("Arial", "Liberation Sans", "DejaVu Sans"), size: 15pt,
          fill: ink)
#set par(justify: false, leading: 0.68em)

// Template titles are blue, bold, 48pt, and carry no rule under them.
#let slide(title, body) = {
  text(font: ("Helvetica", "Liberation Sans"), size: 48pt, weight: "bold",
       fill: accent)[#title]
  v(0.62cm)
  body
  pagebreak(weak: true)
}

// A tighter title, for the one heading that will not fit on a single line.
#let slide-sm(title, body) = {
  text(font: ("Helvetica", "Liberation Sans"), size: 32pt, weight: "bold",
       fill: accent)[#title]
  v(0.5cm)
  body
  pagebreak(weak: true)
}

#let note(body) = text(size: 12pt, fill: muted)[#body]

#let chip(state) = {
  let (fill, stroke, label) = if state == "ready" {
    (rgb("#E4F4F6"), teal, "ready")
  } else if state == "wip" {
    (rgb("#FFF6E8"), amber, "in progress")
  } else if state == "flawed" {
    (rgb("#FFF6E8"), amber, "done, data flawed")
  } else {
    (rgb("#FBE9E7"), red, "not started")
  }
  box(fill: fill, stroke: 0.8pt + stroke, radius: 3pt,
      inset: (x: 0.45em, y: 0.25em))[
    #text(size: 11pt, fill: stroke, weight: "medium")[#label]
  ]
}

// ── 1  title ─────────────────────────────────────────────────────────────────
#page(margin: 0pt, background: none)[
  #stack(dir: ttb, spacing: 0pt,
    image("assets/theme_band.png", width: 100%, height: 4.75cm, fit: "cover"),
    block(width: 100%, height: 6.12cm, fill: white)[
      #place(top + left, dx: 1.02cm, dy: 0.68cm,
             image("assets/logo_autoware.png", width: 8.34cm))
      #place(top + left, dx: 10.59cm, dy: 0.30cm)[
        #text(font: ("Helvetica", "Liberation Sans"), size: 25pt,
              weight: "bold", fill: accent)[Golf Cart bring-up progress]
        #v(0.30cm)
        #text(size: 20pt, weight: "bold")[National Taiwan University]
        #v(0.22cm)
        #text(size: 13pt, fill: muted)[Autoware LSV meeting, August 2026]
      ]
      #place(top + left, dx: 1.18cm, dy: 4.80cm,
             image("assets/logo_ntu.png", height: 0.64cm))
      #place(top + left, dx: 4.25cm, dy: 4.69cm,
             image("assets/logo_newslab.png", width: 3.97cm))
    ],
    image("assets/theme_band.png", width: 100%, height: 3.35cm, fit: "cover"),
  )
]

// ══ what works ═══════════════════════════════════════════════════════════════

// ── 2 ────────────────────────────────────────────────────────────────────────
#slide[The vehicle][
  #grid(
    columns: (1.3fr, 1fr), column-gutter: 1.0em,
    image("assets/vehicle_blvd_init.jpg", height: 7.4cm),
    [
      A low-speed campus vehicle on a #strong[Turing Drive VCU], with an
      Autoware stack across #strong[two machines].

      #v(0.5em)
      Bring-up in five steps:

      #v(0.25em)
      #note[
        sensors, two-host system, vehicle interface,
        data collection, autonomous run
      ]

      #v(0.6em)
      Running at NTU today.
    ],
  )
]

// ── 3 ────────────────────────────────────────────────────────────────────────
#slide[Where we are][
  #align(center)[#image("assets/sensor_wiring.png", height: 6.5cm)]
  #v(0.3em)
  #align(center)[#grid(
    columns: (auto, auto, auto, auto, auto),
    column-gutter: 0.7em, align: center,
    [#text(size: 11pt)[sensors] #h(0.25em) #chip("ready")],
    [#text(size: 11pt)[two-host] #h(0.25em) #chip("ready")],
    [#text(size: 11pt)[vehicle interface] #h(0.25em) #chip("wip")],
    [#text(size: 11pt)[data collection] #h(0.25em) #chip("flawed")],
    [#text(size: 11pt)[autonomous run] #h(0.25em) #chip("none")],
  )]
]

// ── 4 ────────────────────────────────────────────────────────────────────────
#slide[Sensors are up][
  Every sensor on the vehicle publishes, on both machines.

  #v(0.6em)
  #set text(size: 13.5pt)
  #table(
    columns: (auto, auto, 1fr),
    stroke: none, inset: (x: 0.4em, y: 0.38em), row-gutter: 0.05em,
    align: (left, left, left),
    [*Sensor*], [*Host*], [*Feeds*],
    table.hline(stroke: 0.6pt + accent.lighten(50%)),
    [Velodyne VLP-32C],   [Advantech], [NDT scan matching, perception],
    [Seyond Falcon],      [Advantech], [perception],
    [3 GMSL cameras],     [Advantech], [perception, recording],
    [ZED X stereo + IMU], [Orin],      [the IMU the stack runs on today],
    [u-blox GNSS],        [Orin],      [pose initialisation],
    [Turing Drive VCU],   [Advantech], [velocity, gear, subsystem states],
  )
]

// ── 5 ────────────────────────────────────────────────────────────────────────
#slide[Two machines, one stack][
  ROS 2 dropped ROS 1's `machine` tag, so orchestration is ours. It works.

  #v(0.55em)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.2em,
    [
      *One instance, nothing left behind*

      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.5em)
      - #strong[play_launch] cleans up orphans when the launch dies, and starts
        the stack in #strong[~20 s] against #strong[~60 s] for `ros2 launch`
      - #strong[systemd user units] around it: singleton by construction,
        `KillMode=control-group` takes the whole tree down
    ],
    [
      *One command, either machine*

      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.5em)
      - one CycloneDDS profile per role, plus a `config/host` marker file
      - `scripts/env.sh` reads it, and every shell and every unit sources it
      - so a terminal on either box is correct the moment it opens. Nobody has
        to remember which machine they are on
    ],
  )

  #v(0.6em)
  #note[`just launch-all` brings both hosts up and returns. `just stop-all`
  takes them down.]
]

// ── 6 ────────────────────────────────────────────────────────────────────────
#slide[The interface drives the cart][
  #grid(
    columns: (0.7fr, 1.3fr), column-gutter: 1.2em,
    align: (center, left),
    image("assets/vcu_lineage.png", height: 7.2cm),
    [
      #v(0.2em)
      Not written from a specification. Grown from the vendor's own test code,
      and every step exists in the repo.

      #v(0.6em)
      The safety rules are ours:

      #v(0.25em)
      #set text(size: 13pt)
      #set list(spacing: 0.45em)
      - target speed can never go negative, reverse is gear `R`
      - gear `P` pins speed and angle to zero, re-applied every cycle
      - ESTOP release is never a key the terminal cannot send

      #v(0.55em)
      #note[A test suite sits on top: keyboard control, a command service, and
      trajectory replay.]
    ],
  )
]

// ── 7 ────────────────────────────────────────────────────────────────────────
#slide[Data collection works][
  #grid(
    columns: (1.05fr, 1fr), column-gutter: 1.0em,
    image("assets/vehicle_csie_init.jpg", height: 7.2cm),
    [
      #v(0.1em)
      Three runs at NTU. #strong[Both hosts record separately]: each writes the
      topics for the devices it owns, and the bags merge afterwards.

      #v(0.55em)
      Only #strong[first-hand driver output] is recorded. Anything a node
      computed is left out, so replay recomputes it with today's parameters
      rather than the ones frozen at record time.

      #v(0.55em)
      #note[Replay is one command: `just ntu-test run`. Bag paused for
      `/clock`, then stack, RViz, initial pose, in the only order that works.]
    ],
  )
]

// ══ what needs fixing ════════════════════════════════════════════════════════

// ── 8 ────────────────────────────────────────────────────────────────────────
#slide[What bit us][
  Three things worth knowing before you copy this.

  #v(0.6em)
  #set list(spacing: 0.8em)
  - *GMSL cameras need a vendor kernel module and a device tree overlay.*
    The `.ko` files are ABI-bound to kernel `5.15.148-tegra`, so a JetPack OTA
    reinstalls the stock modules and silently undoes it.

  - *The Xsens IMU cable broke, and is being remade.* Meanwhile the stack runs
    on the #strong[ZED X built-in IMU], which sits on the other machine and
    crosses the network at 100 Hz.

  - *The u-blox GNSS is on the Orin*, because the Advantech is short of USB
    ports. So a second localization input is remote too, for an unrelated
    reason.
]

// ── 9 ────────────────────────────────────────────────────────────────────────
#slide[The machine is at its limit][
  #grid(
    columns: (1.25fr, 1fr), column-gutter: 1.0em,
    [
      #v(0.1em)
      The GMSL cameras emit #strong[UYVY] at 1920x1280, 30 fps, three of them.
      The consuming nodes want #strong[RGB or JPEG], so something must convert.
      We tried #strong[`nvvidconv`]. It still costs us CPU, per camera.

      #v(0.55em)
      That is one reason the box runs hot enough to need a fan held against it
      by hand, and one reason there are #strong[two machines] at all.

      #v(0.55em)
      #note[Fix in progress: #link("https://github.com/newslabntu/gmslcam")[`gmslcam`],
      to take that stage out.]
    ],
    image("assets/thermal_fan_cooling.jpg", height: 7.2cm),
  )
]

// ── 10 ───────────────────────────────────────────────────────────────────────
#slide[The bill for that speed][
  #grid(
    columns: (1.05fr, 1fr), column-gutter: 1.0em,
    image("assets/htop_before_governor.jpg", height: 6.2cm),
    [
      #set text(size: 12.5pt)
      play_launch is fast #emph[because] it spawns as fast as it can. On a box
      already at its limit, that is a thundering herd, and the machine locks up
      hard enough to need a power cycle.

      #v(0.45em)
      *Pacing the spawns is the obvious fix. We measured it losing:* about 10%
      fewer runnable tasks for more than double the startup time, spending the
      exact advantage we adopted the tool for.

      #v(0.45em)
      What ships is a #strong[1 GiB `MemAvailable` floor]. Nothing on a healthy
      boot; holds back only when the machine is about to die.

      #v(0.3em)
      #note[Gate on the resource that runs out, not on the rate.]
    ],
  )
]

// ── 11 ───────────────────────────────────────────────────────────────────────
#slide-sm[Engage is the VCU's decision, and one door we cannot open][
  #align(center)[#image("assets/vcu_states.png", width: 72%)]
  #v(0.45em)
  #set text(size: 12.5pt)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.2em,
    [
      There is no `vehicle_cmd_gate` external selector. The interface commands
      nothing until all four subsystems report autonomous. #strong[No service
      call can force it.]
    ],
    [
      After a VCU restart, #strong[BRK and Drv come up `Invalid`], and only a
      brake-pedal press was seen to clear them. Not reproducible from CAN.

      #v(0.3em)
      #text(fill: red)[*Unattended autonomous start-up is blocked.*] A vendor
      question, not more software on our side.
    ],
  )
]

// ── 12 ───────────────────────────────────────────────────────────────────────
#slide[NDT still breaks][
  #grid(
    columns: (1.2fr, 1fr), column-gutter: 1.0em,
    image("assets/ndt_slide_chart.png", height: 6.8cm),
    [
      #set text(size: 13pt)
      We tuned it and measured it on #strong[scan-to-map residual], not on the
      NVTL score. The change that helped accuracy most actually *lowered* NVTL.

      #v(0.45em)
      It converges parked, to 0.14 m. It #strong[degrades a few seconds after
      the vehicle starts moving].

      #v(0.45em)
      *The cause is upstream of NDT, in the recording:* 45% of scans are
      fragments of a revolution, and scans arrive #strong[376 ms stale].

      #v(0.35em)
      #note[No raw LiDAR packets were recorded, so these bags cannot be
      re-decoded. The next run records them.]
    ],
  )
]

// ══ close ════════════════════════════════════════════════════════════════════

// ── 13 ───────────────────────────────────────────────────────────────────────
#slide[Status][
  #v(0.1em)
  #set text(size: 13.5pt)
  #table(
    columns: (auto, auto, 1fr),
    stroke: none, inset: (x: 0.45em, y: 0.48em), row-gutter: 0.05em,
    align: (left, left, left),
    [*Step*], [*State*], [*What stands in the way*],
    table.hline(stroke: 0.6pt + accent.lighten(50%)),
    [Sensors], [#chip("ready")],
    [fragmented LiDAR scans; the Xsens cable is being remade],
    [Two-host system], [#chip("ready")], [none],
    [Vehicle interface], [#chip("wip")],
    [the VCU will not enter its autonomous state from CAN alone],
    [Data collection], [#chip("flawed")],
    [the bags carry the sensor defects above],
    [Autonomous run], [#chip("none")],
    [gated on the vehicle interface blocker],
  )
]

// ── 14 ───────────────────────────────────────────────────────────────────────
#slide[Next][
  #set list(spacing: 0.85em)
  - *Ask Turing Drive what clears the `Invalid` brake state after a restart.*
    Everything else on the autonomous run waits behind this.

  - *Record raw LiDAR packets*, and check the VLP-32C rotation configuration
    against the hardware. Then re-run the localization work on data that is not
    already broken.

  - *Migrate the sensor kit to `gmslcam`*, and take the per-camera CPU
    conversion out.

  #v(0.6em)
  #note[TSN is a separate track, happy to cover it if there is interest.]
]
