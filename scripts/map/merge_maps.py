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

"""Merge two Autoware maps that share a projection into one.

    python3 scripts/map/merge_maps.py MAP_A MAP_B OUT

Each input is a directory holding `pointcloud_map.pcd` (or `*.pcd`),
`lanelet2_map.osm` and `map_projector_info.yaml`.

**Merging is only concatenation when the projections agree.** Both NTU maps
declare MGRS grid 51RUH, so their coordinates are already in one frame and the
point clouds can simply be appended — the numbers are directly comparable, which
the extent check below confirms rather than assumes. Two maps built on different
grids would need a transform, and this script refuses that case rather than
producing a plausible-looking wrong map.

The lanelet2 side is not concatenation. OSM ids are per-file, and here 40 node
ids appear in both maps meaning different points. Appending the XML would
silently merge those into whichever came last, moving lane boundaries by
hundreds of metres. Every id from the second map is therefore offset into a
disjoint range, references included.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys

import numpy as np

# Large enough to clear any id in a hand-built map, round enough to be obvious
# in a diff when someone wonders where an id came from.
ID_OFFSET = 1_000_000


# ── point cloud ─────────────────────────────────────────────────────────────


def read_pcd(path: str) -> tuple[np.ndarray, list[str]]:
    """Read a binary PCD with fields x y z intensity. Returns (Nx4, header)."""
    header_lines = []
    with open(path, "rb") as f:
        while True:
            line = f.readline()
            if not line:
                raise ValueError(f"{path}: no DATA line, truncated?")
            header_lines.append(line.decode("ascii", errors="replace"))
            if line.strip().startswith(b"DATA"):
                break
        header = "".join(header_lines)

        fields = re.search(r"FIELDS (.+)", header).group(1).split()
        if fields != ["x", "y", "z", "intensity"]:
            raise ValueError(f"{path}: unexpected FIELDS {fields}")
        data_format = re.search(r"DATA (\w+)", header).group(1)
        if data_format != "binary":
            raise ValueError(f"{path}: DATA {data_format}, only binary is handled")

        count = int(re.search(r"POINTS (\d+)", header).group(1))
        raw = f.read(count * 16)
        if len(raw) < count * 16:
            raise ValueError(f"{path}: expected {count} points, file is short")
        points = np.frombuffer(raw, dtype=np.float32, count=count * 4).reshape(count, 4)
    return points, header_lines


def write_pcd(path: str, points: np.ndarray) -> None:
    count = len(points)
    header = (
        "# .PCD v0.7 - Point Cloud Data file format\n"
        "VERSION 0.7\n"
        "FIELDS x y z intensity\n"
        "SIZE 4 4 4 4\n"
        "TYPE F F F F\n"
        "COUNT 1 1 1 1\n"
        f"WIDTH {count}\n"
        "HEIGHT 1\n"
        "VIEWPOINT 0 0 0 1 0 0 0\n"
        f"POINTS {count}\n"
        "DATA binary\n"
    )
    with open(path, "wb") as f:
        f.write(header.encode("ascii"))
        f.write(np.ascontiguousarray(points, dtype=np.float32).tobytes())


def find_pcd(map_dir: str) -> str:
    candidates = sorted(
        os.path.join(map_dir, n) for n in os.listdir(map_dir) if n.endswith(".pcd")
    )
    if not candidates:
        raise FileNotFoundError(f"{map_dir}: no .pcd file")
    # r01 ships 'pointcloud_map.pcd.pcd'; take whichever exists rather than
    # hard-coding a name that only matches one of the two inputs.
    return candidates[0]


def extents(points: np.ndarray) -> str:
    return "  ".join(
        f"{ax}[{points[:, i].min():.1f}, {points[:, i].max():.1f}]"
        for i, ax in enumerate("xyz")
    )


# ── lanelet2 ────────────────────────────────────────────────────────────────


def merge_lanelet2(path_a: str, path_b: str, out_path: str) -> tuple[int, int]:
    """Append map B's lanelet2 to map A's, with every id in B shifted clear.

    Parsed as XML rather than rewritten with regexes. The first version of this
    used pattern matching and silently missed `<member type=".." role=".." ref>`,
    because `role` sits between the two attributes it keyed on. Ids were offset,
    the references to them were not, and the merge produced 260 dangling
    references -- from two inputs that each had zero. XML has structure; parsing
    it is both shorter and the only version that cannot miss an attribute
    because of where it appears in a tag.
    """
    import xml.etree.ElementTree as ET

    tree_a = ET.parse(path_a)
    tree_b = ET.parse(path_b)
    root_a, root_b = tree_a.getroot(), tree_b.getroot()

    def element_ids(root):
        return {e.get("id") for tag in ("node", "way", "relation")
                for e in root.findall(tag)}

    collisions = len(element_ids(root_a) & element_ids(root_b))

    # Ids first, then every reference to one. Both live on `id` and `ref`
    # attributes, so a single pass over B covers them.
    for element in root_b.iter():
        for attr in ("id", "ref"):
            value = element.get(attr)
            if value is not None:
                try:
                    element.set(attr, str(int(value) + ID_OFFSET))
                except ValueError:
                    pass  # non-numeric ids are not ours to renumber

    for child in list(root_b):
        root_a.append(child)

    tree_a.write(out_path, encoding="UTF-8", xml_declaration=True)
    return collisions, ID_OFFSET


# ── projection ──────────────────────────────────────────────────────────────


def read_projector(map_dir: str) -> dict:
    path = os.path.join(map_dir, "map_projector_info.yaml")
    info = {}
    for line in open(path, encoding="utf-8"):
        if ":" in line:
            k, _, v = line.partition(":")
            info[k.strip()] = v.strip()
    return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("map_a")
    parser.add_argument("map_b")
    parser.add_argument("out")
    args = parser.parse_args()

    info_a, info_b = read_projector(args.map_a), read_projector(args.map_b)
    if info_a != info_b:
        print("the two maps do not share a projection:", file=sys.stderr)
        print(f"  {args.map_a}: {info_a}", file=sys.stderr)
        print(f"  {args.map_b}: {info_b}", file=sys.stderr)
        print("\nConcatenating them would place one map in the other's frame.",
              file=sys.stderr)
        return 2
    print(f"projection matches on both maps: {info_a}")

    os.makedirs(args.out, exist_ok=True)

    pa, _ = read_pcd(find_pcd(args.map_a))
    pb, _ = read_pcd(find_pcd(args.map_b))
    print(f"  A {len(pa):>9,} pts   {extents(pa)}")
    print(f"  B {len(pb):>9,} pts   {extents(pb)}")

    merged = np.vstack([pa, pb])
    out_pcd = os.path.join(args.out, "pointcloud_map.pcd")
    write_pcd(out_pcd, merged)
    print(f"  = {len(merged):>9,} pts   {extents(merged)}  -> {out_pcd}")

    collisions, offset = merge_lanelet2(
        os.path.join(args.map_a, "lanelet2_map.osm"),
        os.path.join(args.map_b, "lanelet2_map.osm"),
        os.path.join(args.out, "lanelet2_map.osm"),
    )
    print(f"  lanelet2: {collisions} colliding ids resolved by offsetting map B by {offset:,}")

    shutil.copy(os.path.join(args.map_a, "map_projector_info.yaml"),
                os.path.join(args.out, "map_projector_info.yaml"))
    print(f"  projector info copied -> {args.out}/map_projector_info.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
