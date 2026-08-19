// Golf Cart progress, for the Autoware LSV meeting, 30 minutes.
//
//   typst compile docs/reports/2026-08_golfcart_progress.typ
//
// Fourteen slides for a thirty-minute slot, about two minutes each. The rules
// this deck is built to, from docs/reports/OUTLINE.md:
//
//   - a figure or a photograph carries the slide wherever one exists
//   - where none exists, short bullets, never paragraphs
//   - no diagram for a detail a sentence covers
//
// The audience knows Autoware. Nothing here explains the architecture, the
// launch system or NDT; the time goes to what is specific to this vehicle.
//
// TSN lives in tsn_setup.typ. Detail cut from these slides is held in NOTES.md,
// notes-otocam.md, notes-usb-ports.md and notes-vcu.md for questions.

// Theme is lifted from the lab's own PowerPoint template
// (20251029_Progress.pptx): its colour scheme, its fonts, its blue title
// treatment with no rule beneath, and its logo furniture. The band image and
// the four logos are extracted from that file into assets/.
//
//   accent1 #4285F4   accent4 #FFAB40   accent5 #0097A7   lt2 #535353
//   major Helvetica, minor Arial

#let accent = rgb("#4285F4")
#let ink    = rgb("#000000")
#let muted  = rgb("#535353")
#let teal   = rgb("#0097A7")
#let amber  = rgb("#A85F00")
#let red    = rgb("#C5372C")

// Bottom furniture, on every slide but the title: our two lab marks on the
// left, the foundation on the right, exactly as the template places them.
#let furniture = context {
  if counter(page).get().first() > 1 {
    pad(x: 1.0cm, bottom: 0.15cm)[
      #grid(
        columns: (auto, auto, 1fr, auto), column-gutter: 0.5em,
        align: bottom + left,
        image("assets/logo_ntu.png", height: 0.44cm),
        image("assets/logo_newslab.png", height: 0.40cm),
        [],
        image("assets/logo_autoware_small.png", height: 0.46cm),
      )
    ]
  }
}

#set page(
  paper: "presentation-16-9",
  margin: (x: 2.0cm, top: 1.3cm, bottom: 1.9cm),
  footer: furniture,
  footer-descent: 0.5em,
)
#set text(font: ("Arial", "Liberation Sans", "DejaVu Sans"), size: 19pt,
          fill: ink)
#set par(justify: false, leading: 0.72em)

// The template's titles are blue, bold, and carry no rule under them.
#let slide(title, body) = {
  text(font: ("Helvetica", "Liberation Sans"), size: 27pt, weight: "bold",
       fill: accent)[#title]
  v(0.55em)
  set text(size: 17pt)
  body
  pagebreak(weak: true)
}

#let note(body) = text(size: 14pt, fill: muted)[#body]

// Status chip. Colour carries the state so the board reads at a glance.
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
  box(
    fill: fill, stroke: 0.8pt + stroke, radius: 3pt,
    inset: (x: 0.5em, y: 0.28em),
  )[#text(size: 13pt, fill: stroke, weight: "medium")[#label]]
}

// ── 1 ─────────────────────────────────────────────────────────────────────
#page(margin: 0pt, footer: none)[
  #let band = image("assets/theme_band.png", width: 100%, height: 3.15cm,
                    fit: "cover")
  #stack(dir: ttb, spacing: 0pt,
  band,
  block(width: 100%, height: 10.4cm, fill: white, inset: (x: 1.6cm, y: 0.9cm))[
    #grid(
      columns: (auto, 1fr), column-gutter: 1.6em, align: horizon,
      image("assets/logo_autoware.png", height: 3.0cm),
      [
        #text(font: ("Helvetica", "Liberation Sans"), size: 30pt,
              weight: "bold", fill: accent)[Golf Cart bring-up progress]
        #v(0.35em)
        #text(size: 19pt, weight: "bold")[National Taiwan University]
        #v(0.25em)
        #text(size: 15pt, fill: muted)[Autoware LSV meeting, August 2026]
      ],
    )
    #v(1fr)
    #grid(
      columns: (auto, auto), column-gutter: 0.6em, align: bottom + left,
      image("assets/logo_ntu.png", height: 0.62cm),
      image("assets/logo_newslab.png", height: 0.56cm),
    )
  ],
  band,
  )
]

// ── 2 ────────────────────────────────────────────────────────────────────────
#slide[The vehicle][
  #grid(
    columns: (1.35fr, 1fr), column-gutter: 1.1em,
    image("assets/vehicle_blvd_init.jpg", height: 9.4cm),
    [
      A low-speed campus vehicle on a #strong[Turing Drive VCU], with an
      Autoware stack across #strong[two machines].

      #v(0.5em)
      Bring-up in five steps:

      #v(0.3em)
      #note[
        sensors, two-host system, vehicle interface,
        data collection, autonomous run
      ]

      #v(0.7em)
      Running at NTU today.
    ],
  )
]

