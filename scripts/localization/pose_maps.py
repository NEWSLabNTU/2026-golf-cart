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

"""Per-map initial poses: where they live, and whether one fits the map.

A pose only means something in the frame of the map it was captured on. r01 and
r02 share the MGRS grid 51RUH, so a pose from one is a valid-looking number in
the other and would be accepted without complaint, then sent to NDT a few
hundred metres from any point it can match. Two checks stop that:

  - the pose must fall inside the map's lanelet extent (plus a margin), read
    from the `local_x` / `local_y` tags of its lanelet2_map.osm;
  - the running stack's point cloud map loader must have loaded this map's
    directory, read from its `pcd_paths_or_directory` parameter.

    config/initial_poses/<map>/map.yaml   map_path: data/...   (repo-relative)
                                          extent: [x0, y0, x1, y1]   (optional)
    config/initial_poses/<map>/<spot>.yaml                     one captured pose
"""

from __future__ import annotations

import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
POSES_DIR = os.path.join(REPO, "config", "initial_poses")

# Metres beyond the outermost lanelet node a pose may sit. A start spot in a
# parking bay or a building entrance can be off the drivable network.
EXTENT_MARGIN = 30.0


def map_dir(name: str) -> str:
    return os.path.join(POSES_DIR, name)


def known_maps() -> list[str]:
    if not os.path.isdir(POSES_DIR):
        return []
    return sorted(d for d in os.listdir(POSES_DIR)
                  if os.path.isfile(os.path.join(POSES_DIR, d, "map.yaml")))


def map_path(name: str) -> str:
    """Absolute data directory of a map, from its map.yaml."""
    import yaml
    with open(os.path.join(map_dir(name), "map.yaml"), encoding="utf-8") as f:
        rel = yaml.safe_load(f)["map_path"]
    return os.path.normpath(os.path.join(REPO, rel))


def extent(name: str):
    """(min_x, min_y, max_x, max_y) a pose must fall in, or None.

    From map.yaml's `extent` when given, for a map whose lanelets cover less
    than the area a start spot can be in; else from the lanelet nodes.
    """
    import yaml
    with open(os.path.join(map_dir(name), "map.yaml"), encoding="utf-8") as f:
        box = yaml.safe_load(f).get("extent")
    if box:
        return tuple(float(v) for v in box)
    osm = os.path.join(map_path(name), "lanelet2_map.osm")
    if not os.path.exists(osm):
        return None
    xs, ys = [], []
    tag = re.compile(r'<tag k="local_([xy])" v="([-0-9.eE+]+)"')
    with open(osm, encoding="utf-8") as f:
        for axis, value in tag.findall(f.read()):
            (xs if axis == "x" else ys).append(float(value))
    if not xs or not ys:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def check_extent(name: str, x: float, y: float) -> str | None:
    """None if (x, y) is inside the map, else a message saying why not."""
    box = extent(name)
    if box is None:
        return None
    x0, y0, x1, y1 = box
    m = EXTENT_MARGIN
    if x0 - m <= x <= x1 + m and y0 - m <= y <= y1 + m:
        return None
    return (f"pose ({x:.1f}, {y:.1f}) is outside map {name} "
            f"(x {x0:.0f}..{x1:.0f}, y {y0:.0f}..{y1:.0f}, margin {m:.0f} m)")


def loaded_map(node, timeout: float = 3.0) -> str | None:
    """The directory the running stack's point cloud map loader was given."""
    import rclpy
    from rcl_interfaces.srv import GetParameters

    client = node.create_client(GetParameters, "/map/pointcloud_map_loader/get_parameters")
    if not client.wait_for_service(timeout_sec=timeout):
        return None
    req = GetParameters.Request()
    req.names = ["pcd_paths_or_directory"]
    future = client.call_async(req)
    rclpy.spin_until_future_complete(node, future, timeout_sec=timeout)
    if not future.result() or not future.result().values:
        return None
    paths = list(future.result().values[0].string_array_value)
    if not paths:
        return None
    p = os.path.realpath(paths[0])
    return p if os.path.isdir(p) else os.path.dirname(p)
