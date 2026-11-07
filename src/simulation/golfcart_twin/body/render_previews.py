#!/usr/bin/env python3
"""Offline previews of the body make_body.py wrote, optionally beside the photos.

    python3 render_previews.py OUT_DIR PREVIEW_DIR [PHOTO_DIR] [--headlights on]

Renders the composed /Vehicle (wheels included) with a small numpy z-buffer, flat-shaded
from each material's diffuse colour: front, left, right, rear (orthographic) and two 3/4 views
(perspective). With PHOTO_DIR (the cart's photos 01-10.jpg, kept out of git: they show
bystanders' licence plates), each view is saved beside the matching photo.
Needs usd-core, numpy, matplotlib (and Pillow, which matplotlib brings, to read the photos).
"""
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
from pxr import Usd, UsdGeom, UsdShade  # noqa: E402

ASSET_ID = "vehicle.newslab.golfcart"
# view: (elevation, azimuth, orthographic, photo)
VIEWS = {
    "front": (2, 0, True, "08.jpg"),
    "left": (2, 90, True, "05.jpg"),
    "right": (2, -90, True, "06.jpg"),
    "rear": (2, 180, True, None),
    "front_left_3q": (14, 38, False, "07.jpg"),
    "front_left_3q_far": (10, 55, False, "09.jpg"),
}
LIGHT = np.array([0.4, 0.3, 0.85])
LIGHT /= np.linalg.norm(LIGHT)
FILL = np.array([0.5, 0.7, 0.1])
FILL /= np.linalg.norm(FILL)


def triangles(path, headlights="off"):
    stage = Usd.Stage.Open(str(path))
    vs = stage.GetPrimAtPath("/Vehicle").GetVariantSets()
    if vs.HasVariantSet("headlights"):
        vs.GetVariantSet("headlights").SetVariantSelection(headlights)
    cache = UsdGeom.XformCache()
    tris, cols, alphas = [], [], []
    for prim in stage.Traverse():
        if not prim.IsA(UsdGeom.Mesh):
            continue
        mesh = UsdGeom.Mesh(prim)
        M = np.array(cache.GetLocalToWorldTransform(prim))
        pts = np.array(mesh.GetPointsAttr().Get(), float)
        pts = pts @ M[:3, :3] + M[3, :3]
        counts, idx = mesh.GetFaceVertexCountsAttr().Get(), mesh.GetFaceVertexIndicesAttr().Get()
        mat, _ = UsdShade.MaterialBindingAPI(prim).ComputeBoundMaterial()
        col, alpha = (0.5, 0.5, 0.5), 1.0
        if mat:
            sh = UsdShade.Shader(mat.GetPrim().GetChild("PreviewSurface"))
            col = tuple(sh.GetInput("diffuseColor").Get())
            op = sh.GetInput("opacity")
            alpha = op.Get() if op else 1.0
            em = sh.GetInput("emissiveColor")
            if em and em.Get() is not None and max(em.Get()) > 0:      # a lit lamp: draw it glowing
                col = tuple(min(1.0, c) for c in em.Get())
        o = 0
        for c in counts:
            f = idx[o:o + c]
            o += c
            for k in range(1, c - 1):
                tris.append(pts[[f[0], f[k], f[k + 1]]])
                cols.append(col)
                alphas.append(alpha)
    return np.array(tris), np.array(cols), np.array(alphas)


def camera(view, lo, hi):
    """World -> camera axes (right, up, forward) for a view, and the eye for a perspective one."""
    elev, azim, ortho, _ = view
    e, a = np.radians(elev), np.radians(azim)
    d = -np.array([np.cos(e) * np.cos(a), np.cos(e) * np.sin(a), np.sin(e)])   # looking along d
    right = np.cross(d, [0, 0, 1])
    right /= np.linalg.norm(right)
    up = np.cross(right, d)
    c = (lo + hi) / 2
    eye = c - d * 6.0
    return np.stack([right, up, d]), c, eye, ortho


def project(P, cam):
    axes, c, eye, ortho = cam
    if ortho:
        q = (P - c) @ axes.T
        return q[..., 0], q[..., 1], q[..., 2]
    q = (P - eye) @ axes.T
    z = np.maximum(q[..., 2], 1e-3)
    return q[..., 0] / z * 6.0, q[..., 1] / z * 6.0, z


