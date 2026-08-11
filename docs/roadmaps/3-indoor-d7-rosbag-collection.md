# Phase 3D-7 — Rosbag collection

Part of [Phase 3D](3-indoor-d-runtime-integration.md).
Spec: [design](../superpowers/specs/2026-08-10-aruco-indoor-localizer-design.md) §10

**Depends on**: nothing. **Runs in parallel with D1–D6, starting now.**

---

## Goal

Recorded real-camera data to develop and validate the detector against, and to
answer the questions simulation structurally cannot.

**Recording is not blocked by camera calibration.** Calibration is applied
downstream of the raw image, so bags recorded today stay valid when the
intrinsics are fixed — as long as `camera_info` is recorded alongside so it is
visible what was assumed at capture time. Do not wait for sub-phase A.

---

## Fix this before the first recording

`scripts/rosbag/record_outdoor.sh` lists `/sensing/camera/front/image_raw`,
`/sensing/camera/front/image_raw/compressed` and
`/sensing/camera/front/camera_info` — the old single-camera topics. The sensor
kit's `camera.launch.xml` publishes **left, right and rear**, and only the
compressed topic is remapped, so `image_raw` does not exist at all.

Recording against the current list captures nothing.

- [ ] New `scripts/rosbag/record_aruco.sh` with the correct topics:
      ```
      /sensing/camera/{left,right,rear}/image_raw/compressed
      /sensing/camera/{left,right,rear}/camera_info
      /sensing/imu/imu_data
      /tf  /tf_static
      /vehicle/status/velocity_status        # zeros for now, record anyway
      /diagnostics
      ```
- [ ] `just bag-record-aruco` recipe.
- [ ] Fix or retire the stale `front` topics in `record_outdoor.sh` and
      `record_localization.sh` while in there.

**Record compressed, not raw.** Three 1920×1280 streams at 30 Hz is roughly
2 GB/minute raw. Check available disk before a long session, and check whether
the recorder keeps up — dropped frames in a bag are worse than a lower recorded
rate, because they are invisible later.

---

## Two collection tracks

### Bench bags — start immediately

Four or five boards in a room, positions measured with a tape. No vehicle, no
site, no mounted boards. Enough for all detector development and most accuracy
work.

- [ ] **Static, single board, fronto-parallel, ~1000 frames.** This is the
      `corner_sigma_px` measurement (D5) and it is the single most valuable
      recording on this list, because that constant is currently inferred from
      other people's data and the whole covariance model scales on it.
- [ ] **Static, at two more ranges** — near and far. Confirms whether corner
      noise is range-dependent, which the literature does not answer.
- [ ] **Static, oblique** — roughly 45° and 70° incidence.
- [ ] **Fronto-parallel approach** — walk the camera straight down a board
      normal. This is the ambiguity worst case and the recording that shows how
      often the flip actually bites.
- [ ] **Multi-board, well-spread** — the nominal case.
- [ ] **Multi-board, coplanar at one depth** — the degenerate case.
- [ ] **Handheld motion at walking pace** — motion blur and exposure behaviour.
- [ ] **Exposure comparison** — the same scene with `auto_exposure` true and
      false. Auto-exposure hunting plus motion blur is the leading cause of
      intermittent detection, and this recording is the evidence for fixing the
      gscam profile.

### Site bags — after boards are mounted and surveyed

- [ ] **Full route, nominal.** The reference recording.
- [ ] **Coverage census.** Drive or walk the whole route recording all three
      cameras, then count boards visible per position offline. This is the
      coverage survey from the master roadmap, and doing it from a bag means it
      can be re-analysed when detection parameters change instead of re-walked.
- [ ] **Known coverage gaps**, if any exist after mounting.
- [ ] **Lighting variation** — the same route at different times of day, and with
      lights on and off if the field has controllable lighting.

---

## Ground truth without a total station

Accuracy claims need something to compare against. Sparse ground truth is enough
and is cheap to get:

- [ ] Mark a set of surveyed stop points on the route.
- [ ] Drive to each, stop, and note the wall-clock time or trigger a marker
      topic recorded into the bag.
- [ ] Offline, compare the localizer's pose at those stamps against the measured
      positions.

Sparse, but it is *absolute* — which continuous comparison against another
estimator is not.

---

## Conventions

- [ ] Bags land in `rosbags/` following the existing pattern.
- [ ] Name them so the scenario is readable without opening them:
      `aruco_bench_static_1board_3m_20260810_1430`.
- [ ] **A sidecar note per bag** recording what was actually done: board layout
      and measured positions, camera settings, lighting, anything that went
      wrong. A bag whose conditions are not written down is much less useful six
      weeks later, and this is the cheapest possible moment to write them down.
- [ ] Record the tag map file used, alongside the bag.

---

## Acceptance

