#!/usr/bin/env python3
# Copyright 2026 Golf Cart Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Why a denser but narrower LiDAR localizes worse, measured rather than argued.

    python3 observability_analysis.py --map <pcd> \\
        --bag full=data/tiers/baked_odo/full \\
        --bag vlp32=data/tiers/baked_odo/vlp32 \\
        --bag robinw=data/tiers/baked_odo/robinw

The campaign measured a 1.4x accuracy penalty for a 120 x 70 degree wedge that
survived a change of matcher, a change of estimator structure and every parameter
swept. This asks what, structurally, that penalty is.

Three quantities, all computed from the same frames:

1. **Normal scatter**, `N = sum over points of n n^T`. For any registration that
   matches points to local surface structure, translation is constrained along
   the directions the surface normals span. `N`'s eigenvalues say how evenly
   those directions are covered, and its smallest eigenvector names the
   translation the scan cannot see. This is geometry alone -- no matcher
   involved.

2. **The matcher's own information matrix** `H`, taken from an actual
   registration against the real map. This is what the estimator experiences,
   including the effect of correspondence and weighting.

3. **How both respond to point count.** The same frame is scored at full density
   and subsampled. If accuracy were sampling-limited, halving the points would
   change the *shape* of `N` and `H`, not merely their scale.

The third is the direct test of the intuition that density should compensate for
a narrow field of view. Sampling more of the same surfaces multiplies the
information without redistributing it, so it shrinks the nominal covariance
without touching the conditioning -- and if the error is set by conditioning or
by bias rather than by sampling noise, more points buy nothing. The campaign
already saw the consequence: a tenfold rise in the point budget moved the error
by 2 mm.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

try:
    from offline_matcher_eval import cloud_dtype, read_pcd
except ImportError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from offline_matcher_eval import cloud_dtype, read_pcd


def anisotropy(M: np.ndarray):
    ev = np.linalg.eigvalsh((M + M.T) * 0.5)
    ev = np.clip(ev, 1e-30, None)
    return ev, float(ev[-1] / ev[0])


def normal_scatter(xyz: np.ndarray, k: int = 20, sample: int = 6000, seed: int = 0):
    """Normal scatter matrix, lever arm, normals and their weights.

    Uses small_gicp's own normal estimation rather than scipy's KdTree: the
    scipy build here is compiled against an older numpy ABI and importing its
    spatial module aborts.
    """
    import small_gicp

    rng = np.random.default_rng(seed)
    idx = rng.choice(xyz.shape[0], size=min(sample, xyz.shape[0]), replace=False)
    pts = np.ascontiguousarray(xyz[idx])
    cloud = small_gicp.PointCloud(pts)
    tree = small_gicp.KdTree(cloud, num_threads=8)
    small_gicp.estimate_normals(cloud, tree, num_neighbors=k, num_threads=8)
    normals = np.asarray(cloud.normals())[:, :3]

    # Points with too few neighbours get a zero normal; they carry no direction
    # and must not dilute the scatter matrix.
    norm = np.linalg.norm(normals, axis=1)
    ok = norm > 1e-6
    normals = normals[ok] / norm[ok, None]
    pts = pts[ok]

    N = normals.T @ normals
    lever = float(np.median(np.linalg.norm(pts, axis=1)))
    return N, lever, normals, pts


