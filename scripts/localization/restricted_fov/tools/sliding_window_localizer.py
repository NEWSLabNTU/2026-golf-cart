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

"""Fixed-lag smoothing on a prior map, to test the last idea the campaign has.

    python3 sliding_window_localizer.py \\
        --bag data/tiers/baked_odo/robinw \\
        --map data/tiers/road01_map/pointcloud_map.pcd \\
        --out /tmp/swin_robinw.txt --window 10

Two matchers built on different principles lost the *same fraction* of accuracy
when the field of view narrowed — 1.54x for NDT, 1.49x for VGICP, each against
its own full-circle run. That is what a geometric limit looks like, and it says
the per-frame matcher is not where the penalty lives. Every remaining idea that
treats each scan independently is therefore expected to fail the same way.

This one does not treat scans independently. It is the mechanism the literature
points at for a narrow field of view: a direction the wedge cannot observe now is
usually observable a second later, and a window recovers what frame-by-frame
registration throws away.

Two things make it work, and both are already available:

- **The matcher's own information matrix**, `H` from `small_gicp`, weights each
  scan factor by *what that scan actually constrained*. A direction the wedge did
  not observe gets almost no weight, so the estimate along it comes from motion
  instead of from a badly-conditioned registration. This is the soft form of the
  degeneracy-aware update, obtained for free rather than thresholded.
- **Inertial motion** between frames, from the same measured twist and IMU yaw
  rate that feeds Autoware's `gyro_odometer`.

Estimated jointly over a window rather than sequentially, so a later scan can
correct an earlier pose that was under-constrained when it was first seen.

**Conventions.** `H` from small_gicp orders the tangent vector as
`[rotation, translation]` — verified empirically rather than assumed, from the
ratio between the two diagonal blocks, which sits near the square of the scene
radius as rotation information should. Residuals here use the same ordering.

**Approximations, stated because they bound what the result proves.** The right
Jacobian of the SE(3) logarithm is taken as identity, which is standard for the
small increments a fixed-lag window produces and is what makes the solve a
handful of dense 6x6 blocks. The oldest pose in the window is held fixed rather
than marginalised, so information older than the window is dropped instead of
being summarised into a prior. Both make this a fair test of *whether the idea
helps*, not a production estimator.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

try:
    from offline_matcher_eval import cloud_dtype, read_pcd
except ImportError:  # invoked from elsewhere
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from offline_matcher_eval import cloud_dtype, read_pcd


def skew(v):
    return np.array([[0.0, -v[2], v[1]], [v[2], 0.0, -v[0]], [-v[1], v[0], 0.0]])


def so3_log(R):
    c = (np.trace(R) - 1.0) / 2.0
    c = min(1.0, max(-1.0, c))
    theta = np.arccos(c)
    if theta < 1e-8:
        return np.array([R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]]) * 0.5
    return (theta / (2.0 * np.sin(theta))) * np.array(
        [R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]])


def so3_exp(w):
    theta = np.linalg.norm(w)
    if theta < 1e-8:
        return np.eye(3) + skew(w)
    k = w / theta
    K = skew(k)
    return np.eye(3) + np.sin(theta) * K + (1.0 - np.cos(theta)) * (K @ K)


def se3_log(T):
    """Tangent vector ordered [rotation, translation], matching small_gicp's H."""
    return np.concatenate([so3_log(T[:3, :3]), T[:3, 3]])


