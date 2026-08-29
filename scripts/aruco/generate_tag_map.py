#!/usr/bin/env python3
# Copyright 2026 NEWSLab, National Taiwan University
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

"""Place ArUco boards along a lanelet2 map's lanes, in facing pairs.

This exists because the layout rules are not obvious and were learned the hard
way on the bench fixture. See aruco_sim_detector/config/bench_tag_map.yaml for
the full account; the short version is:

* A board flat on a wall is init-eligible only while it is roughly 2 to 4 m
  away, a window about 2 m long, because the view angle must sit between
  min_view_angle_deg and the stricter initialization limit.
* Initialization needs TWO boards inside that window at the same moment, with
  different normals. Boards staggered along one side never manage it: each
  enters and leaves the window alone.
* So boards go in facing pairs at matching positions on opposite sides, which
  also gives the widest possible spread of normals.
* Corners are where coverage fails. A layout planned along the straights leaves
  the turn unseen, and the vehicle crosses it DEGRADED with no heading
  correction. Placing at a fixed arclength interval, as this does, follows the
  lane through its curves and closes that hole by construction.

The output is a tag map in the localizer's format, and it is a FIXTURE. Nothing
here is surveyed; the poses are exact by construction because the simulator
places its boards from this same file.
"""

import argparse
import math
import xml.etree.ElementTree as ET
from pathlib import Path

import pyproj


def parse_nodes(root, projector):
    """Map every OSM node id to local metres in the map frame."""
    nodes = {}
    for node in root.findall("node"):
        lat = float(node.get("lat"))
        lon = float(node.get("lon"))
        elevation = 0.0
        for tag in node.findall("tag"):
            if tag.get("k") == "ele":
                elevation = float(tag.get("v"))
        easting, northing = projector(lon, lat)
        nodes[node.get("id")] = (easting, northing, elevation)
    return nodes


def mgrs_projector(grid):
    """Autoware's MGRS frame: metres within the named 100 km square."""
    zone = int(grid[:2])
    proj = pyproj.Proj(proj="utm", zone=zone, ellps="WGS84", preserve_units=False)

    def project(lon, lat):
        easting, northing = proj(lon, lat)
        return easting % 100000.0, northing % 100000.0

    return project


