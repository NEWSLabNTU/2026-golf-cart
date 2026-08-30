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

"""Accumulate a rosbag's clouds along an odometry trajectory into a PCD map.

    kiss_icp_pipeline --topic /sensing/lidar/os0/pointcloud_raw <bag>
    python3 scripts/localization/build_pcd_map.py <bag> results/latest/*_poses.txt \\
        --topic /sensing/lidar/os0/pointcloud_raw --out map/pointcloud_map.pcd

For the restricted-FOV study: the TIERS sequences ship no prior map, and the
comparison needs one. The map is built from the **full** field of view and the
restricted runs then localize against it, which is the same arrangement a real
deployment has -- the map is surveyed once with whatever sensor is convenient,
and the vehicle localizes against it with the sensor it carries.

Poses are read in KITTI format: one line per frame, twelve numbers, a row-major
3x4 transform from sensor frame to the odometry frame.

Voxel downsampling keeps one point per occupied voxel, which is what makes 290
million points fit in memory and what NDT wants anyway -- it builds its own
distributions per voxel, and feeding it the raw density mostly costs time.

The result is odometry-frame, not georeferenced. Pair it with a
`map_projector_info.yaml` declaring a local projector; anything expecting MGRS or
UTM will be wrong.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np


def read_kitti_poses(path: Path) -> np.ndarray:
    """Return an (N, 4, 4) stack of transforms."""
    raw = np.loadtxt(path)
    if raw.ndim == 1:
        raw = raw[None, :]
    if raw.shape[1] != 12:
        raise ValueError(f"{path}: expected 12 columns (KITTI), got {raw.shape[1]}")
    out = np.tile(np.eye(4), (raw.shape[0], 1, 1))
    out[:, :3, :4] = raw.reshape(-1, 3, 4)
    return out


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


def write_pcd(path: Path, xyz: np.ndarray, intensity: np.ndarray) -> None:
    """Write a binary PCD with x, y, z, intensity as float32.

    Written by hand rather than through a point cloud library: this is the only
    thing here that would need one, the format's header is eight lines, and the
    binary body is the array as it already sits in memory.
    """
    n = xyz.shape[0]
    header = (
        "# .PCD v0.7 - Point Cloud Data file format\n"
        "VERSION 0.7\n"
        "FIELDS x y z intensity\n"
        "SIZE 4 4 4 4\n"
        "TYPE F F F F\n"
        "COUNT 1 1 1 1\n"
        f"WIDTH {n}\n"
        "HEIGHT 1\n"
        "VIEWPOINT 0 0 0 1 0 0 0\n"
        f"POINTS {n}\n"
        "DATA binary\n"
    )
    body = np.empty((n, 4), dtype=np.float32)
    body[:, :3] = xyz
    body[:, 3] = intensity
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as fh:
        fh.write(header.encode("ascii"))
        fh.write(body.tobytes())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bag", type=Path)
    ap.add_argument("poses", type=Path, help="KITTI-format poses, one line per cloud")
    ap.add_argument("--topic", required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--voxel", type=float, default=0.2, help="metres")
    ap.add_argument("--max-range", type=float, default=100.0,
                    help="drop returns beyond this; far points are sparse and noisy")
    ap.add_argument("--min-range", type=float, default=1.0,
                    help="drop returns nearer than this, which are the rig itself")
    args = ap.parse_args()

    from rosbags.highlevel import AnyReader

    poses = read_kitti_poses(args.poses)
    print(f"{poses.shape[0]} poses from {args.poses}")

    # Deduplication happens on quantised integer coordinates rather than on
    # floats, so a point seen from two frames a few millimetres apart collapses
    # to one entry instead of two near-identical ones.
    keys_acc: list[np.ndarray] = []
    vals_acc: list[np.ndarray] = []
    kept_keys = np.empty((0, 3), dtype=np.int64)
    kept_vals = np.empty((0, 4), dtype=np.float32)

    def compact():
        nonlocal keys_acc, vals_acc, kept_keys, kept_vals
        if not keys_acc:
            return
        keys = np.concatenate([kept_keys] + keys_acc)
        vals = np.concatenate([kept_vals] + vals_acc)
        _, idx = np.unique(keys, axis=0, return_index=True)
        kept_keys, kept_vals = keys[idx], vals[idx]
        keys_acc, vals_acc = [], []

    used = 0
    with AnyReader([args.bag]) as reader:
        conns = [c for c in reader.connections if c.topic == args.topic]
        if not conns:
            print(f"{args.topic} not in {args.bag}", file=sys.stderr)
            return 1
        for i, (conn, _stamp, raw) in enumerate(reader.messages(connections=conns)):
            if i >= poses.shape[0]:
                # More clouds than poses means odometry dropped frames. Stopping
                # is right: pairing cloud i with pose i after a gap would place
                # points at the wrong pose and quietly smear the map.
                print(f"stopping at cloud {i}: only {poses.shape[0]} poses")
                break
            msg = reader.deserialize(raw, conn.msgtype)
            pts = np.frombuffer(msg.data, dtype=cloud_dtype(msg))
            xyz = np.stack([pts["x"], pts["y"], pts["z"]], axis=1).astype(np.float64)

            good = np.isfinite(xyz).all(axis=1)
            rng = np.linalg.norm(xyz, axis=1)
            good &= (rng >= args.min_range) & (rng <= args.max_range)
            xyz = xyz[good]
            if not xyz.shape[0]:
                continue
            names = pts.dtype.names or ()
            inten = (pts["intensity"][good].astype(np.float32)
                     if "intensity" in names
                     else np.zeros(xyz.shape[0], dtype=np.float32))

            T = poses[i]
            world = xyz @ T[:3, :3].T + T[:3, 3]

            keys_acc.append(np.floor(world / args.voxel).astype(np.int64))
            v = np.empty((world.shape[0], 4), dtype=np.float32)
            v[:, :3] = world
            v[:, 3] = inten
            vals_acc.append(v)
            used += 1

            if used % 100 == 0:
                compact()
                print(f"  {used} clouds, {kept_keys.shape[0]} voxels", flush=True)

    compact()
    if not kept_keys.shape[0]:
        print("no points survived", file=sys.stderr)
        return 1

    write_pcd(args.out, kept_vals[:, :3], kept_vals[:, 3])
    lo = kept_vals[:, :3].min(axis=0)
    hi = kept_vals[:, :3].max(axis=0)
    print(f"wrote {args.out}: {kept_keys.shape[0]} points from {used} clouds")
    print(f"  extent x {lo[0]:.1f}..{hi[0]:.1f}  y {lo[1]:.1f}..{hi[1]:.1f}  "
          f"z {lo[2]:.1f}..{hi[2]:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
