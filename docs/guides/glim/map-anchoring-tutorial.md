# Anchor a GLIM Map to a Retroreflective Board

GLIM produces a metrically consistent map, but its coordinate frame is arbitrary: its origin is determined by the SLAM run rather than by a feature at the site. **Map anchoring** is the offline step that applies one rigid transform to the completed cloud so a permanently installed, detectable object has a prescribed pose in the map frame.

This tutorial uses a retroreflective rectangular board as that object. The result is a local indoor PCD map whose origin can be physically found again when a vehicle starts. At runtime, a board-pose initializer can use the same board to supply NDT's initial pose.

> This is not part of GLIM itself. GLIM creates and corrects the map; `golfcart_board_initializer` detects the board and anchors GLIM's exported PLY/PCD. The procedure is based on the reflector-anchor design and the initializer README supplied with this project.

## What anchoring does—and does not—do

```text
GLIM arbitrary SLAM frame --[one rigid transform from board]--> anchored local map frame
                                                           \
runtime board detection -> initial vehicle pose -> NDT refinement
```

Anchoring makes the map frame repeatable across sessions and map rebuilds. It is a cold-start aid, not a substitute for localization:

- It does **not** georeference an indoor map. The output is a local metric frame.
- It does **not** replace GLIM loop closures. Make the cloud self-consistent first.
- One board does **not** bound NDT drift away from the board. Add other localization infrastructure if the route needs it.
- It does **not** make a mobile or altered board safe. If the board moves, the map frame has silently moved too.

## 1. Design the fixed board and its map contract

Install one board permanently before collecting the mapping bag. The recommended design is a rectangular retroreflective face—0.8 m wide by 1.0 m high in the referenced site design—covered in high-intensity retroreflective sheeting, with at least 0.15 m of matte material on each side. The rectangle avoids the 90-degree yaw ambiguity of a square board, and the low-intensity side margins support intensity-pattern detection.

The current initializer's installed example configuration uses a different, 0.6 m × 0.6 m square board at a 1.6 m centre height. Treat that as a deployment example, not a design value to copy. A square needs another asymmetric visual/intensity feature or an explicitly resolved orientation; otherwise its face alone does not determine yaw. In every case, the YAML actually passed to the anchoring and runtime tools is authoritative.

Mount its centre at the configured height, face it toward the intended approach direction, and keep vehicles at least about 2 m away. Use a bolted or otherwise permanent mount and mark its floor footprint. A board on a movable stand is not an anchor.

Before mapping, decide and record the board's intended pose in the final map:

```yaml
# board_initializer.param.yaml
# [x, y, z, roll, pitch, yaw]; metres and radians
board_pose_in_map: [0.0, 0.0, 1.075, 0.0, 0.0, 0.0]
```

The exact value is site-specific. The referenced design uses the board centre at `(0, 0, 1.075)`, outward normal along `+x`, and `+z` upward; the installed initializer configuration is the source of truth. Rotation follows `Rz(yaw) @ Ry(pitch) @ Rx(roll)`.

Keep the physical dimensions, centre height, and `board_pose_in_map` together in the one YAML file used by both anchoring and runtime detection. Do not put competing values into command-line arguments or a separate map note.

## 2. Configure and collect a board-visible GLIM bag

Follow [Create a PLY or PCD Map with GLIM](mapping-tutorial.md) through sensor setup and collection, with these anchoring-specific requirements:

1. The input PointCloud2 must contain `x`, `y`, `z`, and **`intensity`**. Set GLIM's `intensity_field` in `config_sensors.json` to the actual field name—normally `intensity`.
2. Preserve per-point timestamps and record the raw IMU. They are needed for deskewing and accurate LiDAR--IMU mapping.
3. Keep the board in the environment and pass it at the beginning, at least once mid-route, and at the end. These passes provide useful inspection evidence, but the board is not the SLAM loop-closure mechanism.
4. Drive smoothly and close the site's loops using walls, corners, doors, and pillars. Keep pedestrians and movable clutter out whenever possible.
5. Start from rest for several seconds so the IMU can settle. For an indoor reflector workflow, do not rely on GNSS topics.

