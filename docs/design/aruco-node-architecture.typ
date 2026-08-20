// ArUco Indoor Localizer — target node architecture
// Spec: docs/superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md
//
// Build:  typst compile docs/design/aruco-node-architecture.typ
// Pure standard-library Typst — no external packages, compiles offline.

#set page(width: 297mm, height: 210mm, margin: (x: 12mm, y: 10mm))
#set text(font: ("DejaVu Sans", "Liberation Sans"), size: 8pt)

// ─── palette ────────────────────────────────────────────────────────────────
#let c-create    = rgb("#0E7C86")
#let c-create-bg = rgb("#DFEFF0")
#let c-reuse     = rgb("#4A5C7A")
#let c-reuse-bg  = rgb("#E4E9F1")
#let c-exist     = rgb("#7C8688")
#let c-exist-bg  = rgb("#F2F4F3")
#let c-warn      = rgb("#B8600F")
#let c-ink       = rgb("#14191A")
#let c-soft      = rgb("#5B6668")
#let c-edge      = rgb("#7C8688")
#let c-rule      = rgb("#D2D8D7")

#let mono = ("DejaVu Sans Mono", "Liberation Mono")
#let warnmark = text(size: 7pt, fill: c-warn, weight: "bold")[#sym.triangle.stroked.t]

// ─── node ───────────────────────────────────────────────────────────────────
// kind: "create" | "reuse" | "exist"
// warn: exists, but must be fixed before this architecture works
#let kindcol(kind) = if kind == "create" { c-create } else if kind == "reuse" { c-reuse } else { c-exist }
#let kindbg(kind)  = if kind == "create" { c-create-bg } else if kind == "reuse" { c-reuse-bg } else { c-exist-bg }
#let kindth(kind)  = if kind == "create" { 1.1pt } else { 0.5pt }

#let node(x, y, w, h, kind, title, sub, warn: false) = {
  place(dx: x, dy: y, rect(
    width: w, height: h, fill: kindbg(kind),
    stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt, inset: 1.6mm,
  )[
    #set par(leading: 0.42em)
    #text(font: mono, size: 7.4pt, weight: "bold", fill: c-ink, title)
    #if sub != none [ \ #text(size: 6.3pt, fill: c-soft, sub) ]
  ])
  if warn {
    place(dx: x, dy: y, rect(width: 1.1mm, height: h, fill: c-warn, stroke: none))
    place(dx: x + w - 4.4mm, dy: y + 1.1mm, warnmark)
  }
}

// ─── edges ──────────────────────────────────────────────────────────────────
#let hd = 1.7mm

#let head-r(x, y, col) = place(dx: x - hd, dy: y - hd/2,
  polygon(fill: col, (0mm, 0mm), (hd, hd/2), (0mm, hd)))
#let head-d(x, y, col) = place(dx: x - hd/2, dy: y - hd,
  polygon(fill: col, (0mm, 0mm), (hd, 0mm), (hd/2, hd)))
#let head-l(x, y, col) = place(dx: x, dy: y - hd/2,
  polygon(fill: col, (hd, 0mm), (0mm, hd/2), (hd, hd)))

#let seg(x1, y1, x2, y2, col, dash) = place(dx: x1, dy: y1,
  line(end: (x2 - x1, y2 - y1), stroke: (paint: col, thickness: 0.6pt, dash: dash)))

#let arr-r(x, y, len, col: c-edge, dash: none) = {
  seg(x, y, x + len, y, col, dash); head-r(x + len, y, col)
}
#let arr-d(x, y, len, col: c-edge, dash: none) = {
  seg(x, y, x, y + len, col, dash); head-d(x, y + len, col)
}
// right → vertical → right
#let arr-rvr(x1, y1, xm, x2, y2, col: c-edge, dash: none) = {
  seg(x1, y1, xm, y1, col, dash); seg(xm, y1, xm, y2, col, dash)
  seg(xm, y2, x2, y2, col, dash); head-r(x2, y2, col)
}
// left → vertical → left
#let arr-lvl(x1, y1, xm, x2, y2, col: c-edge, dash: none) = {
  seg(x1, y1, xm, y1, col, dash); seg(xm, y1, xm, y2, col, dash)
  seg(xm, y2, x2, y2, col, dash); head-l(x2, y2, col)
}

#let lbl(x, y, s, col: c-soft, sz: 5.9pt) = place(dx: x, dy: y,
  text(font: mono, size: sz, fill: col, s))
#let lblb(x, y, s, col: c-ink, sz: 6.5pt) = place(dx: x, dy: y,
  text(font: mono, size: sz, weight: "bold", fill: col, s))

