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

Steps 3 and 4 largely exist. Step 5's map does not. What follows is the gap.

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

## Track B — an anchored PCD map from the GLIM basement survey

Source: `2026-08-20 GLIM pointcloud mapping bags/falcon_map/` on the NAS. Two
exports of the same survey.

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

### C1 — two config files, deliberately separate

They describe different sensors doing different jobs, and B3 is the reason they
cannot be one file: the runtime gates are VLP-32C measurements, the map gates
are properties of a merged Falcon survey with no rings, no scan rate and no
sensor origin.

| File | Read by | Installed |
|---|---|---|
| `src/launcher/golfcart_launch/config/localization/reflective_pose/vehicle.param.yaml` | the two nodes, via our launch | yes, to `share/` |
| `config/reflective_pose/falcon_map.yaml` | `anchor-map-to-board`, offline | no |

The split in location follows the split in use. The vehicle file is referenced by
a launch file, so it must reach `share/` through the package's `data_files`. The
map file is a command-line input to a tool a person runs by hand, never launched,
so it belongs with the rest of `config/` and is read by path.

Both keep the section structure the package defines, and the comments that carry
measurements travel with their keys — the 101-255 band and the 3 m minimum stay
in the vehicle file because they are VLP-32C facts, and must not be copied into
the map file where they mean nothing.

**Done when:** neither file is the submodule's packaged default, `just build`
installs the vehicle one, and the map one is reachable without a build.

### C2 — both nodes in our launch

`golfcart.launch.yaml` brings up `board_detector_node` and
`board_pose_initializer`, passing `config_file` pointed at C1's vehicle file.

This is a `pose_source` value, not a new top-level switch. `pose_source` already
selects the localization *method* — `ndt`, `cuda_ndt`, `aruco`, `yabloc`,
`eagleye` — and board-based cold start is a sixth: it seeds NDT rather than
replacing it, so it composes with `ndt` rather than excluding it.

Two things the existing launch already teaches, and this must not relearn:

- A preset that names `pose_source` only takes effect if its `<arg>` is the
  first declaration of that name. The localization preset include sits above the
  `pose_source` declaration for exactly this reason.
- `camera_model`, `imu_source` and `tx_enabled` do not survive the trip through
  `tier4_sensing_component.launch.xml`, which forwards a fixed argument set.
  Check where these nodes are included from before assuming `config_file:=`
  reaches them; if the include path drops it, the env-var route is the
  established fallback here.

**Done when:** `just launch` brings both nodes up with our config, and
`ros2 param get /board_detector config_file` shows the installed path.

### C3 — a script for the map processing

Map anchoring is a rare, deliberate, destructive-if-wrong operation that takes
minutes and produces artifacts a whole deployment depends on. It should not be a
command someone reconstructs from a README each time.

`scripts/map/anchor_reflective_map.sh` wraps `anchor-map-to-board` with
`config/reflective_pose/falcon_map.yaml`, defaults to `--dry-run`, and requires
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

Replay a bag recorded in that basement against the anchored map: detector
publishes, Autoware node calls the service, NDT converges and tracks.

**Done when:** NDT holds lock through a drive, from a cold start with no GNSS.

### D2 — on the vehicle

The full sequence, with `tx` off first.

**Done when:** the driver can bring the cart up indoors without touching a
terminal beyond the launch.

## Risks

**The board in the basement may not be the board in the config.** B2 is blocked
on ground truth from the survey, and the whole of Track B is blocked on B2.
Guessing which of nine candidates is the board and anchoring to the wrong one
shifts the entire map with no later symptom — the detector would then confirm
its own error at startup, because the same code produced both.

**`AMBIGUOUS` is terminal today.** On a map with 308 retro clusters, A1 is not a
refinement; without it the detector stops permanently the first time two
reflectors share a frame, and the failure looks like a hang.

**Two sensors, one config.** The map comes from a Falcon and the runtime scan
from a VLP-32C. The gates are named as VLP-32C measurements. B3 keeps them
apart; a single shared gate set would silently mistune one path or the other.

**One config for two sensors would silently mistune one of them.** C1 keeps them
apart, and the failure it prevents is quiet: gates that are slightly wrong for a
merged map produce a plausible detection at the wrong place, not an error.

**The 0.5 m map is a trap.** It is smaller, loads faster, and is the natural
thing to reach for. It cannot work, and the failure mode is a plausible-looking
wrong detection rather than an error.
