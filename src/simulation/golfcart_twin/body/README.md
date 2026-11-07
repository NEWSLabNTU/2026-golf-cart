# Golf cart body for Isaac Sim

A low-poly USD body of NEWSLab's golf cart as it stands in 2026: the white hood, windshield,
canopy and roof rack, the VLP-32C on its mast, the front deck with the Falcon over the ZED X,
the four-door cargo box, the bench seat and the wheels. It is render only: no physics and no
colliders. aib's PhysX vehicle and its box are the physics.

```bash
pip install usd-core numpy             # make_body.py needs only these
python3 make_body.py OUT_DIR
```

`make_body.py` writes `OUT_DIR/vehicle.newslab.golfcart/`:

| File | Holds |
|---|---|
| `vehicle.newslab.golfcart.usda` | default prim `/Vehicle`: the cart, its sensor housings and its wheels (`/Vehicle/Wheels/*`, referencing `wheels.usda`) |
| `wheels.usda` | `/Wheel_Front_Left`, `/Wheel_Front_Right`, `/Wheel_Rear_Left`, `/Wheel_Rear_Right`, each centred on its own origin, axle along y, spokes facing out |
| `entry.json` | the cart's entry for swb_isaac_world's `vehicles.json`, paths relative to `OUT_DIR` |

Frame, as in CARLA's vehicle assets: metres, Z up, x forward, y left. The origin is on the
ground at mid-length, halfway between the hood's front and the cargo box's rear. The rear axle
is at `rear_axle_x` = -0.823; swb's `add_ego_body()` puts it on base_link. Each part is its
own named mesh (`/Vehicle/Body/Hood`, `/Vehicle/Cabin/Windshield`,
`/Vehicle/Sensors/Falcon/Housing`, ...) with a `UsdPreviewSurface` material under
`/Vehicle/Looks`. The body is about 5,600 triangles and the four wheels about 3,000.

Previews, flat-shaded with a small numpy z-buffer:

```bash
pip install matplotlib
python3 render_previews.py OUT_DIR PREVIEW_DIR [PHOTO_DIR]
```

With `PHOTO_DIR`, each view is put beside the matching photo. The photos stay out of git
because they show bystanders' licence plates.

## Headlights

The body carries a `headlights` variant set on `/Vehicle`: `off` (the default) and `on`. With
`on`, the headlamps' material glows and a light shines from each lamp: a UsdLux SphereLight,
0.03 m across, shaped to a 40 degree cone and aimed 4 degrees down, at 5e6 nits. That value was
chosen in Isaac Sim 6.1 on 2026-11-07, in a night scene with a wall 8 m ahead: 7e5 nits barely
showed, and 2e7 washed out the wall. It is `HEADLIGHT_INTENSITY` in `make_body.py`.

Switch it in the Isaac editor: select the vehicle's `model` prim (the prim that references
this asset), then Property panel, Variants, `headlights`. From code:

```python
prim.GetVariantSets().GetVariantSet("headlights").SetVariantSelection("on")
```

`render_previews.py ... --headlights on` draws the lamps lit.

## The Autoware vehicle mesh

`make_vehicle_mesh.py OUT.dae` writes the same geometry (body, sensor housings, wheels) as a
COLLADA mesh for `golfcart_vehicle_description` (`mesh/golfcart.dae`). It uses the frame of
Autoware's vehicle meshes, as in sample_vehicle_description's lexus.dae: Y up, facing -X, with
the origin on the ground at mid wheelbase. `vehicle.xacro` places it with
`origin xyz="${wheel_base/2} 0 0" rpy="${pi/2} 0 ${pi}"`.

Every triangle is written for both sides, because RViz culls back faces. Regenerate the mesh
after changing the body:

```bash
python3 make_vehicle_mesh.py ../../../vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/mesh/golfcart.dae
```

## The lidars' own rays

Isaac's RTX lidar casts from the sensor origin. A housing around the emitter stops every ray
before the near range (0.3 m on the VLP-32C, 0.4 m on the Falcon), and the sensor returns
nothing. That happened on 118 on 2026-11-07. So the housings stay out of their own rays:

- The VLP-32C's body ends 0.03 m below its origin, inside the -25 deg cone, with its top band
  in the cap's blue as the cue. The head (window and cap) is not modelled.
- The Falcon's housing lies wholly behind its emitter plane, 5 mm back, square to its own axes.
  It has no window.

`check_lidar_clearance.py` casts their rays through the generated body. On 2026-11-07:

- **Falcon:** no hit within 0.5 m (the corner and centre rays, and every 1 deg).
- **VLP-32C:** still meets the cart's own structure close by:
  - the cargo box's top just behind it and below (646 of 11520 rays, nearest 0.15 m);
  - the canopy (170, nearest 0.37 m);
  - the rack's cross bar under the mast (4, nearest 0.23 m).

  The real lidar sits in the same place over the same box, so this is a blind sector, not a
  modelling error. The box's top height (1.90 m) is an estimate.

## What each part is sized from

From the cart's files, exact:

| Part | Source |
|---|---|
| Wheel centres, radius 0.265, width 0.14 | `vehicle_info.param.yaml`: wheel_base 2.061, wheel_tread 1.213 |
| Length 3.288 m, from the hood's front to the cargo box's rear | front_overhang 0.406, rear_overhang 0.821 (see below) |
| VLP-32C origin at base_link (0.46, 0, 1.966), with the kit's roll and pitch | `sensors_calibration.yaml`, sensor_kit_base_link |
| Every sensor housing (the VLP-32C's too, above): Falcon, ZED X, left, right and rear cameras | `sensor_kit_calibration.yaml`, composed with the kit's pose |
| Front wheels' max_steer_deg 30 | max_steer_angle 0.52 rad (`vehicle_info.param.yaml`) |

The rear overhang is read as reaching the cargo box's rear, not the bumper's. In the side
photo, hood front to box rear measures 3.31 m at the wheels' scale, which matches 3.288. The
bumper ends about 0.24 m ahead of the box.

Estimates, from the photos (01-10) at the wheels' scale:

| Part | Estimate |
|---|---|
| Body half width 0.635, box half width 0.68 | photos 01, 07, 08, 09 |
| Bonnet: bounded by the windshield, two near-vertical outer edges (half width 0.58 at the windshield, 0.63 at the front) and the U at its front (the user's sketches on the front photo, 2026-11-07). Its centre is a sunken panel, flat across +-0.22 with a centre crease, that sinks 0.15 below the shoulders by the front. Slopes rise from it to raised shoulders along the outer edges. The shoulders' top line falls from 0.98 at the windshield to 0.70 at the front, where the edge rolls over (radius 0.065), so the U is 0.56 in the middle and 0.71 over the headlamps. Front arches hug the tyres (radius 0.32, thin black lip) | the user's sketches; photos 05, 07, 08 |
| Windshield base x 1.55 base_link, front posts raked 0.24 m over their height | photo 05 |
| Canopy x 0.42 to 1.54, top 1.80; roof rack 5 cm above it | photos 05, 06; the canopy sits under the VLP-32C |
| Cargo box x -0.821 to 0.47, z 0.73 to 1.90, doors in two rows of two each side | photos 05, 06 |
| Bench seat, seat base, the dark cockpit console (side profile), steering wheel (right-hand drive) | photos 02, 05, 06, 08 |
| Front face, in two parts (the user's sketch, 2026-11-07): a white band under the bonnet's U, following it 0.15 m lower (its lower edge 0.415 in the middle, 0.565 under the headlamps), with the headlamps (0.11 m across, grey as in the photo, sRGB about (105, 105, 108), with a thin dark rim) in its raised corners at (+-0.48, 0.63) and a horizontal recess in the middle; under it the black bumper, its top following the white band, with thin wings out to the wheel arches (down to 0.50) and a deeper centre block (+-0.44, down to 0.25) carrying the reflectors | the user's sketch; photos 07, 08 |
| Mirrors at the windshield's top corners, z 1.47 to 1.66 | front photo, 2026-11-07 |
| GNSS antenna puck on the box at x -0.52 base_link, y 0 | photos 05, 06 (see below) |
| VLP-32C body 103 mm across, ending 0.03 m below its origin (the head is left out, see the lidars' own rays) | the Velodyne family's drawings |
| Falcon housing 0.16 x 0.27 x 0.09 m, centred on its origin | photos 04, 10 |
| ZED X housing 0.034 x 0.188 x 0.033 m, centred on its origin | Stereolabs' size class |
| GMSL camera housings 35 mm cubes, the lens on the origin | none |

## Where the photos and the calibration disagree

Every sensor housing sits at its calibrated pose. On 2026-11-07 the user chose the calibration
over the photos for the front deck and the side cameras, so the model and the sim's sensors
(built from the same calibration) agree. A model that followed the photos would have put each
housing away from the sensor it stands for.

- **The front deck** is at its calibrated height: the Falcon's centre at z 0.465 and the ZED X
  at 0.358 in base_link, with the kit's pitch. That is level with the black bumper. In photos 04,
  08 and 10 the Falcon is at headlamp height, about 0.15 m higher. The Falcon's six LCTK
  archives are all marked DEGENERATE. Without the kit's pitch of 0.032 rad, the Falcon would
  sit at 0.535.
- **The left and right cameras** are at (1.366, 0.539, 0.800) and (1.403, -0.474, 0.807). That is
  behind the bonnet's rear edge, 0.19 m below where the photos show them (outside the front
  posts at the windshield's base). At those poses they sat inside the cockpit console. The
  console's outer strips (outside +-0.44) now stop at z 0.72, a local notch that leaves both
  housings in the open.
- **gnss_base_link** is at base_link (0.83, 0, 1.69), under the canopy's front. The antenna puck
  in the photos is on the cargo box's roof, near its rear, so the model puts the puck there.
- **camera_rear** (-0.50, 0, 0.30) sits at the rear body's lower edge, behind the rear wheels and
  under the cargo box. The model's rear body ends at x -0.47 so that the housing stays outside it.