// ─── header ─────────────────────────────────────────────────────────────────
#text(font: mono, size: 15pt, weight: "bold", fill: c-ink)[ArUco Indoor Localizer — target node architecture]
#v(-2.8mm)
#text(size: 8pt, fill: c-soft)[
  Sole pose source indoors. No NDT, no point cloud map, no GNSS.
  #h(4mm) Spec: `docs/superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md`
]
#v(0.8mm)

#let key(kind, label, note) = {
  box(baseline: 1.2pt, rect(width: 6mm, height: 3.2mm, fill: kindbg(kind),
    stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt))
  h(1.4mm); text(font: mono, size: 7.2pt, weight: "bold", fill: c-ink, label)
  h(1.2mm); text(size: 7pt, fill: c-soft, note)
}
#box[
  #key("create", "CREATE", "written by us")
  #h(7mm) #key("reuse", "REUSE", "upstream Autoware, unmodified")
  #h(7mm) #key("exist", "EXISTING", "already on the vehicle / in this repo")
  #h(7mm)
  #box(baseline: 1.2pt, rect(width: 1.1mm, height: 3.2mm, fill: c-warn, stroke: none))
  #h(1.4mm) #text(font: mono, size: 7.2pt, weight: "bold", fill: c-warn)[#warnmark BLOCKER]
  #h(1.2mm) #text(size: 7pt, fill: c-soft)[exists, but must be fixed before this works]
]

#v(2.5mm)