def se3_exp(xi):
    T = np.eye(4)
    T[:3, :3] = so3_exp(xi[:3])
    T[:3, 3] = xi[3:]
    return T


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bag", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--topic", default="/sensing/lidar/os0/pointcloud_raw")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--window", type=int, default=10, help="frames held jointly")
    ap.add_argument("--iterations", type=int, default=3, help="Gauss-Newton steps")
    ap.add_argument("--voxel-resolution", type=float, default=1.0)
    ap.add_argument("--downsample", type=float, default=0.5)
    ap.add_argument("--max-correspondence", type=float, default=2.0)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--odom-sigma-xy", type=float, default=0.05,
                    help="metres of drift expected between frames")
    ap.add_argument("--odom-sigma-z", type=float, default=0.02)
    ap.add_argument("--odom-sigma-rot", type=float, default=0.01, help="radians")
    ap.add_argument("--scan-scale", type=float, default=1.0,
                    help="scales the matcher information; below 1 trusts motion more")
    ap.add_argument("--twist-topic",
                    default="/sensing/vehicle_velocity_converter/twist_with_covariance")
    ap.add_argument("--imu-topic", default="/sensing/imu/imu_data")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    import small_gicp
    from rosbags.highlevel import AnyReader

    twist, gyro = [], []
    with AnyReader([args.bag]) as reader:
        for name, sink, get in (
                (args.twist_topic, twist, lambda m: m.twist.twist.linear.x),
                (args.imu_topic, gyro, lambda m: m.angular_velocity.z)):
            conns = [c for c in reader.connections if c.topic == name]
            for conn, stamp, raw in reader.messages(connections=conns):
                sink.append((stamp, get(reader.deserialize(raw, conn.msgtype))))
    twist_t = np.array([t for t, _ in twist], dtype=np.float64)
    twist_v = np.array([v for _, v in twist], dtype=np.float64)
    gyro_t = np.array([t for t, _ in gyro], dtype=np.float64)
    gyro_w = np.array([w for _, w in gyro], dtype=np.float64)
    print(f"prior: {twist_v.size} twist, {gyro_w.size} imu", flush=True)

    map_pts = read_pcd(args.map)
    target = small_gicp.GaussianVoxelMap(args.voxel_resolution)
    target.insert(small_gicp.PointCloud(map_pts))
    print(f"map: {map_pts.shape[0]} points", flush=True)

    # Odometry information, same [rotation, translation] ordering as the scan
    # factor so the two can be summed without a permutation.
    W_odom = np.diag(np.concatenate([
        np.full(3, 1.0 / args.odom_sigma_rot ** 2),
        np.array([1.0 / args.odom_sigma_xy ** 2, 1.0 / args.odom_sigma_xy ** 2,
                  1.0 / args.odom_sigma_z ** 2])]))

    poses: list[np.ndarray] = []     # committed output, one per frame
    stamps: list[int] = []
    win_T: list[np.ndarray] = []     # optimisation variables
    win_Z: list[np.ndarray] = []     # scan-to-map measurements
    win_H: list[np.ndarray] = []     # their information
    win_U: list[np.ndarray] = []     # relative motion into each frame
    times = []

    def motion(t_prev: int, t_now: int) -> np.ndarray:
        dt = (t_now - t_prev) / 1e9
        v = float(np.interp(t_now, twist_t, twist_v)) if twist_t.size else 0.0
        w = float(np.interp(t_now, gyro_t, gyro_w)) if gyro_t.size else 0.0
        U = np.eye(4)
        U[:3, :3] = so3_exp(np.array([0.0, 0.0, w * dt]))
        U[0, 3] = v * dt
        return U

    with AnyReader([args.bag]) as reader:
        conns = [c for c in reader.connections if c.topic == args.topic]
        if not conns:
            print(f"{args.topic} not in {args.bag}", file=sys.stderr)
            return 1
        for i, (conn, stamp, raw) in enumerate(reader.messages(connections=conns)):
            if args.limit and i >= args.limit:
                break
            msg = reader.deserialize(raw, conn.msgtype)
            pts = np.frombuffer(msg.data, dtype=cloud_dtype(msg))
            xyz = np.stack([pts["x"], pts["y"], pts["z"]], axis=1).astype(np.float64)
            xyz = xyz[np.isfinite(xyz).all(axis=1)]
            if xyz.shape[0] < 100:
                continue

            U = motion(stamps[-1], stamp) if stamps else np.eye(4)
            init = (win_T[-1] @ U) if win_T else np.eye(4)

            t0 = time.perf_counter()
            source, _ = small_gicp.preprocess_points(
                xyz, args.downsample, num_threads=args.threads)
            result = small_gicp.align(
                target, source, init,
                max_correspondence_distance=args.max_correspondence,
                num_threads=args.threads)

            win_T.append(np.asarray(result.T_target_source).copy())
            win_Z.append(np.asarray(result.T_target_source).copy())
            H = np.asarray(result.H, dtype=np.float64)
            win_H.append(args.scan_scale * (H + H.T) * 0.5)
            win_U.append(U)
            if len(win_T) > args.window:
                for buf in (win_T, win_Z, win_H, win_U):
                    buf.pop(0)

            # Gauss-Newton over the window. Index 0 is held fixed, so it acts as
            # the anchor that older information would otherwise have to be
            # marginalised into.
            n = len(win_T)
            if n > 1:
                for _ in range(args.iterations):
                    dim = 6 * (n - 1)
                    A = np.zeros((dim, dim))
                    b = np.zeros(dim)
                    for k in range(1, n):
                        s = 6 * (k - 1)
                        # scan-to-map factor on pose k
                        r = se3_log(np.linalg.inv(win_Z[k]) @ win_T[k])
                        A[s:s + 6, s:s + 6] += win_H[k]
                        b[s:s + 6] -= win_H[k] @ r
                        # motion factor between k-1 and k
                        rel = np.linalg.inv(win_T[k - 1]) @ win_T[k]
                        rm = se3_log(np.linalg.inv(win_U[k]) @ rel)
                        A[s:s + 6, s:s + 6] += W_odom
                        b[s:s + 6] -= W_odom @ rm
                        if k > 1:
                            p = 6 * (k - 2)
                            A[p:p + 6, p:p + 6] += W_odom
                            A[p:p + 6, s:s + 6] -= W_odom
                            A[s:s + 6, p:p + 6] -= W_odom
                            b[p:p + 6] += W_odom @ rm
                    try:
                        dx = np.linalg.solve(A + np.eye(dim) * 1e-6, b)
                    except np.linalg.LinAlgError:
                        break
                    for k in range(1, n):
                        win_T[k] = win_T[k] @ se3_exp(dx[6 * (k - 1):6 * k])
                    if np.linalg.norm(dx) < 1e-6:
                        break
            times.append((time.perf_counter() - t0) * 1e3)

            poses.append(win_T[-1].copy())
            stamps.append(stamp)
            if len(poses) % 200 == 0:
                print(f"  {len(poses)} frames, {np.median(times):.1f} ms median",
                      flush=True)

    if not poses:
        print("no poses produced", file=sys.stderr)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as fh:
        for T in poses:
            fh.write(" ".join(f"{v:.9f}" for v in T[:3, :4].reshape(-1)) + "\n")
    with args.out.with_suffix(".stamps").open("w") as fh:
        for s in stamps:
            fh.write(f"{s}\n")

    t = np.asarray(times)
    print(f"wrote {args.out}: {len(poses)} poses, window {args.window}")
    print(f"  per-frame: mean {t.mean():.1f} ms, p50 {np.percentile(t, 50):.1f}, "
          f"p95 {np.percentile(t, 95):.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
