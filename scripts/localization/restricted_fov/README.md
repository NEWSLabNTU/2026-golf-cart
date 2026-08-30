# Restricted field-of-view localization campaign

**Question.** The vehicle is to carry a Seyond Robin-W, a solid-state LiDAR that
sees a 120 by 70 degree wedge instead of the full circle a spinning sensor
sweeps. NDT scan matching here has always run on 360 degree input. Does it still
work?

**Answer, measured on two datasets: yes, forward-facing.** A 120 by 70 degree
forward wedge tracks a full-sensor reference to 0.08 m median and 0.23 m at p95,
on a third of the points, with heading unchanged. Restricting the *vertical*
field of view to the Robin-W's 70 degrees is free. Pointing the same wedge
backwards is 30 times worse, so the mounting direction matters more than the
width.

Findings, caveats and the numbers:
[docs/research/localization/restricted-fov-ndt.md](../../../docs/research/localization/restricted-fov-ndt.md).
What to build if the margin proves thin:
[ndt-revisions-for-narrow-fov.md](../../../docs/research/localization/ndt-revisions-for-narrow-fov.md).
Why the camera analogy half-holds:
[narrow-fov-localization-methods.md](../../../docs/research/localization/narrow-fov-localization-methods.md).
Related work and papers:
[narrow-fov-related-work.md](../../../docs/research/localization/narrow-fov-related-work.md).

No Robin-W recording exists, so both arms emulate one by discarding the returns
it would never have received.

## The two arms

**Autoware sample bag** — the harness already known to localize. Its top sensor
is a VLS128, 360 by 40 degrees, so it is **narrower vertically than a Robin-W**
and only the horizontal restriction can be emulated.

**TIERS `road01`** — an Ouster OS0-128 at 360 by 90 degrees, wider in **both**
axes, so the whole envelope can be emulated. No prior map ships with it, so one
is built here from the full field of view and the restricted runs localize
against it.

## Reproducing

Everything writes to `data/fov_study/<label>/`, which is gitignored.

### Sample bag, horizontal only

```bash
# Restrict at the Nebula decoder. Cheapest and most faithful, but on this bag it
# can only produce a cloud for azimuth windows containing 0 or 300 degrees, and
# every such window points left or behind. Read the doc before using it.
./fov_study.sh <min_az> <max_az> <max_range> <label>

# Restrict by bearing in base_link, after decoding. Can aim anywhere, which the
# decoder crop cannot. This is the arm that produced the forward-facing numbers.
./fov_bearing_study.sh -60 60 70 robinw_fwd_120

# Which directions actually survived a crop. Run it on every new configuration:
# an empty sensor does not announce itself, because the rig's other LiDARs keep
# publishing.
python3 tools/fov_azimuth_probe.py data/fov_study/robinw_fwd_120

# Score against a full-FOV run of the same pipeline.
python3 tools/fov_study_report.py --baseline data/fov_study/baseline_360 \
    data/fov_study/robinw_fwd_120
```

### TIERS OS0-128, both axes

One-time preparation, from `road01.bag` as downloaded from the TIERS dataset:

```bash
# 1. ROS 1 to ROS 2, OS0 only. Also fixes two things that silently break the
#    replay: both Ouster sensors stamp the same frame_id, and the clouds carry
#    sensor-boot time rather than ROS time.
python3 tools/tiers_extract_os0.py data/tiers/road01.bag data/tiers/road01_os0

# 2. Trajectory. Doubles as the scoring reference.
kiss_icp_pipeline --topic /sensing/lidar/os0/pointcloud_raw data/tiers/road01_os0
cp <results>/road01_os0_poses_kitti.txt data/tiers/road01_reference_poses_kitti.txt

# 3. Prior map, from the FULL field of view.
python3 tools/build_pcd_map.py data/tiers/road01_os0 \
    data/tiers/road01_reference_poses_kitti.txt \
    --topic /sensing/lidar/os0/pointcloud_raw \
    --out data/tiers/road01_map/pointcloud_map.pcd
# then write map_projector_info.yaml with `projector_type: local`

# 4. The twist the localization chain assumes and this rig does not have.
#    Without it the same configuration diverges on some runs and not others.
python3 tools/tiers_add_odometry.py data/tiers/road01_os0 data/tiers/road01_os0_odo \
    --poses data/tiers/road01_reference_poses_kitti.txt \
    --cloud-topic /sensing/lidar/os0/pointcloud_raw

# 5. Bake each field of view into its own bag.
python3 tools/fov_bake_bag.py data/tiers/road01_os0_odo data/tiers/baked_odo/robinw \
    --topic /sensing/lidar/os0/pointcloud_raw \
    --min-bearing -60 --max-bearing 60 \
    --min-elevation -35 --max-elevation 35 --max-range 70
```