// ─── diagram ────────────────────────────────────────────────────────────────
#block(width: 100%, height: 150mm)[

  #lbl(0mm,   0mm, "SENSING",         sz: 6.4pt)
  #lbl(58mm,  0mm, "DETECTION",       sz: 6.4pt)
  #lbl(122mm, 0mm, "LOCALIZATION",    sz: 6.4pt)
  #lbl(202mm, 0mm, "FUSION / SYSTEM", sz: 6.4pt)

  // ── sensing (existing)
  #node(0mm, 5mm,  44mm, 12mm, "exist", "camera_left",  "gscam · jpeg · 1920×1280", warn: true)
  #node(0mm, 20mm, 44mm, 12mm, "exist", "camera_right", "gscam · jpeg · 1920×1280", warn: true)
  #node(0mm, 35mm, 44mm, 12mm, "exist", "camera_rear",  "gscam · jpeg · 1920×1280", warn: true)
  #lbl(0mm, 48.6mm, "one calibration file copied x3")

  #node(0mm, 66mm, 44mm, 12mm, "exist", "imu_corrector", "Tamagawa IMU")
  #node(0mm, 82mm, 44mm, 14mm, "exist", "vehicle_interface", "velocity_report — STUB,\npublishes zero", warn: true)
  #node(0mm, 106mm, 44mm, 12mm, "exist", "sensor_kit URDF / TF", "no *_optical_link exists", warn: true)

  // ── detection (create)
  #node(58mm, 5mm,  50mm, 12mm, "create", "aruco_detector", "left  · extends LCTK node")
  #node(58mm, 20mm, 50mm, 12mm, "create", "aruco_detector", "right · extends LCTK node")
  #node(58mm, 35mm, 50mm, 12mm, "create", "aruco_detector", "rear  · extends LCTK node")

  #node(58mm, 74mm, 50mm, 12mm, "reuse", "gyro_odometer", "IMU + wheel odometry")
  #node(58mm, 100mm, 50mm, 12mm, "exist", "aruco_tag_map.yaml", "hand-measured · ID -> pose")

  // ── localizer (create)
  #node(122mm, 5mm, 58mm, 62mm, "create", "golfcart_aruco_localizer", none)
  #place(dx: 124.6mm, dy: 14mm, block(width: 53mm)[
    #set par(leading: 0.55em)
    #set text(size: 6.4pt, fill: c-soft)
    window across all cameras \
    motion-compensate to one stamp \
    flip consensus in SE(3) \
    joint LM over every corner \
    eigen-saturated covariance \
    per-ID integrity check (RAIM) \
    state machine + observability gates
    #v(1.4mm)
    #text(size: 6.2pt, fill: c-create, weight: "bold")[one instance · owns map, TF, solve]
  ])

  #node(122mm, 100mm, 58mm, 12mm, "create", "aruco_detection_msgs",
        "build dep of detector + localizer")

  // ── fusion / system
  #node(202mm, 5mm,  50mm, 14mm, "reuse", "MRM / system handler", "stop request on FAULT")
  #node(202mm, 34mm, 50mm, 14mm, "reuse", "ekf_localizer", "the only pose consumer")
  #node(202mm, 62mm, 50mm, 12mm, "reuse", "kinematic_state", "fused output · 50 Hz")
  #node(202mm, 95mm,  50mm, 12mm, "reuse", "lanelet2_map_loader", "for PLANNING only")
  #node(202mm, 110mm, 50mm, 12mm, "reuse", "map_projection_loader", "map origin / datum")

  // ── cameras → detectors
  #arr-r(44mm, 11mm, 14mm)
  #arr-r(44mm, 26mm, 14mm)
  #arr-r(44mm, 41mm, 14mm)
  #lbl(44.5mm, 2.6mm, "image_raw/compressed + camera_info")

  // ── detectors → localizer
  #arr-rvr(108mm, 11mm, 115mm, 122mm, 22mm)
  #arr-rvr(108mm, 26mm, 115mm, 122mm, 26mm)
  #arr-rvr(108mm, 41mm, 115mm, 122mm, 30mm)
  #lbl(58mm, 53mm, "ArucoDetectionArray — corners, K, IPPE pair")

  // ── tag map → localizer
  #arr-rvr(108mm, 106mm, 116mm, 122mm, 50mm)
  #lbl(109mm, 102.4mm, "map")

  // ── TF → localizer
  #arr-rvr(44mm, 112mm, 119mm, 122mm, 58mm)
  #lbl(48mm, 113.4mm, "TF   base_link <- camera_*_optical")

  // ── IMU + vehicle → gyro_odometer
  #arr-rvr(44mm, 72mm, 51mm, 58mm, 78mm)
  #arr-rvr(44mm, 89mm, 51mm, 58mm, 83mm)

  // ── localizer → MRM (state)
  #arr-rvr(180mm, 14mm, 188mm, 202mm, 12mm, col: c-warn)
  #lbl(182mm, 7.2mm, "status", col: c-warn)

  // ── localizer → EKF (the pose)
  #arr-rvr(180mm, 36mm, 193mm, 202mm, 41mm, col: c-create)
  #lbl(182mm, 31.4mm, "pose+cov", col: c-create, sz: 6.2pt)

  // ── gyro → EKF
  #arr-rvr(108mm, 80mm, 197mm, 202mm, 45mm)
  #lbl(150mm, 76.4mm, "twist")

  // ── EKF → kinematic_state
  #arr-d(227mm, 48mm, 14mm)

  // ── kinematic_state → localizer (twist for motion compensation)
  #arr-lvl(202mm, 68mm, 185mm, 180mm, 64mm, dash: (2pt, 2pt))
  #lbl(138mm, 71.4mm, "twist -> motion compensation   (dashed = feedback)")

  // ── key topics band
  #seg(0mm, 126mm, 252mm, 126mm, c-rule, none)
  #lblb(0mm,  130mm, "KEY TOPICS")
  #lblb(19mm, 130mm, "pose+cov", col: c-create)
  #lbl(32mm,  130mm,
    ": /localization/pose_estimator/pose_with_covariance   —   the sole pose source", sz: 6.5pt)
  #lblb(19mm, 134mm, "status", col: c-warn)
  #lbl(32mm,  134mm,
    ": NOMINAL / DEGRADED / DEAD_RECKONING / FAULT   —   localization state, drives MRM", sz: 6.5pt)

  // ── not launched band
  #lblb(0mm,  141mm, "NOT LAUNCHED", col: c-warn)
  #lbl(19mm,  141mm,
    "ndt_scan_matcher · cuda_ndt_matcher · pointcloud_map_loader · NDT pointcloud preprocessing", sz: 6.5pt)
  #lbl(19mm,  145mm,
    "autoware_ar_tag_based_localizer · autoware_landmark_manager · pose_estimator_arbiter · golfcart_pose_merger", sz: 6.5pt)
]

#pagebreak()

// ─── inventory ──────────────────────────────────────────────────────────────
#text(font: mono, size: 13pt, weight: "bold", fill: c-ink)[Inventory]
#v(-2mm)
#text(size: 8pt, fill: c-soft)[Every box in the diagram, by origin.]
#v(3mm)

#let dot(kind) = box(baseline: 0.6pt, rect(width: 4mm, height: 2.8mm, fill: kindbg(kind),
  stroke: (paint: kindcol(kind), thickness: kindth(kind)), radius: 0.6pt))

