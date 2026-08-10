// ArUco Indoor Localizer — design document
// Build: typst compile docs/design/aruco-localizer-design.typ
//
// Companion: docs/superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md
// carries the operational detail — failure table, test plan, phase breakdown.

#set page(width: 210mm, height: 297mm, margin: (x: 20mm, y: 18mm),
  numbering: "1", number-align: center)
#set text(font: ("DejaVu Sans", "Liberation Sans"), size: 9.6pt)
#set par(justify: true, leading: 0.62em)

#let c-acc     = rgb("#0E7C86")
#let c-acc-bg  = rgb("#DFEFF0")
#let c-warm    = rgb("#B8600F")
#let c-warm-bg = rgb("#F8EDE1")
#let c-alt     = rgb("#4A5C7A")
#let c-alt-bg  = rgb("#E4E9F1")
#let c-ink     = rgb("#14191A")
#let c-soft    = rgb("#5B6668")
#let c-faint   = rgb("#8B9698")
#let c-rule    = rgb("#D2D8D7")
#let mono = ("DejaVu Sans Mono", "Liberation Mono")

#show heading.where(level: 1): it => {
  v(4mm)
  text(font: mono, size: 12.5pt, weight: "bold", fill: c-ink, it.body)
  v(-1.6mm)
  line(length: 100%, stroke: 0.8pt + c-ink)
  v(0.8mm)
}
#show heading.where(level: 2): it => {
  v(2.4mm)
  text(font: mono, size: 10pt, weight: "bold", fill: c-acc, it.body)
  v(0.4mm)
}
#show raw: set text(font: mono, size: 8.8pt)

#let note(col, head, body) = block(width: 100%, fill: white,
  stroke: (left: 2pt + col), inset: (x: 3.5mm, y: 2.4mm), radius: 0.5pt)[
  #text(font: mono, size: 8.2pt, weight: "bold", fill: col, upper(head))
  #v(0.9mm)
  #body
]
#let chip(col, bg, s) = box(baseline: 0.6pt, rect(fill: bg,
  stroke: (paint: col, thickness: 0.8pt), radius: 0.6pt,
  inset: (x: 1.5mm, y: 0.8mm),
  text(font: mono, size: 7.6pt, weight: "bold", fill: col, s)))
#let tbl(..args) = table(stroke: (x, y) => (bottom: 0.4pt + c-rule),
  inset: (x: 2mm, y: 1.6mm), ..args)
#let th(s) = text(size: 8pt, fill: c-soft, weight: "bold", s)

// diagram primitives
#let hd = 1.8mm
#let head-r(x, y, col) = place(dx: x - hd, dy: y - hd/2,
  polygon(fill: col, (0mm, 0mm), (hd, hd/2), (0mm, hd)))
#let head-d(x, y, col) = place(dx: x - hd/2, dy: y - hd,
  polygon(fill: col, (0mm, 0mm), (hd, 0mm), (hd/2, hd)))
#let seg(x1, y1, x2, y2, col, t, dash) = place(dx: x1, dy: y1,
  line(end: (x2 - x1, y2 - y1), stroke: (paint: col, thickness: t, dash: dash)))
#let arr-r(x, y, len, col: c-soft, t: 0.7pt) = {
  seg(x, y, x + len, y, col, t, none); head-r(x + len, y, col) }
#let arr-d(x, y, len, col: c-soft, t: 0.7pt) = {
  seg(x, y, x, y + len, col, t, none); head-d(x, y + len, col) }
#let dbox(x, y, w, bh, col, bg, title, sub, t: 0.7pt) = {
  place(dx: x, dy: y, rect(width: w, height: bh, fill: bg,
    stroke: (paint: col, thickness: t), radius: 0.6pt, inset: 1.8mm)[
    #set par(leading: 0.45em, justify: false)
    #text(font: mono, size: 8pt, weight: "bold", fill: c-ink, title)
    #if sub != none [ \ #text(size: 7pt, fill: c-soft, sub) ]
  ]) }
#let dlbl(x, y, s, col: c-soft, sz: 6.8pt) = place(dx: x, dy: y,
  text(font: mono, size: sz, fill: col, s))

// ── title ───────────────────────────────────────────────────────────────────
#align(center)[
  #text(font: mono, size: 16pt, weight: "bold", fill: c-ink)[ArUco Indoor Localizer]
  #v(0.8mm)
  #text(size: 10.5pt, fill: c-soft)[Design document]
  #v(1mm)
  #text(font: mono, size: 8.5pt, fill: c-soft)[golf cart · 華夏科大 campus · 2026-08-10]
]
#v(2mm)

#note(c-acc, "Summary")[
  ArUco boards, one ID each, are mounted around an indoor field. Their poses are
  measured by hand and supplied as data. Three cameras detect whatever is in
  view; one solver turns every detected corner from every camera into a single
  vehicle pose with a covariance. That pose goes to the EKF.
  *No NDT, no point cloud map, no GNSS.*
]

= 1. Scope

NDT indoors is degenerate along the axis a corridor is long — the axis you most
need. Boards give absolute position directly, so NDT would add a mapping
pipeline and a tuning surface for a signal that is weakest where it matters.
Dropping it removes indoor LiDAR mapping, the NDT-bootstrapped tag map, NDT
regularization, the pose merger and the separate initializer node. Camera
calibration is the only remaining prerequisite.

