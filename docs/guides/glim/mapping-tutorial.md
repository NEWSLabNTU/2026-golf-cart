# Create a PLY or PCD Map with GLIM

This tutorial takes you from a sensor recording to a cleaned, exported point-cloud map. It is written for ROS 2 and GLIM's `glim_ros` package. The recommended deliverable is the **GLIM dump directory** plus a **PLY** export: the dump remains editable, while the PLY is portable. GLIM's offline viewer exports binary PLY directly; make a PCD afterward only if another program requires it.

## What you need

- A working GLIM ROS 2 installation with the viewer enabled. Follow [Installation](installation.md) or [Docker](docker.md).
- A range sensor publishing `sensor_msgs/msg/PointCloud2`. For the usual LiDAR-inertial workflow, also record an IMU topic (`sensor_msgs/msg/Imu`). GLIM can run LiDAR-only, but the configuration must be changed as described below.
- A rigid, calibrated LiDAR--IMU setup, good time synchronization, and enough storage for the bag and output map.
- An environment with geometric structure and overlap between revisited areas. Avoid starting in a featureless corridor, open field, or beside a moving crowd.

> **Keep the original bag and GLIM dump.** A PLY/PCD is a flattened point cloud. It cannot be used to add loop closures, recover the factor graph, or redo map edits in GLIM.

## Workflow at a glance

```text
LiDAR + IMU -> ROS 2 bag -> GLIM mapping -> dump directory
                                            |
                               offline viewer: validate / correct / save
                                            |
                                         PLY export -> optional PCD conversion
```

## 1. Prepare the sensor configuration

Work from a copy of GLIM's `config` directory, rather than editing the installed package. Pass that directory to GLIM with an absolute `config_path`:

```bash
ros2 run glim_ros glim_rosnode --ros-args -p config_path:=$(realpath ./config)
```