Then, per run:

```bash
./tiers_baked_run.sh robinw odo_robinw_r1
python3 tools/compare_to_reference.py \
    --reference data/tiers/road01_reference_poses_kitti.txt \
    --reference-bag data/tiers/road01_os0 \
    --reference-topic /sensing/lidar/os0/pointcloud_raw \
    data/fov_study/odo_robinw_r1
```

`tiers_fov_study.sh` filters live instead of using a baked bag. It is kept for
one-off exploration and is **not** the measurement path; see below.

## Four traps this campaign walked into

Each cost a round of measurements, and each presented as something other than
what it was.

**A live Python filter cannot pass a 2048x128 cloud at 10 Hz.** The unrestricted
run fell to 5 Hz while a 120 degree run held 10, simply by having fewer points to
move. The runs keeping the most points therefore had the fewest poses and lost
localization, producing a clean, plausible, *reversed* result: 19.8 m median
error for the full field of view against 0.07 m for the restricted one. Fixed by
baking the field of view into the bag, so every run plays identically.

**The Ouster clouds are stamped in sensor-boot time.** 2468 seconds, against the
2022 wall clock in the bag's own message timestamps. Every frame failed pose
interpolation and NDT never published a thing, which reads as a localization
failure rather than a clock one.

**Autoware's crop box accepts only `PointXYZIRC` or `PointXYZIRCAEDT`.** An
Ouster driver publishes neither. The crop box logs the complaint about its input
while NDT, the node that appears broken, says nothing.

**`scan_phase` has to travel with a decoder crop.** It is the azimuth where the
Velodyne decoder cuts one scan from the next; put it outside the retained window
and the decoder emits *nothing*, not a thin cloud. The pipeline stays up and NDT
keeps publishing, because the rig's other LiDARs ignore the crop. A run that had
discarded the entire sensor under test looked like a run that had merely narrowed
it.

The lesson common to all four: **check that the sensor under test is still
producing data**, rather than inferring it from a live pipeline. That is what
`tools/fov_azimuth_probe.py` and the filters' kept-percentage logs are for.

## Files

| file | does |
|---|---|
| `fov_study.sh` | sample bag, decoder-side azimuth crop |
| `fov_bearing_study.sh` | sample bag, bearing crop after decoding |
| `tiers_baked_run.sh` | TIERS replay of a pre-baked bag — the measurement path |
| `tiers_fov_study.sh` | TIERS replay filtering live — exploration only |
| `tools/fov_restrict_node.py` | live bearing/elevation/range filter, `PointXYZIRC` re-encoding |
| `tools/fov_bake_bag.py` | same geometry, applied offline into a new bag |
| `tools/fov_azimuth_probe.py` | which bearings actually survived a crop |
| `tools/fov_study_report.py` | score runs against a full-FOV run of the same pipeline |
| `tools/compare_to_reference.py` | score runs against an external trajectory |
| `tools/build_pcd_map.py` | accumulate a prior map along a trajectory |
| `tools/tiers_extract_os0.py` | TIERS ROS 1 bag to ROS 2, OS0 only, frames and stamps fixed |
| `tools/tiers_add_odometry.py` | add IMU and a synthesised vehicle twist |

## What lives in the submodule instead

`src/localization/cuda_ndt_matcher` carries the parts that are not campaign
scaffolding:

- `src/cuda_ndt_matcher/src/node/degeneracy.rs` — per-frame conditioning of the
  registration, published under `/localization/pose_estimator/degeneracy/`. Not
  specific to this study, and the thing to watch on a narrow-FOV vehicle.
- `ndt_replay_simulation.launch.xml` — an `input_pointcloud` argument, so a study
  can interpose a node between the concatenator and localization.
- `tests/rosbag_replay/tiers_sensor_kit_{description,launch}` — the OS0 rig.
- `tests/rosbag_replay/rosbag_sensor_kit_launch/launch/lidar.launch.xml` — the
  decoder-side crop and `scan_phase` knobs.
- `scripts/run_demo.sh`, `scripts/run_ndt_simulation.sh` — pass launch arguments
  through, so a caller can set `sensor_model`, `map_path` or `input_pointcloud`
  without forking the harness.

## Data

Not committed. `data/tiers/` is 48 GB of upstream bags plus ~25 GB derived, and
`data/fov_study/` is run output. Both are gitignored. The TIERS sequences are at
<https://github.com/TIERS/tiers-lidars-dataset>; this campaign used `Road01`.
