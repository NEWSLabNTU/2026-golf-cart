# Phase 7 — reflective-board cold start for NDT

Bring the vehicle up indoors with no GNSS: the driver positions the cart so the
VLP-32C sees a known retroreflective board, the detector finds it, NDT gets an
initial pose from it, and NDT tracking runs against a point-cloud map anchored
to that same board.

Package: [`src/localization/reflective_pose_detector`](../../src/localization/reflective_pose_detector/README.md)
Design: [reflective_pose_detector.md](../../src/localization/reflective_pose_detector/docs/design/reflective_pose_detector.md)

## The target sequence

1. Vehicle starts. Localization stack up, `/localization/initialize` available.
2. Driver moves the cart until the board is in view. **Scans taken while moving
   are discarded** — stacking assumes a stationary sensor.
3. Cart stops. The detector accumulates, detects, and publishes the vehicle pose
   on `~/board_pose`, continuously, whenever it has one it trusts.
4. `reflective_pose_autoware` gates on velocity, takes one pose, and calls
   `/localization/initialize` with `method=AUTO`.
5. NDT align refines the guess and tracks against the anchored PCD map.

Steps 3 and 4 largely exist. Step 5's map was delivered 2026-09-10 (see
[Track B, delivered](#track-b--delivered)). What follows is the gap.

## Decisions, 2026-09-10

Made at the campaign kickoff. Each one changes an item below, and the item says
so where it applies.

| Decision | Consequence |
|---|---|
| The board is **0.6 x 0.6 m**, centre **1.3 m** above the floor | `board.height: 0.97` was wrong. B2's lead was chosen for its 0.97 m vertical extent, so it was picked for the wrong reason; the delivered anchor shows it was the right cluster anyway. |
| Runtime `intensity_threshold` is **100** on the VLP-32C | Bottom of the datasheet retroreflector band, so a sensor contract rather than a tuning. Replaces A4's derivation. A1 and A2 stop being refinements: the shape gates now sort everything retroreflective in the basement. |
| A teammate anchors the map, not this repository | Track B is consumed, not run, here. `anchor-map-to-board` stays the tool; C3's wrapper becomes a rebuild aid, not a prerequisite. |
| D1 is **init-only** from `vlp32_1` | D1b stays blocked on a bag with velocity and IMU. No synthetic-twist experiment. |
| One config file per reader, scenario directories | Replaces C1's two-file split. Layout under C1. |
| Board init is `pose_initializer:=board`, orthogonal to `pose_source` | Replaces C2's "sixth `pose_source` value": one value cannot compose with both `ndt` and `cuda_ndt`. |

## Track A — a detector that survives being driven around

The node already publishes on **every** successful detection rather than latching
after the first, so "continuously emit when found" is done. Two things stop it
being usable while a driver hunts for the board.

### A1 — `AMBIGUOUS` must stop being terminal

Today a second surviving candidate calls `_fail()`, which sets `State.FAILED`,
and `_on_cloud` returns immediately forever after. The reasoning was sound for a
one-shot initializer: "the map holds one board, so two survivors means the
assumption is broken, and choosing would produce a confident wrong pose."

Under the target sequence that reasoning inverts. The cart is being driven around
a basement whose map contains **308 retroreflective clusters** (measured, see
Track B), so a transient second candidate is expected, not exceptional. A
detector that latches off the first time two reflectors are in frame never
recovers, and the driver has no way to know why.

Refusing to publish an ambiguous frame stays correct. Refusing to look at any
later frame does not.

**Done when:** ambiguity suppresses that frame's pose, is visible on
`/diagnostics`, and the next frame is still processed. `NO_CANDIDATE` already
behaves this way.

### A2 — a confidence gate on what gets published

"Emit when found with high confidence" needs a definition of confidence. The
detector already computes the raw material — plane residual, extent error
against nominal, point count against the expected density, how many of the four
bounding edges were actually observed, range — and folds some of it into the
covariance. Nothing thresholds it.

Publishing every geometric survivor and leaving the decision to a downstream
covariance check spreads one judgement across two packages.

**Done when:** a single scalar confidence is computed from those terms, exposed
on the diagnostic, and gated by one config key; poses below it are not
published, and the reason is legible.

### A3 — the motion guard is wired on the vehicle

`ros.twist_topic` defaults to empty, which disables it. That is right on a bench
and wrong here: step 2 of the sequence has the cart moving by definition.

**Done when:** the vehicle config sets it to a real topic and a bag replay shows
scans discarded while moving and accepted once stopped.

### A4 — the runtime intensity threshold is wrong, and nothing will detect until it is fixed

`detector.intensity_threshold` is 240.0, and the config comment calls it a sensor
contract rather than a tuning: "the VLP-32C reports calibrated reflectivity,
0-100 diffuse, 101-255 reserved for retroreflectors."

The band is real. The threshold is not reachable. Measured over the whole
replay bag (see D1), sampling every twelfth scan:

| threshold | points per scan (median / p90 / max) | scans with >= 60 points |
|---|---|---|
| > 240 | 0 / 2 / **5** | **0 of 197** |
| > 200 | 30 / 84 / 123 | 43 of 197 |
| > 150 | 166 / 317 / 654 | 188 of 197 |

`cluster_min_points` is 60. **No scan in the bag clears it at 240**, so the
detector cannot produce a candidate at any point in that drive, and would report
`NO_CANDIDATE` for the entire run without anything being wrong with the geometry
gates, the TF or the board.

The datasheet band being 101-255 does not mean this board at this range through
this sensor's calibration returns 240. It returns something in the 150-255 range,
and the threshold has to come from the data.

**Do not simply lower it to 150.** At 150 the median scan has 166 qualifying
points spread across whatever else in a basement is retroreflective, which is
what the clustering and shape gates are then asked to sort out — the same problem
Track B found in the map, one sensor over. Derive it from the separation between
the board's returns and everything else in the same scan, and record which scan
and which cluster the number came from.

**Done when:** the runtime threshold is derived from bag data with the evidence
recorded beside it, and a replay produces candidates.

**Decided 2026-09-10: 100.** Not derived from the separation study above but
from the datasheet band edge, which makes it a sensor contract like the old
value claimed to be, only reachable. The table above still describes what the
clustering and shape gates are then asked to sort, which is why A1 and A2 are
prerequisites of this number rather than follow-ups. The comment beside the key
in the scenario file carries this paragraph. Still done when a replay produces
candidates.

## Track B — an anchored PCD map from the GLIM basement survey

Source:

```
~/nas/autoveh/dataset/2026-08-20 GLIM pointcloud mapping bags/falcon_map/
```

Two exports of the same survey. The `~/nas` mount path is the same on the other
development machines, so these paths are quotable as written.

`anchor-map-to-board` already does the shape of this job — detect the board,
move the origin onto it, write `pointcloud_map.pcd`, `board_anchor.yaml`,
`board_polygon.osm` and `map_projector_info.yaml` with `projector_type: Local`.
Track B is making it work on *this* cloud, and the study below says it will not
work unchanged.

### What the survey actually contains

Measured, not assumed:

| | `basement_voxel_resol_0.5.ply` | `basement_voxel_resol_0.15.ply` |
|---|---|---|
| points | 483,100 | 3,995,308 |
| retro returns (>240) | 11,927 | 142,109 |
| clusters | 97 | 308 |

Extent is roughly 105 x 81 m, floor at z ≈ -0.06, and the intensity histogram is
strongly bimodal — median 16, p90 44, p99 254 — so **the Falcon does produce a
usable retroreflector band**, which was the first open question.

### Track B — delivered

Anchored 2026-09-10 by the survey team with `anchor-map-to-board`, on the
0.15 m export:

```
~/nas/autoveh/dataset/2026-08-20 GLIM pointcloud mapping bags/autoware_falcon_map/basement_voxel_resol_0.15/
  pointcloud_map.pcd        3,995,308 points, x y z intensity, binary, 64 MB
  board_anchor.yaml         the transform and the detection it came from
  board_polygon.osm         0.6 x 0.6 m at y = ±0.3, z = 1.0 to 1.6
  map_projector_info.yaml   projector_type: Local
```

From `board_anchor.yaml`, so the rest of this track can be read against it:

| | |
|---|---|
| board in source frame | centre (-10.21, 3.91, 0.70), normal (0.992, 0.108, 0.062) |
| floor tilt | 0.145 deg (B5: recorded) |
| detection | 1380 points, extents **0.866 x 0.611 m**, plane residual 0.058 m |
| map frame | origin on the floor below the board centre, +x along the board normal |

So `board.pose_in_map` is `[0, 0, 1.3, 0, 0, 0]` and `board.centre_height` is
`1.3`, and the runtime scenario file must say exactly that.

**One number to look at before trusting the map:** the detected extents are
0.87 x 0.61, against a board declared 0.6 x 0.6. The short axis matches; the
long one is 44% over nominal, inside `extent_tolerance`'s upper bound of 1.5
but not explained. Either the mounting frame is retroreflective too, or the
board is not square, or the merged Falcon cloud smears one edge. It does not
move the anchor much — the centre is the centroid either way — but the runtime
gate on the VLP-32C sees the same object, and if the 0.87 is real then a 0.6
nominal with the same tolerance still passes it. Resolve by looking at the
cluster in the debug viewer, or by measuring the board. Not blocking.

Status of the items below, against that delivery: B1 done (0.15 m used), B2
done (the cluster the lead pointed at, identified by the tool rather than by a
person), B3 needs the config the survey team ran with, copied into
`scenarios/basement/falcon_map.yaml` so a rebuild is reproducible, B4 is the
part still owed here, B5 done.

### B1 — use the 0.15 m map; the 0.5 m one cannot work

At 0.5 m voxels a 0.6 x 0.97 m board is about two voxels across. Its extents
cannot be measured, so every shape gate the detector applies is meaningless.
This is not a tuning question.

### B2 — the map is not free of other retroreflectors

The premise "the only reflective board in the map" does not hold as stated. The
largest clusters are 7 x 18 m and 8 x 23 m at z ≈ 2.0 — basement ceiling, pipes
or insulation, not boards. Restricting to a 0.5-1.9 m band above the floor drops
142,109 retro points to 30,686 and 308 clusters to 136.

Nine clusters survive a board-shaped filter on the raw map. **None matches the
configured 0.6 x 0.97 m.** The closest is

```
n=1909  centre=(-10.21, 3.87, 0.88)  extent=(0.38, 0.85, 0.97)
```

whose 0.97 m vertical extent equals the configured board height exactly, and
whose centre height 0.88 is close to the configured 1.0. Its horizontal
footprint spans two axes, consistent with a board mounted at an angle to the map
frame.

**That is a lead, not an identification.** Two things are needed from whoever ran
the survey, and neither can be derived from the cloud:

- the board's true face dimensions, since the configured 0.6 x 0.97 may describe
  a different board than the one in this basement
- roughly where it was, to tell it from eight other candidates

The replay bag of D1 is from the same session and may settle both: the board is
in view at some point during that drive, at a known-ish range, and the VLP-32C
returns are far sparser than the map's. Reconciling one cluster in the map with
one detection in the bag identifies the board without anyone measuring it.

**Done when:** one cluster is identified as the board, with a stated reason.

### B3 — detector parameters for a Falcon map, separate from the VLP-32C ones

The gates in `reflective_pose.yaml` are VLP-32C properties and say so: the
101-255 reflectivity band is that sensor's contract, the 3 m minimum follows
from its 9.36 degree beam gap, `azimuth_step_rad` is 0.2 deg at 600 rpm.

None of that describes a Seyond Falcon, and none of it describes a *merged map*,
which has no sensor origin, no rings and no scan rate. `anchor.detector_params_for_map`
already relaxes some of this for the offline path; it was tuned against VLP-32C
maps.

**Done when:** the offline path has its own gate set, derived from this cloud's
measured statistics rather than inherited, and B2's cluster is the only survivor.

### B4 — anchor, convert, verify

Run the tool, then check the things that are cheap to get wrong:

- the board lands exactly at `board.pose_in_map`
- `map_projector_info.yaml` says `projector_type: Local`
- the cloud loads in Autoware's `pointcloud_map_loader`
- tile it with `autoware_pointcloud_divider` if the loader wants tiles at this
  size

**Done when:** the map loads and RViz shows the board where the config says it
is.

### B5 — the frame the map is in

GLIM output is not guaranteed gravity-aligned, and the anchoring tool fits a
floor plane and levels the cloud before detecting. The floor sits at z ≈ -0.06
with p1 at -0.26, which looks close to level already, but `max_floor_tilt_deg`
is 10.0 and a survey that drifted past that will be refused rather than silently
tilted.

**Done when:** the measured floor tilt is recorded next to the map, so a rebuild
can be compared against it.

## Track C — configs and wiring in this repository

The package ships a default `reflective_pose.yaml` so it runs standalone. This
repository does not use it: the vehicle has its own gates, the map has different
ones again, and neither should be an edit to a file inside a submodule.

### C1 — one file per reader, scenario directories

Decided 2026-09-10, replacing the two-file split this item first proposed.
The package's single six-section file made three consumers read one document
and share a `board:` block by fan-out. That coupling is what the split undoes:
a file is read by exactly one kind of consumer, and a scenario is a directory.

```
src/launcher/golfcart_launch/config/localization/reflective_pose/
  board_detector.param.yaml          ROS wiring, per vehicle: frames, accumulate_scans,
                                     twist topic, max speed. Not per scenario.
  board_pose_initializer.param.yaml  handoff policy: service, speed gate, attempts, fallback
  scenarios/
    basement/
      detector.yaml                  VLP-32C runtime. board 0.6 x 0.6, centre 1.3,
                                     pose_in_map [0,0,1.3,0,0,0], threshold 100, covariance
      falcon_map.yaml                offline. Same board block, Falcon-survey gates;
                                     the file the survey team anchored with
    sim/
      detector.yaml                  synthetic scenes and the desk test; package defaults
```

The detector file has three sections, `board`, `detector`, `covariance`, and
is what both `board_detector_node` (`config_file`) and `anchor-map-to-board`
(`--config`) load. The loader rejects `ros:`, `autoware:` and `anchor:` with a
message saying where each moved, so a file from the old layout fails loudly.

What moved where:

- `ros:` became ordinary ROS parameters of `board_detector_node`, from
  `board_detector.param.yaml`. `accumulate_scans` still feeds `scan_count`; the
  node injects it when it loads the detector file, since the node is the one
  thing that knows how many scans it stacks.
- `autoware:` became ROS parameters of `board_pose_initializer`.
- `anchor:` became CLI flags of `anchor-map-to-board` with `AnchorParams` as
  defaults. Floor-fit tuning is a property of one run of one tool.
- The input topic is a **remap** in whichever launch starts the node. The bag
  replay remaps to `/sensing/lidar/vlp32/velodyne_points`; the vehicle to the
  live topic. No file edit per bag.

The board block is duplicated between `detector.yaml` and `falcon_map.yaml`:
four numbers, same directory. `board_anchor.yaml` records the dimensions the
map was anchored with and the node logs its own at startup, so disagreement is
visible in two logs side by side. A third `board.yaml` passed to both tools was
considered and rejected as an extra argument for four numbers.

Everything lives under `golfcart_launch/config` and reaches `share/` through
the package's `data_files`, so launch resolves it with `find-pkg-share` and the
CLI reads it by path; colcon's symlink install keeps edits live without a
rebuild. Wiring and policy are deliberately not per scenario: they describe the
vehicle and the stack, not the site. A second site adds one directory with two
files.

**Done when:** the submodule's loader accepts the three-section file and
rejects the old one; `just build` installs the tree above; and neither node
reads the submodule's packaged default when launched from this repository.

### C2 — both nodes in our launch, behind `pose_initializer`

`golfcart.launch.yaml` and the replay launches bring up `board_detector_node`
and `board_pose_initializer` when asked:

```
just launch pose_initializer:=board reflective_pose_scenario:=basement
```

`pose_initializer` is a new argument, `gnss | board | none`, default `gnss`,
which leaves every existing invocation unchanged. It names which node seeds
`/localization/initialize`, and is orthogonal to `pose_source`, which names
what tracks afterwards: `board` composes with `ndt` and with `cuda_ndt` alike.
The 2026-09-08 text of this item made it a sixth `pose_source` value; that
would have needed a seventh for the CUDA matcher, so it was dropped on
2026-09-10.

`reflective_pose_scenario` resolves to
`scenarios/$(var reflective_pose_scenario)/detector.yaml`, the same shape as
`perception_preset`. `board` implies `use_gnss:=false` for the pose
initializer's `gnss_enabled`, which is the whole of "replacing the GNSS
initializer": with GNSS disabled Autoware's `pose_initializer` waits on the
service, and the board node is what calls it.

Two things the existing launch already teaches, and this must not relearn:

- A preset that names `pose_source` only takes effect if its `<arg>` is the
  first declaration of that name. The localization preset include sits above the
  `pose_source` declaration for exactly this reason.
- `camera_model`, `imu_source` and `tx_enabled` do not survive the trip through
  `tier4_sensing_component.launch.xml`, which forwards a fixed argument set.
  These two nodes are included from `golfcart_autoware.launch.xml` directly,
  beside the localization component, so `config_file` and the param files reach
  them as arguments; if that ever moves under an installed Autoware include, the
  env-var route is the established fallback here.

**Done when:** `just launch pose_initializer:=board` brings both nodes up with
our config, `ros2 param get /board_detector config_file` shows the installed
scenario path, and `pose_initializer:=gnss` (the default) starts neither.

### C3 — a script for the map processing

Map anchoring is a rare, deliberate, destructive-if-wrong operation that takes
minutes and produces artifacts a whole deployment depends on. It should not be a
command someone reconstructs from a README each time.

Since 2026-09-10 the survey team runs the anchoring, so this is a rebuild aid
rather than a prerequisite, and it sits after D1a in the order of work.

`scripts/map/anchor_reflective_map.sh` wraps `anchor-map-to-board` with
`scenarios/<scenario>/falcon_map.yaml`, defaults to `--dry-run`, and requires
an explicit flag to write. It records the resulting transform and floor tilt
next to the output, which is what B5 asks for.

Note the neighbour: `scripts/map/shift_map_coordinates.py` shifts Lanelet2 OSM
local coordinates. It is a different job on a different file, but anchoring the
PCD moves the origin that the vector map's coordinates are relative to — so a
map rebuild very likely needs both, in that order.

**Done when:** one command, from a clean checkout, takes the GLIM export to a
loadable anchored map, and refuses to overwrite without being told.

## Track D — end to end

### D1 — bag replay

Input:

```
~/nas/autoveh/dataset/2026-08-20 GLIM pointcloud mapping bags/rosbags/vlp32_1
```

Same survey session as the map in Track B, so the two describe one basement. The
map is the Falcon's; this is the VLP-32C's, which is the runtime sensor.

What it contains, read from the bag rather than assumed:

| | |
|---|---|
| topic | `/sensing/lidar/vlp32/velodyne_points` |
| type | `sensor_msgs/PointCloud2`, `PointXYZIRCAEDT`, `point_step` 32 |
| fields | x, y, z, intensity (**uint8**), return_type, channel, azimuth, elevation, distance, time_stamp |
| `frame_id` | `velodyne` |
| messages | 2354 over 235 s, ~10 Hz, ~48,700 points per scan |
| size | 3.7 GB, one `.db3` |

Two things line up already: `frame_id` matches `ros.sensor_frame` unchanged, and
the cloud is already in Autoware's preprocessed layout rather than raw driver
output, so no preprocessing chain is needed to feed the detector.

**Two things the bag does not contain, and both block a naive replay:**

- **No `/tf` or `/tf_static`.** The detector looks up `base_frame -> sensor_frame`
  and will sit in `WAIT_TF` forever. `just fake-tf` already publishes exactly
  this transform from the sensor kit calibration; the replay needs it running.
- **No velocity or odometry of any kind.** The topic list is one entry long. That
  has two consequences. A3's motion guard cannot be exercised from this bag at
  all — there is nothing to gate on, so `ros.twist_topic` stays empty for replay
  and the guard is verified separately on the vehicle. And NDT itself needs
  velocity through `/vehicle/status/velocity_status` to `gyro_odometer` to
  `ekf_localizer`, so full tracking cannot run from this bag alone. Cold-start
  *initialization* can be tested from it; tracking needs a bag recorded with the
  vehicle interface running.

So D1 splits in two. **D1a**: replay this bag, publish the static TF, and show the
detector producing a pose and the Autoware node calling the service. **D1b**:
NDT convergence and tracking, which needs a bag with velocity in it.

**Done when:** D1a shows a cold-start pose from replay with no GNSS; D1b is
recorded as blocked until a suitable bag exists, rather than attempted against
this one.

**Decided 2026-09-10: D1a only.** A synthetic zero-twist replay to coax NDT
into tracking was considered and dropped; it would prove something about a
stationary cart, and the bag is a drive. D1a's pass mark, against the delivered
map: the detector publishes `~/board_pose` while the cart is stopped near the
board, `board_pose_initializer` calls `/localization/initialize` with it, and
the align result is logged. With the anchored map the align is expected to
succeed; a failure there is a finding, not a blocker on D1a.

D1a runs through a replay harness of its own, `just indoor-test`, mirroring
`just ntu-test`: bag paused for `/clock`, stack up with drivers off, RViz on
bag time, resume, then watch the service call. The stack supplies
`base_link -> velodyne` from the vehicle description, so `fake-tf` is only
for the standalone detector check; the bag's `frame_id` is `velodyne` and the
sensor kit's is `velodyne`, so nothing is renamed.

### D2 — on the vehicle

The full sequence, with `tx` off first.

**Done when:** the driver can bring the cart up indoors without touching a
terminal beyond the launch.

## Steps

Checked as they land; the date beside a box says when. Lane 0 first, then the
config split, then 2a, 2b and 2c in parallel: their files do not overlap. The
submodule is one of those lanes, and its commits go to the fork's `main`
before the parent pointer moves.

**Lane 0 — build**

- [ ] `just build` on this checkout; the five `reflective_pose_*` packages install
- [ ] `anchor-map-to-board` on PATH after `source install/setup.bash`

**Lane 1 — config split (submodule), C1**

- [ ] loader reads the three-section detector file and rejects `ros:`, `autoware:`, `anchor:` by name
- [ ] `board_detector_node` takes wiring as ROS parameters; `accumulate_scans` injected into `scan_count`
- [ ] `board_pose_initializer` takes policy as ROS parameters; no `config_file`
- [ ] `anchor-map-to-board --config` takes the detector file; floor-fit knobs are flags
- [ ] packaged defaults renamed and split; `docs/configuration.md` and README follow
- [ ] pushed to the fork's `main`

**Lane 2a — detector (submodule), Track A**

- [ ] A4: `intensity_threshold` 100 with the evidence table beside it; board default 0.6 x 0.6
- [ ] A1: `AMBIGUOUS` suppresses the frame, shows on `/diagnostics`, next frame still processed
- [ ] A2: one confidence scalar, on the diagnostic, gated by one key
- [ ] standalone replay of `vlp32_1` with `fake-tf` produces candidates
- [ ] pushed to the fork's `main`

**Lane 2b — wiring (this repo), C1 + C2**

- [ ] `config/localization/reflective_pose/` tree, basement scenario filled from `board_anchor.yaml`
- [ ] `pose_initializer` and `reflective_pose_scenario` through `golfcart_autoware.launch.xml`
- [ ] `indoor_logging_sim.launch.xml`: GNSS off, camera none, bag topic remapped
- [ ] `just indoor-test` module: bag, up, rviz, resume, down, fake-tf
- [ ] `ros2 param get /board_detector config_file` shows the installed scenario path

**Lane 2c — map (this repo), Track B**

- [x] B1: 0.15 m export used (2026-09-10, survey team)
- [x] B2: board cluster identified, by `anchor-map-to-board` rather than by hand (2026-09-10)
- [x] B5: floor tilt recorded, 0.145 deg in `board_anchor.yaml` (2026-09-10)
- [x] anchor and convert: `pointcloud_map.pcd`, `board_anchor.yaml`, `board_polygon.osm`, `map_projector_info.yaml` delivered (2026-09-10)
- [ ] B3: the survey team's anchoring config copied to `scenarios/basement/falcon_map.yaml`
- [ ] the 0.87 x 0.61 m extents question looked at once
- [ ] copy to `data/basement-indoor/`
- [ ] B4 verify: loads in `pointcloud_map_loader`; minimal `lanelet2_map.osm` with the board polygon; RViz shows the board at the origin

**Lane 3 — D1a**

- [ ] `just indoor-test` end to end on the merged lanes
- [ ] outcome and align result recorded under D1

**Lane 4 — after D1a**

- [ ] C3: rebuild script, dry-run by default
- [ ] A3: motion guard wired on the vehicle
- [ ] D2: on-vehicle sequence, `tx` off
- [ ] D1b: basement bag with velocity and IMU recorded; first job of the next vehicle session

## Risks

**The board in the basement may not be the board in the config.** B2 is blocked
on ground truth from the survey, and the whole of Track B is blocked on B2.
Guessing which of nine candidates is the board and anchoring to the wrong one
shifts the entire map with no later symptom — the detector would then confirm
its own error at startup, because the same code produced both.
Resolved 2026-09-10: the delivered anchor identified the cluster by tool, not
by guess. What remains is the 0.87 x 0.61 m extents question in Track B.

**`AMBIGUOUS` is terminal today.** On a map with 308 retro clusters, A1 is not a
refinement; without it the detector stops permanently the first time two
reflectors share a frame, and the failure looks like a hang.

**Two sensors, one config.** The map comes from a Falcon and the runtime scan
from a VLP-32C. The gates are named as VLP-32C measurements. B3 keeps them
apart; a single shared gate set would silently mistune one path or the other.

**One config for two sensors would silently mistune one of them.** C1 keeps them
apart, and the failure it prevents is quiet: gates that are slightly wrong for a
merged map produce a plausible detection at the wrong place, not an error.

**The configured intensity threshold detects nothing on the replay bag.** A4 is
not a tuning task to be done when convenient; until it is done, every other item
in Track A and Track D reads as broken. The failure is silent in the worst way —
`NO_CANDIDATE` forever, with correct geometry, correct TF and a board in plain
view.
Decided 2026-09-10: 100. The risk moves, it does not vanish; at 100 the gates
carry the load, which is why A1 and A2 precede any replay.

**The bag has no velocity, so it cannot prove the thing it looks like it proves.**
It is a 3.7 GB recording of a drive past the board, and the obvious reading is
that a successful replay demonstrates cold start to tracking. It cannot: NDT
needs velocity through gyro_odometer and ekf_localizer, and the bag has one topic
in it. D1 is split so that limit is stated rather than discovered.

**The 0.5 m map is a trap.** It is smaller, loads faster, and is the natural
thing to reach for. It cannot work, and the failure mode is a plausible-looking
wrong detection rather than an error.
