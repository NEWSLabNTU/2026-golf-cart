#!/usr/bin/env python3
"""A low-poly USD body of NEWSLab's golf cart (2026 build), for Isaac Sim, render only.

    python3 make_body.py OUT_DIR

writes OUT_DIR/vehicle.newslab.golfcart/:
  vehicle.newslab.golfcart.usda  default prim /Vehicle: the cart, its sensors and its wheels;
  wheels.usda                    /Wheel_Front_Left, ..., each centred on its own origin, axle y;
  entry.json                     the cart's entry for swb_isaac_world's vehicles.json
                                 (paths relative to OUT_DIR).

Frame (as CARLA's vehicle assets): metres, Z up, x forward, y left, the origin on the ground at
mid-length (between the hood's front and the cargo box's rear). The rear axle is at
x = rear_axle_x (entry.json); swb's add_ego_body() puts it on base_link.

Sizes come from the cart's own files where they say anything (README.md lists every source):
  golfcart_vehicle_description/config/vehicle_info.param.yaml   wheels, length, height;
  golfcart_sensor_kit_description/config/sensors_calibration.yaml and
  sensor_kit_calibration.yaml                                   every sensor housing;
and from the photos for the rest (estimates). No physics, no colliders: aib's PhysX vehicle
and its box are the physics.

Needs only usd-core (pxr) and numpy.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, Vt

ASSET_ID = "vehicle.newslab.golfcart"

# ---- vehicle_info.param.yaml (golfcart_vehicle_description) ----------------------------------
WHEEL_BASE = 2.061
WHEEL_TREAD = 1.213
WHEEL_RADIUS = 0.265
WHEEL_WIDTH = 0.14
FRONT_OVERHANG = 0.406
REAR_OVERHANG = 0.821
VEHICLE_HEIGHT = 2.005
MAX_STEER_DEG = 30.0           # max_steer_angle 0.52 rad, inside the VCU's +-30 deg

# base_link (rear axle centre on the ground) -> the asset frame: x_asset = x_base + X_SHIFT
X_FRONT = WHEEL_BASE + FRONT_OVERHANG           # the hood's front, in base_link
X_REAR = -REAR_OVERHANG                         # the cargo box's rear, in base_link
X_SHIFT = -(X_FRONT + X_REAR) / 2.0
REAR_AXLE_X = X_SHIFT

# ---- sensors_calibration.yaml / sensor_kit_calibration.yaml (golfcart_sensor_kit_description)
SENSOR_KIT = ((0.46, 0.0, 1.966), (-0.016794, 0.031978, 0.0))     # base_link -> sensor_kit_base_link
KIT_CHILDREN = {                                                   # sensor_kit_base_link -> child
    "vlp32c": ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0)),
    "falcon": ((2.197845303, 0.05262411, -1.430838877), (-0.077524484, -1.333385551, -3.073378269)),
    "zed_camera_link": ((2.225473859, 0.032849606, -1.537299588), (0.016835173, -0.037701763, 0.006832191)),
    "camera_left": ((0.9426154546835364, 0.5584876525550044, -1.1269152055909257),
                    (-0.08157476261707551, -0.1090220082688429, 0.7341035203898821)),
    "camera_right": ((0.9795053939071179, -0.4553600340666411, -1.1362438424601349),
                     (0.028163430272001973, -0.08230178821024782, -0.09271942248981242)),
    "camera_rear": ((-0.906242929, 0.02847863, -1.695602761), (-0.016802674, 0.031973444, 3.141052803)),
    "gnss_base_link": ((0.37863526, 0.004433895, -0.263991818), (0.016802589, -0.031973489, -0.000537196)),
}


def rpy(r, p, y):
    """URDF fixed-axis XYZ: R = Rz(y) Ry(p) Rx(r)."""
    cr, sr, cp, sp, cy, sy = math.cos(r), math.sin(r), math.cos(p), math.sin(p), math.cos(y), math.sin(y)
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]])
    ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]])
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]])
    return rz @ ry @ rx


def sensor_pose(name):
    """`name`'s origin and rotation in base_link."""
    (t0, r0), (t1, r1) = SENSOR_KIT, KIT_CHILDREN[name]
    R0 = rpy(*r0)
    return np.array(t0) + R0 @ np.array(t1), R0 @ rpy(*r1)


# ---- mesh primitives: (points [N,3], faces [list of index lists]) in base_link ----------------

class Part:
    def __init__(self):
        self.pts, self.faces = [], []

    def add(self, pts, faces):
        o = sum(len(p) for p in self.pts)
        self.pts.append(np.asarray(pts, float))
        self.faces += [[i + o for i in f] for f in faces]
        return self

    def points(self):
        return np.concatenate(self.pts) if self.pts else np.zeros((0, 3))


def box(c, size, R=None):
    c, h = np.asarray(c, float), np.asarray(size, float) / 2
    p = np.array([[sx, sy, sz] for sx in (-1, 1) for sy in (-1, 1) for sz in (-1, 1)], float) * h
    if R is not None:
        p = p @ np.asarray(R).T
    f = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
    return p + c, f


def box_span(x, y, z):
    """Axis-aligned box from (min, max) spans."""
    return box([(x[0] + x[1]) / 2, (y[0] + y[1]) / 2, (z[0] + z[1]) / 2], [x[1] - x[0], y[1] - y[0], z[1] - z[0]])


