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

"""Localize a bag against a prior map with a candidate matcher, offline.

    python3 offline_matcher_eval.py \\
        --bag data/tiers/baked_odo/robinw \\
        --map data/tiers/road01_map/pointcloud_map.pcd \\
        --method VGICP --out /tmp/vgicp_robinw.txt

Exists to answer "is NDT the right matcher for a narrow dense field of view"
without integrating a candidate into Autoware first. The campaign's NDT numbers
come from a full Autoware replay; this runs a different matcher over the same
bag and the same map and emits poses in the same KITTI format, so
`compare_to_reference.py` scores both against the same trajectory.

**What this is not.** It is not the Autoware pipeline. There is no EKF, no
gyro_odometer, no crop box, no ring outlier filter — the scan goes from the bag
to the matcher. So an absolute number here is not comparable to an absolute
number from a replay; what is comparable is **one matcher against another under
this same harness**, and against NDT the honest reading is the ratio rather than
the difference.

**The prior is deliberately weaker than the replay's.** Autoware's NDT is handed
a pose from an EKF fed by a synthesised twist that was derived from the reference
trajectory. This uses constant velocity from the matcher's own previous two
poses, which is the weakest defensible prior and leaks nothing. A candidate that
wins here wins with a handicap; one that loses may be losing to the prior rather
than to the matcher, so `--prior static` is provided to see how much of the
result is the prior at all.
"""

from __future__ import annotations

import argparse
import math
import sys
import time
from pathlib import Path

import numpy as np


def read_pcd(path: Path) -> np.ndarray:
    """Read the binary PCD written by build_pcd_map.py. Returns Nx3 float64."""
    with path.open("rb") as fh:
        fields, sizes, types, counts, npoints = None, None, None, None, None
        while True:
            line = fh.readline().decode("ascii", "replace").strip()
            if not line:
                raise ValueError(f"{path}: header ended without DATA")
            key, _, rest = line.partition(" ")
            key = key.upper()
            if key == "FIELDS":
                fields = rest.split()
            elif key == "SIZE":
                sizes = [int(v) for v in rest.split()]
            elif key == "TYPE":
                types = rest.split()
            elif key == "COUNT":
                counts = [int(v) for v in rest.split()]
            elif key == "POINTS":
                npoints = int(rest)
            elif key == "DATA":
                if rest.strip() != "binary":
                    raise ValueError(f"{path}: only binary PCD is supported, got {rest!r}")
                break
        if not (fields and sizes and types and npoints is not None):
            raise ValueError(f"{path}: incomplete header")
        counts = counts or [1] * len(fields)

        np_of = {("F", 4): np.float32, ("F", 8): np.float64,
                 ("U", 1): np.uint8, ("U", 2): np.uint16, ("U", 4): np.uint32,
                 ("I", 1): np.int8, ("I", 2): np.int16, ("I", 4): np.int32}
        names, formats = [], []
        for name, size, typ, count in zip(fields, sizes, types, counts):
            names.append(name)
            base = np_of[(typ.upper(), size)]
            formats.append(base if count == 1 else (base, count))
        dtype = np.dtype({"names": names, "formats": formats})
        pts = np.frombuffer(fh.read(npoints * dtype.itemsize), dtype=dtype, count=npoints)
    return np.stack([pts["x"], pts["y"], pts["z"]], axis=1).astype(np.float64)


