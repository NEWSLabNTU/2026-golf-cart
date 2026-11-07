"""Cast each lidar's rays from its origin through the generated body; report hits by prim.

    python3 check_lidar_clearance.py OUT_DIR BODY_DIR

OUT_DIR is what make_body.py wrote, BODY_DIR this directory. The VLP-32C casts its 32
elevations (nebula's VLP32.yaml) at every 1 deg of azimuth, the Falcon its corner and centre
rays and a 1 deg grid over +-60 deg across, -14 to +11 deg up (the seyond frame's +z forward),
each to 0.5 m. A hit inside a lidar's near range blocks the ray in Isaac's RTX lidar: no point.
Needs usd-core, numpy, PyYAML and Autoware's nebula_decoders (for the VLP-32C's elevations).
"""
import math, sys
import numpy as np, yaml
from pxr import Usd, UsdGeom
sys.path.insert(0, sys.argv[2])
import make_body as mb
st = Usd.Stage.Open(sys.argv[1] + "/vehicle.newslab.golfcart/vehicle.newslab.golfcart.usda")
cache = UsdGeom.XformCache()
tris, names = [], []
for prim in st.Traverse():
    if not prim.IsA(UsdGeom.Mesh):
        continue
    M = np.array(cache.GetLocalToWorldTransform(prim))
    P = np.array(UsdGeom.Mesh(prim).GetPointsAttr().Get(), float) @ M[:3, :3] + M[3, :3]
    c, idx = UsdGeom.Mesh(prim).GetFaceVertexCountsAttr().Get(), UsdGeom.Mesh(prim).GetFaceVertexIndicesAttr().Get()
    o = 0
    for n in c:
        f = idx[o:o + n]; o += n
        for k in range(1, n - 1):
            tris.append(P[[f[0], f[k], f[k + 1]]]); names.append(str(prim.GetPath()))
T = np.array(tris); names = np.array(names)
shift = np.array([mb.X_SHIFT, 0, 0])


def cast(o, D, maxr):
    near = np.linalg.norm(T.mean(1) - o, axis=1) < maxr + 1.0
    t, nm = T[near], names[near]
    e1, e2 = t[:, 1] - t[:, 0], t[:, 2] - t[:, 0]
    hits = []
    for d in D:
        p = np.cross(d, e2); det = (e1 * p).sum(1)
        ok = np.abs(det) > 1e-12
        inv = np.where(ok, 1 / np.where(ok, det, 1), 0)
        s = o - t[:, 0]; u = (s * p).sum(1) * inv
        q = np.cross(s, e1); v = (q * d).sum(1) * inv; r = (q * e2).sum(1) * inv
        m = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (r > 1e-6) & (r <= maxr)
        if m.any():
            i = np.argmin(np.where(m, r, np.inf)); hits.append((nm[i], r[i]))
    return hits


def report(name, hits, nrays, near):
    by = {}
    for n, r in hits:
        by.setdefault(n, []).append(r)
    print(f"{name}: {nrays} rays, {len(hits)} hit body geometry within 0.5 m, {sum(r < near for _, r in hits)} within the near range {near} m")
    for n, rs in sorted(by.items(), key=lambda kv: -len(kv[1])):
        print(f"   {n}: {len(rs)} rays, nearest {min(rs):.3f} m")


vo, vR = mb.sensor_pose("vlp32c")
els = sorted(l["vert_correction"] for l in yaml.safe_load(open("/opt/autoware/1.5.0/share/nebula_decoders/calibration/velodyne/VLP32.yaml"))["lasers"])
D = [vR @ [math.cos(e) * math.cos(math.radians(a)), math.cos(e) * math.sin(math.radians(a)), math.sin(e)] for e in els for a in range(360)]
report("VLP-32C", cast(vo + shift, np.array(D), 0.5), len(D), 0.3)
fo, fR = mb.sensor_pose("falcon")
fwd = fR[:, 2]
across, upf = sorted((fR[:, 0], fR[:, 1]), key=lambda v: abs(v[2]))
upf = upf if upf[2] > 0 else -upf
across = np.cross(upf, fwd)
def fdir(az, el):
    az, el = math.radians(az), math.radians(el)
    return math.cos(el) * (math.cos(az) * fwd + math.sin(az) * across) + math.sin(el) * upf
corners = [fdir(a, e) for a in (-60, 0, 60) for e in (-14, 0, 11)]
report("Falcon corners and centre", cast(fo + shift, np.array(corners), 0.5), len(corners), 0.4)
grid = [fdir(a, e) for a in range(-60, 61) for e in range(-14, 12)]
report("Falcon, every 1 deg", cast(fo + shift, np.array(grid), 0.5), len(grid), 0.4)
print("falcon fwd in base_link", np.round(fwd, 3), "across", np.round(across, 3), "up", np.round(upf, 3))