def rbox(x, y, z, r, n=4):
    """Rounded box from spans, corner radius r, n segments per quarter."""
    lo, hi = np.array([x[0], y[0], z[0]], float), np.array([x[1], y[1], z[1]], float)
    c, inner = (lo + hi) / 2, np.maximum((hi - lo) / 2 - r, 1e-4)
    nu, nv = 4 * n, 2 * n
    th = (np.arange(nu) + 0.5) * 2 * math.pi / nu                  # half-step: no sample on an axis
    ph = (np.arange(nv) + 0.5) * math.pi / nv - math.pi / 2
    pts = []
    for p in ph:
        for t in th:
            d = np.array([math.cos(p) * math.cos(t), math.cos(p) * math.sin(t), math.sin(p)])
            pts.append(c + np.sign(d) * inner + r * d)
    top, bot = len(pts), len(pts) + 1
    pts += [c + [0, 0, inner[2] + r], c - [0, 0, inner[2] + r]]
    f = []
    for j in range(nv - 1):
        for i in range(nu):
            a, b = j * nu + i, j * nu + (i + 1) % nu
            f.append([a, b, b + nu, a + nu])
    f += [[bot, (i + 1) % nu, i] for i in range(nu)]
    o = (nv - 1) * nu
    f += [[o + i, o + (i + 1) % nu, top] for i in range(nu)]
    return np.array(pts), f


def frame_of(axis):
    a = np.asarray(axis, float)
    a = a / np.linalg.norm(a)
    u = np.cross(a, [0, 0, 1] if abs(a[2]) < 0.9 else [1, 0, 0])
    u /= np.linalg.norm(u)
    return a, u, np.cross(a, u)


def cylinder(p0, p1, r, n=16, caps=True):
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    a, u, v = frame_of(p1 - p0)
    ring = [r * (math.cos(t) * u + math.sin(t) * v) for t in np.arange(n) * 2 * math.pi / n]
    pts = [p0 + q for q in ring] + [p1 + q for q in ring]
    f = [[i, (i + 1) % n, n + (i + 1) % n, n + i] for i in range(n)]
    if caps:
        f += [list(range(n))[::-1], list(range(n, 2 * n))]
    return np.array(pts), f


def bar(p0, p1, w, h=None, up=(0, 0, 1)):
    """A square or rectangular bar between two points."""
    p0, p1 = np.asarray(p0, float), np.asarray(p1, float)
    a = p1 - p0
    L = np.linalg.norm(a)
    a /= L
    up = np.asarray(up, float)
    s = np.cross(up, a) if abs(np.dot(up, a)) < 0.95 else np.cross([1, 0, 0], a)
    s /= np.linalg.norm(s)
    t = np.cross(a, s)
    return box((p0 + p1) / 2, [L, w, h or w], np.stack([a, s, t], 1))


def lathe_y(profile, n=24):
    """Revolve a closed (r, y) profile about the y axis."""
    m = len(profile)
    pts = []
    for k in range(n):
        t = 2 * math.pi * k / n
        for r, y in profile:
            pts.append([r * math.cos(t), y, r * math.sin(t)])
    f = [[k * m + i, k * m + (i + 1) % m, ((k + 1) % n) * m + (i + 1) % m, ((k + 1) % n) * m + i]
         for k in range(n) for i in range(m)]
    return np.array(pts), f


def loft(rings, cap0=True, cap1=True):
    """Closed rings of equal size along a path, joined; the ends capped with a fan."""
    m = len(rings[0])
    pts = [p for r in rings for p in r]
    f = [[j * m + i, j * m + (i + 1) % m, (j + 1) * m + (i + 1) % m, (j + 1) * m + i]
         for j in range(len(rings) - 1) for i in range(m)]
    for ring_i, cap, rev in ((0, cap0, True), (len(rings) - 1, cap1, False)):
        if cap:
            c = len(pts)
            pts.append(np.mean(rings[ring_i], 0))
            o = ring_i * m
            f += [[o + (i + 1) % m, o + i, c] if rev else [o + i, o + (i + 1) % m, c] for i in range(m)]
    return np.array(pts), f


def arch(xc, y_in, y_out, r0, r1, a0=0.0, a1=math.pi, n=12, zc=WHEEL_RADIUS):
    """A wheel-arch flare: an annulus sector about (xc, zc) in the x-z plane, extruded in y."""
    ring = []
    for t in np.linspace(a0, a1, n):
        ring.append((xc + r1 * math.cos(t), zc + r1 * math.sin(t)))
    for t in np.linspace(a1, a0, n):
        ring.append((xc + r0 * math.cos(t), zc + r0 * math.sin(t)))
    return loft([[np.array([x, y, z]) for x, z in ring] for y in (y_in, y_out)])


def disc(c, normal, r, depth, n=16):
    c, a = np.asarray(c, float), np.asarray(normal, float)
    a /= np.linalg.norm(a)
    return cylinder(c - a * depth / 2, c + a * depth / 2, r, n)


# ---- the cart, in base_link -------------------------------------------------------------------