The cost is that nothing cross-checks the localizer. Three consequences follow,
and they are the whole of the remaining risk.

#tbl(columns: (42mm, 1fr), align: (left, left),
  [*Coverage is safety-critical*],
  [No boards means dead reckoning on gyro and odometry, error unbounded. Hence
   the state machine and MRM stop (§10).],
  [*Heading has no other source*],
  [Yaw must come from boards, which is where a single board is worst. Hence
   consensus (§5).],
  [*A wrong map entry is uncontradicted*],
  [A knocked or mistyped board places the vehicle confidently wrong. Hence
   integrity monitoring (§10).])

#pagebreak()

= 2. Architecture

#block(width: 100%, height: 136mm)[
  #dlbl(0mm, 0mm, "SENSING", col: c-soft, sz: 7.2pt)
  #dbox(0mm, 5mm, 54mm, 12mm, c-faint, white, "camera left", "gscam · jpeg")
  #dbox(58mm, 5mm, 54mm, 12mm, c-faint, white, "camera right", "gscam · jpeg")
  #dbox(116mm, 5mm, 54mm, 12mm, c-faint, white, "camera rear", "gscam · jpeg")

  #arr-d(27mm, 17mm, 8mm) #arr-d(85mm, 17mm, 8mm) #arr-d(143mm, 17mm, 8mm)

  #dlbl(0mm, 21mm, "DETECTION", col: c-acc, sz: 7.2pt)
  #dbox(0mm, 27mm, 54mm, 13mm, c-acc, c-acc-bg, "aruco_detector", "corners + IPPE pair", t: 1.2pt)
  #dbox(58mm, 27mm, 54mm, 13mm, c-acc, c-acc-bg, "aruco_detector", "corners + IPPE pair", t: 1.2pt)
  #dbox(116mm, 27mm, 54mm, 13mm, c-acc, c-acc-bg, "aruco_detector", "corners + IPPE pair", t: 1.2pt)

  #seg(27mm, 40mm, 27mm, 46mm, c-soft, 0.7pt, none)
  #seg(85mm, 40mm, 85mm, 46mm, c-soft, 0.7pt, none)
  #seg(143mm, 40mm, 143mm, 46mm, c-soft, 0.7pt, none)
  #seg(27mm, 46mm, 143mm, 46mm, c-soft, 0.7pt, none)
  #arr-d(105mm, 46mm, 6mm)
  #dlbl(0mm, 49.6mm, "ArucoDetectionArray ×3")

  #dbox(0mm, 54mm, 44mm, 11mm, c-faint, white, "aruco_tag_map.yaml", "hand-measured")
  #dbox(0mm, 70mm, 44mm, 11mm, c-faint, white, "TF", "base_link ← camera_*_optical")
  #arr-r(44mm, 59.5mm, 8mm)
  #arr-r(44mm, 75.5mm, 8mm)

  #dbox(52mm, 52mm, 118mm, 34mm, c-acc, c-acc-bg, "golfcart_aruco_localizer", none, t: 1.4pt)
  #place(dx: 55mm, dy: 60mm, block(width: 112mm)[
    #set text(size: 7.2pt, fill: c-soft)
    #set par(leading: 0.6em, justify: false)
    #grid(columns: (1fr, 1fr), gutter: 4mm,
      [window across cameras \
       flip consensus in SE(3) (§5) \
       joint solve over every corner (§6)],
      [eigen-saturated covariance (§8) \
       per-board integrity check (§10) \
       localization state machine (§10)])
    #v(0.8mm)
    #text(size: 7.2pt, fill: c-acc, weight: "bold")[NEW · one instance, all cameras]
  ])

  #arr-d(86mm, 86mm, 8mm, col: c-acc, t: 1.3pt)
  #dlbl(88mm, 88mm, "pose + covariance", col: c-acc, sz: 7pt)
  #arr-d(150mm, 86mm, 8mm, col: c-warm, t: 1.2pt)
  #dlbl(152mm, 88mm, "status", col: c-warm, sz: 7pt)

  #dbox(0mm, 94mm, 46mm, 13mm, c-alt, c-alt-bg, "gyro_odometer", "reused")
  #dbox(54mm, 94mm, 64mm, 13mm, c-alt, c-alt-bg, "ekf_localizer", "the only pose consumer")
  #dbox(126mm, 94mm, 44mm, 13mm, c-warm, c-warm-bg, "MRM / system", "stop on FAULT")
  #arr-r(46mm, 100.5mm, 8mm)
  #dlbl(0mm, 110mm, "IMU + wheel odometry")

  #arr-d(86mm, 107mm, 8mm)
  #dbox(54mm, 115mm, 64mm, 12mm, c-alt, c-alt-bg, "kinematic_state", "fused output · 50 Hz")

  #seg(54mm, 121mm, 48mm, 121mm, c-faint, 0.7pt, (2pt, 2pt))
  #seg(48mm, 121mm, 48mm, 80mm, c-faint, 0.7pt, (2pt, 2pt))
  #seg(48mm, 80mm, 50mm, 80mm, c-faint, 0.7pt, (2pt, 2pt))
  #head-r(52mm, 80mm, c-faint)
  #dlbl(30mm, 129mm, "twist, for motion compensation within the window")

  #seg(0mm, 133mm, 170mm, 133mm, c-rule, 0.7pt, none)
]