#set table(stroke: (x, y) => (bottom: 0.4pt + c-rule))
#table(
  columns: (8mm, 50mm, 26mm, 1fr),
  inset: (x: 2.4mm, y: 2mm),
  align: (center + horizon, left + horizon, left + horizon, left),
  table.header(
    [], text(size: 7pt, fill: c-soft, weight: "bold")[NODE / ARTIFACT],
    text(size: 7pt, fill: c-soft, weight: "bold")[ORIGIN],
    text(size: 7pt, fill: c-soft, weight: "bold")[NOTE],
  ),

  dot("create"), text(font: mono, size: 7.6pt)[aruco_detector ×3], [LCTK, extended],
  [Add `rational_polynomial` support; switch from the all-or-nothing ID gate to the permissive detect entry point; replace the dead pose path with `solvePnPGeneric(IPPE_SQUARE)` keeping both solutions and both reprojection errors. All three are fixes LCTK wants on its own terms (`L-03`, `L-12`).],

  dot("create"), text(font: mono, size: 7.6pt)[golfcart_aruco_localizer], [new, this repo],
  [Owns the map, TF and the solve. Windowing, flip consensus, joint Levenberg–Marquardt over every corner from every camera, eigen-saturated covariance, per-ID integrity monitoring, localization state machine.],

  dot("create"), text(font: mono, size: 7.6pt)[aruco_detection_msgs], [new, standalone],
  [Corners carried in a real field rather than smuggled through a bounding box — the bug LCTK shipped twice (`C-01`, then `H-10` re-created it through a dump/load path).],

  dot("reuse"), text(font: mono, size: 7.6pt)[ekf_localizer], [Autoware, unmodified],
  [#warnmark Config change needed: restore `pose_gate_dist` from `10000.0`. With one pose source, the Mahalanobis gate is the only remaining defence against a bad fix.],

  dot("reuse"), text(font: mono, size: 7.6pt)[gyro_odometer], [Autoware, unmodified],
  [Carries heading between multi-board fixes. Its accuracy sets the `DEAD_RECKONING` time budget.],

  dot("reuse"), text(font: mono, size: 7.6pt)[MRM / system handler], [Autoware, unmodified],
  [Consumes the localizer's `FAULT` state. Hook is the existing `docs/guides/mrm_configuration.md`.],

  dot("reuse"), text(font: mono, size: 7.6pt)[lanelet2_map_loader\ map_projection_loader], [Autoware, unmodified],
  [Vector map for planning and the map origin. The *point cloud* map loader is not used at all.],

  dot("exist"), text(font: mono, size: 7.6pt)[camera_left / right / rear], [this repo],
  [#warnmark All three calibration files are byte-identical but for `camera_name` — one calibration copied three times. They declare `rational_polynomial` with `K` and `P` disagreeing 25% on `fx`. Also needs fixed exposure: `auto_exposure` and `auto_white_balance` are currently `true`.],

  dot("exist"), text(font: mono, size: 7.6pt)[sensor_kit URDF / TF], [this repo],
  [#warnmark No `*_optical_link` exists anywhere in the URDF, while PnP returns optical-convention poses. Every observation lands about 90° rotated until the optical children are added with `RPY = (−π/2, 0, −π/2)`.],

  dot("exist"), text(font: mono, size: 7.6pt)[vehicle_interface], [this repo],
  [#warnmark `velocity_report.py` publishes zero velocity pending Turing Drive DBW. Blocks the *fused* EKF output — the localizer's raw pose can still be validated against ground truth with no vehicle interface.],

  dot("exist"), text(font: mono, size: 7.6pt)[imu_corrector], [this repo],
  [Tamagawa IMU. Hardware still pending.],

  dot("exist"), text(font: mono, size: 7.6pt)[aruco_tag_map.yaml], [hand survey],
  [Supplied as data, not produced by the system. `survey.stated_accuracy` sets the accuracy ceiling for everything downstream.],
)

#v(4mm)
#block(inset: (x: 3mm, y: 2.5mm), fill: rgb("#F8EDE1"), stroke: (left: 1.2pt + c-warn), width: 100%)[
  #text(font: mono, size: 7.2pt, weight: "bold", fill: c-warn)[LAUNCH SURGERY]
  #h(2mm)
  #text(size: 7.6pt, fill: c-ink)[
    Both branches of `tier4_localization_component.launch.xml` currently assume a scan matcher exists.
    A new `pose_source:=aruco` must bring up the three detectors, the localizer and `gyro_odometer`,
    and must *not* bring up `ndt_scan_matcher`, its pointcloud preprocessing, or `pointcloud_map_loader`.
  ]
]
