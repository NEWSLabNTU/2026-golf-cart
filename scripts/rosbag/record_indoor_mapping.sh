#!/usr/bin/env bash
# record_indoor_mapping.sh — Record the indoor mapping run for phase 3B.
#
# Feeds two consumers with one drive:
#   * GLIM offline LiDAR-inertial SLAM  -> PCD map        (LiDAR + IMU)
#   * Phase 3C tag-map bootstrap        -> Lanelet2 tags  (cameras)
#
# See docs/design/indoor_pcd_mapping_reflector_anchor.md §6.1 and
# docs/roadmaps/3-indoor-b-indoor-mapping.md.
#
# What this adds over `just bag record` is the pre-drive checklist and the bag
# name, nothing else. The topics are this host's config/recording list, via
# scripts/recording/record_foreground.sh. The inline list this script used to
# carry named /sensing/lidar/top/pointcloud_raw_ex and
# /sensing/lidar/velodyne_packets, neither of which exists; the list records
# /sensing/lidar/vlp32/velodyne_points (the driver's cloud, which carries the
# intensity the board detector needs and the per-point time GLIM deskews with)
# and /sensing/lidar/vlp32/velodyne_packets.
#
# The list's GNSS topics come along and record nothing indoors. That is the
# list's own rule: an empty topic says the device was expected and was silent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

cat <<EOF
Recording indoor mapping bag.

Before starting, confirm:
  * The reflective board is mounted and will stay mounted. It defines the map
    origin; moving it later invalidates the map without any visible error.
  * Tags for phase 3C are in place.
  * The route closes its loops, and passes the board at the start, mid-run,
    and end.
  * Speed stays at or below 1 m/s, with smooth steering.
  * No pedestrians in the space — they survive into the map as smeared walls.

EOF

exec "${REPO_ROOT}/scripts/recording/record_foreground.sh" indoor_mapping