HALF_W = 0.64         # body half width at the hood (estimate: photos 01, 08)
BOX_HALF_W = 0.68     # cargo box half width (estimate: overhangs the wheels a little, photos 07, 09)
POST_Y = 0.60
FLOOR_Z = 0.30
HOOD_REAR_X = 1.55    # windshield base (estimate: photo 05)
HOOD_TOP = 0.98       # the hood's top at the windshield (estimate: photo 05)
HOOD_NOSE_TOP = 0.75  # ... where the nose starts (estimate: photo 05)
FRONT_FACE_TOP = 0.74      # the front face, between the nose and the bumper (estimate: photos 05, 08)
FRONT_FACE_BOTTOM = 0.50
BONNET_EDGE_MID = 0.55    # the bonnet's front edge at the centre line (sketch; README)
BONNET_EDGE_CORNER = 0.70  # ... over the headlamps
HOOD_SKIRT = 0.45     # the white fender's lower edge away from the wheel (estimate: photo 05)
# the left and right cameras' origins, from the photos (front view, 2026-11-07): outside the
# front posts, just above the windshield's base. The calibration has them at (1.366, 0.539,
# 0.800) and (1.403, -0.474, 0.807), behind the hood (README).
CAMERA_PHOTO = {"camera_left": (1.50, 0.665, 0.99), "camera_right": (1.50, -0.665, 0.99)}
DECK_DZ = 0.155      # the front deck above its calibrated height, from the photos (README)
NOSE_X = 2.18        # where the hood's top starts rounding down to its front face (estimate: photo 05)
ARCH_R = 0.32         # the front wheel arch about the wheel centre: the flare hugs the tyre (photos 05, 09)
CANOPY = (0.42, 1.54, 1.72, 1.80)         # x0, x1, z0, z1 (estimate; the VLP-32C on the rack fixes the top)
BOX_X = (X_REAR, 0.47)
BOX_Z = (0.73, 1.90)


def post_x(z):
    """The front post's line, from the floor to the canopy (photo 05)."""
    return 1.60 - (z - FLOOR_Z) * (0.24 / 1.42)


def bonnet_edge(y):
    """The bonnet's front edge, seen from the front (the user's sketch on the front photo,
    2026-11-07): high over each headlamp, low across the middle, just under the Falcon."""
    u = min(max((abs(y) - 0.28) / 0.20, 0.0), 1.0)          # flat to +-0.28, up by +-0.48
    return BONNET_EDGE_MID + (BONNET_EDGE_CORNER - BONNET_EDGE_MID) * u * u * (3 - 2 * u)


def _smooth(pts, n=3):
    """Chaikin corner cutting of an open polyline, ends kept."""
    for _ in range(n):
        q = [pts[0]]
        for p0, p1 in zip(pts[:-1], pts[1:]):
            q += [0.75 * p0 + 0.25 * p1, 0.25 * p0 + 0.75 * p1]
        q.append(pts[-1])
        pts = q
    return pts


def hood_ring(x, m=None):
    """The hood's cross-section at x (photos 05, 07, 08). The top slopes from HOOD_TOP at the
    windshield down to HOOD_NOSE_TOP before the nose. Two raised panels sit either side of a
    centre groove. The sides slope out from the panels' shoulders to the fender line, the
    widest point, then drop to the skirt, which follows the wheel arch."""
    s = min(max((x - HOOD_REAR_X) / (NOSE_X - HOOD_REAR_X), 0.0), 1.0)
    zt = HOOD_TOP + (HOOD_NOSE_TOP - HOOD_TOP) * s
    ws, wb = 0.50 - 0.02 * s, HALF_W - 0.01 * s            # shoulder and fender half widths
    zf = zt - (0.25 - 0.13 * s)                             # the fender line
    zb = HOOD_SKIRT
    dx = x - WHEEL_BASE
    if abs(dx) < ARCH_R:
        zb = max(zb, WHEEL_RADIUS + math.sqrt(ARCH_R ** 2 - dx ** 2))
    k = 0.0                                                 # 0 behind the nose, 1 at the front face
    if x > NOSE_X:
        k = min((x - NOSE_X) / (X_FRONT - NOSE_X), 1.0)
        c = 1 - math.sqrt(max(1 - k * k, 0.0))              # quarter-circle nose in plan and side
        zt -= (HOOD_NOSE_TOP - FRONT_FACE_TOP) * c
        zf = min(zf, zt - 0.06)
        ws *= 1 - 0.25 * c
        wb *= 1 - 0.03 * c
        zb = max(zb, FRONT_FACE_BOTTOM)
    half = [np.array(p, float) for p in (
        (0.0, zt - 0.008), (0.012, zt + 0.002), (0.05, zt + 0.012), ((0.05 + ws) / 2, zt + 0.03), (ws - 0.08, zt + 0.012),
        (ws, zt - 0.012), (ws + 0.05, zt - 0.045), (wb - 0.015, zf + 0.015), (wb, zf - 0.02),
        (wb, zb + 0.03), (wb - 0.02, zb), (0.0, zb))]
    half = half[:2] + _smooth(half[1:-1], 3)[1:] + [half[-1]]
    if k > 0:   # the nose's top comes down to the bonnet's front edge, a U across the front
        c = k ** 1.5
        half = [np.array([y, z - c * max(0.0, z - bonnet_edge(y))]) if z > zb + 0.02 else np.array([y, z])
                for y, z in half]
    ring = [np.array([x, y, z]) for y, z in half] + [np.array([x, -y, z]) for y, z in reversed(half[1:-1])]
    return ring


def _inside(poly, y, z):
    """Point in polygon (y-z plane), even-odd."""
    c = False
    for (y0, z0), (y1, z1) in zip(poly, poly[1:] + poly[:1]):
        if (z0 > z) != (z1 > z) and y < y0 + (z - z0) * (y1 - y0) / (z1 - z0):
            c = not c
    return c


