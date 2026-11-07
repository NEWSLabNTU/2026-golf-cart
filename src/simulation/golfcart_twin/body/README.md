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

## What each part is sized from

From the cart's files, exact:

| Part | Source |
|---|---|
| Wheel centres, radius 0.265, width 0.14 | `vehicle_info.param.yaml`: wheel_base 2.061, wheel_tread 1.213 |
| Length 3.288 m, from the hood's front to the cargo box's rear | front_overhang 0.406, rear_overhang 0.821 (see below) |
| VLP-32C origin at base_link (0.46, 0, 1.966), with the kit's roll and pitch | `sensors_calibration.yaml`, sensor_kit_base_link |
| Left, right and rear camera housings | `sensor_kit_calibration.yaml`, composed with the kit's pose |
| Falcon and ZED X housings: x and y, and their height relative to each other | the same, then lifted 0.155 m (see below) |
| Front wheels' max_steer_deg 30 | max_steer_angle 0.52 rad (`vehicle_info.param.yaml`) |

The rear overhang is read as reaching the cargo box's rear, not the bumper's. In the side
photo, hood front to box rear measures 3.31 m at the wheels' scale, which matches 3.288. The
bumper ends about 0.24 m ahead of the box.

Estimates, from the photos (01-10) at the wheels' scale:

| Part | Estimate |
|---|---|
| Body half width 0.635, box half width 0.68 | photos 01, 07, 08, 09 |
| Hood: top 0.96 at the windshield, front face 0.50 to 0.80, crown 3 cm, centre crease 1.8 cm | photos 01, 05, 08 |
| Windshield base x 1.55 base_link, front posts raked 0.24 m over their height | photo 05 |
| Canopy x 0.42 to 1.54, top 1.80; roof rack 5 cm above it | photos 05, 06; the canopy sits under the VLP-32C |
| Cargo box x -0.821 to 0.47, z 0.73 to 1.90, doors in two rows of two each side | photos 05, 06 |
| Bench seat, seat base, dashboard, steering wheel (right-hand drive) | photos 02, 05, 06, 08 |
| GNSS antenna puck on the box at x -0.52 base_link, y 0 | photos 05, 06 (see below) |
| VLP-32C 103 mm across, 88 mm tall, origin 38 mm above its base | the Velodyne family's drawings |
| Falcon housing 0.16 x 0.27 x 0.09 m, centred on its origin | photos 04, 10 |
| ZED X housing 0.034 x 0.188 x 0.033 m, centred on its origin | Stereolabs' size class |
| Front deck height: the Falcon's centre at z 0.62 base_link, its ZED X bracket's foot on the bumper | photos 04, 08, 10 |
| GMSL camera housings 35 mm cubes, the lens on the calibrated origin | none |

## Where the photos and the calibration disagree

The housings follow the calibration, except for the front deck.

- **The front deck follows the photos, 0.155 m above the calibration** (`DECK_DZ`).
  The calibration puts the Falcon at z 0.465 and the ZED X at 0.358 in base_link. At that
  height the deck sits level with the black bumper and does not read as the deck. In photos
  04, 08 and 10, the Falcon is at headlamp height and the ZED X just above the bumper. The
  Falcon's six LCTK archives are all marked DEGENERATE. Without the kit's pitch of 0.032 rad,
  the Falcon would sit at 0.535. Their x and y stay calibrated. An Isaac rig built from the
  calibration places these two sensors 0.155 m below their housings here.
- **gnss_base_link** is at base_link (0.83, 0, 1.69), under the canopy's front. The antenna puck
  in the photos is on the cargo box's roof, near its rear, so the model puts the puck there.
- **camera_rear** (-0.50, 0, 0.30) sits at the rear body's lower edge, behind the rear wheels and
  under the cargo box. The model's rear body ends at x -0.47 so that the housing stays outside it.