For the cart design, the mapping bag additionally retains `/tf_static` and cameras so later workflows can replay the same capture. The core GLIM mapping input is still the configured point and IMU topics.

Record and preserve the calibration, exact YAML configuration, board measurements, bag name, map build date, and a photo/inspection record of the board. Those items are as important as the cloud: a changed board or configuration invalidates the anchor.

## 3. Build, inspect, and clean the SLAM map in GLIM

Run GLIM offline and retain its dump directory:

```bash
ros2 run glim_ros glim_rosbag /path/to/mapping_bag \
  --ros-args -p config_path:=$(realpath ./config)
```

Then open the dump in the offline viewer:

```bash
ros2 run glim_ros offline_viewer
```

Before anchoring, inspect all loop closures and correct any visible seams. Add manual loop constraints only between genuinely overlapping static submaps; then save a separate corrected dump. If GLIM reports a missing graph edge, recover the graph before optimization or merging. See the [GLIM mapping tutorial](mapping-tutorial.md#4-inspect-and-correct-the-mapping-result) for the complete correction workflow.

Remove dynamic ghosts after pose correction, not before it:

```bash
ros2 run glim_ros map_editor
```

Use MinCut, region growing, the gizmo, or radius tools on only the unwanted points. Preserve walls, ceilings, and other stable indoor structure—these are valuable NDT geometry, not clutter.

Finally, reopen the cleaned/corrected dump in `offline_viewer` and select **File -> Save -> Export Points**. Save a PLY such as `glim_export.ply`.

GLIM's native offline export is binary PLY. It carries intensity when the map has it, which is why the GLIM intensity configuration and the next verification step matter. Keep both the editable GLIM dump and the exported PLY; neither is replaceable by the anchored delivery cloud.

## 4. Verify intensity before anchoring

The anchoring detector identifies the board from its bright returns, then rejects false candidates by geometry. Confirm the PLY contains an intensity scalar and that the board is present before you run the tool. A cloud produced by a converter that strips intensity cannot be anchored reliably.

For the VLP-32C deployment described by the initializer, the reflector threshold is `110` on a 0--255 intensity scale. That is a site/sensor parameter, not a universal threshold. Inspect an actual scan/cloud and tune the shared configuration if the board's intensity distribution differs.

Avoid these common errors:

- Using a non-`_ex` point-cloud topic that omitted intensity or per-point time.
- Converting with a tool that silently drops scalar fields. In this workflow, do not use Open3D for PLY-to-PCD conversion because it can drop intensity.
- Changing board dimensions or mounting height without changing the shared configuration and rebuilding/validating the map.
- Leaving a reflective sign, tape, or a second board that can satisfy the same detector gates.

## 5. Dry-run the board detector

Use the same parameter YAML that the runtime initializer will load. Run the anchoring tool once in dry-run mode; it reports the detection and transform but writes no map artifacts:

```bash
ros2 run golfcart_board_initializer anchor_map_to_board \
  /path/to/glim_export.ply \
  -o /path/to/anchored-map \
  --config /path/to/board_initializer.param.yaml \
  --dry-run
```

Review the reported candidate before proceeding:

- The detected extents match the physical board, including its non-square orientation.
- The centre height and plane normal make sense relative to the fitted floor.
- There is exactly one valid candidate. An ambiguous result is a stop condition, not a choice to make by eye.
- The proposed transform has the expected translation and orientation.

The tool thresholds intensity, clusters candidate returns, checks planarity, dimensions, and height, then fits the board plane and rectangle. It fits/refits the floor so wall bases and low markings do not bias the map vertical origin. For an exported map, range and point-density gates are deliberately disabled because the cloud combines many viewpoints; geometric checks remain essential.

If dry-run fails, correct the cloud/configuration/physical board and rerun it. Do not anchor by manually guessing a transform. If the map contains two plausible board-shaped reflectors, remove or distinguish the distractor and rebuild the evidence; the tool intentionally aborts rather than anchor the entire map to the wrong object.

## 6. Write the anchored map artifacts

When dry-run is correct, repeat without `--dry-run`:

```bash
ros2 run golfcart_board_initializer anchor_map_to_board \
  /path/to/glim_export.ply \
  -o /path/to/anchored-map \
  --config /path/to/board_initializer.param.yaml
```

The command creates these artifacts in the output directory:

| Artifact | Purpose |
| --- | --- |
| `pointcloud_map.pcd` | The transformed map cloud for downstream localization/deployment. |
| `board_anchor.yaml` | The rigid transform and anchoring record. Retain it to compare future rebuilds. |
| `board_polygon.osm` | A Lanelet2 landmark polygon for the board. Merge it into the route vector map. |
| `map_projector_info.yaml` | Declares the map's coordinate convention. |

The generated `map_projector_info.yaml` must use a local projector:

```yaml
projector_type: Local
vertical_datum: WGS84
```

Do not copy an outdoor `TransverseMercator` configuration with latitude/longitude into this indoor map. The anchored map is metric-local and has no geodetic datum.

Use `pointcloud_map.pcd` as the source for the downstream tiling step (for example, `autoware_pointcloud_divider`). Retain the original GLIM dump, PLY export, configuration YAML, and the generated anchor record alongside the tiled output.

## 7. Validate the complete map contract

Map anchoring is successful only when the offline cloud, the fixed board, and runtime initialization agree. Validate in this order:

1. **Map-frame check:** Load the PCD and confirm the board lies at `board_pose_in_map`, with the expected normal and height.
2. **Rebuild check:** If you rebuild from the same bag, run anchoring with the same YAML and compare the new `board_anchor.yaml` and board pose to the prior version. Investigate material differences.
3. **Lanelet check:** Merge the generated board polygon into the Lanelet2 route map. Its dimensions and coordinates must agree with the shared YAML.
4. **Stationary bag test:** With a stationary, board-visible scan and calibrated static TF, launch the board initializer in dry-run mode. Its input must have `x`, `y`, `z`, and intensity; the cloud frame must match its `sensor_frame`.
5. **Vehicle test:** Only after dry-run passes, start the localization stack, verify `/localization/initialize` exists, start the initializer with `dry_run:=false`, and confirm it supplies an `AUTO` pose that NDT refines.

For the stationary bag test:

```bash
ros2 launch golfcart_board_initializer board_initializer.launch.xml \
  dry_run:=true input_topic:=/your/lidar/topic

ros2 bag play /path/to/stationary_board_bag --clock
```

Success means the diagnostic state is `done`, the accepted-board debug cloud contains only board points, and the debug initial pose is published. Record the bag name, board range, dimensions, configuration revision, computed pose, independently expected pose, and pass/fail result for every validation run.

## Operating rules after deployment

- Inspect the board and its mount before each mapping or localization campaign.
- Treat any board move, new reflective material, changed dimensions, sensor-extrinsic change, or map rebuild as a map-contract change: re-anchor and repeat the stationary-bag test.
- Keep the vehicle stationary and board-visible for the one-shot cold-start initializer. It accumulates scans to improve the detection; it is not a continuous localizer.
- If initialization fails, fix the cause and restart the node. In the referenced implementation, terminal failure does not retry automatically.
- Never use a confident NDT result as proof that anchoring was correct; a moved board can yield a consistently wrong but plausible local frame.

## Final checklist

- [ ] Board is permanently fixed, rectangular, and physically measured
- [ ] One shared YAML records board dimensions, height, and `board_pose_in_map`
- [ ] GLIM source cloud retains intensity and the board is visible
- [ ] GLIM map was loop-closure-checked and cleaned before anchoring
- [ ] Anchoring dry run found exactly one geometrically valid board
- [ ] Anchored PCD, `board_anchor.yaml`, local projector metadata, and board polygon were retained
- [ ] Board pose agrees in map inspection, stationary-bag dry run, and vehicle/NDT validation

## Source notes

The anchoring contract, board design, and deployment boundaries are derived from `/home/jetson/2026-golf-cart/docs/design/indoor_pcd_mapping_reflector_anchor.md`. Commands, generated artifacts, and runtime validation behavior are derived from `/home/jetson/2026-golf-cart/src/localization/golfcart_board_initializer/README.md`. GLIM-specific collection, editing, and PLY-export guidance is cross-linked to this repository's [mapping tutorial](mapping-tutorial.md).