// ── 3 ────────────────────────────────────────────────────────────────────────
#slide[Where we are][
  #align(center)[#image("assets/sensor_wiring.png", height: 8.9cm)]
  #v(0.45em)
  #align(center)[#grid(
    columns: (auto, auto, auto, auto, auto),
    column-gutter: 0.75em, align: center,
    [#text(size: 12pt)[sensors] #h(0.3em) #chip("ready")],
    [#text(size: 12pt)[two-host] #h(0.3em) #chip("ready")],
    [#text(size: 12pt)[vehicle interface] #h(0.3em) #chip("wip")],
    [#text(size: 12pt)[data collection] #h(0.3em) #chip("flawed")],
    [#text(size: 12pt)[autonomous run] #h(0.3em) #chip("none")],
  )]
]

// ── 4 ────────────────────────────────────────────────────────────────────────
#slide[Sensors: what bit us][
  All sensors publish. Three things are worth knowing before you copy this.

  #v(0.6em)
  #set list(spacing: 1.0em)
  - *GMSL cameras need a vendor kernel module and a device tree overlay.*
    The `.ko` files are ABI-bound to kernel `5.15.148-tegra`, so a JetPack OTA
    reinstalls the stock modules and silently undoes it.

  - *The Xsens IMU cable broke, and is being remade.* Meanwhile the stack runs
    on the #strong[ZED X built-in IMU], which sits on the other machine and
    crosses the network at 100 Hz.

  - *The u-blox GNSS is on the Orin*, because the Advantech is short of USB
    ports. So a second localization input is remote too, for an unrelated reason.
]

// ── 5 ────────────────────────────────────────────────────────────────────────
#slide[GMSL cameras cost CPU][
  #set list(spacing: 0.9em)
  - Three cameras, #strong[1920×1280 at 30 fps], emitting #strong[UYVY].
  - The consuming nodes want #strong[RGB or JPEG]. Something must convert.
  - We tried #strong[`nvvidconv`]. The conversion still costs us CPU, per camera.

  #v(0.9em)
  #line(length: 100%, stroke: 0.6pt + accent.lighten(60%))
  #v(0.6em)

  A colour conversion per camera, always on, on a box that also carries two
  LiDARs and the whole Autoware stack.

  #v(0.5em)
  #note[
    Fix in progress: #link("https://github.com/newslabntu/gmslcam")[`gmslcam`],
    to take that stage out. The sensor kit migrates to it.
  ]
]

// ── 6 ────────────────────────────────────────────────────────────────────────
#slide[So the machine sits at its limit][
  #grid(
    columns: (1fr, 1.15fr), column-gutter: 1.1em,
    [
      #v(0.4em)
      This is a fan, held against the cabinet by hand, to keep the box running.

      #v(0.9em)
      Hence #strong[two machines]:

      #v(0.35em)
      #set list(spacing: 0.65em)
      #set text(size: 16pt)
      - compute headroom
      - a shared kernel module name the two camera stacks fight over
      - ZEDLink only works on the Orin

      #v(0.9em)
      #note[Splitting the load solved the thermals. It bought a distributed
      system in exchange.]
    ],
    image("assets/thermal_fan_cooling.jpg", height: 9.4cm),
  )
]

// ── 7 ────────────────────────────────────────────────────────────────────────
#slide[Launching across two hosts][
  ROS 2 dropped ROS 1's `machine` tag. Orchestration is ours. Two problems:

  #v(0.6em)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.4em,
    [
      *One instance, nothing left behind*

      #v(0.35em)
      #set text(size: 15pt)
      #set list(spacing: 0.55em)
      - #strong[play_launch] cleans up orphans when the launch dies, and starts
        the stack in #strong[~20 s] against #strong[~60 s] for `ros2 launch`
      - #strong[systemd user units] around it: singleton by construction,
        `KillMode=control-group` takes the whole tree down
    ],
    [
      *DDS configured on both sides, then lived with*

      #v(0.35em)
      #set text(size: 15pt)
      #set list(spacing: 0.55em)
      - one CycloneDDS profile per role, plus a `config/host` marker file
      - `scripts/env.sh` reads it, and every shell and every unit sources it
      - so a terminal on either box is correct the moment it opens. Nobody has
        to remember which machine they are on
    ],
  )
]

// ── 8 ────────────────────────────────────────────────────────────────────────
#slide[The bill for that speed][
  #grid(
    columns: (1.1fr, 1fr), column-gutter: 1.1em,
    image("assets/htop_before_governor.jpg", height: 6.8cm),
    [
      #set text(size: 14.5pt)
      play_launch is fast #emph[because] it spawns as fast as it can. On a box
      already at its limit, that is a thundering herd, and the machine locks up
      hard enough to need a power cycle.

      #v(0.6em)
      *Pacing the spawns is the obvious fix. We measured it losing:* about 10%
      fewer runnable tasks for more than double the startup time, spending the
      exact advantage we adopted the tool for.

      #v(0.6em)
      What ships is a #strong[1 GiB `MemAvailable` floor]. Nothing on a healthy
      boot; holds back only when the machine is about to die.

      #v(0.45em)
      #text(size: 13pt, fill: muted)[Gate on the resource that runs out, not on
      the rate.]
    ],
  )
]

