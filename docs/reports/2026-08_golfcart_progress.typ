// Golf Cart progress report.
//
//   typst compile docs/reports/2026-08_golfcart_progress.typ
//
// Text and figures for the multi-host, TSN and CAN sections come from the
// 2026-08-05 draft deck; the localization section is new. Figures live in
// assets/ and were extracted from that draft rather than recreated, so the
// photographs and hand diagrams are the originals.

#set page(paper: "presentation-16-9", margin: (x: 2.4cm, y: 1.8cm))
#set text(font: ("Liberation Sans", "DejaVu Sans"), size: 19pt)
#set par(justify: false, leading: 0.75em)

#let accent = rgb("#1f5c99")
#let muted = rgb("#5a5a5a")

// A normal content slide.
#let slide(title, body) = {
  text(size: 27pt, weight: "regular")[#title]
  v(0.3em)
  line(length: 100%, stroke: 0.6pt + accent.lighten(45%))
  v(0.45em)
  block(width: 100%)[
    #set text(size: 17pt)
    #body
  ]
  pagebreak(weak: true)
}

// A section divider, matching the draft's centred dividers.
#let section(name) = {
  align(center + horizon)[
    #text(size: 40pt, fill: accent)[#name]
  ]
  pagebreak(weak: true)
}

#let note(body) = block(inset: (left: 1.1em, top: 0.2em), width: 100%)[
  #text(size: 14pt, fill: muted)[#body]
]

// ── title ───────────────────────────────────────────────────────────────────
#align(center + horizon)[
  #text(size: 40pt)[Golf Cart Progress]
  #v(0.4em)
  #text(size: 22pt, fill: muted)[Sensors, System, Vehicle Interface, Localization]
  #v(1.6em)
  #text(size: 17pt, fill: muted)[NEWSLab NTU · August 2026]
]
#pagebreak(weak: true)

#slide[Overview][
  #set text(size: 19pt)
  + *Multi-host setup* — splitting the stack across Advantech and AGX Orin
  + *IMU CAN bus* — wiring failure and the remake
  + *Localization* — NTU campus logging simulation and NDT tuning

  #v(1.2em)
  #note[
    First three sections continue the 2026-08-05 report. Localization is new
    work since then.
  ]
]

// ── multi-host ──────────────────────────────────────────────────────────────
#section[Multi-host setup]

#slide[Multi-host Setup (WIP)][
  #grid(
    columns: (1.55fr, 1fr), gutter: 1.2em, align: horizon,
    image("assets/multihost_photo.jpg", height: 8.6cm),
    [
      #image("assets/safety_island.jpg", height: 6.6cm)
      #v(0.3em)
      #note[NXP CANHUBK344 \ Safety Island]
    ],
  )
]

#slide[The rationale behind the multi-host setup][
  *Constrained computation power*
  #note[
    The Advantech drives three mono oToBrite cameras and two LiDARs. It burns.
    The ZED X stereo + depth camera moves to the AGX Orin.
  ]

  #v(0.5em)
  *Driver conflict*
  #note[
    The oToBrite and ZED camera drivers cannot be installed together on one
    machine — they share the same kernel module name.
  ]

  #v(0.5em)
  *Hardware limitation*
  #note[
    The ZED camera requires a ZEDLink capture card, which only works on Orin.
  ]
]

#slide[Sensors across the two machines][
  #align(center)[#image("assets/sensor_wiring.png", height: 9.4cm)]
]

#slide[Challenges][
  *Lack of multi-host support in ROS 2*
  #note[
    ROS 2 launch files are designed for a single machine. ROS 1 supported
    `machine` tags in launch files; ROS 2 dropped it, moving the multi-host
    responsibility to the user side.
  ]

  #v(0.5em)
  *Non-standard RMW setup*
  #note[
    Autoware's recommended Cyclone DDS and Zenoh settings no longer fit. Node
    and topic discovery has to work across both machines.
  ]

  #v(0.5em)
  *Orchestration work is needed*
  #note[
    Advantech and Orin run disjoint sets of nodes that together make up
    Autoware. Start and stop must be synchronous and singleton, with no orphans
    left after termination.
  ]
]