#v(-2mm)
#grid(columns: (auto, auto, auto, 1fr), gutter: 3mm,
  chip(c-acc, c-acc-bg, "NEW"), chip(c-alt, c-alt-bg, "REUSED UNMODIFIED"),
  chip(c-faint, white, "EXISTING"),
  block(width: 100%)[
    #set par(justify: false)
    #text(size: 8.4pt, fill: c-warm)[
      *Must not be launched:* `ndt_scan_matcher` · `cuda_ndt_matcher` ·
      `pointcloud_map_loader` · NDT preprocessing ·
      `autoware_ar_tag_based_localizer` · `pose_estimator_arbiter`
    ]
  ])

#v(1.5mm)
No upstream package is forked. Two config changes are mandatory: restore
`pose_gate_dist` from `10000.0`, since the EKF's outlier gate is now the only
defence against a bad fix; and add a golfcart map component, because
`tier4_map_launch` composes the point cloud map loader unconditionally with no
argument to disable it.

= 3. Notation

Every symbol used in this document is defined here.

#note(c-acc, "Transform convention")[
  $bold(T)_(a b)$ takes a point from frame $b$ to frame $a$:
  $bold(p)_a = bold(T)_(a b) bold(p)_b$. Compose left to right,
  $bold(T)_(a c) = bold(T)_(a b) bold(T)_(b c)$; invert to reverse,
  $bold(T)_(b a) = bold(T)_(a b)^(-1)$. Each $bold(T) in "SE"(3)$ is a rotation
  $bold(R)$ plus a translation $bold(t)$, acting as
  $bold(T) bold(p) = bold(R) bold(p) + bold(t)$.

  Getting this direction wrong is the most common way a pose pipeline produces
  plausible, self-consistent, wrong numbers.
]

== Frames

#tbl(columns: (13mm, 1fr), align: (left + horizon, left),
  [$m$], [*map* — world frame. Board poses and the output pose live here.],
  [$b$], [*base_link* — vehicle body frame. What we solve for.],
  [$c$], [*camera optical frame*, one per camera: $z$ forward, $x$ right, $y$ down. PnP always returns poses in this frame, never the camera *body* frame — confusing the two rotates every observation by about 90°.],
  [$t_i$], [*board $i$'s frame* — origin at the marker centre, $x$ right, $y$ up, $z$ out of the printed face. OpenCV's convention.])

== Geometry

