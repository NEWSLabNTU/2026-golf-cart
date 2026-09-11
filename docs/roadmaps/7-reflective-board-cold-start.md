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

### A5 — the detected board visible in RViz

The detector publishes the board's points and a normal arrow, but not its shape,
so "is this detection the board, and all of it" is answered by reading numbers
off the log. Publish the outline as `~/debug/board_outline`, a latched
`MarkerArray` in the sensor frame, cleared on every batch that detects nothing:

- `nominal`: the configured 0.6 x 0.6 m around the detected centre, one closed
  cyan loop. This is the rectangle the published pose is composed from.
- `measured`: the observed extents, one marker per edge, green if the detector
  saw that edge and red if not. A red edge is the one defect that biases the
  centre; an outline larger than the nominal one is a neighbour clustered in.

With the stack initialized and RViz's fixed frame `map`, TF carries the outline
onto the anchored map, beside `board_polygon.osm`: the detected board against
the mapped one, in one view.

Nodes and files: `board_detector_node` only. In the submodule,
`reflective_pose_ros/debug_viz.py` (the builder), `detector_node.py` (the
publisher), `test/test_debug_viz.py`, `rviz/board_detector.rviz`, and the design
doc, README and debugging guide. Here, the pointer and a display in
`golfcart.rviz` and `golfcart_ntu.rviz`.

**Done when:** the outline draws in RViz from the replay bag, the edge colours
are pinned by a test on a partially hidden board, and a batch without a
detection leaves no outline on screen.

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

**What the cloud says about the floor.** Nothing, nearly. The z histogram has
one peak, the ceiling at 2.4 to 2.8 m, and below it a thin tail rising from
z = 0 with no floor plane in it anywhere: within 8 m of the origin there are
about 2,500 points in the 0.2 m slab at z = 0.2 against 130,000 at z = 2.6.
So the tool's floor fit (the lowest 2 % of a floor band) had almost nothing to
hold onto, and `pose_in_map[2] = 1.3` is the config default carried through,
not a measured mounting height: the origin sits 1.3 m under the board centre
because the file said so. The tilt it reports, 0.145 deg, is the tilt of that
sparse tail. Two consequences, neither blocking:

- The board's real height above the floor comes from the VLP-32C bag, which
  does see the floor, in Lane 2a. If it is not 1.3 m, `pose_in_map[2]` and
  `centre_height` both move, and the map's z origin is simply off by the
  difference — harmless to NDT, which matches the ceiling and walls, but the
  runtime `height_min`/`height_max` band would reject the board.
- NDT here matches ceiling and walls, as the design note wanted. Do not
  strip the ceiling from this map.

The retroreflective content at the origin, from the PCD directly:
1,973 returns above 240 within |x| < 0.3, |y| < 0.6, z 0.7 to 1.9; the board
band z 1.0 to 1.6 and y -0.45 to +0.25, and a second band z 1.7 to 1.9 of the
same width directly above it, which is what stretched the tool's extent to
0.87 m.

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

Replayed from a repo-local copy, never from the NAS mount in place: copy it
once into the gitignored `rosbags/basement/vlp32_1`, which is
`indoor_sim_bag.sh`'s default. The source PLY likewise lives at
`data/basement-indoor/source/basement_voxel_resol_0.15.ply`, gitignored, which
is `anchor_reflective_map.sh`'s default.

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

**D1a passed, 2026-09-10.** See Lane 3 in the checklist for the sequence and
the numbers. Three things had to be found and fixed on the way, none of them in
the detector, and each would have read as "the board initializer does not work":

- **The client spoke the wrong service type.** The installed Autoware 1.5.0 (apt, `autoware_pose_initializer` 1.5.0) serves
  `/localization/initialize` as `autoware_localization_msgs/srv/InitializeLocalization`
  (`component_interface_specs/localization.hpp`); the initializer node was built
  on `tier4_localization_msgs`, identical field for field, different type name,
  so rclpy's `service_is_ready()` never became true and the node reported
  "pose initializer service unavailable" while `ros2 service list` showed it.
  Fixed in the submodule (`ff08ccb`), with a test pinning the type.