def yaw_information(normals: np.ndarray, idx_pts: np.ndarray) -> float:
    """Scalar information about yaw: sum of (r x n) . z, squared.

    Rotation is constrained by the component of each surface normal
    perpendicular to the lever arm, so this is the quantity a narrow wedge
    reduces by removing both distant points and angular spread.
    """
    cross_z = idx_pts[:, 0] * normals[:, 1] - idx_pts[:, 1] * normals[:, 0]
    return float(np.mean(cross_z ** 2))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--bag", action="append", required=True,
                    metavar="LABEL=PATH", help="repeatable")
    ap.add_argument("--topic", default="/sensing/lidar/os0/pointcloud_raw")
    ap.add_argument("--frames", type=int, default=25, help="frames to average over")
    ap.add_argument("--stride", type=int, default=40)
    ap.add_argument("--voxel-resolution", type=float, default=1.0)
    ap.add_argument("--downsample", type=float, default=0.5)
    args = ap.parse_args()

    import small_gicp
    from rosbags.highlevel import AnyReader

    map_pts = read_pcd(args.map)
    target = small_gicp.GaussianVoxelMap(args.voxel_resolution)
    target.insert(small_gicp.PointCloud(map_pts))

    rows = []
    for spec in args.bag:
        label, _, path = spec.partition("=")
        stats = {"n": [], "trans_aniso": [], "trans_weak": [], "yaw_info": [],
                 "H_trans_aniso": [], "H_rot_aniso": [], "lever": [],
                 "half_shape_change": [], "H_trans_tr": [], "H_rot_tr": [],
                 "H_trans_min": [], "inliers": [], "inlier_frac": [], "err": []}
        with AnyReader([Path(path)]) as reader:
            conns = [c for c in reader.connections if c.topic == args.topic]
            taken = 0
            for i, (conn, _stamp, raw) in enumerate(reader.messages(connections=conns)):
                if i % args.stride or taken >= args.frames:
                    if taken >= args.frames:
                        break
                    continue
                msg = reader.deserialize(raw, conn.msgtype)
                pts = np.frombuffer(msg.data, dtype=cloud_dtype(msg))
                xyz = np.stack([pts["x"], pts["y"], pts["z"]], axis=1).astype(np.float64)
                xyz = xyz[np.isfinite(xyz).all(axis=1)]
                rng_ok = np.linalg.norm(xyz, axis=1) > 1.0
                xyz = xyz[rng_ok]
                if xyz.shape[0] < 2000:
                    continue

                N, lever, normals, npts = normal_scatter(xyz)
                ev, aniso = anisotropy(N)
                _, vec = np.linalg.eigh((N + N.T) * 0.5)
                weak = vec[:, 0]

                rngi = np.random.default_rng(1)
                sel = rngi.choice(xyz.shape[0], size=xyz.shape[0] // 2, replace=False)
                N_half, _, _, _ = normal_scatter(xyz[sel])
                # Compare SHAPE, not scale: normalise both by trace before
                # differencing, so this answers "did halving the points
                # redistribute the information" rather than "did it halve it".
                a = N / max(np.trace(N), 1e-12)
                b = N_half / max(np.trace(N_half), 1e-12)
                stats["half_shape_change"].append(
                    float(np.linalg.norm(a - b) / np.linalg.norm(a)))

                stats["yaw_info"].append(yaw_information(normals, npts))

                source, _ = small_gicp.preprocess_points(
                    xyz, args.downsample, num_threads=8)
                res = small_gicp.align(target, source, np.eye(4),
                                       max_correspondence_distance=2.0, num_threads=8)
                H = np.asarray(res.H, dtype=np.float64)
                _, ha_rot = anisotropy(H[:3, :3])
                _, ha_tr = anisotropy(H[3:, 3:])

                # Absolute information, not just its shape. Anisotropy is a
                # ratio and says nothing about how tightly the pose is pinned;
                # two scans can be equally well conditioned and one still carry
                # far less information than the other.
                ev_t = np.linalg.eigvalsh((H[3:, 3:] + H[3:, 3:].T) * 0.5)
                stats["H_trans_tr"].append(float(np.trace(H[3:, 3:])))
                stats["H_rot_tr"].append(float(np.trace(H[:3, :3])))
                stats["H_trans_min"].append(float(max(ev_t[0], 0.0)))
                stats["inliers"].append(float(res.num_inliers))
                stats["inlier_frac"].append(float(res.num_inliers) / max(source.size(), 1))
                stats["err"].append(float(res.error))
                stats["n"].append(xyz.shape[0])
                stats["trans_aniso"].append(aniso)
                stats["trans_weak"].append(weak)
                stats["H_trans_aniso"].append(ha_tr)
                stats["H_rot_aniso"].append(ha_rot)
                stats["lever"].append(lever)
                taken += 1
        rows.append((label, stats))

    def med(v):
        return float(np.median(v)) if len(v) else float("nan")

    print("\nGeometry of what each sensor sees (medians over sampled frames)")
    hdr = (f"{'sensor':<10}{'points':>9}{'lever m':>9}{'nrm-aniso':>11}"
           f"{'Htr aniso':>11}{'Hrot aniso':>12}{'tr(Htrans)':>12}"
           f"{'min eig':>11}{'inliers':>9}{'in frac':>9}")
    print(hdr)
    print("-" * len(hdr))
    for label, s in rows:
        print(f"{label:<10}{med(s['n']):>9.0f}{med(s['lever']):>9.1f}"
              f"{med(s['trans_aniso']):>11.2f}{med(s['H_trans_aniso']):>11.2f}"
              f"{med(s['H_rot_aniso']):>12.2f}{med(s['H_trans_tr']):>12.4g}"
              f"{med(s['H_trans_min']):>11.4g}{med(s['inliers']):>9.0f}"
              f"{med(s['inlier_frac']):>9.2f}")

    print("\n  normal-scatter = anisotropy of sum(n n^T): how unevenly the surface")
    print("  normals cover direction space. Large means some translation is seen")
    print("  by few surfaces. Matcher-independent -- it is the scene geometry the")
    print("  sensor happens to capture.")
    print("  H trans / H rot = anisotropy of the matcher's own information blocks.")
    print("  yaw info = mean of ((r x n).z)^2, per-point leverage for heading;")
    print("  a mean rather than a sum, so it compares geometry and not point count.")

    print("\nDoes halving the points change the information's SHAPE?")
    for label, s in rows:
        print(f"  {label:<10} relative change {med(s['half_shape_change']):.4f}")
    print("  Near zero means extra points re-sample the same surfaces rather than")
    print("  adding new directions -- so density scales the information without")
    print("  reconditioning it, and cannot compensate for a narrow field of view.")

    print("\nWhich translation is worst observed (median weak axis, base_link)")
    for label, s in rows:
        if not s["trans_weak"]:
            continue
        v = np.median(np.abs(np.array(s["trans_weak"])), axis=0)
        v = v / max(np.linalg.norm(v), 1e-12)
        axis = ["x fwd", "y left", "z up"][int(np.argmax(v))]
        print(f"  {label:<10} |x| {v[0]:.2f}  |y| {v[1]:.2f}  |z| {v[2]:.2f}"
              f"   -> {axis}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