def surface_x(y, z):
    """The hood's foremost x at (y, z): where a headlamp sits on its front face."""
    for x in np.linspace(X_FRONT, HOOD_REAR_X, 400):
        if _inside([(p[1], p[2]) for p in hood_ring(x)], y, z):
            return float(x)
    return HOOD_REAR_X


def build():
    P = {}

    def part(name, mat):
        P.setdefault(name, (Part(), mat))
        return P[name][0]

    xf, xr = WHEEL_BASE, 0.0
    # body
    xs = list(np.linspace(HOOD_REAR_X, NOSE_X, 22)) + list(NOSE_X + (X_FRONT - NOSE_X) * np.linspace(0.06, 1.0, 16))
    part("Body/Hood", "white_body").add(*loft([hood_ring(x) for x in xs]))
    part("Body/FrontLower", "black_plastic").add(*rbox((1.52, 2.36), (-0.50, 0.50), (0.24, 0.55), 0.04, 2))
    for sgn in (1, -1):     # the black panel behind each front wheel, floor to fender (photo 05)
        part("Body/FrontLower", "black_plastic").add(*rbox((1.52, 1.68), sorted((sgn * 0.52, sgn * 0.64)), (0.22, 0.56), 0.02, 2))
    # the black bumper (photos 07, 08 and the front photo, 2026-11-07): a low centre piece and
    # two corner pieces that rise to the headlamps and wrap back to the wheel arches
    bump = part("Body/BumperFront", "black_plastic")
    bump.add(*rbox((2.30, X_FRONT), (-0.44, 0.44), (0.25, 0.44), 0.04, 3))
    for sgn in (1, -1):
        bump.add(*rbox((2.24, X_FRONT - 0.01), sorted((sgn * 0.40, sgn * 0.62)), (0.25, 0.47), 0.06, 3))
    # the white fascia under the bonnet's front edge, set back from the bumper, with its
    # horizontal recess (front photo)
    part("Body/Fascia", "white_body").add(*rbox((2.28, X_FRONT - 0.025), (-0.44, 0.44), (0.43, 0.53), 0.02, 2))
    part("Body/FasciaRecess", "fascia_recess").add(*rbox((X_FRONT - 0.032, X_FRONT - 0.022), (-0.28, 0.28), (0.455, 0.505), 0.004, 1))
    lamps = part("Body/Headlamps", "lamp")
    for y in (0.45, -0.45):           # on the front face, right under the bonnet's edge
        xl = surface_x(y, 0.61)
        nrm = np.array([1.0, 0.6 * y, 0.0])
        lamps.add(*disc((xl - 0.006, y, 0.61), nrm, 0.055, 0.03))
        part("Body/HeadlampBezels", "black_plastic").add(*disc(np.array([xl - 0.012, y, 0.61]), nrm, 0.066, 0.03))
    seam = part("Body/BonnetSeam", "dark_plastic")   # the bonnet's front edge, as a dark line
    ys = np.linspace(-0.58, 0.58, 41)
    pts = [np.array([surface_x(y, bonnet_edge(y) - 0.008) + 0.003, y, bonnet_edge(y) - 0.008]) for y in ys]
    for p0, p1 in zip(pts[:-1], pts[1:]):
        seam.add(*bar(p0, p1, 0.008, 0.006))
    amb = part("Body/Reflectors", "amber")
    for y in (0.43, -0.43):
        amb.add(*disc((X_FRONT + 0.002, math.copysign(0.33, y), 0.36), (1, 0, 0), 0.03, 0.008))
    ar = part("Body/WheelArches", "black_plastic")
    for xc in (xf, xr):
        for sgn in (1, -1):
            yi, yo = sorted((sgn * (HALF_W - 0.03), sgn * (HALF_W + 0.035)))   # a thin lip
            r = ARCH_R if xc > 1.0 else 0.345
            a0 = 0.30 if xc > 1.0 else -0.05    # the front flare ends at the bumper, inside the length
            ar.add(*arch(xc, yi, yo, r - 0.015, r + 0.03, a0, math.pi + 0.05, 16))
    part("Body/Floor", "rubber_mat").add(*box_span((0.47, 1.60), (-0.60, 0.60), (0.20, FLOOR_Z)))
    sill = part("Body/Sills", "black_plastic")
    for sgn in (1, -1):
        sill.add(*rbox((0.30, 1.76), sorted((sgn * 0.56, sgn * 0.665)), (0.16, 0.31), 0.03, 2))
    part("Body/RearBody", "white_body").add(*rbox((-0.47, 0.47), (-0.66, 0.66), (0.26, BOX_Z[0]), 0.03, 2))
    part("Body/BumperRear", "black_plastic").add(*rbox((-0.58, -0.40), (-0.62, 0.62), (0.10, 0.26), 0.03, 2))
    # cabin
    # the dark cockpit console behind the windshield, floor to dashboard, its side profile from
    # photo 05: a sloped front panel over the footwell rising to a deep dashboard top
    prof = [(1.62, FLOOR_Z), (1.62, 1.00), (1.50, 1.08), (1.30, 1.12), (1.14, 1.10), (1.12, 1.03),
            (1.28, 0.96), (1.40, 0.70), (1.43, FLOOR_Z)]
    part("Cabin/Console", "dark_plastic").add(*loft([[np.array([x, y, z]) for x, z in prof] for y in (-0.56, 0.56)]))
    sw_c = np.array([1.05, -0.30, 1.20])                        # right-hand drive (photos 01, 08)
    sw_axis = np.array([-0.55, 0.0, 0.84])
    part("Cabin/SteeringColumn", "dark_plastic").add(*cylinder((1.25, -0.30, 1.08), sw_c, 0.025, 10))
    swp = part("Cabin/SteeringWheel", "dark_plastic")
    a, u, v = frame_of(sw_axis)
    ring = [sw_c + 0.17 * (math.cos(t) * u + math.sin(t) * v) for t in np.linspace(0, 2 * math.pi, 17)]
    for p0, p1 in zip(ring[:-1], ring[1:]):
        swp.add(*cylinder(p0, p1, 0.016, 6, caps=False))
    for t in (0.0, 2 * math.pi / 3, 4 * math.pi / 3):
        swp.add(*bar(sw_c, sw_c + 0.16 * (math.cos(t) * u + math.sin(t) * v), 0.02, 0.012))
    part("Cabin/SeatBase", "white_body").add(*rbox((0.47, 1.08), (-0.60, 0.60), (FLOOR_Z - 0.04, 0.62), 0.02, 2))
    seat = part("Cabin/BenchSeat", "seat")
    seat.add(*rbox((0.55, 1.07), (-0.55, 0.55), (0.62, 0.72), 0.04, 3))
    seat.add(*rbox((0.48, 0.57), (-0.55, 0.55), (0.76, 1.16), 0.035, 3))
    arm = part("Cabin/SeatRails", "black_plastic")
    for sgn in (1, -1):
        y = sgn * 0.57
        arm.add(*bar((0.55, y, 0.92), (0.80, y, 0.84), 0.025))
        arm.add(*bar((0.80, y, 0.84), (0.82, y, 0.70), 0.025))
    posts = part("Cabin/Posts", "black_plastic")
    for sgn in (1, -1):
        y = sgn * POST_Y
        posts.add(*bar((post_x(FLOOR_Z), y, FLOOR_Z), (post_x(CANOPY[2] + 0.02), y, CANOPY[2] + 0.02), 0.045))
        posts.add(*bar((0.50, y, BOX_Z[0] - 0.05), (0.50, y, CANOPY[2] + 0.02), 0.045))
    zw0, zw1, zband = HOOD_TOP, CANOPY[2] - 0.02, HOOD_TOP + 0.16
    for name, mat, z0, z1 in (("Cabin/WindshieldBand", "tinted_glass", zw0, zband),
                              ("Cabin/Windshield", "glass", zband, zw1)):
        q = [np.array(p) for p in ((post_x(z0), -POST_Y + 0.03, z0), (post_x(z0), POST_Y - 0.03, z0),
                                    (post_x(z1), POST_Y - 0.03, z1), (post_x(z1), -POST_Y + 0.03, z1))]
        n = np.array([1.0, 0.0, 0.24 / 1.42])
        n /= np.linalg.norm(n)
        pts = [p + n * 0.004 for p in q] + [p - n * 0.004 for p in q]
        part(name, mat).add(pts, [[0, 1, 2, 3], [7, 6, 5, 4], [0, 4, 5, 1], [1, 5, 6, 2], [2, 6, 7, 3], [3, 7, 4, 0]])
    x0, x1, z0, z1 = CANOPY
    part("Cabin/Canopy", "white_body").add(*rbox((x0, x1), (-0.64, 0.64), (z0, z1), 0.035, 3))
    part("Cabin/CanopyVisor", "white_body").add(*rbox((x1 - 0.14, x1 + 0.02), (-0.64, 0.64), (z0 - 0.06, z0 + 0.03), 0.03, 2))
    mir = part("Cabin/Mirrors", "black_plastic")
    for sgn in (1, -1):
        mir.add(*rbox((1.36, 1.40), sorted((sgn * 0.66, sgn * 0.77)), (1.47, 1.66), 0.012, 2))
        mir.add(*bar((post_x(1.60), sgn * POST_Y, 1.60), (1.38, sgn * 0.68, 1.58), 0.02))
    # roof rack (black aluminium), the VLP-32C mast on its rear cross bar
    vlp_o, vlp_R = sensor_pose("vlp32c")
    rack = part("Cabin/RoofRack", "alu_black")
    zr = z1 + 0.05
    for sgn in (1, -1):
        rack.add(*bar((vlp_o[0], sgn * 0.56, zr), (x1 - 0.10, sgn * 0.56, zr), 0.03))
        for xx in (vlp_o[0] + 0.03, x1 - 0.12):
            rack.add(*bar((xx, sgn * 0.56, z1 - 0.005), (xx, sgn * 0.56, zr), 0.025))
    for xx in (vlp_o[0], (vlp_o[0] + x1) / 2, x1 - 0.10):
        rack.add(*bar((xx, -0.575, zr), (xx, 0.575, zr), 0.03))
    # cargo box
    cb = part("CargoBox/Box", "white_body")
    cb.add(*rbox(BOX_X, (-BOX_HALF_W, BOX_HALF_W), BOX_Z, 0.012, 2))
    seams = part("CargoBox/DoorSeams", "dark_plastic")
    knobs = part("CargoBox/DoorLocks", "dark_plastic")
    xm, zm = (BOX_X[0] + BOX_X[1]) / 2, (BOX_Z[0] + BOX_Z[1]) / 2
    for sgn in (1, -1):
        yf = sgn * (BOX_HALF_W + 0.002)
        seams.add(*box((xm, yf, zm), (0.010, 0.006, BOX_Z[1] - BOX_Z[0] - 0.03)))
        seams.add(*box((xm, yf, zm), (BOX_X[1] - BOX_X[0] - 0.03, 0.006, 0.010)))
        for zz in (zm + 0.24, BOX_Z[0] + 0.25):
            for dx in (-0.07, 0.07):
                knobs.add(*disc((xm + dx, yf, zz), (0, sgn, 0), 0.015, 0.012, 10))
    struts = part("CargoBox/Struts", "black_plastic")
    for sgn in (1, -1):
        struts.add(*cylinder((X_REAR + 0.06, sgn * 0.60, BOX_Z[0]), (-0.50, sgn * 0.60, 0.30), 0.015, 8))
    # the GNSS antenna puck on top of the box (photos 05, 06; estimate: x from the photos, y = 0)
    part("CargoBox/GNSS_Antenna", "lidar_body").add(*cylinder((-0.52, 0, BOX_Z[1]), (-0.52, 0, BOX_Z[1] + 0.03), 0.065, 16))
    # ---- sensors, at their calibrated poses
    # VLP-32C: 103 mm across, 88 mm tall, its origin 38 mm above the base (estimates from the
    # Velodyne family's drawings); on a mast from the rack's rear cross bar.
    up = vlp_R[:, 2]
    base = vlp_o - up * 0.038
    part("Sensors/VLP32C/Mast", "alu_black").add(*cylinder((vlp_o[0], 0, zr), base, 0.025, 12))
    part("Sensors/VLP32C/Housing", "lidar_body").add(*cylinder(base, base + up * 0.025, 0.0515, 24))
    part("Sensors/VLP32C/Window", "lens").add(*cylinder(base + up * 0.025, base + up * 0.068, 0.0505, 24))
    part("Sensors/VLP32C/Cap", "lidar_cap").add(*cylinder(base + up * 0.068, base + up * 0.088, 0.0515, 24))
    # front deck, placed from the photos, not the calibration: two black extrusions from the
    # bumper's bottom, the Falcon on a white plate at headlamp height, the ZED X below it in a
    # white bracket, a white bar across the bottom. The calibration puts the Falcon and the
    # ZED X DECK_DZ lower, level with the black bumper (README).
    lift = np.array([0.0, 0.0, DECK_DZ])
    f_o = sensor_pose("falcon")[0] + lift
    z_o, z_R = sensor_pose("zed_camera_link")
    z_o = z_o + lift
    FAL = (0.16, 0.27, 0.09)          # the Falcon box, depth x width x height (estimate: photos 04, 10)
    deck = part("Sensors/SensorDeck/Frame", "alu_black")
    xp, yp = f_o[0] + 0.03, 0.215     # the posts, beside the Falcon's front half
    for sgn in (1, -1):
        y = sgn * yp
        deck.add(*bar((xp, y, 0.20), (xp, y, f_o[2] + FAL[2] / 2 + 0.035), 0.04))
        deck.add(*bar((X_FRONT - 0.02, y, 0.28), (xp, y, 0.28), 0.03))
    deck.add(*bar((xp - 0.04, -yp, 0.24), (xp - 0.04, yp, 0.24), 0.03))
    plates = part("Sensors/SensorDeck/Plates", "white_plate")
    zf = f_o[2] - FAL[2] / 2
    plates.add(*box_span((f_o[0] - FAL[0] / 2 - 0.02, xp + 0.02), (-yp, yp), (zf - 0.008, zf)))
    zz = z_o[2]
    plates.add(*box_span((z_o[0] - 0.035, z_o[0] - 0.017), (-0.15, 0.15), (zz - 0.035, zf - 0.008)))
    plates.add(*box_span((z_o[0] - 0.035, z_o[0] + 0.02), (-0.15, 0.15), (zz - 0.035, zz - 0.025)))
    plates.add(*box_span((xp + 0.02, xp + 0.026), (-yp + 0.02, yp - 0.02), (0.235, 0.29)))
    part("Sensors/Falcon/Housing", "black_plastic").add(*box(f_o, FAL))
    part("Sensors/Falcon/Window", "lens").add(*box(f_o + [FAL[0] / 2 + 0.002, 0, 0.005], (0.004, FAL[1] * 0.75, FAL[2] * 0.6)))
    ZED = (0.034, 0.188, 0.033)       # ZED X, depth x width x height (estimate, Stereolabs' size class)
    part("Sensors/ZEDX/Housing", "dark_plastic").add(*box(z_o, ZED, z_R))
    zl = part("Sensors/ZEDX/Lenses", "lens")
    for dy in (0.06, -0.06):
        zl.add(*disc(z_o + z_R @ [ZED[0] / 2, dy, 0], z_R[:, 0], 0.012, 0.006, 12))
    # GMSL cameras (Otobrite): a 35 mm cube with a lens, oriented as calibrated. The left and
    # right ones sit where the photos show them, outside the front posts at the windshield's
    # base, each on a silver bracket to its post (CAMERA_PHOTO; README). The rear one is at its
    # calibrated pose.
    cam = part("Sensors/Cameras/Housings", "dark_plastic")
    lens = part("Sensors/Cameras/Lenses", "lens")
    brk = part("Sensors/Cameras/Brackets", "white_plate")
    for name in ("camera_left", "camera_right", "camera_rear"):
        o, R = sensor_pose(name)
        if name in CAMERA_PHOTO:
            o = np.array(CAMERA_PHOTO[name])
        cam.add(*box(o - R[:, 0] * 0.018, (0.035, 0.035, 0.035), R))
        lens.add(*disc(o + R[:, 0] * 0.003, R[:, 0], 0.009, 0.012, 10))
        if name != "camera_rear":
            y = math.copysign(POST_Y, o[1])
            brk.add(*bar(o - R[:, 0] * 0.03 - [0, 0, 0.02], (post_x(o[2] - 0.02), y, o[2] - 0.02), 0.02, 0.006))
            brk.add(*box(o - R[:, 0] * 0.03 - [0, 0, 0.005], (0.01, 0.03, 0.04), R))
    return P


