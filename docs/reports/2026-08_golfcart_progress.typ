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
#slide[Vehicle platform][
  #grid(
    columns: (1.3fr, 1fr), column-gutter: 1.0em,
    image("assets/vehicle_blvd_init.jpg", height: 7.4cm),
    [
      A low-speed campus vehicle on a #strong[Turing Drive VCU], with an
      Autoware stack across #strong[two machines].

      #v(0.5em)
      Bring-up sequence:

      #v(0.3em)
      #set text(size: 13pt)
      #grid(
        columns: (auto, auto), column-gutter: 0.6em, row-gutter: 0.42em,
        align: (left, left + horizon),
        [1. Sensors],            chip("ready"),
        [2. Two-host system],    chip("ready"),
        [3. Vehicle interface],  chip("wip"),
        [4. Map preparation],    chip("ready"),
        [5. Data collection],    chip("flawed"),
        [6. Autonomous run],     chip("none"),
      )
    ],
  )
]

// ── 3 ────────────────────────────────────────────────────────────────────────
#slide[System architecture][
  // The legend sits BESIDE the figure, not under it. The figure is about 2:1 on
  // a 2.3:1 hole, so there is spare width and no spare height; a legend under it
  // would have to come out of the figure's height, and the figure is scaled down
  // enough already. Legend text is Typst, so it stays at slide size while the
  // figure shrinks.
  #let key(fill, stroke, dash, label) = grid(
    columns: (auto, auto), column-gutter: 0.45em, align: horizon,
    box(width: 0.6cm, height: 0.33cm, radius: 2pt,
        fill: fill, stroke: (paint: stroke, thickness: 1pt, dash: dash)),
    text(size: 11.5pt)[#label],
  )
  #grid(
    columns: (1fr, auto), column-gutter: 0.9em, align: (center, left + horizon),
    image("assets/sensor_wiring.png", height: 8.5cm),
    [
      #stack(dir: ttb, spacing: 0.75em,
        key(rgb("#f4f8fb"), rgb("#B7C7DA"), "solid", "sensor"),
        key(accent, accent, "solid", "software"),
        key(rgb("#E4F4F6"), teal, "solid", "vehicle control"),
        key(rgb("#FFF6E8"), rgb("#FFAB40"), "dashed", "not in service"),
      )
    ],
  )
]

// ── 4 ────────────────────────────────────────────────────────────────────────
#slide[Sensor integration][
  All sensors publish, across both hosts.

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
#slide[Multi-host orchestration][
  ROS 2 provides no equivalent of ROS 1's `machine` tag, so orchestration is
  ours to supply. It is in place and operational.

  #v(0.55em)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.2em,
    [
      *Single instance, no orphaned processes*

      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.5em)
      - #strong[play_launch] reclaims orphaned processes when a launch
        terminates, and brings the stack up in #strong[~20 s] against
        #strong[~60 s] for `ros2 launch`
      - #strong[systemd user units] around it: singleton by construction,
        `KillMode=control-group` takes the whole tree down
    ],
    [
      *Uniform environment on either host*

      #v(0.3em)
      #set text(size: 13pt)
      #set list(spacing: 0.5em)
      - one CycloneDDS profile per role, plus a `config/host` marker file
      - `scripts/env.sh` reads it, and every shell and every unit sources it
      - so any shell is correctly configured on open, and no operator needs to
        track which host they are working on
    ],
  )

  #v(0.6em)
  #note[`just launch-all` starts both hosts and returns; `just stop-all` shuts
  them down.]
]

// ── 6 ────────────────────────────────────────────────────────────────────────
#slide[Vehicle interface][
  #grid(
    columns: (0.7fr, 1.3fr), column-gutter: 1.2em,
    align: (center, left),
    image("assets/vcu_lineage.png", height: 7.2cm),
    [
      #v(0.2em)
      Developed from the vendor's own test code rather than from a
      specification. Every stage below exists in the repository.

      #v(0.6em)
      The safety constraints are our addition:

      #v(0.25em)
      #set text(size: 13pt)
      #set list(spacing: 0.45em)
      - target speed is clamped non-negative; reverse is gear `R`
      - gear `P` forces speed and steering angle to zero, re-applied each cycle
      - ESTOP release is never bound to a key the terminal cannot emit

      #v(0.55em)
      #note[A test suite sits above it: keyboard control, a command service,
      and trajectory replay.]
    ],
  )
]

// ── 7 ────────────────────────────────────────────────────────────────────────
#slide[Data acquisition][
  #grid(
    columns: (1.05fr, 1fr), column-gutter: 1.0em,
    image("assets/vehicle_csie_init.jpg", height: 7.0cm),
    [
      #v(0.1em)
      Three runs at NTU. #strong[Each host records independently], writing only
      the topics for the devices it owns; the bags are merged afterwards.

      #v(0.55em)
      Only #strong[first-hand driver output] is recorded. Derived topics are
      excluded, so replay recomputes them under current parameters rather than
      those fixed at record time.

      #v(0.55em)
      #note[Replay is a single command, `just ntu-test run`: bag paused for
      `/clock`, then stack, RViz and initial pose, in the required order.]
    ],
  )
]

// ══ what needs fixing ════════════════════════════════════════════════════════

// ── 8 ────────────────────────────────────────────────────────────────────────
#slide[Integration findings][
  Three findings relevant to comparable deployments.

  #v(0.6em)
  #set list(spacing: 0.8em)
  - *The vendor's default oToCam setup enables the cameras and disables every
    USB port.* A workaround now provides both. The `.ko` files remain ABI-bound
    to kernel `5.15.148-tegra`, so a JetPack update silently reverts it.

  - *The Xsens IMU cable has failed and is being remade.* The stack currently
    uses the #strong[ZED X built-in IMU], which resides on the other host and
    crosses the network at 100 Hz.

  - *The u-blox GNSS is hosted on the Orin*, the Advantech having no free USB
    port. A second localization input is therefore also remote, for an unrelated
    reason.
]