- `corner_sigma_px` measured at three ranges and while moving, and the value
  written into the localizer config with the measurement referenced.
- Detection rate characterized against incidence angle and range, on real
  optics — enough to confirm or correct the 25–75° usable window the design
  takes from the literature.
- A fixed-exposure gscam profile chosen on evidence.
- At least one multi-board bench bag that D5's detector and D4's localizer can
  run against end to end, with tape-measured ground truth.

---

## What these bags settle that simulation cannot

Simulation shares its camera model, tag map and geometry conventions with the
localizer, so a consistent error in any of them cancels and passes.

Real recordings are the only source for: lens distortion against the actual
`rational_polynomial` calibration, detection rate under real lighting and motion
blur, CPU cost of three detectors on the Orin, exposure behaviour, and whether
the board layout delivers the coverage the design assumes.

Collecting them early means these answers arrive while there is still time to
act on them — particularly the coverage census, which can change where boards
get mounted, and the CPU measurement, which can change the detection rate the
whole design budgets for.

## Status — tooling done, recordings blocked on hardware

Everything except pressing record is in place. The measurements themselves need
a camera, printed boards and a tape measure, and the site bags need the vehicle
and the mounted boards; none of that can be produced from a workstation.

### Recording

- `scripts/rosbag/record_aruco.sh`, `just bag-record-aruco <scenario>`.
  Records the three compressed camera streams with their `camera_info`, IMU, TF,
  velocity status and `/diagnostics`, plus the detector output if it happens to
  be running.

  It checks free disk before starting and, more usefully, **lists topics that
  nobody is currently publishing and asks before continuing**. `ros2 bag record`
  will happily record a topic with no publisher and produce an empty channel,
  which is exactly how a session gets recorded with no camera data and nobody
  notices until afterwards.

- `record_outdoor.sh` named `/sensing/camera/front/image_raw`,
  `.../front/image_raw/compressed` and `.../front/camera_info`. There is no
  `front` camera on this vehicle and no raw `image_raw` on any of them: the kit
  brings up left, right and rear, and gscam is configured compressed-only. Every
  camera channel it recorded was empty. Fixed.
  (`record_localization.sh` turned out not to name any camera topics.)

- `scripts/rosbag/bag_note_template.md`, copied next to each bag automatically.
  It asks for the tag map used, how board positions were measured **and to what
  stated accuracy** — that number is the ceiling on every accuracy claim later
  made from the bag — the exposure setting, and what went wrong.

### Analysis

`scripts/analysis/aruco_bag_report.py`, `just bag-report-aruco <bag>`. Three
reports, matching the three questions in this phase:

- **corner sigma** — per-board standard deviation of corner pixel positions,
  pooled over the eight coordinates. Also prints **drift**, the start-to-end
  movement of the mean, so a "static" recording where the rig actually crept is
  visible rather than silently reported as corner noise.
- **detection geometry** — detections bucketed by range and by incidence angle,
  with median ambiguity ratio per bucket. This is what confirms or corrects the
  25–75° window the design takes from the literature.
- **coverage census** — boards visible per solve window, how many had normals
  spread far enough for 6-DoF, and the **longest unbroken stretch with no usable
  constellation**. That last number is the one to compare against
  `dead_reckoning_budget_s`: a hole longer than the budget is a stop, not a
  degradation. An average hides it completely.

### Verified against a synthetic bag

The tooling was run end to end on a bag recorded from the simulator. The corner
sigma report recovered **0.296–0.303 px** from data generated with
`corner_sigma_px: 0.3`, so the measurement method round-trips. That validates the
tool, not the constant: 0.3 is still inferred, and only a real camera pointed at
a real board can replace it.

One bug surfaced from that run and is worth recording, because it would have
produced a confidently wrong conclusion about board layout. The coverage census
originally counted each **camera's** message as one window, so a vehicle seeing
one board in each of three cameras was scored as "one board" three times. The
symptom was a suspiciously tidy 33.3 / 33.3 / 33.3 split. Detections are now
grouped across cameras by time, using the same window as the localizer, and the
same bag reports 99.4 % two-or-more.

### What is left, and what it needs

| item | needs |
|---|---|
| `corner_sigma_px` at three ranges and while moving | one camera, one board, a tripod, a tape measure |
| detection rate against incidence and range | the same, plus a protractor or a measured layout |
| fixed-exposure gscam profile chosen on evidence | the same scene recorded with auto-exposure on and off |
| multi-board bench bag, end to end | four or five boards and tape-measured positions |
| all site bags, coverage census, stop-point ground truth | mounted boards, a surveyed map, the vehicle |

The bench recordings need no vehicle, no site and no mounted boards, and the
corner-sigma one is roughly an hour of work. Everything downstream of it — the
whole covariance model — is currently scaled by a number nobody here has
measured.