def wheel(left):
    """One wheel, centred on its origin, axle along y; the spokes face out (+y on the left)."""
    s = 1.0 if left else -1.0
    hw, R, rim = WHEEL_WIDTH / 2, WHEEL_RADIUS, 0.165
    prof = [(rim, -hw + 0.01), (rim + 0.02, -hw), (R - 0.03, -hw + 0.005), (R - 0.008, -hw + 0.02),
            (R, -hw + 0.04), (R, hw - 0.04), (R - 0.008, hw - 0.02), (R - 0.03, hw - 0.005), (rim + 0.02, hw),
            (rim, hw - 0.01)]
    tyre = Part().add(*lathe_y(prof, 28))
    hub = Part().add(*cylinder((0, -hw + 0.015, 0), (0, hw - 0.015, 0), rim, 20))
    face = s * (hw - 0.012)
    spokes = Part()
    for k in range(5):
        t = 2 * math.pi * k / 5
        d = np.array([math.cos(t), 0, math.sin(t)])
        spokes.add(*bar(d * 0.035 + [0, face, 0], d * (rim - 0.012) + [0, face, 0], 0.028, 0.02, up=(0, 1, 0)))
    spokes.add(*cylinder((0, face - s * 0.01, 0), (0, face + s * 0.012, 0), 0.04, 12))
    return {"Tyre": (tyre, "tyre"), "Hub": (hub, "alloy_dark"), "Spokes": (spokes, "alloy")}


