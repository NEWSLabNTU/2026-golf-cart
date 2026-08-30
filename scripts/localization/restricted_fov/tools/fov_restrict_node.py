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

"""Restrict a point cloud to the wedge a narrower LiDAR would have seen.

    python3 scripts/localization/fov_restrict_node.py \\
        --min-bearing -60 --max-bearing 60 --max-range 70

Why this exists rather than a decoder crop: Nebula can crop azimuth at decode,
which is cheaper and more faithful, but on the Autoware sample bag it can only
produce a cloud for windows containing azimuth 0 or 300, and those necessarily
include bearing +85 or +145. A forward-facing wedge is exactly the set of
bearings that excludes both, so it is unreachable that way at any width. See
docs/research/localization/restricted-fov-ndt.md.

Geometry. The filter works on the concatenated cloud in `base_link`, but measures
bearing and range about the **sensor's** position, not the vehicle origin. Those
differ by 0.9 m of longitudinal offset here, which at a 6 m return is about 8
degrees of bearing -- enough to matter for a wedge boundary. Pass the mount with
--origin.

Consequence worth knowing: because it acts on the concatenated cloud, it also
clips the rig's other LiDARs to the same wedge. For emulating a vehicle carrying
one narrow forward sensor that is correct, and it removes the optimism a
decoder-side crop leaves behind, where the side sensors keep returning a full
circle the emulated rig would never have seen.

This is a study tool. It is not in the vehicle's launch path and is not built as
a package; it runs as a plain rclpy process beside the stack.
"""

from __future__ import annotations

import argparse
import math
import sys

import numpy as np


def dtype_of(msg) -> np.dtype:
    """Build a numpy dtype matching the cloud's own layout, padding included.

    Reconstructing points field-by-field would silently drop anything the fields
    do not name, and the layouts in this pipeline carry padding between fields.
    Pinning itemsize to point_step keeps every byte, so the republished cloud is
    the input minus rows, not a re-encoding of it.
    """
    numpy_of = {1: np.int8, 2: np.uint8, 3: np.int16, 4: np.uint16,
                5: np.int32, 6: np.uint32, 7: np.float32, 8: np.float64}
    names, formats, offsets = [], [], []
    for f in msg.fields:
        names.append(f.name)
        formats.append(numpy_of[f.datatype] if f.count == 1
                       else (numpy_of[f.datatype], f.count))
        offsets.append(f.offset)
    return np.dtype({"names": names, "formats": formats,
                     "offsets": offsets, "itemsize": msg.point_step})


# Autoware's PointXYZIRC, which its crop box and downsample filters require.
# Anything else is refused outright with "The pointcloud layout is not compatible
# with PointXYZIRCAEDT or PointXYZIRC. Aborting", which is logged by the filter
# and not by the node that produced the cloud, so it reads as a crop box fault.
#
# An Ouster driver publishes x, y, z, intensity, t, reflectivity, ring, ambient,
# range in 48 bytes and hits exactly that. Re-encoding here is the cheapest fix:
# this node already rewrites every cloud it forwards.
XYZIRC_DTYPE = np.dtype({
    "names": ["x", "y", "z", "intensity", "return_type", "channel"],
    "formats": [np.float32, np.float32, np.float32, np.uint8, np.uint8, np.uint16],
    "offsets": [0, 4, 8, 12, 13, 14],
    "itemsize": 16,
})


def xyzirc_fields(PointField):
    return [
        PointField(name="x", offset=0, datatype=PointField.FLOAT32, count=1),
        PointField(name="y", offset=4, datatype=PointField.FLOAT32, count=1),
        PointField(name="z", offset=8, datatype=PointField.FLOAT32, count=1),
        PointField(name="intensity", offset=12, datatype=PointField.UINT8, count=1),
        PointField(name="return_type", offset=13, datatype=PointField.UINT8, count=1),
        PointField(name="channel", offset=14, datatype=PointField.UINT16, count=1),
    ]