// ── 9 ────────────────────────────────────────────────────────────────────────
#slide[Vehicle interface: how it was built][
  #grid(
    columns: (0.8fr, 1.25fr), column-gutter: 1.4em,
    align: (center, left),
    image("assets/vcu_lineage.png", height: 9.2cm),
    [
      #v(0.6em)
      Not written from a specification. Grown from the vendor's own test code,
      and every step exists in the repo.

      #v(0.9em)
      The safety rules are ours:

      #v(0.35em)
      #set text(size: 15.5pt)
      #set list(spacing: 0.6em)
      - target speed can never go negative, reverse is gear `R`
      - gear `P` pins speed and angle to zero, re-applied every cycle
      - ESTOP release is never a key the terminal cannot send

      #v(0.8em)
      #note[CAN bindings generate from the vendor DBC at build time, the same
      file the bench decodes with.]
    ],
  )
]

// ── 10 ───────────────────────────────────────────────────────────────────────
#slide[Engage is the VCU's decision, and one door we cannot open][
  #align(center)[#image("assets/vcu_states.png", width: 76%)]
  #v(0.55em)
  #set text(size: 14pt)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.4em,
    [
      There is no `vehicle_cmd_gate` external selector. The interface commands
      nothing until all four subsystems report autonomous. #strong[No service
      call can force it.]
    ],
    [
      After a VCU restart, #strong[BRK and Drv come up `Invalid`], and only a
      brake-pedal press was seen to clear them. Not reproducible from CAN.

      #v(0.4em)
      #text(fill: red)[*Unattended autonomous start-up is blocked.*] A vendor
      question, not more software on our side.
    ],
  )
]

// ── 11 ───────────────────────────────────────────────────────────────────────
#slide[Data collection][
  #grid(
    columns: (1.15fr, 1fr), column-gutter: 1.1em,
    image("assets/vehicle_csie_init.jpg", height: 8.6cm),
    [
      #set text(size: 15.5pt)
      Three runs at NTU. #strong[Both hosts record separately]: each writes the
      topics for the devices it owns, and the bags merge afterwards.

      #v(0.7em)
      Only #strong[first-hand driver output] is recorded. Anything a node
      computed is left out, so replay recomputes it with today's parameters
      rather than the ones frozen at record time.

      #v(0.7em)
      #note[Replay is one command: `just ntu-test run`. Bag paused for
      `/clock`, then stack, RViz, initial pose, in the only order that works.]
    ],
  )
]

// ── 12 ───────────────────────────────────────────────────────────────────────
#slide[NDT: tuned, and it still breaks][
  #grid(
    columns: (1.25fr, 1fr), column-gutter: 1.1em,
    image("assets/ndt_slide_chart.png", height: 7.6cm),
    [
      #set text(size: 14.5pt)
      We tuned it and measured it on #strong[scan-to-map residual], not on the
      NVTL score. The change that helped accuracy most actually *lowered* NVTL.

      #v(0.55em)
      It converges parked, to 0.14 m. It #strong[degrades a few seconds after
      the vehicle starts moving].

      #v(0.55em)
      *The cause is upstream of NDT, in the recording:* 45% of scans are
      fragments of a revolution, and scans arrive #strong[376 ms stale].

      #v(0.45em)
      #text(size: 13pt, fill: muted)[No raw LiDAR packets were recorded, so
      these bags cannot be re-decoded. Next run records them.]
    ],
  )
]

// ── 13 ───────────────────────────────────────────────────────────────────────
#slide[Status][
  #v(0.3em)
  #set text(size: 16pt)
  #table(
    columns: (auto, auto, 1fr),
    stroke: none,
    inset: (x: 0.5em, y: 0.7em),
    row-gutter: 0.1em,
    align: (left, left, left),

    [*Step*], [*State*], [*What stands in the way*],
    table.hline(stroke: 0.6pt + accent.lighten(50%)),

    [Sensors], [#chip("ready")],
    [fragmented LiDAR scans; the Xsens cable is being remade],

    [Two-host system], [#chip("ready")],
    [none],

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
  #set list(spacing: 1.0em)
  - *Ask Turing Drive what clears the `Invalid` brake state after a restart.*
    Everything else on the autonomous run waits behind this.

  - *Record raw LiDAR packets*, and check the VLP-32C rotation configuration
    against the hardware. Then re-run the localization work on data that is not
    already broken.

  - *Migrate the sensor kit to `gmslcam`*, and take the per-camera CPU
    conversion out.

  #v(0.8em)
  #note[TSN is a separate track, happy to cover it if there is interest.]
]
