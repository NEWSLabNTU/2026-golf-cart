// ArUco Indoor Localizer — implementation roadmap (phase 3D)
// Index: docs/roadmaps/3-indoor-d-runtime-integration.md
//
// Build:  typst compile docs/design/aruco-implementation-roadmap.typ
// Pure standard-library Typst — no external packages, compiles offline.

#set page(width: 297mm, height: 210mm, margin: (x: 12mm, y: 10mm))
#set text(font: ("DejaVu Sans", "Liberation Sans"), size: 8pt)

// ─── palette ────────────────────────────────────────────────────────────────
#let c-crit    = rgb("#0E7C86")   // critical path
#let c-crit-bg = rgb("#DFEFF0")
#let c-par     = rgb("#4A5C7A")   // parallel track
#let c-par-bg  = rgb("#E4E9F1")
#let c-gate    = rgb("#B8600F")   // gated on hardware / site
#let c-gate-bg = rgb("#F8EDE1")
#let c-ink     = rgb("#14191A")
#let c-soft    = rgb("#5B6668")
#let c-edge    = rgb("#7C8688")
#let c-rule    = rgb("#D2D8D7")

#let mono = ("DejaVu Sans Mono", "Liberation Mono")

#let kindcol(k) = if k == "crit" { c-crit } else if k == "par" { c-par } else { c-gate }
#let kindbg(k)  = if k == "crit" { c-crit-bg } else if k == "par" { c-par-bg } else { c-gate-bg }
#let kindth(k)  = if k == "crit" { 1.3pt } else { 0.6pt }

// ─── phase box ──────────────────────────────────────────────────────────────
#let phase(x, y, w, bh, kind, id, title, body, now: false) = {
  place(dx: x, dy: y, rect(width: w, height: bh, fill: kindbg(kind),
    stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt, inset: 2mm)[
    #set par(leading: 0.45em)
    #text(font: mono, size: 7pt, weight: "bold", fill: kindcol(kind), id)
    #h(1.6mm)
    #text(font: mono, size: 7.6pt, weight: "bold", fill: c-ink, title)
    #linebreak()
    #text(size: 6.3pt, fill: c-soft, body)
  ])
  if now {
    place(dx: x + w - 15mm, dy: y - 3.4mm,
      rect(fill: c-crit, radius: 0.6pt, inset: (x: 1.2mm, y: 0.5mm),
        text(font: mono, size: 5.6pt, weight: "bold", fill: white)[START NOW]))
  }
}

// ─── edges ──────────────────────────────────────────────────────────────────
#let hd = 1.7mm
#let head-r(x, y, col) = place(dx: x - hd, dy: y - hd/2,
  polygon(fill: col, (0mm, 0mm), (hd, hd/2), (0mm, hd)))
#let head-d(x, y, col) = place(dx: x - hd/2, dy: y - hd,
  polygon(fill: col, (0mm, 0mm), (hd, 0mm), (hd/2, hd)))
#let seg(x1, y1, x2, y2, col, th, dash) = place(dx: x1, dy: y1,
  line(end: (x2 - x1, y2 - y1), stroke: (paint: col, thickness: th, dash: dash)))

#let arr-r(x, y, len, col: c-edge, th: 0.6pt, dash: none) = {
  seg(x, y, x + len, y, col, th, dash); head-r(x + len, y, col)
}
#let arr-d(x, y, len, col: c-edge, th: 0.6pt, dash: none) = {
  seg(x, y, x, y + len, col, th, dash); head-d(x, y + len, col)
}
#let arr-rvr(x1, y1, xm, x2, y2, col: c-edge, th: 0.6pt, dash: none) = {
  seg(x1, y1, xm, y1, col, th, dash); seg(xm, y1, xm, y2, col, th, dash)
  seg(xm, y2, x2, y2, col, th, dash); head-r(x2, y2, col)
}

#let lbl(x, y, s, col: c-soft, sz: 5.9pt) = place(dx: x, dy: y,
  text(font: mono, size: sz, fill: col, s))
#let lblb(x, y, s, col: c-ink, sz: 6.5pt) = place(dx: x, dy: y,
  text(font: mono, size: sz, weight: "bold", fill: col, s))

// ─── header ─────────────────────────────────────────────────────────────────
#text(font: mono, size: 15pt, weight: "bold", fill: c-ink)[ArUco Indoor Localizer — implementation roadmap]
#v(-2.8mm)
#text(size: 8pt, fill: c-soft)[
  Phase 3D. Infrastructure and launch first, then the algorithm, then simulation.
  #h(3mm) Index: `docs/roadmaps/3-indoor-d-runtime-integration.md`
]
#v(1mm)

#let key(kind, label, note) = {
  box(baseline: 1.2pt, rect(width: 6mm, height: 3.2mm, fill: kindbg(kind),
    stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt))
  h(1.4mm); text(font: mono, size: 7.2pt, weight: "bold", fill: c-ink, label)
  h(1.2mm); text(size: 7pt, fill: c-soft, note)
}
#box[
  #key("crit", "CRITICAL PATH", "D1 → D3 → D4 → D6, the longest chain")
  #h(8mm) #key("par", "PARALLEL", "off the critical path, run alongside")
  #h(8mm) #key("gate", "GATED", "needs the site, the boards, or DBW")
]

