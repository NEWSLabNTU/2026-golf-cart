"""Command line front end for the map anchoring tool.

    anchor_map_to_board glim_export.ply -o data/huaxia-indoor

Writes the anchored cloud, the transform that produced it, the board's Lanelet2
polygon, and a map_projector_info.yaml declaring a local frame.
"""

import argparse
import os
import sys

from .anchor import (
    MAP_PROJECTOR_INFO,
    AnchorParams,
    anchor_cloud,
    anchored_board_centre,
    apply_transform,
    board_polygon_osm,
    transform_yaml,
)
from .config import default_config_path, load_anchor_config
from .pointcloud_io import read_cloud, write_pcd


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="anchor_map_to_board",
        description="Anchor a SLAM cloud to the retroreflective board.",
    )
    parser.add_argument("cloud", help="input .ply or .pcd from the SLAM run")
    parser.add_argument(
        "-o", "--output-dir", required=True, help="map directory to write"
    )
    parser.add_argument(
        "--name", default="pointcloud_map.pcd", help="anchored cloud filename"
    )
    parser.add_argument(
        "--config",
        default=default_config_path(),
        help="shared board_initializer.param.yaml (default: package config)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report the transform without writing anything",
    )
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)

    try:
        params, detector_params = load_anchor_config(args.config)
    except (OSError, ValueError) as error:
        print(f"error: cannot load config {args.config}: {error}", file=sys.stderr)
        return 2

    cloud = read_cloud(args.cloud)
    print(f"read {len(cloud)} points from {args.cloud}")
    if not cloud.has_intensity:
        print(
            "error: no intensity channel. The board cannot be found without it — "
            "check that the PLY-to-PCD conversion preserved the field.",
            file=sys.stderr,
        )
        return 2

    try:
        result = anchor_cloud(cloud, params, detector_params)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    detection = result.detection
    print(
        f"board found: {detection.n_points} points, "
        f"extents {detection.extents[0]:.2f} x {detection.extents[1]:.2f} m, "
        f"plane residual {detection.plane_residual * 100:.1f} cm"
    )
    print(f"floor tilt in the source frame: {result.floor_tilt_deg:.2f} deg")
    print("transform (map <- cloud):")
    for row in result.transform_map_cloud:
        print("  " + "  ".join(f"{v: 9.5f}" for v in row))

    anchored = apply_transform(cloud, result.transform_map_cloud)
    moved = anchored_board_centre(result)
    print(
        "board centre after anchoring: "
        f"[{moved[0]: .4f}, {moved[1]: .4f}, {moved[2]: .4f}] "
        f"(expected [{params.board_pose_in_map[0]}, {params.board_pose_in_map[1]}, "
        f"{params.board_pose_in_map[2]}])"
    )

    expected = params.board_pose_in_map[:3]
    if not all(abs(actual - wanted) <= 1e-3 for actual, wanted in zip(moved, expected)):
        print(
            f"error: anchoring did not place board at configured pose ({moved})",
            file=sys.stderr,
        )
        return 3

    if args.dry_run:
        print("dry run: nothing written")
        return 0

    os.makedirs(args.output_dir, exist_ok=True)
    cloud_path = os.path.join(args.output_dir, args.name)
    write_pcd(cloud_path, anchored)

    with open(os.path.join(args.output_dir, "map_projector_info.yaml"), "w") as handle:
        handle.write(MAP_PROJECTOR_INFO)
    with open(os.path.join(args.output_dir, "board_anchor.yaml"), "w") as handle:
        handle.write(transform_yaml(result, os.path.abspath(args.cloud)))
    with open(os.path.join(args.output_dir, "board_polygon.osm"), "w") as handle:
        handle.write(board_polygon_osm(params))

    print(f"wrote {cloud_path}")
    print("wrote map_projector_info.yaml, board_anchor.yaml, board_polygon.osm")
    print(
        "next: merge board_polygon.osm into the route's lanelet2_map.osm, then "
        "tile the cloud with autoware_pointcloud_divider"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
