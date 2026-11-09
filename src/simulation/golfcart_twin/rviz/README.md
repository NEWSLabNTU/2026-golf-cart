# Twin demo RViz

`twin_demo.rviz` is the RViz a presenter opens beside the Isaac editor. It shows what the
cart's own Autoware sees and does at the T junction in front of 學新館.

```bash
src/simulation/golfcart_twin/rviz/twin_rviz.sh      # after sourcing Autoware, in the ego's domain
```

`ros2 launch golfcart_twin twin_autoware.launch.xml` starts the same RViz (`rviz:=true`, the
default), with the same parameters. `twin_rviz.sh` is for opening it on its own. It passes the vehicle parameters from `golfcart_vehicle_description` and
`use_sim_time:=true`. Without the vehicle parameters, RViz drops the whole config ("Statically
typed parameter 'wheel_radius' must be initialized") and opens empty. That is why neither goes through `golfcart_autoware.launch.xml`'s `rviz_config`.

## How it is made

`make_twin_rviz.py` derives it from the cart's `golfcart_launch/rviz/golfcart_ntu.rviz`. That
is the NTU config: the stock Autoware one with the point cloud map made visible from above.
Only the differences below are applied, so regenerate after the base changes:

```bash
python3 src/simulation/golfcart_twin/rviz/make_twin_rviz.py
```

## What it shows, and why

- **View:** it follows the cart from behind and above (ThirdPersonFollower on `base_link`,
  26 m away, 0.85 rad above the horizon, centred 1.5 m ahead of `base_link`): the whole cart,
  its lidar returns around it and the road ahead. The top-down view of the T junction is kept
  as the saved view "Twin T junction" (centred at map (53014, 67870), north up, about 70 m
  tall), with "Follow the cart" and the base's ThirdPersonFollower and TopDownOrtho.
- **Map:** the lanelet2 vector map, and the point cloud map dimmed to a backdrop (grey,
  1 px, alpha 0.4) so the live lidar stands out over it.
- **Ego:** the vehicle model (its footprint, from `robot_description`), the EKF pose history,
  and `/tf` as axes only. Frame names and arrows are off: the cart's tree is dense.
- **What it senses:**
  - `/sensing/lidar/concatenated/pointcloud`: both lidars, coloured by intensity, 3 px, best effort.
  - `/localization/pose_estimator/points_aligned`: the cloud NDT matched, in green. It shows
    localization working.
  - Perception's predicted objects.
- **What it plans:**
  - the route (`route_marker`) and the goal;
  - the scenario trajectory, coloured by speed;
  - the behavior path;
  - virtual walls and planning factors, which explain any stop.
- **Camera:** the ZED X image (`/sensing/camera/zed/rgb/color/rect/image`, best effort,
  depth 1) in the dock named "Image", where the base window keeps an image dock. Move it to
  any corner and save the config.
- **Panels:** AutowareStatePanel (engage, operation mode), ControlModeDisplay and the date
  and time, in the left dock. The right dock's panels (Displays, Views, Tool Properties,
  Selection) are closed so the 3D view has the room; Panels > Add New Panel brings any of
  them back, and the saved views with the Views panel. (`Hide Right Dock` only collapses them
  in rviz2, and they still showed, so the generator drops them from the config.) On the
  toolbar: 2D Pose Estimate (`/initialpose`), 2D Goal Pose (`/planning/mission_planning/goal`)
  and the base's other tools.

**Turned off as noise for the demo:**
- debug output: anything on a `/debug/` topic except virtual walls;
- lane-change candidate paths, since the roads there have one lane each way;
- the traffic light group, since the site has no traffic lights;
- the board detector outline and the Monte Carlo initial pose markers;
- the polar grid, the no-ground cloud and the controller's predicted trajectory;
- the freespace pose arrays and the planning error and validator debug markers.

## Checked

- 2026-11-07 on host 243 (rviz2 from ROS 2 Humble, Autoware 1.5.0 plugins), with the vehicle
  parameters: RViz loaded the config and ran 47 s with no "Failed to load" or plugin errors.
  No stack was running, so no data was shown.
- Every topic is the base config's or the cart's own:
  - the lidar topic: `golfcart_sensor_kit_launch` `pointcloud_preprocessor.launch.py`;
  - the ZED topic: `zed.launch.xml` (node `zed` in `/sensing/camera`) and the sensor kit README;
  - the rest: Autoware 1.5's own names, unchanged from `golfcart_ntu.rviz`.