def to_xyzirc(pts: np.ndarray) -> np.ndarray:
    """Re-encode an arbitrary cloud as PointXYZIRC, keeping what maps across."""
    out = np.zeros(pts.shape[0], dtype=XYZIRC_DTYPE)
    for axis in ("x", "y", "z"):
        out[axis] = pts[axis]
    names = pts.dtype.names or ()
    if "intensity" in names:
        # Ouster reports intensity well outside a byte. Clipping rather than
        # wrapping: a saturated bright return is still bright, whereas a wrapped
        # one becomes an arbitrary dark point in the middle of a retroreflector.
        out["intensity"] = np.clip(pts["intensity"], 0, 255).astype(np.uint8)
    if "ring" in names:
        out["channel"] = pts["ring"].astype(np.uint16)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--min-bearing", type=float, required=True,
                    help="degrees in base_link; 0 is ahead, positive is left")
    ap.add_argument("--max-bearing", type=float, required=True)
    ap.add_argument("--max-range", type=float, default=float("inf"),
                    help="horizontal range from the sensor mount, metres")
    ap.add_argument("--min-elevation", type=float, default=-90.0,
                    help="degrees below horizontal at the sensor; -35 with +35 gives a 70 deg band")
    ap.add_argument("--max-elevation", type=float, default=90.0)
    ap.add_argument("--keep-fraction", type=float, default=1.0,
                    help="thin the survivors to this fraction, to emulate a sparser sensor")
    ap.add_argument("--seed", type=int, default=0,
                    help="thinning is seeded, so a run is reproducible")
    ap.add_argument("--origin", type=float, nargs=3, default=(0.9, 0.0, 2.0),
                    metavar=("X", "Y", "Z"),
                    help="sensor mount in base_link; default is this rig's top LiDAR")
    ap.add_argument("--emit-xyzirc", action="store_true",
                    help="re-encode the output as Autoware's PointXYZIRC layout")
    ap.add_argument("--input", default="/sensing/lidar/concatenated/pointcloud")
    ap.add_argument("--output", default="/sensing/lidar/fov_restricted/pointcloud")
    args = ap.parse_args()

    import rclpy
    from rclpy.node import Node
    from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
    from sensor_msgs.msg import PointCloud2, PointField

    lo = math.radians(args.min_bearing)
    hi = math.radians(args.max_bearing)
    # Not `(hi - lo) % 2pi`: that maps a full circle to 0 and the filter silently
    # discards everything. Wrap only a non-positive difference, so -180..180
    # stays 2pi while 300..60 still becomes 120 degrees.
    width = hi - lo
    while width <= 0.0:
        width += 2.0 * math.pi
    ox, oy, oz = args.origin
    min_el = math.radians(args.min_elevation)
    max_el = math.radians(args.max_elevation)
    # Elevation limits are only meaningful when the SOURCE is wider than the
    # sensor being emulated. Check the source before trusting a band set here:
    # the Autoware sample bag's VLS128 spans 40 degrees, so asking it for a
    # Robin-W's 70 silently does nothing at all.
    thin = args.keep_fraction < 1.0
    rng = np.random.default_rng(args.seed)

    class Restrict(Node):
        def __init__(self):
            super().__init__("fov_restrict")
            # The concatenator publishes best-effort; a reliable subscription
            # would simply never match it and the node would sit silent while
            # everything downstream waited on a topic that never arrives.
            qos = QoSProfile(depth=5, history=HistoryPolicy.KEEP_LAST,
                             reliability=ReliabilityPolicy.BEST_EFFORT)
            self.pub = self.create_publisher(PointCloud2, args.output, qos)
            self.create_subscription(PointCloud2, args.input, self.on_cloud, qos)
            self.kept = self.total = self.clouds = 0

        def on_cloud(self, msg):
            pts = np.frombuffer(msg.data, dtype=dtype_of(msg))
            x = pts["x"].astype(np.float64) - ox
            y = pts["y"].astype(np.float64) - oy

            # Offset each bearing from the window start and wrap into [0, 2pi).
            # Comparing against lo and hi separately breaks for any window that
            # straddles +/-180, which is most rear-facing ones.
            rel = (np.arctan2(y, x) - lo) % (2.0 * math.pi)
            mask = rel <= width
            horiz_sq = x * x + y * y
            if math.isfinite(args.max_range):
                mask &= horiz_sq <= args.max_range ** 2
            if min_el > -math.pi / 2 or max_el < math.pi / 2:
                el = np.arctan2(pts["z"].astype(np.float64) - oz, np.sqrt(horiz_sq))
                mask &= (el >= min_el) & (el <= max_el)

            kept = pts[mask]
            if args.emit_xyzirc:
                kept = to_xyzirc(kept)
            if thin and kept.shape[0]:
                # Uniform random thinning, not every Nth point: the clouds arrive
                # in scan order, so a stride would delete whole rings or whole
                # azimuth slices and change the pattern rather than the density.
                kept = kept[rng.random(kept.shape[0]) < args.keep_fraction]
            out = PointCloud2()
            out.header = msg.header
            out.height = 1
            out.width = int(kept.shape[0])
            if args.emit_xyzirc:
                out.fields = xyzirc_fields(PointField)
                out.point_step = XYZIRC_DTYPE.itemsize
            else:
                out.fields = msg.fields
                out.point_step = msg.point_step
            out.is_bigendian = msg.is_bigendian
            out.row_step = out.point_step * out.width
            out.is_dense = msg.is_dense
            out.data = kept.tobytes()
            self.pub.publish(out)

            self.kept += out.width
            self.total += pts.shape[0]
            self.clouds += 1
            if self.clouds % 50 == 0:
                self.get_logger().info(
                    f"{self.clouds} clouds, kept {100.0 * self.kept / max(self.total, 1):.1f}% "
                    f"of points in bearing [{args.min_bearing:.0f}, {args.max_bearing:.0f}] deg")

    rclpy.init()
    node = Restrict()
    node.get_logger().info(
        f"restricting {args.input} -> {args.output}: bearing "
        f"[{args.min_bearing:.0f}, {args.max_bearing:.0f}] deg, elevation "
        f"[{args.min_elevation:.0f}, {args.max_elevation:.0f}] deg, range {args.max_range} m, "
        f"keeping {100.0 * args.keep_fraction:.0f}% about mount {args.origin}")
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