#tbl(columns: (23mm, 11mm, 1fr), align: (left + horizon, center + horizon, left),
  table.header(th("SYMBOL"), th("SIZE"), th("MEANING · SOURCE")),
  [$bold(T)_(m b)$], [SE(3)], [*The unknown.* Vehicle pose in the map.],
  [$bold(T)_(m t_i)$], [SE(3)], [Board $i$'s pose in the map. Known, from the surveyed `aruco_tag_map.yaml`.],
  [$bold(T)_(b c)$], [SE(3)], [Camera $c$'s pose in base_link. Known, from TF.],
  [$bold(T)_(c t_i)$], [SE(3)], [Board $i$'s pose in camera $c$. Measured by PnP; used only for the candidates in §5.],
  [$bold(p)_j$], [$RR^3$], [Corner $j in {0..3}$ in the board's frame: $(minus.plus s\/2, plus.minus s\/2, 0)$.],
  [$bold(P)_(i j)$], [$RR^3$], [That corner in the map frame, $bold(T)_(m t_i) bold(p)_j$.],
  [$bold(Y)_(i j)$], [$RR^3$], [That corner in base_link (§6.1).],
  [$bold(X)_(i j c)$], [$RR^3$], [That corner in camera $c$'s frame.],
  [$bold(x)_(i j c)$], [$RR^2$], [*The measurement* — where the corner appeared, in rectified pixels.],
  [$bold(K)_c$], [$RR^(3 times 3)$], [Camera $c$ intrinsics, from `CameraInfo`.],
  [$pi(bold(K), bold(X))$], [$RR^2$], [Pinhole projection of a point already in the camera frame: $(f_x X\/Z + c_x, space f_y Y\/Z + c_y)$.],
  [$f$, $s$, $Z$], [scalar], [Focal length in pixels; marker edge in metres; range to the board.],
  [$N$, $M$], [count], [Boards used in a solve; corner observations, $M = 4N$ when each board is seen once.])

== Solver

#tbl(columns: (23mm, 11mm, 1fr), align: (left + horizon, center + horizon, left),
  table.header(th("SYMBOL"), th("SIZE"), th("MEANING")),
  [$bold(r)_(i j c)$], [$RR^2$], [Residual: predicted pixel minus measured pixel (§6.1).],
  [$xi = (delta bold(t), delta bold(theta))$], [$RR^6$], [Pose increment — a small translation and a small rotation vector. What the optimizer solves for (§6.2).],
  [$bold(J)$], [$RR^(2M times 6)$], [Jacobian: how every predicted pixel moves when $xi$ changes (§6.3).],
  [$bold(W)$], [$RR^(2M times 2M)$], [Weight matrix, block diagonal, one $2 times 2$ block per corner (§7).],
  [$rho(dot)$], [—], [Huber robust kernel, applied per board (§7).],
  [$Delta xi$], [$RR^6$], [The step solved at each iteration (§6.4).],
  [$lambda$], [scalar], [Levenberg–Marquardt damping factor (§6.4).],
  [$sigma_"px"$], [scalar], [Corner localization noise, in pixels.],
  [$hat(sigma)^2$], [scalar], [Estimated residual variance (§8).],
  [$bold(V)$, $bold(Lambda)$, $lambda_k$], [—], [Eigenvectors, eigenvalue matrix, and $k$-th eigenvalue of $bold(J)^TT bold(J)$ (§8).],
  [$sigma_"max"^2$], [scalar], [Variance cap for unobservable directions (§8).],
  [$bold(Sigma)$], [$RR^(6 times 6)$], [Output pose covariance (§8).],
  [$bold(I)_3$], [$RR^(3 times 3)$], [Identity matrix.],
  [$bold(D)_pi$], [$RR^(2 times 3)$], [Derivative of the projection $pi$ with respect to a camera-frame point (§6.3).],
  [$[dot]_times$], [$RR^(3 times 3)$], [Skew-symmetric matrix of a vector, so $bold(a) times bold(b) = [bold(a)]_times bold(b)$.],
  [$e_1, e_2$], [scalar], [Reprojection errors of the two PnP solutions, $e_1 <= e_2$ (§4).])

No distortion coefficients appear anywhere: the detector already maps corners
into the rectified frame, so $pi$ is a pure pinhole.

= 4. One board gives two poses

PnP on a single square returns $bold(T)_(c t_i)$ — but two of them.

The image of a plane is a homography, and decomposing a homography yields two
physically valid poses that reproject the four corners to nearly the same
pixels [5]. Intuitively: a small or nearly fronto-parallel marker projects almost
affinely, and an affine projection of a plane cannot say which way the plane is
slanted. Only perspective breaks the tie — the near edge being slightly larger
than the far one — and that cue vanishes as the marker shrinks or flattens on.

OpenCV's `estimatePoseSingleMarkers` computes both and returns the lower-error
one. The ambiguity remains; the *choice* just becomes invisible, and flips frame
to frame when the errors are close. That is the measured 11.7° jitter of §9
[1].

So the detector calls `solvePnPGeneric` and keeps both. The ratio
$e_1\/e_2 in (0, 1]$ is the ambiguity metric: near 0 the answer is clear, near 1
the board cannot resolve its own orientation.

= 5. Stage one — consensus

Board $i$ with solution $k in {1,2}$ gives a full guess at the vehicle pose:

$ bold(T)_(m b)^((i,k)) = bold(T)_(m t_i)
  (bold(T)_(b c) bold(T)_(c t_i)^((k)))^(-1) $

Read right to left: base_link to the board, then board to the map. Because
$bold(T)_(m t_i)$ is known from the survey, this turns a camera-relative
measurement into an absolute pose. With $N$ boards there are $2N$ candidates;
cluster them in SE(3) and take the largest cluster.

#note(c-acc, "Why clustering works")[
  Every board watches the *same* vehicle, so the correct solutions all land on
  one pose and pile up. The wrong ones do not: each board's flip reflects about
  a plane through *its own* line of sight, a different transformation per board.

  No prior pose enters this argument — which is what makes cold start possible.
]

#note(c-warm, "Where it fails: coplanar boards flip together")[
  Two boards on one wall form a single planar point set, so their flips are
  nearly the same transformation. The wrong solutions then agree with each other
  as well as the right ones do: two equal clusters, a tie rather than a
  consensus.

  Hence the mounting rule is "≥2 boards *with different normals*", not merely
  "≥2 boards". Non-coplanar boards share no planar ambiguity and break the tie
  cleanly. A tie publishes nothing for that window.
]

Never resolve the flip by picking the candidate nearest the prior — that is how
an estimator ends up confirming what the filter already believes. The winning
cluster fixes each board's flip and seeds stage two.

= 6. Stage two — the joint solve

Stage one worked in pose space. Stage two returns to pixels, because that is
where the noise is: corner error is close to independent and isotropic in
pixels, so least squares on corners is the maximum-likelihood estimate.
Averaging per-board poses instead would need a correct $6 times 6$ weight per
board, which is exactly what no good model exists for.

== 6.1 Residual

Push each known map corner forward into the camera and compare:

$ bold(Y)_(i j) = bold(T)_(m b)^(-1) bold(P)_(i j) #h(3mm) "(base_link)"
  quad
  bold(X)_(i j c) = bold(T)_(b c)^(-1) bold(Y)_(i j) #h(3mm) "(camera)" $
$ bold(r)_(i j c) = pi(bold(K)_c, bold(X)_(i j c)) - bold(x)_(i j c) $

Splitting into $bold(Y)$ then $bold(X)$ matters: $bold(Y)$ is where the
Jacobian's geometry lives.

== 6.2 Optimizing on a manifold

$"SE"(3)$ is a manifold, not a vector space — there is no derivative with
respect to a pose that keeps the result a valid pose. So we differentiate with
respect to a small increment $xi = (delta bold(t), delta bold(theta))$ applied as

$ bold(T)_(m b) arrow.l bold(T)_(m b) exp(xi^and) $

where $exp(xi^and)$ turns the six-vector into a rigid transform. Each iteration
solves for the best $xi$, applies it, and re-linearizes. Six parameters, always
a valid pose.

== 6.3 The Jacobian

$bold(J)$ is $partial bold(r) \/ partial xi$: how each predicted pixel moves
when the pose is nudged. Chain rule, three links.

*Increment to base_link point.* The update gives
$bold(Y)(xi) approx bold(Y)_0 - delta bold(t) - delta bold(theta) times bold(Y)_0$,
so

$ (partial bold(Y)) / (partial xi) = mat(-bold(I)_3, [bold(Y)_0]_times)
  #h(5mm) (3 times 6) $

*base_link to camera.* A fixed rotation, so the derivative is that rotation:
$partial bold(X) \/ partial bold(Y) = bold(R)_(c b)$, size $3 times 3$.

*Projection.* Differentiating $pi$ with respect to $bold(X) = (X, Y, Z)$:

$ bold(D)_pi = mat(f_x / Z, 0, -(f_x X) / Z^2 ;
                   0, f_y / Z, -(f_y Y) / Z^2)
  #h(5mm) (2 times 3) $

Multiplying gives one $2 times 6$ block per corner:

$ bold(J)_(i j c) = bold(D)_pi space bold(R)_(c b)
  space mat(-bold(I)_3, [bold(Y)_(i j)]_times) $

Stack all $M$ corners: $bold(J)$ is $2M times 6$, so $bold(J)^TT bold(J)$ is
$6 times 6$ however many boards are visible.

#note(c-warm, "Signs")[
  The minus on $bold(I)_3$ comes from perturbing $bold(T)_(m b)$ while the
  residual contains its *inverse*. The other convention,
  $exp(xi^and) bold(T)_(m b)$, moves the signs. Either works; mixing them makes
  the optimizer walk away from the solution instead of converging.
]