def cloud_dtype(msg) -> np.dtype:
    numpy_of = {1: np.int8, 2: np.uint8, 3: np.int16, 4: np.uint16,
                5: np.int32, 6: np.uint32, 7: np.float32, 8: np.float64}
    names, formats, offsets = [], [], []
    for f in msg.fields:
        names.append(f.name)
        formats.append(numpy_of[f.datatype])
        offsets.append(f.offset)
    return np.dtype({"names": names, "formats": formats,
                     "offsets": offsets, "itemsize": msg.point_step})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bag", type=Path, required=True)
    ap.add_argument("--map", type=Path, required=True)
    ap.add_argument("--topic", default="/sensing/lidar/os0/pointcloud_raw")
    ap.add_argument("--out", type=Path, required=True, help="KITTI-format poses")
    ap.add_argument("--method", default="VGICP",
                    help="VGICP uses a Gaussian voxel map target; GICP, ICP and "
                         "PLANE_ICP use a KdTree over the raw map")
    ap.add_argument("--voxel-resolution", type=float, default=1.0,
                    help="target voxel size for VGICP, metres")
    ap.add_argument("--downsample", type=float, default=0.5,
                    help="source voxel-grid leaf, metres; 0.5 matches the "
                         "localization chain's voxel_grid_filter")
    ap.add_argument("--max-correspondence", type=float, default=2.0)
    ap.add_argument("--max-iterations", type=int, default=30)
    ap.add_argument("--threads", type=int, default=8)
    ap.add_argument("--prior", choices=("constant-velocity", "static", "twist"),
                    default="constant-velocity")
    ap.add_argument("--twist-topic",
                    default="/sensing/vehicle_velocity_converter/twist_with_covariance")
    ap.add_argument("--imu-topic", default="/sensing/imu/imu_data")
    ap.add_argument("--accumulate", type=int, default=1,
                    help="register the union of the last N scans instead of one. "
                         "Single-sensor way to widen the observed arc: the wedge "
                         "sweeps across directions as the vehicle turns, so an "
                         "accumulated submap sees more of the surroundings than "
                         "any one scan. Expected to help only where the vehicle "
                         "actually rotates -- translation re-observes the same "
                         "surfaces at the same incidence.")
    ap.add_argument("--init-pose", type=float, nargs=7, default=None,
                    metavar=("X", "Y", "Z", "QX", "QY", "QZ", "QW"),
                    help="seed pose in the map frame. Required whenever the map "
                         "is not in the sensor's own start frame, which is every "
                         "real surveyed map.")
    ap.add_argument("--limit", type=int, default=0, help="stop after N clouds")
    args = ap.parse_args()

    import small_gicp
    from rosbags.highlevel import AnyReader

    # `twist` propagates the prior with the same measurements Autoware's
    # gyro_odometer feeds its EKF -- vehicle linear velocity and IMU angular
    # rate. It exists so a candidate matcher can be compared against the replay's
    # NDT on equal information, rather than being handicapped by a weaker prior
    # and losing for the wrong reason.
    twist, gyro = [], []
    if args.prior == "twist":
        with AnyReader([args.bag]) as reader:
            for name, sink, get in (
                    (args.twist_topic, twist,
                     lambda m: m.twist.twist.linear.x),
                    (args.imu_topic, gyro,
                     lambda m: m.angular_velocity.z)):
                conns = [c for c in reader.connections if c.topic == name]
                if not conns:
                    print(f"{name} not in {args.bag}", file=sys.stderr)
                    return 1
                for conn, stamp, raw in reader.messages(connections=conns):
                    sink.append((stamp, get(reader.deserialize(raw, conn.msgtype))))
        twist_t = np.array([t for t, _ in twist], dtype=np.float64)
        twist_v = np.array([v for _, v in twist], dtype=np.float64)
        gyro_t = np.array([t for t, _ in gyro], dtype=np.float64)
        gyro_w = np.array([w for _, w in gyro], dtype=np.float64)
        print(f"prior: {twist_v.size} twist, {gyro_w.size} imu samples", flush=True)

    map_pts = read_pcd(args.map)
    print(f"map: {map_pts.shape[0]} points from {args.map}", flush=True)

    if args.method.upper() == "VGICP":
        target = small_gicp.GaussianVoxelMap(args.voxel_resolution)
        target.insert(small_gicp.PointCloud(map_pts))
        target_tree = None
    else:
        target, target_tree = small_gicp.preprocess_points(
            map_pts, args.downsample, num_threads=args.threads)

    poses, stamps, times = [], [], []
    T = np.eye(4)
    if args.init_pose is not None:
        x, y, z, qx, qy, qz, qw = args.init_pose
        n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw) or 1.0
        qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
        T = np.array([
            [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw), x],
            [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw), y],
            [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy), z],
            [0.0, 0.0, 0.0, 1.0]])
    prev_T = T.copy()
    history: list[tuple[np.ndarray, np.ndarray]] = []   # (pose, points)

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

            # Constant velocity from the matcher's own history. Deliberately not
            # the synthesised twist the replay's EKF used: that twist came from
            # the reference trajectory, and reusing it here would score the
            # matcher on a prior it will not have.
            if args.prior == "twist" and stamps:
                # Integrate forward from the previous scan with the measured
                # speed and yaw rate, in the body frame, exactly as a dead
                # reckoning step would.
                dt = (stamp - stamps[-1]) / 1e9
                v = float(np.interp(stamp, twist_t, twist_v)) if twist_t.size else 0.0
                w = float(np.interp(stamp, gyro_t, gyro_w)) if gyro_t.size else 0.0
                dyaw = w * dt
                c, s_ = np.cos(dyaw), np.sin(dyaw)
                step = np.eye(4)
                step[:3, :3] = np.array([[c, -s_, 0.0], [s_, c, 0.0], [0.0, 0.0, 1.0]])
                step[0, 3] = v * dt
                init = T @ step
            elif args.prior == "constant-velocity" and len(poses) >= 2:
                init = T @ (np.linalg.inv(prev_T) @ T)
            else:
                init = T.copy()

            scan = xyz
            if args.accumulate > 1:
                history.append((init.copy(), xyz))
                if len(history) > args.accumulate:
                    history.pop(0)
                # Bring every retained scan into the current frame through the
                # poses they were seen at. Errors in those poses smear the
                # submap, which is the cost of the wider arc it buys.
                parts = []
                inv = np.linalg.inv(init)
                for T_k, pts_k in history:
                    rel = inv @ T_k
                    parts.append(pts_k @ rel[:3, :3].T + rel[:3, 3])
                scan = np.concatenate(parts, axis=0)

            source, _ = small_gicp.preprocess_points(
                scan, args.downsample, num_threads=args.threads)

            t0 = time.perf_counter()
            if args.method.upper() == "VGICP":
                result = small_gicp.align(
                    target, source, init,
                    max_correspondence_distance=args.max_correspondence,
                    num_threads=args.threads, max_iterations=args.max_iterations)
            else:
                result = small_gicp.align(
                    target, source, target_tree, init,
                    registration_type=args.method.upper(),
                    max_correspondence_distance=args.max_correspondence,
                    num_threads=args.threads, max_iterations=args.max_iterations)
            times.append((time.perf_counter() - t0) * 1e3)

            prev_T, T = T, np.asarray(result.T_target_source)
            poses.append(T.copy())
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
    stamp_path = args.out.with_suffix(".stamps")
    with stamp_path.open("w") as fh:
        for s in stamps:
            fh.write(f"{s}\n")

    t = np.asarray(times)
    print(f"wrote {args.out}: {len(poses)} poses")
    print(f"  {args.method} per-frame: mean {t.mean():.1f} ms, "
          f"p50 {np.percentile(t, 50):.1f}, p95 {np.percentile(t, 95):.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
