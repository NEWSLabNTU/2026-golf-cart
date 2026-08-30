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

"""Bake a restricted field of view into a copy of a bag, offline.

    python3 scripts/localization/fov_bake_bag.py <in_bag> <out_bag> \\
        --topic /sensing/lidar/os0/pointcloud_raw \\
        --min-bearing -60 --max-bearing 60 \\
        --min-elevation -35 --max-elevation 35 --max-range 70

Same geometry as fov_restrict_node.py, applied ahead of time instead of live.

**This exists because the live filter invalidated its own measurements.** It is a
Python node passing every point of a 2048x128 cloud at 10 Hz, and it cannot: on
the TIERS OS0 data the unrestricted run fell to 5 Hz while a 120 degree run held
10 Hz simply by having a quarter of the points to move. Scored against an
external reference, the runs that kept the most points were the ones that lost
localization -- an ordering produced by the harness, not by the field of view.
The measured spread was 19.8 m of median error for the full FOV against 0.07 m
for the restricted one, which is the opposite of the expected result and was
entirely an artifact.

Baking removes it. Every run then plays a bag at the same rate through the same
pipeline, and the only difference between them is the one under study.

Clouds are re-encoded to Autoware's PointXYZIRC, which its crop box requires and
an Ouster driver does not produce.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

XYZIRC = np.dtype({
    "names": ["x", "y", "z", "intensity", "return_type", "channel"],
    "formats": [np.float32, np.float32, np.float32, np.uint8, np.uint8, np.uint16],
    "offsets": [0, 4, 8, 12, 13, 14],
    "itemsize": 16,
})


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
    ap.add_argument("source", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("--topic", required=True, help="cloud topic to restrict")
    ap.add_argument("--min-bearing", type=float, default=-180.0)
    ap.add_argument("--max-bearing", type=float, default=180.0)
    ap.add_argument("--extra-window", action="append", default=[], metavar="MIN,MAX",
                    help="keep a second (or third) bearing wedge as well. "
                         "Emulates a rig with more than one sensor, which is the "
                         "direct test of whether the narrow-FOV penalty is an "
                         "uncancelled bias: two opposed wedges see the same total "
                         "solid angle as one wide one but from opposite sides.")
    ap.add_argument("--min-elevation", type=float, default=-90.0)
    ap.add_argument("--max-elevation", type=float, default=90.0)
    ap.add_argument("--max-range", type=float, default=float("inf"))
    ap.add_argument("--origin", type=float, nargs=3, default=(0.0, 0.0, 0.0),
                    metavar=("X", "Y", "Z"))
    ap.add_argument("--keep-fraction", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--max-rings", type=int, default=0,
                    help="thin to this many evenly spaced rings, 0 to keep all. "
                         "Emulates a sensor with fewer laser lines, which "
                         "--keep-fraction cannot: that thins within every ring "
                         "and leaves the vertical sampling untouched.")
    args = ap.parse_args()

    from rosbags.highlevel import AnyReader
    from rosbags.rosbag2 import Writer
    from rosbags.typesys import Stores, get_typestore

    if args.dest.exists():
        print(f"{args.dest} exists; refusing to overwrite", file=sys.stderr)
        return 1

    typestore = get_typestore(Stores.ROS2_HUMBLE)
    PointField = typestore.types["sensor_msgs/msg/PointField"]

    def as_window(lo_deg, hi_deg):
        lo_r = math.radians(lo_deg)
        hi_r = math.radians(hi_deg)
        # Wrap only a non-positive difference, so a full circle stays 2pi
        # instead of collapsing to zero and discarding everything.
        w = hi_r - lo_r
        while w <= 0.0:
            w += 2.0 * math.pi
        return lo_r, w

    windows = [as_window(args.min_bearing, args.max_bearing)]
    for spec in args.extra_window:
        a, _, b = spec.partition(",")
        windows.append(as_window(float(a), float(b)))
    lo, width = windows[0]
    min_el, max_el = math.radians(args.min_elevation), math.radians(args.max_elevation)
    ox, oy, oz = args.origin
    rng = np.random.default_rng(args.seed)

    fields = [
        PointField(name="x", offset=0, datatype=7, count=1),
        PointField(name="y", offset=4, datatype=7, count=1),
        PointField(name="z", offset=8, datatype=7, count=1),
        PointField(name="intensity", offset=12, datatype=2, count=1),
        PointField(name="return_type", offset=13, datatype=2, count=1),
        PointField(name="channel", offset=14, datatype=4, count=1),
    ]

    # Which rings survive is decided once, from the first cloud, and reused. A
    # per-cloud decision would let the surviving set drift between frames and
    # emulate a sensor whose lasers move, which is not a sensor.
    ring_keep = None

    kept_total = seen_total = clouds = 0
    with AnyReader([args.source]) as reader, Writer(args.dest) as writer:
        out_conns = {}
        for c in reader.connections:
            if c.topic not in out_conns:
                out_conns[c.topic] = writer.add_connection(
                    c.topic, c.msgtype, typestore=typestore)

        for conn, stamp, raw in reader.messages():
            msg = reader.deserialize(raw, conn.msgtype)
            if conn.topic == args.topic:
                pts = np.frombuffer(msg.data, dtype=cloud_dtype(msg))
                x = pts["x"].astype(np.float64) - ox
                y = pts["y"].astype(np.float64) - oy
                horiz_sq = x * x + y * y

                bearing = np.arctan2(y, x)
                mask = np.zeros(bearing.shape, dtype=bool)
                for w_lo, w_width in windows:
                    mask |= ((bearing - w_lo) % (2.0 * math.pi)) <= w_width
                if math.isfinite(args.max_range):
                    mask &= horiz_sq <= args.max_range ** 2
                if min_el > -math.pi / 2 or max_el < math.pi / 2:
                    el = np.arctan2(pts["z"].astype(np.float64) - oz, np.sqrt(horiz_sq))
                    mask &= (el >= min_el) & (el <= max_el)
                if args.max_rings > 0 and "ring" in (pts.dtype.names or ()):
                    if ring_keep is None:
                        # Evenly spaced across the rings that survive the
                        # elevation crop, so the emulated sensor's lines are
                        # spread over its field of view rather than bunched at
                        # one edge of the source's.
                        present = np.unique(pts["ring"][mask])
                        if present.size > args.max_rings:
                            idx = np.linspace(0, present.size - 1, args.max_rings)
                            ring_keep = set(present[np.round(idx).astype(int)].tolist())
                        else:
                            ring_keep = set(present.tolist())
                        print(f"  rings: {present.size} in band -> keeping "
                              f"{len(ring_keep)}", flush=True)
                    mask &= np.isin(pts["ring"], list(ring_keep))

                sel = pts[mask]
                if args.keep_fraction < 1.0 and sel.shape[0]:
                    sel = sel[rng.random(sel.shape[0]) < args.keep_fraction]

                out = np.zeros(sel.shape[0], dtype=XYZIRC)
                for axis in ("x", "y", "z"):
                    out[axis] = sel[axis]
                names = pts.dtype.names or ()
                if "intensity" in names:
                    out["intensity"] = np.clip(sel["intensity"], 0, 255).astype(np.uint8)
                if "ring" in names:
                    out["channel"] = sel["ring"].astype(np.uint16)

                msg.fields = fields
                msg.point_step = XYZIRC.itemsize
                msg.height = 1
                msg.width = int(out.shape[0])
                msg.row_step = msg.point_step * msg.width
                msg.data = np.frombuffer(out.tobytes(), dtype=np.uint8)

                seen_total += pts.shape[0]
                kept_total += out.shape[0]
                clouds += 1
                if clouds % 200 == 0:
                    print(f"  {clouds} clouds, keeping "
                          f"{100.0 * kept_total / max(seen_total, 1):.1f}%", flush=True)

            writer.write(out_conns[conn.topic], stamp,
                         typestore.serialize_cdr(msg, conn.msgtype))

    print(f"wrote {args.dest}: {clouds} clouds, kept "
          f"{100.0 * kept_total / max(seen_total, 1):.1f}% of points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