The directory must contain `config.json` and the configuration files it references. This approach also avoids rebuilding every time you tune a file. If you edit configuration files in an installed ROS 2 package instead, rebuild it; `colcon build --symlink-install` makes iteration easier. See [Getting started](quickstart.md#configuration-files).

Set these values before collecting the final dataset:

1. In `config_ros.json`, set `imu_topic` and `points_topic` to the topics from your driver. Check them first:

   ```bash
   ros2 topic list -t
   ros2 topic echo --once /your/imu/topic
   ros2 topic echo --once /your/points/topic
   ```

2. In `config_sensors.json`, set `T_lidar_imu`, the rigid transform **from the IMU frame into the LiDAR frame**. Its format is `[x, y, z, qx, qy, qz, qw]`. Do not copy an example transform without validating it for your hardware.

3. Leave `autoconf_perpoint_times` enabled unless you know your PointCloud2 time convention. GLIM deskews an ordinary scanning LiDAR using each point's acquisition time. For a genuinely global-shutter sensor, set `global_shutter_lidar` to `true`; do not use that setting merely to silence timestamp problems.

4. Confirm IMU units and axes. At rest, with the IMU z-axis upward, acceleration should be about `[0, 0, +9.81]` m/s². Set `acc_scale` to `9.80665` when acceleration is reported in `g` (for example, some Livox drivers), and set `ang_scale` if angular velocity is not in rad/s.

5. If messages arrive late or the map smears during motion, investigate hardware time synchronization first. `imu_time_offset` and `points_time_offset` exist for known offsets, but they are calibration values, not a substitute for synchronized clocks.

### LiDAR-only option

For a bag without IMU, set `config_odometry` in `config.json` to `config_odometry_ct.json`, then set `enable_imu` to `false` in both `config_sub_mapping_gpu.json` and `config_global_mapping_gpu.json`. This is less constrained than LiDAR--IMU mapping, so move more slowly and ensure abundant overlap.

### Fast preflight test

Before a long capture, run a 30--60 second test. Start GLIM, keep the rig still briefly so the IMU initializes, then make slow turns and pass walls, corners, and other 3D structure. In RViz, check that the current cloud is not visibly bent during motion and that the trajectory does not jump or rotate unexpectedly. Correct extrinsics, time, frame conventions, and units now—not after a large survey.

Useful starting performance/quality controls are in [Important parameters](parameters.md): lower `random_downsample_target` to reduce compute cost; use a smaller voxel resolution indoors (typically 0.1--0.25 m for the GPU odometry); and increase `k_correspondences` to 15--30 for sparse LiDAR patterns such as a VLP-16.

## 2. Collect a ROS 2 bag

Start the sensor driver, verify that the point and IMU streams are alive, then record the two required streams. Replace the topic names below with the exact configured names.

```bash
mkdir -p ~/glim-data
ros2 bag record -o ~/glim-data/site_01 \
  /your/points/topic \
  /your/imu/topic
```

For reproducibility, also save the output of `ros2 topic list -t`, the exact GLIM config directory, sensor firmware/driver version, calibration files, site name, and capture date alongside the bag. Record any other topics needed by your workflow separately (for example, camera data used by an extension); GLIM's base mapper only needs the configured point and IMU streams.

### How to walk or drive the survey

- Begin and end in a distinctive, static location. Revisit it from a similar viewpoint so a loop constraint has usable overlap.
- Move smoothly. Rapid spins, vibration, and aggressive acceleration expose timing and calibration errors.
- Cover each area from more than one direction, with roughly 30--50% overlap between adjacent passes as a practical target.
- Give the scanner range and parallax: vary viewpoint around corners, facades, shelves, and objects. Long, flat, repeated, or featureless scenes are inherently ambiguous.
- Minimize moving cars, people, foliage, mirrors, rain/fog, and direct sensor interference. Make a second static pass if the first was busy.
- Watch disk space and sensor/network load. A bag with dropped point clouds cannot be repaired later.

Stop the recorder cleanly with `Ctrl-C` and keep its metadata directory intact. Validate the recording before leaving the site:

```bash
ros2 bag info ~/glim-data/site_01
```

Confirm that the point and IMU message counts and duration are plausible. A quick playback in RViz is worthwhile when the capture is expensive to repeat.

## 3. Run GLIM on the bag

For offline processing, use `glim_rosbag`; it reads a rosbag directly and adjusts playback speed to avoid drops while processing as quickly as possible:

```bash
ros2 run glim_ros glim_rosbag ~/glim-data/site_01 \
  --ros-args -p config_path:=$(realpath ./config)
```

Use the standard node for live mapping instead:

```bash
ros2 run glim_ros glim_rosnode \
  --ros-args -p config_path:=$(realpath ./config)
```

Run RViz in another terminal when you need live inspection:

```bash
rviz2 -d glim_ros2/rviz/glim_ros.rviz
```

Allow GLIM to finish and exit cleanly. On exit it saves a mapping **dump** (by default `/tmp/dump`) containing the graph, submaps, copied configuration, and trajectories. Preserve it immediately in a named, durable location—`/tmp` may be cleaned by the operating system:

```bash
mkdir -p ~/glim-results
mv /tmp/dump ~/glim-results/site_01_raw
```

The dump also contains `odom_imu.txt` / `odom_lidar.txt` (odometry without loop closure) and `traj_imu.txt` / `traj_lidar.txt` (globally optimized trajectories), in TUM pose format: `t x y z qx qy qz qw`.

### If mapping is poor

Do not immediately edit the final cloud. First inspect the raw dump and solve the underlying cause:

| Symptom | Check first |
| --- | --- |
| Cloud bends or doubles when moving | Per-point timestamps, LiDAR--IMU time offset, and motion during the scan |
| Map rolls, pitches, or flies away | `T_lidar_imu`, IMU axes, acceleration/gyro units, and an initial stationary period |
| Tracking drifts in a sparse scene | More overlap/structure, slower motion, lower voxel resolution indoors, and more keyframes |
| Processing cannot keep up | GPU configuration, point downsampling, bag storage speed, and CPU/GPU load |
| `X... -> E... is missing` warning | Treat the dump as broken; recover its graph before merging or optimizing |

## 4. Inspect and correct the mapping result

Open the dump in the offline viewer:

```bash
ros2 run glim_ros offline_viewer
```

Choose **File -> Open Map** (or **Open New Map**) and select `~/glim-results/site_01_raw`. Inspect the trajectory and scan alignment before exporting. Check walls and other straight surfaces, repeated visits, and the beginning/end of the route.

### Add a manual loop closure

Use this only when the two submaps genuinely observe the same static area.

1. Right-click one submap sphere and choose **Loop begin**.
2. Right-click the matching submap sphere and choose **Loop end**.
3. Roughly align the red and green clouds.
4. Click **Align** to run scan matching.
5. Inspect the result closely. Click **Create Factor** only when it is clearly correct, then optimize and recheck the whole map.

An incorrect loop closure can deform an otherwise good map. Prefer several well-distributed, high-overlap closures to one speculative closure.

### Planar bundle adjustment

For a flat, static surface, right-click a point and select **Bundle Adjustment (Plane)**. Resize the sphere so it contains enough points from the same plane, then create the factor. Avoid a sphere that includes two walls, furniture, or moving objects.

### Save an editable corrected map

After graph edits and optimization, use **File -> Save -> Save Map** and choose a *new empty directory*, for example `~/glim-results/site_01_corrected`. This preserves the editable graph separately from the raw processing result.

### Merge separate mapping sessions (optional)

Open the first dump with **Open New Map** and enable optimization when prompted, then load the next one with **Open Additional Map**. Select **Merge sessions**, choose the appropriate Indoor/Outdoor preset, and use automatic global registration or manually place the green source cloud near the red target cloud. Run fine registration; create the factor only after visual verification. Then find overlapping submaps and optimize several times.

Before any merge, repair each dump that emitted a missing-edge warning: open it alone, select **Recover graph**, save it, close it, and repeat for every affected session. See [Merging Sessions](merge.md) for the full procedure.

## 5. Remove unwanted points without changing poses

Use `map_editor` only after you are satisfied with the trajectory and loop closures: it removes map points but freezes submap poses.

```bash
ros2 run glim_ros map_editor
```

Open the corrected dump with **File -> Open New Map**. Make a copy before removal and save to another new directory afterwards.

Choose the smallest reliable selection method:

- **MinCut segmentation:** right-click an object, choose **Segmentation -> MinCut**, set foreground and background radii, then **Segment** and inspect the selection. Good for cars, trees, and other isolated objects.
- **Region growing:** choose **Segmentation -> RegionGrowing**, tune angle and distance thresholds, then segment. Good for a contiguous plane.
- **Gizmo:** enable **Selection tool**, position/size the gizmo around a small region, then select covered points. Good for precise manual cleanup.
- **Radius tools:** select within a radius for local deletion, or select outside a radius for local outlier cleanup.

Always inspect the selected points before pressing **Remove selected points**. Keep architectural surfaces and only delete points that are genuinely unwanted; overly broad removal leaves holes that cannot be recreated without rerunning the source data.

## 6. Export the final map

Open the final editable dump in `offline_viewer`, then use **File -> Save -> Export Points** and save, for example, `site_01_final.ply`.

GLIM writes a **binary PLY** point cloud and includes intensity when it exists in the map. It does not expose PCD as an offline-viewer export option in the current source, so PLY is the native GLIM export format.

### Optional: make a PCD copy

If your downstream software needs PCD, convert the final PLY rather than discarding it. A GUI route is to open the PLY in CloudCompare and use **File -> Save As -> PCD**. On systems that provide PCL's conversion utility, use:

```bash
pcl_ply2pcd ~/glim-results/site_01_final.ply \
  ~/glim-results/site_01_final.pcd
```

Then open the PCD in your target program and verify its point count, scale (meters), orientation, and available fields. Conversion tools may rename or omit fields, so retain the original PLY and dump as the authoritative artifacts.

## Final handoff checklist

- [ ] Original ROS 2 bag and sensor/calibration metadata retained
- [ ] Raw GLIM dump retained
- [ ] Corrected/edited dump saved to a separate directory
- [ ] Whole map inspected after every loop closure, merge, and deletion pass
- [ ] Final `*.ply` exported and opened successfully
- [ ] Optional `*.pcd` converted and validated in the consuming application

## GLIM source references

This tutorial is based on the repository's [quick start and offline viewer workflow](quickstart.md), [parameter guide](parameters.md), [map editing guide](edit.md), and [session merging guide](merge.md). The current `src/glim/viewer/offline_viewer.cpp` implementation offers only the `*.ply` file filter and writes binary PLY.