MATERIALS = {   # name: (diffuse, roughness, metallic, opacity)
    "white_body": ((0.80, 0.80, 0.76), 0.35, 0.0, 1.0),
    "black_plastic": ((0.025, 0.025, 0.025), 0.6, 0.0, 1.0),
    "dark_plastic": ((0.09, 0.095, 0.10), 0.5, 0.0, 1.0),
    "rubber_mat": ((0.06, 0.06, 0.06), 0.9, 0.0, 1.0),
    "seat": ((0.20, 0.21, 0.22), 0.55, 0.0, 1.0),
    "glass": ((0.55, 0.60, 0.62), 0.05, 0.0, 0.18),
    "tinted_glass": ((0.03, 0.035, 0.04), 0.1, 0.0, 0.85),
    "alu_black": ((0.035, 0.035, 0.04), 0.4, 0.6, 1.0),
    "fascia_recess": ((0.55, 0.55, 0.53), 0.5, 0.0, 1.0),
    "white_plate": ((0.85, 0.85, 0.85), 0.3, 0.3, 1.0),
    "lamp": ((0.70, 0.70, 0.70), 0.15, 0.7, 1.0),
    "amber": ((0.95, 0.45, 0.02), 0.3, 0.0, 1.0),
    "lidar_body": ((0.42, 0.47, 0.55), 0.4, 0.3, 1.0),
    "lidar_cap": ((0.10, 0.32, 0.72), 0.35, 0.2, 1.0),
    "lens": ((0.01, 0.012, 0.015), 0.05, 0.0, 1.0),
    "tyre": ((0.02, 0.02, 0.02), 0.85, 0.0, 1.0),
    "alloy_dark": ((0.07, 0.07, 0.075), 0.35, 0.8, 1.0),
    "alloy": ((0.45, 0.46, 0.48), 0.3, 0.9, 1.0),
}