// ── 9 ────────────────────────────────────────────────────────────────────────
#slide[Compute and thermal limits][
  #grid(
    columns: (1.25fr, 1fr), column-gutter: 1.0em,
    [
      #v(0.1em)
      The three GMSL cameras emit #strong[UYVY] at 1920x1280, 30 fps, while the
      consuming nodes require #strong[RGB or JPEG]. A conversion is therefore
      unavoidable. #strong[`nvvidconv`] was evaluated; the conversion still
      incurs CPU cost per camera.

      #v(0.55em)
      This load contributes to the thermal saturation shown here, and is part of
      the rationale for splitting the stack across #strong[two hosts].

      #v(0.55em)
      #note[Mitigation in progress: #link("https://github.com/newslabntu/gmslcam")[`gmslcam`],
      which removes that stage.]
    ],
    image("assets/thermal_fan_cooling.jpg", height: 6.9cm),
  )
]

// ── 10 ───────────────────────────────────────────────────────────────────────
#slide[Start-up contention][
  #grid(
    columns: (1.05fr, 1fr), column-gutter: 1.0em,
    image("assets/htop_before_governor.jpg", height: 5.5cm),
    [
      #set text(size: 12pt)
      play_launch is fast #emph[because] it spawns without rate limiting. On a
      host already at its limit this produces a thundering herd, and the machine
      becomes unresponsive, requiring a power cycle.

      #v(0.45em)
      *Rate-limiting the spawns is the obvious remedy, and measurement rejects
      it:* roughly 10% fewer runnable tasks for more than double the start-up
      time, forfeiting the advantage the tool was adopted for.

      #v(0.45em)
      The shipped mechanism is a #strong[1 GiB `MemAvailable` floor], engaging
      only as the host approaches exhaustion.

      #v(0.3em)
      #note[Constrain the resource that is exhausted, not the spawn rate.]
    ],
  )
]

// ── 11 ───────────────────────────────────────────────────────────────────────
#slide-sm[Autonomous engagement and VCU state entry][
  #align(center)[#image("assets/vcu_states.png", width: 72%)]
  #v(0.45em)
  #set text(size: 12.5pt)
  #grid(
    columns: (1fr, 1fr), column-gutter: 1.2em,
    [
      There is no `vehicle_cmd_gate` external selector. The interface issues no
      commands until all four subsystems report autonomous, and #strong[no
      service call can override this].
    ],
    [
      After a VCU restart, #strong[BRK and Drv initialise as `Invalid`], and only
      a brake-pedal press was observed to clear them. Not reproducible over CAN.

      #v(0.3em)
      #text(fill: red)[*Unattended autonomous start-up is therefore blocked.*]
      This requires clarification from the vendor rather than further work on
      our side.
    ],
  )
]

// ── 12 ───────────────────────────────────────────────────────────────────────
#slide[NDT localization][
  #grid(
    columns: (1.2fr, 1fr), column-gutter: 1.0em,
    image("assets/ndt_slide_chart.png", height: 6.0cm),
    [
      #set text(size: 12pt)
      Tuning was evaluated against #strong[scan-to-map residual] rather than the
      NVTL score: the change that most improved accuracy in fact *reduced* NVTL.

      #v(0.45em)
      Convergence is reliable when stationary, to 0.14 m, but
      #strong[degrades within seconds of the vehicle moving].

      #v(0.45em)
      *The cause lies upstream of NDT, in the recording:* 45% of scans cover
      only part of a revolution, and scans arrive #strong[376 ms stale].

      #v(0.35em)
      #note[Raw LiDAR packets were not recorded, so these bags cannot be
      re-decoded. The next run will capture them.]
    ],
  )
]

// ══ close ════════════════════════════════════════════════════════════════════

// ── 13 ───────────────────────────────────────────────────────────────────────
#slide[Bring-up status][
  #v(0.1em)
  #set text(size: 13.5pt)
  #table(
    columns: (auto, auto, 1fr),
    stroke: none, inset: (x: 0.45em, y: 0.48em), row-gutter: 0.05em,
    align: (left, left, left),
    [*Step*], [*State*], [*Outstanding issue*],
    table.hline(stroke: 0.6pt + accent.lighten(50%)),
    [Sensors], [#chip("ready")],
    [partial LiDAR scans; Xsens cable under repair],
    [Two-host system], [#chip("ready")], [none],
    [Vehicle interface], [#chip("wip")],
    [the VCU will not enter its autonomous state over CAN alone],
    [Map preparation], [#chip("ready")],
    [PCD and lanelet2 supplied by Turing Drive, downsampled at runtime],
    [Data collection], [#chip("flawed")],
    [the recordings carry the sensor defects above],
    [Autonomous run], [#chip("none")],
    [dependent on the vehicle interface issue],
  )
]

// ── 14 ───────────────────────────────────────────────────────────────────────
#slide[Next steps][
  #set list(spacing: 0.85em)
  - *Establish with Turing Drive what clears the `Invalid` brake state after a
    restart.* All remaining work on the autonomous run depends on this.

  - *Record raw LiDAR packets* and verify the VLP-32C rotation configuration
    against the hardware, then repeat the localization work on sound data.

  - *Migrate the sensor kit to `gmslcam`*, eliminating the per-camera CPU
    conversion.

  #v(0.6em)
  #note[TSN is a separate line of work, available for discussion if of
  interest.]
]