- **play_launch cannot bring this stack's pose initializer up today.** Its
  Python parser renders the array parameters of `pose_initializer.param.yaml`
  (loaded with `allow_substs`) as strings, and `autoware_pose_initializer_node`
  dies at startup with `InvalidParameterTypeException` on
  `output_pose_covariance`, taking the service with it. Its Rust parser refuses
  the repo's `$(eval '\'$(var pose_source)\' == \'aruco\'')` conditions
  outright. Resolved 2026-09-11: the string rendering was already fixed in
  play_launch 0.10.0 (`f78745da`) and only the installed 0.8.2 had it; the
  machine now runs 0.10.0 and `just indoor-test up` is back on play_launch
  with the Python parser, verified on this launch. The Rust parser's refusal
  of the escaped-quote `$(eval ...)` was also only 0.8.2 (play_launch #0027,
  fixed 2026-08-17). At 0.10.0 the Rust parser failed on this stack for a
  different reason, `KeyError: 'rear_overhang'`: since play_launch's Python
  half became a separately loaded object, global parameters (Autoware's
  vehicle-info loader) never reached the next `.launch.py` (play_launch
  #0028). Fixed 2026-09-11 in play_launch `8adc52ad`, ABI 3 to 4, verified
  here: the Rust parser resolves this launch to the same 84 nodes and brings
  the stack up with the service served. The four recipes that pinned
  `--parser python` (`ntu-test up`, `indoor-test up` and their run scripts)
  now use the default, like `just launch` always did. Parity survey of
  every entry point, both parsers: indoor sim 83/83, NTU sim 81/81, logging
  sim 130/130, planning sim 118/118, aruco sim 124/124 after its own fix
  (docs/known-config-defects.md #9); `golfcart.launch.yaml` cannot resolve on
  this workstation under either parser, for want of the ZED packages.
- **Loopback multicast is off on this workstation** (`multicast-lo.service`
  inactive, `lo` without the MULTICAST flag), so the repo's loopback DDS profile
  cannot discover and a stock launch of ~30 processes dies with "Failed to find
  a free participant index for domain 0". The proper fix is
  `sudo systemctl start multicast-lo`, which `scripts/env.sh` already asks
  for; the run used a unicast profile with `MaxAutoParticipantIndex` 250
  through `CYCLONEDDS_URI` instead.

One number to carry into D1b rather than explain away here: 34 s after
initialization, with the cart moving and no twist in the bag,
`/localization/kinematic_state` read (2.1, 2.7, 0.4) against the board-derived
guess of (11.5, -4.6, 0.5). Whether that is NDT following the cart on scans
alone or a walk-off is exactly the question D1b's bag exists to answer.

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

- [x] `just build` on this checkout; the five `reflective_pose_*` packages install (2026-09-10, 29 packages)
- [x] `anchor-map-to-board` reachable: not on PATH — ament puts the console
      script in `install/reflective_pose_cli/lib/reflective_pose_cli/`, so it
      is `ros2 run reflective_pose_cli anchor-map-to-board` (2026-09-10)

Two things the build turned up, neither in this campaign's packages:

- `golfcart_aruco_detector` fails in `turbojpeg-sys`, which builds libjpeg-turbo
  from source and needs `nasm`. Setup's `ros2-dev-tools` step installs it and
  had not been run on this machine. `cuda_ndt_matcher` was aborted by that
  failure and rebuilt alone. D1a uses `pose_source:=ndt`, so neither blocks it.
- An untracked `src/autoware_rosbag_replay/` inside the `cuda_ndt_matcher`
  checkout duplicated `individual_params` and stopped colcon at discovery.
  Not in the pinned commit; a `COLCON_IGNORE` was dropped in beside it. A
  fresh clone does not have it.

**Lane 1 — config split (submodule), C1**

- [x] loader reads the three-section detector file and rejects `ros:`, `autoware:`, `anchor:` by name (2026-09-10)
- [x] `board_detector_node` takes wiring as ROS parameters; `accumulate_scans` injected into `scan_count`; input cloud is a remap of `~/input/pointcloud` (2026-09-10)
- [x] `board_pose_initializer` takes policy as ROS parameters; no `config_file` (2026-09-10)
- [x] `anchor-map-to-board --config` takes the detector file; floor-fit knobs are flags (2026-09-10)
- [x] packaged defaults renamed and split; `docs/configuration.md`, README, design doc and guides follow (2026-09-10)
- [x] pushed to the fork's `main`: `354c440`, 104 tests green, both launch files smoke-tested (2026-09-10)

**Lane 2a — detector (submodule), Track A**

- [x] A4: `intensity_threshold` 100 with the evidence table beside it; board default 0.6 x 0.6, centre 1.3 (`5c8184d`, 2026-09-10). The >100 row: 361 / 559 / 996 points per scan, 197 of 197 scans clear 60.
- [x] A1: `AMBIGUOUS` suppresses the frame, shows on `/diagnostics`, next frame still processed. The per-batch verdict is `reflective_pose_ros.decision.judge()`, tested on real simulator results (`0baf6a2`).
- [x] A2: one confidence scalar in [0, 1] from five terms (planarity, extent, density, edges at double weight, range at half), on every detection and every diagnostic; `detector.min_confidence`, default 0.6, is the one key (`c9d9c02`). Clean simulated boards score 0.86 to 0.93, one hidden edge 0.55.
- [x] two more gates measured on the bag and moved (`e944e04`): `cluster_tolerance` 0.05 to 0.15 (at 0.05 the board split into ring stripes and nothing detected in 235 batches) and `height_max` 1.5 to 1.65 (1.5 clipped the board's top 0.1 m; 1.7 merged the reflective band above it).
- [x] standalone replay of `vlp32_1` with `fake-tf` produces candidates (2026-09-10): 24 of 235 ten-scan batches detect, all while the cart stands still 12 m from the board (bag start and end, confidence 0.85 to 0.90) or passes 3 m from it at t = 74 s (0.69 to 0.80); every other batch is `no candidate`, never `AMBIGUOUS`; the one partial view scores 0.52 and is kept out. Poses: (11.5 to 11.9, -4.6, yaw -178 deg) from 12 m, (1.3 to 1.4, 3.3 to 3.4, yaw -86 deg) from 3 m.
- [x] board centre height measured from the bag (2026-09-10): with the cart 3 m from the board on level floor the cluster spans z 1.0 to 1.65 above `base_link` and the centre reads 1.30 to 1.40 m above the fitted floor; from the 12 m spots it reads 1.15 to 1.20, but there `base_link` sits 0.30 m above the local floor and pitched 1.8 deg, a ramp. **1.3 holds to about 0.1 m**; `pose_in_map[2]` stays. The published z from the 12 m spots is 0.5 m for the same reason, and NDT align absorbs it.
- [x] pushed to the fork's `main`: `5c8184d`, `c9d9c02`, `0baf6a2`, `e944e04`, `d25444b`, and `ff08ccb` from D1a below (2026-09-10)

**Lane 2b — wiring (this repo), C1 + C2**

- [x] `config/localization/reflective_pose/` tree, basement scenario filled from `board_anchor.yaml` and Lane 2a's measured gates; `falcon_map.yaml` is a placeholder until B3 (2026-09-10)
- [x] `pose_initializer` (`gnss | board | none`, default `gnss`) and `reflective_pose_scenario` through `golfcart.launch.yaml`, `logging_simulation.launch.yaml` and `golfcart_autoware.launch.xml`; anything but `gnss` forces the pose initializer's `gnss_enabled` off; `board_input_pointcloud` names the cloud the detector reads (2026-09-10)
- [x] `indoor_logging_sim.launch.xml`: GNSS off, camera none, bag topic to NDT and to the detector (2026-09-10)
- [x] `just indoor-test` module: bag, up, rviz, resume, pause, down, fake-tf, run (2026-09-10)
- [x] `ros2 param get /localization/board_detector config_file` shows `install/.../scenarios/basement/detector.yaml` on the live stack (2026-09-10)

**Lane 2c — map (this repo), Track B**

- [x] B1: 0.15 m export used (2026-09-10, survey team)
- [x] B2: board cluster identified, by `anchor-map-to-board` rather than by hand (2026-09-10)
- [x] B5: floor tilt recorded, 0.145 deg in `board_anchor.yaml` (2026-09-10)
- [x] anchor and convert: `pointcloud_map.pcd`, `board_anchor.yaml`, `board_polygon.osm`, `map_projector_info.yaml` delivered (2026-09-10)
- [x] B3: the survey team's anchoring config, verified by reproduction (2026-09-11).
      It is the detector repo's config at `5b25426` (map ceiling 1.1 m), not
      `5d313f1` (1.5 m, which merges the reflective band above the board and
      rejects it as 1.01 m tall). Translated into
      `scenarios/basement/falcon_map.yaml`; a dry run on the same cloud finds
      the board from 1380 points, 0.87 x 0.61 m, 5.8 cm residual, and gives
      `board_anchor.yaml`'s transform to five decimals. Caveat in the file:
      the 0.61 m is the 0.5 to 1.1 m slab, not the board's edges, so the map's
      z origin may carry up to ~0.2 m of bias; the bag's 1.30 to 1.40 m agrees
      to 0.1 m, and NDT matches the ceiling.
- [x] the 0.87 x 0.61 m extents question looked at once (2026-09-10): a second
      retroreflective band sits directly above the board, z 1.7 to 1.9, same
      width; the tool's cluster merged the two. The board itself is z 1.0 to
      1.6, y -0.45 to +0.25 — 0.6 x 0.6 plus voxel smear, centred where the
      polygon says. See *What the cloud says about the floor* under Track B.
- [x] copy to `data/basement-indoor/` (2026-09-10). PCD gitignored like every
      other map; `board_anchor.yaml`, `board_polygon.osm`,
      `map_projector_info.yaml` and `lanelet2_map.osm` tracked.
- [x] B4 verify, loads: `tier4_map_launch` alone against the directory
      publishes `/map/pointcloud_map` with 3,995,308 points in `map`, extents
      x -59..43, y -39..51, z -2.4..19.8, and `/map/vector_map` from a
      `lanelet2_map.osm` that is the board polygon and nothing else. The
      lanelet loader warns about a missing `format_version`; harmless.
      Board at the origin verified numerically, not visually (2026-09-10).
- [x] B4 verify, RViz look at the board and the ceiling (2026-09-11, on a VNC
      display, fixed frame `map`, cloud coloured by intensity from 100 to 255).
      Looking at the board's face from +x, the retroreflective returns fill the
      delivered `board_polygon.osm` outline (y ±0.3, z 1.0 to 1.6), centred on
      axes placed at `pose_in_map`, with a thin fringe below the bottom edge.
      The ceiling is present as a dense band at about 2.4 to 2.8 m and must
      stay; there are almost no floor returns near the origin, as measured,
      while nearby cars' undersides reach z = 0. A top view is useless: the
      ceiling occludes everything below it.
- [ ] `lanelet2_map.osm` with the drivable route, when planning is wanted;
      the polygon-only file is enough for D1a

**Lane 3 — D1a**

- [x] end to end on the merged lanes, 2026-09-10: bag paused, stock `ros2 launch golfcart_launch indoor_logging_sim.launch.xml rviz:=false`, resume. Board detected at 12.0 m (1013 points, confidence 0.86) 72 s after the stack came up; `board_pose_initializer` attempt 1/5 with (11.53, -4.62, 0.51); Autoware's `pose_initializer` deactivated EKF and NDT, called the align server, **align server succeeded 2.7 s later**, reactivated both; `/localization/initialization_state` read 3 (INITIALIZED); "localization initialized from the board". Two more detections followed (12 m at 0.85, then 3.3 m at 0.71), ignored as designed once initialized.
- [x] outcome and align result recorded under D1 (below)

**Lane 4 — after D1a**

- [x] play_launch: already fixed upstream in 0.10.0 (`f78745da`, 2026-08-08); the machine ran 0.8.2. Regression tests with the recorded values pushed as `cdffdc43`, 0.10.0 installed, `just indoor-test up` back on play_launch and verified: node up, service served, covariance a real sequence (2026-09-11). `just ntu-test up` never left it.
- [x] C3: `scripts/map/anchor_reflective_map.sh` (2026-09-11). Dry run by
      default, reading the scenario's `falcon_map.yaml` from the source tree;
      `--write` builds in a scratch directory, compares the new transform with
      the existing `board_anchor.yaml` to 1e-4, and refuses a moved anchor
      (exit 3) unless `--force`. Writes `anchor_run.txt` beside the map: cloud
      and config sha256, both repo revisions, extra flags. Verified: the dry
      run matches the delivered anchor, and a write reproduces the delivered
      `pointcloud_map.pcd` byte for byte. `lanelet2_map.osm` is seeded from
      the polygon only when absent.
- [x] A5: detected board outline on `~/debug/board_outline`, in the detector's
      and the stack's RViz layouts (2026-09-11, reflective_pose_detector
      `a8078a5`). Drawn for any batch with a detection, including one the
      confidence gate suppresses; cleared on no candidate and on ambiguous
      batches. 155 tests green. Verified on the local `vlp32_1` copy: one
      stepped batch publishes the clear-all, the cyan nominal loop and four
      green measured edges, and RViz draws them around the board at 12 m.
      Displays added to `golfcart.rviz` (Localization group) and
      `golfcart_ntu.rviz` (Map group, the one `just indoor-test rviz` opens)
      on `/localization/board_detector/debug/board_outline`.
- [ ] A3: motion guard wired on the vehicle. Desk half done 2026-09-11: the
      detector reads `geometry_msgs/TwistWithCovarianceStamped` (what
      `vehicle_velocity_converter` publishes; before, such a topic fell through
      to `Odometry` and never matched), and `twist_type` names the type so the
      subscription does not race the publisher at startup. The golf-cart param
      file names the type; `twist_topic` stays empty until D1b's bag verifies
      the guard.
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
