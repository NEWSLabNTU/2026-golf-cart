# Spherical sensor view

Every camera image and every LiDAR return painted onto one sphere centred on
`base_link`, so that a wrong sensor transform is something you see instead of
something you compute.

```bash
just tool sphere        # against the vehicle
just tool sphere-demo   # against synthetic sensors, no vehicle needed
```

Design: [sphere_sensor_view.md](../design/sphere_sensor_view.md).
Phase: [5-sphere-sensor-view.md](../roadmaps/5-sphere-sensor-view.md).

**This tool renders. It does not calibrate.**
[LCTK](https://github.com/NEWSLabNTU/LCTK) computes the extrinsics; this reads
what `/tf_static` already carries. It shows the calibration the system is
*running*, which is not always the one a file describes.

---

## The idea in one paragraph

Every sensor measures directions. A camera pixel is a direction plus a colour; a
LiDAR return is a direction plus a range. If the transforms are right, two
sensors looking at the same physical feature report the same direction from
`base_link`. Put both on one sphere and the comparison is immediate — no target,
no ground truth, no measurement, just the observation that they should agree.

---

## Before it will show anything

- The stack must be running, or a bag playing. This is a passive viewer.
- `/tf_static` must carry `base_link` to each sensor frame. A missing transform
  is reported per layer in the Displays panel rather than failing silently.
- Cameras must publish `camera_info`. There is no patch to paint without
  intrinsics, and the layer says so.

The vehicle can be parked and the DBW off. Nothing here needs motion.

---

## Reading it

Park facing something with both **depth structure and visual texture** — a
doorway, a building corner, parked cars. A blank wall tells you nothing, because
there is no edge for the two sensors to disagree about.

### 1. Does the cloud sit on the image?

Set one camera and one LiDAR visible, `Placement: Angular`. The returns are
snapped to the sphere radius, so range is discarded and only direction remains —
which is the only thing a camera can be compared against.

Look at a depth discontinuity: the doorway's edge, the corner of a building. It
should land on the visual edge in the image.

If it does not, the camera-to-`base_link` rotation is wrong, and the direction
of the offset tells you which angle.

### 2. Are the seams continuous?

Turn on the neighbouring camera. Where two patches meet, a feature crossing the
seam should continue across it.

A break has two possible causes, and the next step tells them apart.

### 3. Sweep the radius

**One sphere has one radius; the world does not.** A camera ray is painted at
the sphere's radius, which is only correct for features actually at that
distance. Everything else lands slightly wrong, and two cameras with different
centres land wrong differently — which opens a seam.

So sweep `Radius`:

- **Seam closes at some radius** — the calibration is fine. The radius was
  simply not the depth of what you were looking at. Features align when the
  radius matches their true distance, which makes this a crude depth read-out.
- **Seam persists at every radius** — a real translation error between the two
  cameras.

### 4. Switch to Metric to separate translation from radius

`Placement: Metric` leaves returns at their measured range. The sphere stops
being a sphere, and the cloud shows the scene's actual shape. A wall stands at
its true distance; what lies beyond a doorway sits behind it.

Use this when Angular says the directions agree but something still looks wrong:
a translation error shows as depth disagreement rather than being projected
away.

---

## Properties worth knowing

| Property | What it does |
|---|---|
| `Radius` | Where camera rays are painted. See step 3 — this is not cosmetic. |
| `Grid Step` | Sphere tessellation in degrees. Smaller is smoother and slower to rebuild; it does not affect the per-frame cost. |
| `Placement` | `Angular` for the direction comparison, `Metric` for true range. |
| `Colour By` | `Intensity`, `Range`, or `Flat`. |
| `Intensity Max` | Top of the intensity scale. The VLP-32C reports 0–100 for diffuse surfaces and 101–255 for retroreflectors, so a 3M board saturates. |
| `Decimation` | Keep one return in N. A 32-plane cloud will otherwise bury the image it is meant to be checked against. |
| Per-layer `Alpha` | Look through an overlap, or fade a camera to see the cloud under it. |

`Colour By: Flat` with a different colour per LiDAR is what makes VLP-32C
against Falcon legible where they overlap.

Every layer can be switched off individually. That is how a seam gets attributed
to one side or the other: turn one camera off and see which one moved.

---

## Gaps between patches are not a fault

Each camera covers only the directions its lens actually sees, so patches stop
short of each other and bare sphere shows through. That is the honest picture.

The reason it is worth stating: a distortion model is fitted over the angles a
lens really sees and is meaningless past them, and a radial polynomial typically
turns over somewhere outside that range and starts mapping ever-wider rays back
towards the image centre. On the Leo Drive cameras, whose real field reaches
about 55 degrees off axis, a ray at 65 degrees projects to a pixel comfortably
inside the frame. Painting those directions produces a band of stretched texture
sampled from somewhere the camera never looked -- and unlike a gap, it looks
like data.

The display finds where each model stops increasing and refuses anything beyond
it. So a gap means "no camera sees this direction", which is a coverage answer
worth having, and never a silent lie.

## What it cannot tell you

**Which parameter is wrong.** A bad extrinsic and a bad intrinsic both bend the
projection. The tool says "these disagree", not "your yaw is off by 3°".

**Whether the intrinsics are right.** It applies whatever `camera_info` carries.
If the distortion coefficients are wrong, the image is painted wrong and the
tool cannot know. See
[phase 3A](../roadmaps/3-indoor-a-camera-calibration.md) — this has been a real
problem on this vehicle.

**Anything below its own resolution.** Judging a seam by eye is worth perhaps a
degree. It catches gross errors — a swapped camera, a missing optical-frame
rotation, a sign flip — and it will not certify 0.5°.

---

## If nothing appears

The Displays panel reports per layer, one line each. In order of likelihood:

| Symptom | Cause |
|---|---|
| `waiting for CameraInfo` | the camera is publishing images but not `camera_info`, or the topic name is wrong |
| `no transform base_link -> camera_x` | `/tf_static` has not arrived, or the sensor kit does not publish that frame |
| `No part of the sphere projects into this image` | the camera's frame orientation is wrong — usually a body frame where an optical frame was expected |
| `0 points` | the LiDAR topic is wrong, or QoS does not match |
| everything blank, no errors | the display is enabled but `Fixed Frame` in Global Options is a frame nothing connects to |

Stock RViz2's **Camera** display does the single-camera version of check 1 for
free, using `camera_info` to composite the 3D scene onto the image. If the
sphere view shows nothing, try that first to establish whether the problem is
this display or the data.