== 6.4 Iteration

Levenberg–Marquardt damps Gauss–Newton so a bad linearization cannot take a wild
step:

$ (bold(J)^TT bold(W) bold(J) + lambda space
  "diag"(bold(J)^TT bold(W) bold(J))) space Delta xi
  = -bold(J)^TT bold(W) bold(r) $

Apply $bold(T)_(m b) arrow.l bold(T)_(m b) exp(Delta xi^and)$, re-linearize,
repeat until $norm(Delta xi)$ is below tolerance. Six unknowns and a few boards
is a small dense problem — no sparse solver, no external optimizer, and direct
access to $bold(J)^TT bold(J)$ for §8.

*Scale.* Three boards, two in one camera and one in another: $N = 3$, $M = 12$,
so $bold(J)$ is $24 times 6$ with $2M - 6 = 18$ degrees of freedom. That
over-determination is what makes the integrity check of §10 possible.

= 7. Weights and robustness

$bold(W)$ carries two things.

*Pixel noise*, the baseline $sigma_"px"^(-2) bold(I)_2$ per corner. Nothing more
is needed for the range-dependent anisotropy: the $1\/Z$ and $1\/Z^2$ terms in
$bold(D)_pi$ already produce $sigma_Z approx Z^2 sigma_"px" \/ (f s)$ [4]. It is a
consequence of the geometry, not a model to supply.

*Survey uncertainty.* A board with an uncertain surveyed pose should count for
less. Propagating its position standard deviation $sigma_"map"$ into pixels
gives about $(f\/Z) sigma_"map"$, so the corner variance becomes
$sigma_"px"^2 + (f\/Z)^2 sigma_"map"^2$.

#note(c-warm, "An approximation, stated as one")[
  That treats each corner independently, but a board's four corners share one
  surveyed pose — their map errors are perfectly correlated. The approximation
  makes the solve slightly *over*-confident about a badly surveyed board. The
  rigorous fix is a correlated block per board.
]

*Robust kernel.* Huber applied to a board's *summed* squared residual:

$ sum_((i,c)) rho( sum_(j=1)^4 norm(bold(r)_(i j c))^2 ) $

A board knocked askew, or mistyped in the map, makes all four corners wrong
together. Rejecting per corner would let three bad corners hide behind the
fourth.

= 8. Covariance and degeneracy

With $2M$ scalar residuals and six parameters,
$hat(sigma)^2 = sum norm(bold(r))^2 \/ (2M - 6)$.

Naively $bold(Sigma) = hat(sigma)^2 (bold(J)^TT bold(J))^(-1)$. But
$bold(J)^TT bold(J)$ is routinely near-singular, and *that is a result, not an
error*: it is the Fisher information, so a small eigenvalue means moving the
pose along that eigenvector barely changes any predicted pixel. The data does
not constrain it.

So eigendecompose $bold(J)^TT bold(J) = bold(V) bold(Lambda) bold(V)^TT$ and
invert per direction, capping each:

$ bold(Sigma) = bold(V) space "diag"( min( hat(sigma)^2 / lambda_k,
  space sigma_"max"^2 ) ) space bold(V)^TT $

This gives a large but finite variance where the geometry is blind, rather than
an exception or a numerical explosion. *Never emit a zero variance* —
downstream reads it as exact, and nothing contradicts it. The covariance is
built in the camera frame and rotated into the map frame, never assumed
axis-aligned in the vehicle frame.

== Reading the null direction off $bold(J)$