#slide[Multi-host launch method][
  *Add a host argument to launch files*
  #note[`host:=…` switches each node on or off per machine.]

  #v(0.5em)
  *Employ systemd services*
  #note[
    The launch command is wrapped in a systemd user unit,
    `golfcart-orin.service`. systemd gives singleton startup, clean
    termination and full logs.
  ]

  #v(0.5em)
  *Orphan prevention using cgroups*
  #note[
    Spawned nodes stay in a control group jail — nothing escapes it, and
    `systemctl stop` captures them all.
  ]

  #v(0.6em)
  #note[
    #text(fill: accent)[Since the draft:] a watchdog unit on the Orin stops the
    stack if the master disappears, and `just service-install` provisions both
    hosts.
  ]
]

#slide[Multi-host launch][
  #align(center)[#image("assets/multihost_launch_diagram.png", height: 9.6cm)]
]

#slide[Startup governor: not bricking the machine][
  #grid(
    columns: (1fr, 1.1fr), gutter: 1.1em, align: top,
    [
      #image("assets/htop_before_governor.jpg", height: 7.4cm)
      #v(0.35em)
      #text(size: 13pt, fill: muted)[
        All 12 cores at 100%, load average 128, during bring-up — before the
        governor.
      ]
    ],
    [
      #set text(size: 15pt)
      *Pacing the spawns was tried, measured, rejected*
      #note[
        Capping at 12 spawns made startup *worse* — 10.6 s → 23.8 s — for ~10%
        fewer runnable tasks. The storm is not contention over fixed work, it
        *is* the work. Throughput gates ship *off*.
      ]

      #v(0.4em)
      *What ships on: a memory floor*
      #note[
        1 GiB `MemAvailable`, capped at a quarter of RAM. Never blocks while
        memory is plentiful; serialises only once it falls through — the
        condition that used to end in a dead desktop.
      ]
    ],
  )
]

// ── CAN ─────────────────────────────────────────────────────────────────────
#section[IMU CAN bus fixing]

#slide[The CAN bus wiring issue][
  #grid(
    columns: (1fr, 1fr), gutter: 1.4em, align: horizon,
    [
      #image("assets/can_connector_broken.jpg", height: 8.0cm)
      #v(0.2em)
      #align(center)[#note[Broken CAN bus connector]]
    ],
    [
      #image("assets/can_wire_remake.jpg", height: 8.0cm)
      #v(0.2em)
      #align(center)[#note[The CAN wire remake]]
    ],
  )
]

#slide[CAN wiring remake][
  *Rationale*
  #note[
    The IMU's CAN bus connector had exposed resistors and connection points,
    which were damaged while tidying up the chassis wiring.
  ]

  #v(0.5em)
  *Remake*
  #note[
    A manufacturer will redo the entire wiring, replacing it with
    plastic-coated, less easily damaged cable.
  ]

  #v(0.5em)
  *Connector change*
  #note[
    The wiring moves to an RS232 female connector, with a fabricated RS232 male
    connector on the host side.
  ]
]

// ── localization ────────────────────────────────────────────────────────────
#section[Localization: NDT on the NTU map]

#slide[NTU campus logging simulation][
  Two recorded runs per session — Advantech and Orin — merged into one bag, and
  replayed against a merged r01 + r02 point cloud map.

  #v(0.6em)
  #set text(size: 17pt)
  #table(
    columns: (auto, 1fr),
    stroke: none, inset: (x: 0.4em, y: 0.5em), row-gutter: 0.1em,
    [*Sets*], [CSIE-1, CSIE-2, BLVD-1],
    [*Map*], [6.6 M points, MGRS 51RUH, r01 + r02 merged],
    [*LiDAR*], [Velodyne VLP-32C, primary for NDT],
    [*IMU*], [ZED X built-in — the XSens was not working during the runs],
    [*GNSS*], [switched off; initialization is a saved pose],
  )

  #v(0.6em)
  #note[
    One command runs it end to end: `just ntu-test run CSIE-1` brings up the
    bag, the stack, RViz and the initial pose in the required order.
  ]
]

