#!/usr/bin/env python3
"""Derive the twin demo's RViz config from the cart's own NTU config.

    python3 make_twin_rviz.py [BASE.rviz] [OUT.rviz]

BASE defaults to golfcart_launch/rviz/golfcart_ntu.rviz in this repository, OUT to
twin_demo.rviz beside this script. Only the differences below are applied; everything else
(panels, tools, plugin settings) is the base's, so the two stay in step when the base moves.
Needs PyYAML.
"""
import math
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
BASE = REPO / "src/launcher/golfcart_launch/rviz/golfcart_ntu.rviz"

# the T junction in front of Xue Xin Guan, map frame; the view's height covers about 70 m
FOCUS = (53014.0, 67870.0, 0.0)
VIEW_DISTANCE = 85.0          # 2 * 85 * tan(fov / 2) with RViz's 45 deg vertical fov: 70 m

# the opening view follows the cart from behind and above: the whole cart, its lidar returns
# around it and the road ahead (FOLLOW_AHEAD m ahead of base_link is the view's centre)
FOLLOW_DISTANCE = 26.0
FOLLOW_PITCH = 0.85           # rad above the horizon
FOLLOW_AHEAD = 1.5            # the cart's body runs 0.8 m behind base_link to 2.5 m ahead of it

RIGHT_DOCK = {"rviz_common/Displays", "rviz_common/Views", "rviz_common/Tool Properties",
              "rviz_common/Selection"}

ZED_TOPIC = "/sensing/camera/zed/rgb/color/rect/image"

# displays the demo does not need, by name: debug output, other sites' helpers, clutter
OFF = {
    "PolarGridDisplay", "BoardOutline", "MonteCarloInitialPose", "NoGroundPointCloud",
    "TrafficLight", "RecognitionResultOnImage", "MapBasedDetectionResult",
    "PartialPoseArray", "PoseArray", "PlanningErrorMarker", "DebugMarker",
    "Resampled Reference Trajectory", "Stop Reason", "Predicted Trajectory",
}
# lane-change and other candidate paths: the demo's roads have one lane each way
OFF_PREFIXES = ("PathChangeCandidate", "(old)PathChangeCandidate")
# displays the demo turns on
ON = {"TF", "Aligned"}


def walk(displays, fn, path=""):
    for d in displays or []:
        fn(d, path)
        walk(d.get("Displays"), fn, path + "/" + d.get("Name", ""))


def topic(d):
    t = d.get("Topic")
    return t.get("Value") if isinstance(t, dict) else t


def edit(d, path):
    name = d.get("Name", "")
    if name in OFF or name.startswith(OFF_PREFIXES):
        d["Enabled"] = False
        d["Value"] = False
    if name in ON:
        d["Enabled"] = True
        d["Value"] = True
    t = topic(d) or ""
    # the planners' own debug markers (virtual walls and planning factors stay: they explain a stop)
    if "/debug/" in t and "virtual_wall" not in t and d["Class"] != "rviz_plugins/Trajectory":
        d["Enabled"] = False
        d["Value"] = False
    if name == "TF":                      # frames only, no names or arrows: the cart's tree is dense
        d.update({"Show Names": False, "Show Arrows": False, "Marker Scale": 0.6})
    if name == "ConcatenatePointCloud":   # the cart's lidars, coloured by intensity, over the map
        d.update({"Color Transformer": "Intensity", "Channel Name": "intensity", "Use rainbow": True,
                  "Autocompute Intensity Bounds": True, "Size (Pixels)": 3, "Alpha": 1.0})
    if name == "PointCloudMap":           # the map dimmed to a backdrop: the live lidar stands out
        d.update({"Color": "120; 120; 120", "Size (Pixels)": 1, "Alpha": 0.4})
    if name == "Aligned":                 # what NDT matched against the map, in green
        d.update({"Size (Pixels)": 3, "Size (m)": 0.08, "Style": "Points", "Alpha": 0.8})
        d["Topic"]["Reliability Policy"] = "Best Effort"


def zed_image():
    # named "Image" so it takes the base window's existing "Image" dock slot
    return {"Class": "rviz_default_plugins/Image", "Enabled": True, "Name": "Image", "Value": True,
            "Max Value": 1, "Min Value": 0, "Median window": 5, "Normalize Range": True,
            "Topic": {"Depth": 1, "Durability Policy": "Volatile", "History Policy": "Keep Last",
                      "Reliability Policy": "Best Effort", "Value": ZED_TOPIC}}


def view(name):
    x, y, z = FOCUS
    return {"Class": "rviz_default_plugins/Orbit", "Name": name, "Value": "Orbit (rviz_default_plugins)",
            "Distance": VIEW_DISTANCE, "Enable Stereo Rendering": {"Stereo Eye Separation": 0.06,
            "Stereo Focal Distance": 1, "Swap Stereo Eyes": False, "Value": False},
            "Focal Point": {"X": x, "Y": y, "Z": z}, "Focal Shape Fixed Size": True, "Focal Shape Size": 0.05,
            "Invert Z Axis": False, "Near Clip Distance": 0.01,
            "Pitch": 1.5597,              # straight down (RViz caps pitch just under pi/2)
            "Yaw": -math.pi / 2,          # north up
            "Target Frame": "map"}


def follow(name):
    return {"Class": "rviz_default_plugins/ThirdPersonFollower", "Name": name,
            "Value": "ThirdPersonFollower (rviz_default_plugins)", "Distance": FOLLOW_DISTANCE,
            "Enable Stereo Rendering": {"Stereo Eye Separation": 0.06, "Stereo Focal Distance": 1,
            "Swap Stereo Eyes": False, "Value": False},
            "Focal Point": {"X": FOLLOW_AHEAD, "Y": 0.0, "Z": 0.0}, "Focal Shape Fixed Size": True,
            "Focal Shape Size": 0.05, "Invert Z Axis": False, "Near Clip Distance": 0.01,
            "Pitch": FOLLOW_PITCH, "Yaw": math.pi,   # behind the cart, looking along its heading
            "Target Frame": "base_link"}


def main():
    base = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else HERE / "twin_demo.rviz"
    d = yaml.safe_load(base.read_text())
    vm = d["Visualization Manager"]
    vm["Global Options"]["Fixed Frame"] = "map"
    walk(vm["Displays"], edit)
    sensing = next(g for g in vm["Displays"] if g.get("Name") == "Sensing")
    sensing["Displays"].append(zed_image())
    vm["Views"]["Current"] = follow("Current View")
    vm["Views"]["Saved"] = [follow("Follow the cart"), view("Twin T junction")] + (vm["Views"].get("Saved") or [])
    d["Window Geometry"]["Image"] = {"collapsed": False}
    # the right dock's panels closed: the 3D view takes their room. (Hide Right Dock only
    # collapses them in rviz2, and they still showed.) Panels > Add New Panel brings any back
    d["Panels"] = [q for q in d["Panels"] if q.get("Class") not in RIGHT_DOCK]
    out.write_text("# Generated by make_twin_rviz.py from golfcart_launch/rviz/golfcart_ntu.rviz; edit the script, not this file.\n"
                   + yaml.safe_dump(d, sort_keys=False, allow_unicode=True, width=200))
    print("wrote", out)


if __name__ == "__main__":
    main()