#v(3mm)

// ─── roadmap ────────────────────────────────────────────────────────────────
#block(width: 100%, height: 152mm)[

  #lblb(0mm, 0mm, "PHASE 3D — SOFTWARE, NO VEHICLE REQUIRED", col: c-crit, sz: 7pt)

  // ── phase boxes
  #phase(0mm,   8mm, 56mm, 26mm, "crit", "D1", "Infrastructure",
    "aruco_detection_msgs · package skeletons · tag map loader (both pose and corners forms) · corner-order constant + test", now: true)

  #phase(72mm,  8mm, 56mm, 26mm, "par", "D2", "Launch switch",
    "pose_source:=aruco · golfcart map component (pointcloud loader cannot be switched off from above) · restore pose_gate_dist")

  #phase(72mm, 42mm, 56mm, 26mm, "crit", "D3", "Synthetic detections",
    "aruco_sim_detector · scripted trajectory · fault injection: displace, blackout, coplanar, fronto-parallel")

  #phase(144mm, 42mm, 56mm, 26mm, "crit", "D4", "Localizer",
    "consensus · joint LM · eigen-saturated covariance · integrity (RAIM) · state machine · init mode")

  #phase(216mm, 25mm, 56mm, 26mm, "crit", "D6", "Sim smoke test",
    "scripted loop, then planning simulator · launch node-list assertions · every fault to its state · MRM reached")

  #phase(72mm,  80mm, 56mm, 26mm, "par", "D5", "Detector",
    "LCTK: rational_polynomial · permissive detect · solvePnPGeneric keeping both IPPE solutions · rectify contract tests")

  #phase(0mm,  80mm, 56mm, 26mm, "par", "D7", "Rosbag collection",
    "fix the stale front-camera topic list first · bench bags now · site bags after mounting", now: true)

  // ── edges
  #arr-r(56mm, 21mm, 16mm, col: c-edge)
  #arr-rvr(56mm, 26mm, 64mm, 72mm, 55mm, col: c-crit, th: 1.3pt)
  #arr-rvr(56mm, 30mm, 60mm, 72mm, 88mm, col: c-edge)
  #arr-r(128mm, 55mm, 16mm, col: c-crit, th: 1.3pt)
  #arr-rvr(128mm, 21mm, 208mm, 216mm, 33mm, col: c-edge)
  #arr-rvr(200mm, 55mm, 208mm, 216mm, 43mm, col: c-crit, th: 1.3pt)
  #arr-r(56mm, 96mm, 16mm, col: c-edge)

  #lbl(58mm, 17.4mm, "names")
  #lbl(130mm, 51.4mm, "the fixture")
  #lbl(61mm, 84.4mm, "msgs")
  #lbl(57mm, 94.4mm, "real images")
  #lbl(72mm, 111mm, "D5 runs entirely in parallel — it blocks nothing until the real-image path")

  // ── the decoupling callout
  #place(dx: 144mm, dy: 80mm, rect(width: 128mm, height: 26mm, fill: white,
    stroke: (left: 1.6pt + c-crit), inset: 2.4mm)[
    #set par(leading: 0.5em)
    #text(font: mono, size: 6.6pt, weight: "bold", fill: c-crit)[WHY D3 COMES BEFORE D4]
    #linebreak()
    #text(size: 6.5pt, fill: c-ink)[
      The localizer does not need the detector — it consumes `ArucoDetectionArray`, and D3
      produces that from a known pose plus the tag map. So the whole solve is built against
      exact ground truth, with faults that can be dialled in. No rosbag offers either.
    ]
  ])

  // ── beyond band
  #seg(0mm, 116mm, 272mm, 116mm, c-rule, 1pt, none)
  #lblb(0mm, 122mm, "BEYOND PHASE 3D — NEEDS THE SITE, THE BOARDS, OR DBW", col: c-gate, sz: 7pt)

  #phase(0mm,   128mm, 56mm, 20mm, "gate", "A", "Camera calibration",
    "intrinsics per camera · optical frames · extrinsics")
  #phase(72mm,  128mm, 56mm, 20mm, "gate", "S1", "Mount + survey",
    "coverage walk first, then mount, then measure")
  #phase(144mm, 128mm, 56mm, 20mm, "gate", "S2", "Coverage census",
    "boards visible per position, from a bag")
  #phase(216mm, 128mm, 56mm, 20mm, "gate", "V", "Vehicle integration",
    "needs DBW velocity · on-site tuning")

  #lbl(0mm, 151mm, "Sub-phase A gates accuracy for everything above it — no optical frames means every observation lands about 90 degrees rotated.")
]

#pagebreak()

// ─── page 2 ─────────────────────────────────────────────────────────────────
#text(font: mono, size: 13pt, weight: "bold", fill: c-ink)[Phases — deliverable, acceptance, what it unblocks]
#v(-2mm)
#text(size: 8pt, fill: c-soft)[Full detail in `docs/roadmaps/3-indoor-d*.md`.]
#v(3mm)