The block $mat(-bold(I)_3, [bold(Y)]_times)$ says which pose changes the data
cannot see. A perturbation moves the corner at $bold(Y)$ by
$delta bold(Y) = -delta bold(t) - delta bold(theta) times bold(Y)$. Let
$macron(bold(Y))$ be the centroid of the observed corners, write
$bold(Y) = macron(bold(Y)) + bold(Delta)$, and pick the translation that cancels
the rotation, $delta bold(t) = -delta bold(theta) times macron(bold(Y))$:

$ delta bold(Y) = -delta bold(theta) times bold(Delta) $

*A rotation about the centroid, with the matching translation, moves each point
only in proportion to its offset from that centroid.* Clustered boards — one
wall, one depth, or a single board — have small $bold(Delta)$, so the residual
barely changes and that direction collapses.

One derivation covers all three cases: a lone board, a coplanar cluster, and
good spread are the same phenomenon at different strengths. Hence one covariance
mechanism, and no special cases in the code.

== Degrees of freedom, per window

#tbl(columns: (56mm, 25mm, 1fr), align: (left, left, left),
  table.header(th("OBSERVABILITY"), th("SOLVE"), th("ORIENTATION")),
  [≥2 boards in consensus, normal spread above threshold], [full 6-DoF], [Estimated. Nominal.],
  [≥2 boards, coplanar or narrow spread], [6-DoF, saturated], [Estimated, weak axis saturated.],
  [1 board, $e_1\/e_2 <= 0.2$, outside the ±25° cone], [3-DoF position], [Clamped to the prior.],
  [1 board, ambiguous or inside the cone], [reject], [—])

One code path with a mask on the parameter vector, not three implementations.

= 9. What the numbers force

#grid(columns: (1fr, 1fr, 1fr, 1fr), gutter: 2.5mm,
  ..(
    ("11.7°", "single-board rotation jitter, std over 1000 frames [1]"),
    ("15×", "accuracy gain, 1 → 7 boards, knee at 5 [2]"),
    ("25–75°", "usable window off the board normal [1,3,6,7]"),
    ($sigma_Z prop Z^2 \/ s$, "depth error scaling [4]; 26× at 10 m is derived"),
  ).map(p => block(width: 100%, fill: white, stroke: 0.6pt + c-rule,
    inset: (x: 2.5mm, y: 2.2mm))[
    #text(font: mono, size: 13pt, weight: "bold", fill: c-ink, p.at(0))
    #v(0.8mm)
    #text(size: 7.4pt, fill: c-soft, p.at(1))
  ]))

#v(2mm)
#note(c-warm, "Counter-intuitive, and four sources agree")[
  *Looking straight at a board is the worst case for orientation.* Variance
  peaks along the board normal and drops an order of magnitude at 40–70° [3];
  detection separately survives to 75° and collapses by 85° [1]. Pitch is
  indistinguishable across −10° to +10° [6], and one group excludes a ±25° cone
  from testing outright [7]; another puts the sweet spot at 25–75° [8]. The usable window
  is bounded *below* by ambiguity and above by detection failure.

  Corner *localization* stays under 0.35 px across that whole sweep [1]. Range
  destroys pose stability, not pixel stability — the geometry conditioning
  collapses, the pixels do not get noisier.
]

= 10. Deployment and states

Mounting is decided with a drill and matters more than anything in the code.

#tbl(columns: (56mm, 1fr), align: (left, left),
  [*≥2 boards with different normals, visible everywhere*],
  [An availability requirement, not an accuracy target. Count alone is not
   enough — two boards on one wall are coplanar and leave the ambiguity
   unresolved (§5). Below this, heading is uncorrected.],
  [*≥5 boards where accuracy matters*], [The measured knee; past seven the gain is marginal.],
  [*Yaw boards ~30° off the wall*], [So the driving line never sits inside the ±25° ambiguity cone.],
  [*Spread normals and depths*], [Five coplanar boards at one depth are worth less than three on different walls.])

#note(c-acc, "Before printing anything")[
  Walk the route with a camera and count what is visible where, and at what
  incidence. It sizes the board count and says whether the rule above is
  satisfiable at this site.
]

#v(2mm)
*Localization state*, published, driving the MRM hook:

#grid(columns: (1fr, 1fr, 1fr, 1fr), gutter: 2.5mm,
  ..(
    ("NOMINAL", "≥2 boards, spread OK. 6-DoF, heading corrected."),
    ("DEGRADED", "1 board or poor spread. Position only, time-limited."),
    ("DEAD_RECKONING", "0 boards. Gyro + odometry, error unbounded."),
    ("FAULT", "Budget expired or integrity failed → MRM stop."),
  ).map(p => block(width: 100%, fill: white, stroke: 0.6pt + c-rule,
    inset: (x: 2.5mm, y: 2mm))[
    #text(font: mono, size: 8pt, weight: "bold", fill: c-ink, p.at(0))
    #v(0.8mm)
    #text(size: 7.6pt, fill: c-soft, p.at(1))
  ]))

#v(2mm)
Recovery is available from every state except `FAULT`. The dead-reckoning budget
must follow from *measured* IMU drift and odometry error; the shipped default is
a deliberately short placeholder.

*Integrity* is the GNSS RAIM problem [9]. With ≥2 boards the solve is
over-determined, so each board's post-solve residual checks it against the
others: a board that has moved or been mistyped shows a persistently large
residual while its neighbours stay small. Track a per-ID residual average, flag,
exclude, and name the physical board to inspect.