def define_materials(stage, root):
    UsdGeom.Scope.Define(stage, f"{root}/Looks")
    out = {}
    for name, (col, rough, metal, opac) in MATERIALS.items():
        mat = UsdShade.Material.Define(stage, f"{root}/Looks/{name}")
        sh = UsdShade.Shader.Define(stage, f"{root}/Looks/{name}/PreviewSurface")
        sh.CreateIdAttr("UsdPreviewSurface")
        sh.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*col))
        sh.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(rough)
        sh.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(metal)
        if opac < 1.0:
            sh.CreateInput("opacity", Sdf.ValueTypeNames.Float).Set(opac)
        mat.CreateSurfaceOutput().ConnectToSource(sh.ConnectableAPI(), "surface")
        out[name] = mat
    return out


def write_mesh(stage, path, part, mat, shift=(0.0, 0.0, 0.0)):
    pts = part.points() + np.asarray(shift)
    m = UsdGeom.Mesh.Define(stage, path)
    m.CreatePointsAttr(Vt.Vec3fArray.FromNumpy(pts.astype(np.float32)))
    m.CreateFaceVertexCountsAttr([len(f) for f in part.faces])
    m.CreateFaceVertexIndicesAttr([i for f in part.faces for i in f])
    m.CreateSubdivisionSchemeAttr(UsdGeom.Tokens.none)
    m.CreateDoubleSidedAttr(True)
    m.CreateExtentAttr([Gf.Vec3f(*pts.min(0)), Gf.Vec3f(*pts.max(0))])
    m.CreateDisplayColorPrimvar(UsdGeom.Tokens.constant).Set([Gf.Vec3f(*MATERIALS[mat[0]][0])])
    if MATERIALS[mat[0]][3] < 1.0:
        m.CreateDisplayOpacityPrimvar(UsdGeom.Tokens.constant).Set([MATERIALS[mat[0]][3]])
    UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(mat[1])
    return sum(len(f) - 2 for f in part.faces), pts