def lane_centrelines(root, nodes):
    """Centreline of every lanelet, as a list of points in the map frame.

    A lanelet is a relation with a left and a right way. The centreline is the
    midpoint of the two, sampled at whichever boundary has more points, which
    keeps curves from being cut short.
    """
    ways = {}
    for way in root.findall("way"):
        points = [nodes[ref.get("ref")] for ref in way.findall("nd") if ref.get("ref") in nodes]
        if points:
            ways[way.get("id")] = points

    centrelines = []
    for relation in root.findall("relation"):
        kinds = {tag.get("k"): tag.get("v") for tag in relation.findall("tag")}
        if kinds.get("subtype") != "road":
            continue
        sides = {}
        for member in relation.findall("member"):
            if member.get("role") in ("left", "right") and member.get("ref") in ways:
                sides[member.get("role")] = ways[member.get("ref")]
        if "left" not in sides or "right" not in sides:
            continue

        left, right = sides["left"], sides["right"]
        samples = max(len(left), len(right))
        centre = []
        for index in range(samples):
            a = left[min(index * len(left) // samples, len(left) - 1)]
            b = right[min(index * len(right) // samples, len(right) - 1)]
            centre.append(((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, (a[2] + b[2]) / 2))
        if len(centre) >= 2:
            centrelines.append(centre)
    return centrelines


def longest_path(centrelines):
    """The single longest lanelet chain, which is route enough for a smoke test."""
    def length(points):
        return sum(
            math.dist(points[i][:2], points[i + 1][:2]) for i in range(len(points) - 1)
        )

    return max(centrelines, key=length) if centrelines else []


def resample(points, spacing):
    """Points every `spacing` metres along the polyline, with local heading."""
    output = []
    carried = 0.0
    for index in range(len(points) - 1):
        start, end = points[index], points[index + 1]
        segment = math.dist(start[:2], end[:2])
        if segment < 1e-6:
            continue
        heading = math.atan2(end[1] - start[1], end[0] - start[0])
        travelled = spacing - carried if carried else 0.0
        while travelled <= segment:
            fraction = travelled / segment
            output.append(
                (
                    start[0] + (end[0] - start[0]) * fraction,
                    start[1] + (end[1] - start[1]) * fraction,
                    start[2] + (end[2] - start[2]) * fraction,
                    heading,
                )
            )
            travelled += spacing
        carried = (segment - (travelled - spacing)) % spacing
    return output


def board_corners(centre, normal, size):
    """Four corners, in the order the detector reports them.

    ArUco gives corners top-left, top-right, bottom-right, bottom-left as seen
    from the camera, so `right` is up x normal with the normal pointing back at
    the viewer.
    """
    half = size / 2.0
    up = (0.0, 0.0, 1.0)
    right = (
        up[1] * normal[2] - up[2] * normal[1],
        up[2] * normal[0] - up[0] * normal[2],
        up[0] * normal[1] - up[1] * normal[0],
    )
    def corner(right_sign, up_sign):
        return [
            round(centre[i] + right_sign * right[i] * half + up_sign * up[i] * half, 3)
            for i in range(3)
        ]

    return [corner(-1, 1), corner(1, 1), corner(1, -1), corner(-1, -1)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("map", type=Path, help="lanelet2_map.osm")
    parser.add_argument("--mgrs-grid", default="54SVE")
    parser.add_argument("--spacing", type=float, default=3.0,
                        help="metres between facing pairs")
    parser.add_argument("--offset", type=float, default=3.0,
                        help="lateral distance from the lane centre to each board")
    parser.add_argument("--height", type=float, default=1.5)
    parser.add_argument("--marker-size", type=float, default=0.384)
    parser.add_argument("--limit", type=int, default=0,
                        help="stop after this many pairs, 0 for no limit")
    arguments = parser.parse_args()

    root = ET.parse(arguments.map).getroot()
    nodes = parse_nodes(root, mgrs_projector(arguments.mgrs_grid))
    path = longest_path(lane_centrelines(root, nodes))
    if not path:
        raise SystemExit("no road lanelets with both boundaries found")

    stations = resample(path, arguments.spacing)
    if arguments.limit:
        stations = stations[: arguments.limit]

    tags = []
    for index, (x, y, z, heading) in enumerate(stations):
        # Left of travel and right of travel, each facing back across the lane.
        left_normal = (math.sin(heading), -math.cos(heading), 0.0)
        right_normal = (-math.sin(heading), math.cos(heading), 0.0)
        left_centre = (x - arguments.offset * left_normal[0],
                       y - arguments.offset * left_normal[1],
                       z + arguments.height)
        right_centre = (x - arguments.offset * right_normal[0],
                        y - arguments.offset * right_normal[1],
                        z + arguments.height)
        tags.append((100 + index, left_centre, left_normal))
        tags.append((200 + index, right_centre, right_normal))

    print("# Generated by scripts/aruco/generate_tag_map.py. Do not hand-edit.")
    print("#")
    print(f"# Source map: {arguments.map}")
    print(f"# Facing pairs every {arguments.spacing} m, {arguments.offset} m from the lane")
    print(f"# centre, {arguments.height} m above it. {len(tags)} boards over "
          f"{len(stations)} stations.")
    print("#")
    print("# A FIXTURE, not a survey: the simulator places its boards from this same")
    print("# file, so the poses are exact by construction and prove nothing about how")
    print("# a hand-measured map would behave.")
    print("frame_id: map")
    print()
    print("survey:")
    print('  date: "2026-08-30"')
    print('  method: "GENERATED FROM LANELET2 CENTRELINES -- not a real survey"')
    print("  stated_accuracy: 0.0")
    print()
    print("defaults:")
    print("  dictionary: DICT_5X5_1000")
    print(f"  marker_size: {arguments.marker_size}")
    print()
    print("tags:")
    for identifier, centre, normal in tags:
        print(f"  - id: {identifier}")
        print(f"    # centre ({centre[0]:.2f}, {centre[1]:.2f}, {centre[2]:.2f}), "
              f"normal ({normal[0]:.2f}, {normal[1]:.2f}, 0)")
        print("    corners:")
        for point in board_corners(centre, normal, arguments.marker_size):
            print(f"      - [{point[0]:.3f}, {point[1]:.3f}, {point[2]:.3f}]")


if __name__ == "__main__":
    main()