Two limits, stated rather than hidden. Exclusion needs redundancy — with two
boards, excluding one leaves an unchecked solve, and with one there is no check
at all, so the published status marks a fix *checked* or *unchecked*. And it
cannot catch an error affecting every board at once: a wrong marker size, a
wrong extrinsic, a map frame offset. Boards are checked against each other, not
against an independent source.

= 11. Interfaces

#tbl(columns: (58mm, 1fr), align: (left, left),
  [`~/input/detections/{left,right,rear}`],
  [`ArucoDetectionArray` — rectified corners, the $bold(K)$ used, both PnP solutions and their errors. Self-contained, so a recorded stream replays without a camera.],
  [`/localization/pose_estimator/`\ `pose_with_covariance`],
  [*The sole pose source.* `PoseWithCovarianceStamped`, frame `map`, stamped with the *sensor* time.],
  [`/initialpose3d`], [Cold start. Nothing to NDT-refine, so the first well-conditioned solve is the answer.],
  [`~/status`], [State, DoF solved, boards used / flagged / unmapped, observability metrics, checked or unchecked.],
  [`/localization/kinematic_state`], [Consumed for twist, to motion-compensate detections to a common stamp.])

== Tag map

```yaml
frame_id: map
survey: {stated_accuracy: 0.02}    # [m] 1-sigma — the system's accuracy ceiling
defaults: {dictionary: DICT_5X5_1000, marker_size: 0.384}   # marker, not board
tags:
  - id: 696
    position:    {x: 12.340, y: -3.210, z: 1.500}
    orientation: {x: 0.0, y: 0.0, z: 0.70711, w: 0.70711}
  - id: 306
    corners: [[...], [...], [...], [...]]     # TL, TR, BR, BL — prefer for a survey
```

Four measured corners fix position, orientation and size at once, with no frame
convention for a human to get wrong; a hand-written quaternion means deciding
what the board's axes mean and being right about it. Both forms must agree, and
a test enforces that.

`stated_accuracy` is the ceiling on the whole system: survey and vision error
add in quadrature, so 2 cm survey with 3 cm vision gives about 3.6 cm, while a
10 cm survey makes vision accuracy irrelevant.

Rejected at load, each naming the board: duplicate ID (uniqueness is what makes
association prior-free), non-planar corners (no defined orientation), a
quaternion whose norm is not 1 (refused rather than normalized — usually
transcription error), and missing marker size or position uncertainty.

== Parameters worth arguing about

#tbl(columns: (44mm, 1fr), align: (left, left),
  [`corner_sigma_px: 0.3`], [*Inferred, not measured.* No published work measures corner noise for ArUco with sub-pixel refinement. Back-solved from [10] and cross-checked against [1]; the covariance model scales on it. Logged as `(INFERRED)` at startup; measured in phase 3D-5.],
  [`min_view_angle_deg: 25`], [A *lower* bound — below it the planar ambiguity dominates.],
  [`max_view_angle_deg: 75`], [Upper bound — detection starts failing.],
  [`ambiguity_ratio_max: 0.2`], [On $e_1\/e_2$; near 1 is ambiguous. The only threshold we found deployed in the field [11]; IPPE itself prescribes a likelihood-ratio test but publishes no number [5].],
  [`huber_delta_px: 2.0`], [Per board, not per corner.],
  [`dead_reckoning_budget_s: 3.0`], [*Placeholder.* Must follow from measured IMU drift.])

= 12. Status and open questions

Phase 3D-1 is complete: messages, the tag map loader with both forms, the frame
convention and a node skeleton, 34 tests green. The corner-order test was
verified to fail — rotating the order by one broke five tests, and OpenCV
reported "rotated by 89.999997 deg about (0,0,1)". Phases 3D-2 (launch switch)
and 3D-3 (synthetic detection source) are unblocked; the solve is 3D-4.

#note(c-warm, "Blockers — none are software")[
  *No `*_optical_link` in the URDF.* Cameras are body-frame links with no
  optical child, while PnP returns optical-convention poses. Every observation
  lands about 90° rotated until this is added.

  *One calibration file copied to three cameras*, with $bold(K)$ and the
  projection matrix disagreeing 25% on $f_x$.

  *`pose_gate_dist: 10000.0`* disables the EKF gate that is now the only defence
  against a bad fix.

  *DBW publishes zero velocity*, so the EKF has no real twist. This blocks the
  *fused* output; the raw localizer pose can still be validated against ground
  truth with no vehicle interface.
]

#v(1.5mm)
*Open questions, in order of leverage.*

#tbl(columns: (6mm, 1fr), stroke: none, align: (right, left),
  [1.], [*Survey instrument and accuracy* — sets the ceiling for the whole system.],
  [2.], [*Board layout and count* — is ≥2-with-different-normals satisfiable here? A route walk answers it before printing.],
  [3.], [*Board geometry actually used* — dictionary, size, border, ratio. Marker size scales every range estimate linearly.],
  [4.], [*Dead-reckoning budget* — follows from measured IMU drift.],
  [5.], [*Keep `pose_initializer` or publish `/initialpose3d` directly?* Direct is simpler; keeping it preserves the AD API localization state.],
  [6.], [*LCTK message change* — replace its `Detection2DArray` output or run both? Replacing is cleaner but breaks its calibration pipeline.])