def new_stage(path, default):
    stage = Usd.Stage.CreateNew(str(path))
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    root = UsdGeom.Xform.Define(stage, default)
    stage.SetDefaultPrim(root.GetPrim())
    return stage, root


WHEELS = {"Wheel_Front_Left": (WHEEL_BASE, True), "Wheel_Front_Right": (WHEEL_BASE, False),
          "Wheel_Rear_Left": (0.0, True), "Wheel_Rear_Right": (0.0, False)}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1]) / ASSET_ID
    out.mkdir(parents=True, exist_ok=True)
    # wheels.usda: one root prim per wheel
    wpath = out / "wheels.usda"
    ws = Usd.Stage.CreateNew(str(wpath))
    UsdGeom.SetStageUpAxis(ws, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(ws, 1.0)
    tris_w = 0
    for name, (_, left) in WHEELS.items():
        UsdGeom.Xform.Define(ws, f"/{name}")
        Usd.ModelAPI(ws.GetPrimAtPath(f"/{name}")).SetKind("component")
        mats = define_materials(ws, f"/{name}")
        for pn, (p, mn) in wheel(left).items():
            tris_w += write_mesh(ws, f"/{name}/{pn}", p, (mn, mats[mn]))[0]
    ws.SetDefaultPrim(ws.GetPrimAtPath("/Wheel_Front_Left"))
    ws.GetRootLayer().Save()
    # the body
    bpath = out / f"{ASSET_ID}.usda"
    st, root = new_stage(bpath, "/Vehicle")
    Usd.ModelAPI(root.GetPrim()).SetKind("component")
    st.GetRootLayer().customLayerData = {"source": "make_body.py, 2026-golf-cart src/simulation/golfcart_twin/body"}
    mats = define_materials(st, "/Vehicle")
    shift = (X_SHIFT, 0.0, 0.0)
    tris, allp = 0, []
    for name, (p, mn) in build().items():
        for i, seg in enumerate(name.split("/")[:-1]):
            UsdGeom.Xform.Define(st, "/Vehicle/" + "/".join(name.split("/")[:i + 1]))
        t, pts = write_mesh(st, f"/Vehicle/{name}", p, (mn, mats[mn]), shift)
        tris += t
        allp.append(pts)
    UsdGeom.Xform.Define(st, "/Vehicle/Wheels")
    wheels = []
    for name, (xb, left) in WHEELS.items():
        pos = [xb + X_SHIFT, (1 if left else -1) * WHEEL_TREAD / 2, WHEEL_RADIUS]
        x = UsdGeom.Xform.Define(st, f"/Vehicle/Wheels/{name}")
        x.AddTranslateOp().Set(Gf.Vec3d(*pos))
        x.GetPrim().GetReferences().AddReference("./wheels.usda", Sdf.Path(f"/{name}"))
        allp.append(np.array(pos) + np.array([[s1 * WHEEL_RADIUS, s2 * WHEEL_WIDTH / 2, s3 * WHEEL_RADIUS]
                                              for s1 in (-1, 1) for s2 in (-1, 1) for s3 in (-1, 1)]))
        wheels.append({"name": name, "path": f"/Vehicle/Wheels/{name}", "pos": [round(v, 4) for v in pos],
                       "radius": WHEEL_RADIUS, "width": WHEEL_WIDTH,
                       "max_steer_deg": MAX_STEER_DEG if xb > 0 else 0.0,
                       "usd": f"{ASSET_ID}/wheels.usda", "usd_prim": f"/{name}"})
    st.GetRootLayer().Save()
    allp = np.concatenate(allp)
    lo, hi = allp.min(0), allp.max(0)
    half_w = max(WHEEL_TREAD / 2 + WHEEL_WIDTH / 2, BOX_HALF_W)
    entry = {
        "id": ASSET_ID,
        "base_type": "car",
        "wheels_n": 4,
        "usd": f"{ASSET_ID}/{ASSET_ID}.usda",
        "prim": "/Vehicle",
        "render_min": [round(v, 4) for v in lo],
        "render_max": [round(v, 4) for v in hi],
        "render_size": [round(v, 4) for v in hi - lo],
        # the footprint vehicle_info declares (hood to cargo box, the body's width, the height)
        "carla_bbox": {"center": [0.0, 0.0, round(VEHICLE_HEIGHT / 2, 4)],
                       "extent": [round((X_FRONT - X_REAR) / 2, 4), round(half_w, 4), round(VEHICLE_HEIGHT / 2, 4)]},
        "wheels": wheels,
        "rear_axle_x": round(REAR_AXLE_X, 4),
        "wheel_base": WHEEL_BASE,
        "track": WHEEL_TREAD,
    }
    (out / "entry.json").write_text(json.dumps(entry, indent=1) + "\n")
    print(f"{bpath}: {tris} triangles; wheels.usda: {tris_w} triangles (4 wheels)")
    print(f"render box {np.round(lo, 3).tolist()} .. {np.round(hi, 3).tolist()}, rear_axle_x {REAR_AXLE_X:.4f}")


if __name__ == "__main__":
    main()