#let tag(kind, s) = box(baseline: 0.6pt, rect(fill: kindbg(kind),
  stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt,
  inset: (x: 1.4mm, y: 0.8mm), text(font: mono, size: 6.6pt, weight: "bold", fill: c-ink, s)))

#set table(stroke: (x, y) => (bottom: 0.4pt + c-rule))
#table(
  columns: (13mm, 34mm, 1fr, 1fr, 20mm),
  inset: (x: 2.2mm, y: 2mm),
  align: (center + horizon, left + horizon, left, left, left + horizon),
  table.header(
    [], text(size: 7pt, fill: c-soft, weight: "bold")[PHASE],
    text(size: 7pt, fill: c-soft, weight: "bold")[DELIVERABLE],
    text(size: 7pt, fill: c-soft, weight: "bold")[ACCEPTANCE],
    text(size: 7pt, fill: c-soft, weight: "bold")[UNBLOCKS],
  ),

  tag("crit", "D1"), [Infrastructure],
  [Messages, package skeletons, tag map loader accepting both the pose form and the four-corner form, corner-order constant.],
  [Build clean from scratch. A map in `corners` form and the same map in `position`/`orientation` form load *identically* — the test that catches a convention error before it reaches the solve.],
  [D2 D3 D4 D5],

  tag("par", "D2"), [Launch switch],
  [`pose_source:=aruco` as a third branch alongside `ndt` and `cuda_ndt`. Golfcart-owned map component. Restore `pose_gate_dist`.],
  [Node list shows the ArUco stack and, more importantly, *no* scan matcher, pointcloud map loader or NDT preprocessing. `ndt` and `cuda_ndt` still launch unchanged.],
  [D6],

  tag("crit", "D3"), [Synthetic detections],
  [`aruco_sim_detector` reading the same map and camera model as the real path. Scripted trajectories. Fault injection.],
  [Zero-noise round trip closes to numerical tolerance. Noise scaling matches the `σ_Z ∝ Z²/s` envelope within about 2×.],
  [D4 D6],

  tag("crit", "D4"), [Localizer],
  [Stage 1 the solve; stage 2 integrity and states. Both are required — stage 2 is what makes it safe to be the only pose source.],
  [Tracks ground truth in sim. Covariance grows only in genuinely unobservable directions. One displaced board is flagged and excluded, its neighbours are not.],
  [D6],

  tag("par", "D5"), [Detector],
  [LCTK extension: `rational_polynomial`, permissive detect entry point, `solvePnPGeneric` keeping both IPPE solutions.],
  [Rectify contract tests pass, including the two that fail loudly when refinement silently stops running. `corner_sigma_px` measured.],
  [real-image path],

  tag("crit", "D6"), [Sim smoke test],
  [Scripted loop first, then the planning simulator with the ground-truth topic remapped off `/localization/kinematic_state`.],
  [Tracks within budget, every fault injection reaches its intended state and nothing else, MRM stop actually reached, launch assertions pass.],
  [—],

  tag("par", "D7"), [Rosbags],
  [Fix the stale `front` topic list, then bench bags immediately; site bags once boards are mounted.],
  [`corner_sigma_px` measured at three ranges and in motion. Detection rate characterized against incidence and range on real optics.],
  [D5 validation],
)

#v(4mm)

#grid(columns: (1fr, 1fr), gutter: 5mm,
  block(inset: (x: 3mm, y: 2.5mm), fill: c-crit-bg, stroke: (left: 1.6pt + c-crit), width: 100%)[
    #text(font: mono, size: 7.2pt, weight: "bold", fill: c-crit)[THREE THINGS THAT CAN START TODAY]
    #v(1.2mm)
    #set par(leading: 0.55em)
    #text(size: 7.4pt, fill: c-ink)[
      *Measure `corner_sigma_px`.* Park in front of a board, record 1000 frames, take the
      standard deviation of the corner positions. The whole covariance model scales on this
      number and it is currently inferred from other people's data. Needs a camera and a board.
      #linebreak()
      *Bench rosbags.* Four or five boards in a room, tape-measured.
      #linebreak()
      *The route coverage walk.* Sizes the board count and says whether ≥2-visible-everywhere
      is satisfiable here — before anything is printed or drilled.
    ]
  ],
  block(inset: (x: 3mm, y: 2.5mm), fill: c-gate-bg, stroke: (left: 1.6pt + c-gate), width: 100%)[
    #text(font: mono, size: 7.2pt, weight: "bold", fill: c-gate)[WHAT SIMULATION CANNOT SETTLE]
    #v(1.2mm)
    #set par(leading: 0.55em)
    #text(size: 7.4pt, fill: c-ink)[
      The synthetic path shares its camera model, tag map and geometry conventions with the
      localizer, so a consistent error in any of them cancels out and passes.
      #linebreak()
      Only real recordings answer: lens distortion against the actual `rational_polynomial`
      calibration, detection rate under real lighting and motion blur, CPU cost of three
      detectors on the Orin, and whether the layout delivers the coverage the design assumes.
      #linebreak()
      Passing D6 means the software is coherent — not that the system works.
    ]
  ],
)