#v(1.5mm)
#note(c-alt, "Standing risk")[
  The LiDARs stay on the vehicle for perception, and remain the obvious route to
  an *independent* check on localization if coverage proves hard in practice.
]

= References

Numbers in this document are cited below. Where a value is *derived* or
*inferred* rather than taken from a source, it is marked as such at the point of
use — see `corner_sigma_px` in §11 and the 26× anisotropy in §9.

#tbl(columns: (6mm, 1fr), align: (right, left),
  [\[1\]], [Benligiray, Topal, Akinlar. *STag: A Stable Fiducial Marker System.*
    Image and Vision Computing, 2019. arXiv:1707.06292.
    Source of the 11.7° rotation jitter (§5.5.1), the corner-localization
    stability under 0.35 px (Fig. 15), and the detection-rate cliff — 0 misses
    to 75°, 416/1000 at 80°, total failure at 85° (Table 5). Static camera and
    marker, 1000 frames per condition, so these are *precision* figures, not
    accuracy against ground truth.],

  [\[2\]], [*Investigation of ArUco Marker Placement for Planar Indoor
    Localization.* arXiv:2509.17345, 2025. 15 cm markers, 1080p camera at
    2.991 m: x-RMSE falls 45.29 → 24.94 → 8.83 → 5.10 → 3.72 → 3.22 → 2.97 cm
    for 1 through 7 markers. The "15×" and the knee at five come from this
    series.],

  [\[3\]], [Adámek et al. *Analytical Models for Pose Estimate Variance of
    Planar Fiducial Markers.* Sensors 23(12):5746, 2023.
    Variance peaks at φ = 0 (line of sight along the marker normal) and is an
    order of magnitude lower between 40° and 70°. Also the source for the
    warning that fusing per-marker Gaussians violates independence and yields
    unrealistically low variance (§6.3 of that paper).],

  [\[4\]], [Fernández Llorca et al. *Vision-based Vehicle Speed Estimation: A
    Survey.* IET Intelligent Transport Systems, 2021. arXiv:2101.06159, Eq. 4 —
    the quadratic range dependence, with the marker edge playing the role a
    stereo baseline plays. The functional form is confirmed for ArUco
    specifically by [3], which publishes the shape but no fitted constants.],

  [\[5\]], [Collins, Bartoli. *Infinitesimal Plane-Based Pose Estimation.*
    IJCV 109(3):252–286, 2014. The planar two-solution ambiguity and the IPPE
    solver. Its documentation prescribes a likelihood-ratio test to reject the
    second solution but gives no numeric threshold.],

  [\[6\]], [*A novel encoding element for robust pose estimation using planar
    fiducials.* Frontiers in Robotics and AI 9:838128, 2022. Pitch
    indistinguishable anywhere between −10° and +10° at 3.3 m.],

  [\[7\]], [Richter, Bohlig, Nüchter, Schilling. *Advanced Edge Detection of
    AprilTags for Precise Docking Manoeuvres of Mobile Robots.* IFAC, 2022.
    Excludes a ±25° cone about the marker normal from testing. Also reports
    ≈3 mm / 0.15° against an iGPS reference over 1.4–6.7 m — conditional on that
    exclusion.],

  [\[8\]], [Abbas, Aslam, Berns, Muhammad. *Analysis and Improvements in
    AprilTag Based State Estimation.* Sensors 19(24):5480, 2019. Places the
    accuracy sweet spot at 25°–75° off the marker normal, and shows error
    growing toward the image edges.],

  [\[9\]], [Receiver Autonomous Integrity Monitoring — the GNSS
    fault-detection-and-exclusion literature. Cited as the structural analogue
    for §10's per-board residual monitoring, not as a specific result.],

  [\[10\]], [FMAC. arXiv:2601.07723, 2026. Synthetic high-fidelity renders,
    10 000 sampled poses: $sigma_X = 5.4$ mm, $sigma_Y = 3.8$ mm, $sigma_Z = 14.7$ mm
    for a 50 mm marker at 0.5–1.5 m, 640×480. Back-solving the model of [4] against these
    gives the $sigma_"px" approx 0.2$–$0.4$ px that `corner_sigma_px` is anchored on.],

  [\[11\]], [PhotonVision documentation, 3D tracking. Defines ambiguity as the
    ratio of the two solutions' reprojection errors and advises rejecting poses
    above 0.2. A deployed field threshold rather than a published measurement.],
)

#v(2mm)
#note(c-warm, "Two caveats on the evidence")[
  *These are ArUco and AprilTag figures mixed together.* [7] and [8] measure
  AprilTag, [1] and [2] measure ArUco. The geometry that drives the viewing-angle
  window is shared, but the detectors differ, so treat the band as an
  engineering consensus rather than a measurement of our exact configuration.

  *One source we could not obtain.* Kalaitzakis et al., *Fiducial Markers for
  Pose Estimation* (J. Intelligent and Robotic Systems 101:71, 2021) is the most
  frequently cited head-to-head comparison of ArUco, AprilTag, ARTag and STag.
  It is paywalled with no open version, so its error tables are not represented
  here. Worth buying if these numbers become load-bearing for a safety argument.
]