#slide[NDT tuning: what the crop range was costing][
  Ranked on *scan-to-map residual* — the distance from each live scan point to
  the nearest map point — not on NDT's own score.

  #v(0.5em)
  #set text(size: 17pt)
  #table(
    columns: (auto, auto, auto, auto, auto, auto),
    stroke: none, inset: (x: 0.5em, y: 0.45em),
    align: (right, right, right, right, right, right),
    table.hline(stroke: 0.5pt),
    [*crop*], [*voxel*], [*gate*], [*p50*], [*p95*], [*\> 3 m*],
    table.hline(stroke: 0.5pt),
    [±20 m], [0.5], [2.3], [0.210 m], [1.661 m], [0.0%],
    [*±60 m*], [*0.5*], [*1.3*], [*0.144 m*], [*0.469 m*], [*0.0%*],
    [±60 m], [3.0], [2.3], [0.682 m], [2.590 m], [12.1%],
    table.hline(stroke: 0.5pt),
  )

  #v(0.5em)
  #note[
    The ±20 m crop was inherited from AutoSDV and clipped real structure — our
    returns reach ~29 m. Restoring Autoware's ±60 m cut p95 by 72%. The
    convergence threshold had to move with it: NVTL is a mean per-point score,
    so it fell while accuracy *improved*.
  ]
]

#slide[NDT internals: where tracking breaks][
  #grid(
    columns: (1.5fr, 1fr), gutter: 1.1em, align: horizon,
    image("assets/ndt_slide_chart.png", height: 8.8cm),
    [
      #set text(size: 15pt)
      Convergence while parked is good — 0.14 m residual.

      #v(0.45em)
      Degradation starts *3.5 s after the vehicle first moves*, not at the turn.
      Iterations hit their cap and the correction NDT applies per scan grows
      from 0.09 m to about 1 m.

      #v(0.45em)
      #note[
        NVTL crosses its gate ~50 s later, so the score is a lagging indicator —
        iteration count is the earlier warning.
      ]
    ],
  )
]

#slide[Root cause: the recordings, not the tuning][
  *45% of scans are partial rotations*
  #note[
    Measured over 300 scans: 55% cover 357°, but 45% cover only ~162° and span
    2.1 ms. Which half of the world they cover changes frame to frame, so the
    geometry constraining the fit rotates with it.
  ]

  #v(0.55em)
  *Scans arrive 376 ms stale*
  #note[
    The EKF stamps its poses at the current time; each cloud reaches NDT 376 ms
    after its own timestamp — 1.9 m of travel at 5 m/s. Autoware reports this as
    "Couldn't interpolate pose", which is what drives the degraded state in RViz.
  ]

  #v(0.55em)
  *Neither is fixable in these bags*
  #note[
    The recordings contain decoded clouds only — no raw Velodyne packets — so
    they cannot be re-decoded with a corrected driver configuration.
  ]
]

#slide[Status and next steps][
  #set text(size: 18pt)
  #table(
    columns: (auto, auto, 1fr),
    stroke: none, inset: (x: 0.45em, y: 0.5em), row-gutter: 0.1em,
    [*Multi-host*], [working], [systemd units on both hosts, cgroup cleanup, watchdog],
    [*TSN*], [design], [Orin ready via I226; Advantech NIC is the blocker],
    [*IMU CAN*], [in progress], [wiring remake ordered, RS232 connector change],
    [*NDT*], [partial], [converges and tracks; degrades from input defects],
  )

  #v(0.9em)
  *Next*
  #note[
    - Record raw Velodyne packets, so bags can be re-decoded after a driver fix
    - Check the VLP-32C rotation configuration against the hardware
    - Locate where the 376 ms scan latency accrues
  ]
]

#section[Q&A]