def render(tris, cols, alphas, view, out_png, title, size=900, margin=0.06):
    """A z-buffered, flat-shaded raster of the triangles; translucent ones blended over the
    opaque image back to front."""
    n = np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0])
    ln = np.linalg.norm(n, axis=1)
    keep = ln > 1e-12
    tris, cols, alphas, n = tris[keep], cols[keep], alphas[keep], n[keep] / ln[keep, None]
    shade = 0.55 + 0.30 * np.abs(n @ LIGHT) + 0.15 * np.abs(n @ FILL)
    rgb = np.clip(cols ** (1 / 2.2) * shade[:, None], 0, 1)
    lo, hi = tris.reshape(-1, 3).min(0), tris.reshape(-1, 3).max(0)
    cam = camera(view, lo, hi)
    u, v, z = project(tris, cam)
    umin, umax, vmin, vmax = u.min(), u.max(), v.min(), v.max()
    scale = (1 - 2 * margin) * size / max(umax - umin, vmax - vmin)
    px = (u - (umin + umax) / 2) * scale + size / 2
    py = size / 2 - (v - (vmin + vmax) / 2) * scale
    img = np.ones((size, size, 3))
    zbuf = np.full((size, size), np.inf)

    def raster(i):
        x, y, d = px[i], py[i], z[i]
        x0, x1 = max(int(np.floor(x.min())), 0), min(int(np.ceil(x.max())), size - 1)
        y0, y1 = max(int(np.floor(y.min())), 0), min(int(np.ceil(y.max())), size - 1)
        if x0 > x1 or y0 > y1:
            return None
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        den = (y[1] - y[2]) * (x[0] - x[2]) + (x[2] - x[1]) * (y[0] - y[2])
        if abs(den) < 1e-9:
            return None
        w0 = ((y[1] - y[2]) * (gx - x[2]) + (x[2] - x[1]) * (gy - y[2])) / den
        w1 = ((y[2] - y[0]) * (gx - x[2]) + (x[0] - x[2]) * (gy - y[2])) / den
        w2 = 1 - w0 - w1
        m = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
        if not m.any():
            return None
        depth = w0 * d[0] + w1 * d[1] + w2 * d[2]
        return (slice(y0, y1 + 1), slice(x0, x1 + 1)), m, depth

    opaque = np.where(alphas >= 0.999)[0]
    for i in opaque:
        r = raster(i)
        if r is None:
            continue
        sl, m, depth = r
        zb = zbuf[sl]
        w = m & (depth < zb)
        zb[w] = depth[w]
        img[sl][w] = rgb[i]
    clear = np.where(alphas < 0.999)[0]
    for i in clear[np.argsort(-z[clear].mean(1))]:
        r = raster(i)
        if r is None:
            continue
        sl, m, depth = r
        w = m & (depth < zbuf[sl])
        img[sl][w] = img[sl][w] * (1 - alphas[i]) + rgb[i] * alphas[i]
    fig = plt.figure(figsize=(6, 6), dpi=size / 6)
    ax = fig.add_axes((0, 0, 1, 1))
    ax.imshow(img)
    ax.set_axis_off()
    ax.text(10, 30, title, fontsize=9)
    fig.savefig(out_png)
    plt.close(fig)


def main():
    argv = sys.argv[1:]
    headlights = "off"
    if "--headlights" in argv:
        i = argv.index("--headlights")
        headlights = argv[i + 1]
        del argv[i:i + 2]
    sys.argv = [sys.argv[0]] + argv
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    usd = Path(sys.argv[1]) / ASSET_ID / f"{ASSET_ID}.usda"
    dest = Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    photos = Path(sys.argv[3]) if len(sys.argv) == 4 else None
    tris, cols, alphas = triangles(usd, headlights)
    print(f"{len(tris)} triangles")
    for name, view in VIEWS.items():
        png = dest / f"render_{name}.png"
        render(tris, cols, alphas, view, png, f"model: {name}")
        if photos and view[3] and (photos / view[3]).exists():
            img = plt.imread(photos / view[3])
            ren = plt.imread(png)
            fig, axs = plt.subplots(1, 2, figsize=(12, 6), dpi=110)
            axs[0].imshow(img)
            axs[0].set_title(f"photo {view[3]}", fontsize=10)
            axs[1].imshow(ren)
            for a in axs:
                a.set_axis_off()
            fig.tight_layout()
            fig.savefig(dest / f"{name}.png")
            plt.close(fig)
        else:
            (dest / f"{name}.png").write_bytes(png.read_bytes())
        print(dest / f"{name}.png")


if __name__ == "__main__":
    main()
